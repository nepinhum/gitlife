module cache

import os
import credentials
import gitrepo
import source

pub struct Cache {
pub:
	root string // <XDG cache>/gitlife/repos
	git  gitrepo.Git
	exe  string // gitlife's own path, git can call back for credentials
}

pub struct Entry {
pub:
	dir    string
	cloned bool // true when this call created the clone rather than updating it
	// filtered records whether blob filtering was asked for and not refused.
	// Git writes the filter into the clone's config even when the server ignored it.
	filtered bool
}

// ensure returns a local bare repository for 'url', cloning it the first time and
// fetching it afterwards.
//
// 'env' carries the credential to git. It is never an argument: a token in argv is
// readable through 'ps' by every user on the machine.
pub fn (c Cache) ensure(url string, env map[string]string) !Entry {
	dir := c.path_for(url)
	if os.exists(os.join_path(dir, 'HEAD')) {
		c.fetch(dir, env)!
		return Entry{
			dir:      dir
			cloned:   false
			filtered: c.is_filtered(dir)
		}
	}
	os.mkdir_all(os.dir(dir))!
	filtered := c.clone(url, dir, env)!
	return Entry{
		dir:      dir
		cloned:   true
		filtered: filtered
	}
}

// path_for maps a remote to a stable, browsable directory: '<host>/<path>.git'.
//
// Every component is sanitized. The input is a URL from a provider or a user and
// a component of '..' would otherwise let a remote choose where on disk gitlife
// writes.
pub fn (c Cache) path_for(url string) string {
	normalized := source.normalize_url(url)
	mut parts := []string{}
	for part in normalized.all_after('://').split('/') {
		safe := sanitize(part)
		if safe != '' {
			parts << safe
		}
	}
	return os.join_path(c.root, parts.join(os.path_separator)) + '.git'
}

// clone reports whether blob filtering survived. A server too old to understand
// the filter rejects the request and the clone is retried without it. A modern
// one warns and sends everything anyway, which is worth recording: the clone is
// then full size.
fn (c Cache) clone(url string, dir string, env map[string]string) !bool {
	// Always redacted. Credentials reach git through its credential protocol.
	address := source.redact_url(url)
	parent := os.dir(dir)
	result := c.git.at_with(parent, c.args(['clone', '--mirror', '--filter=blob:none', address,
		dir]), env) or {
		os.rmdir_all(dir) or {}
		c.git.at_with(parent, c.args(['clone', '--mirror', address, dir]), env)!
		return false
	}
	return !result.stderr.contains('filtering not recognized')
}

// fetch replaces the cached refs with the remote's. '--prune' is what makes a
// deleted branch stop counting.
fn (c Cache) fetch(dir string, env map[string]string) ! {
	c.git.at_with(dir, c.args(['fetch', '--prune']), env)!
}

// args puts the credential bridge in front of every remote operation. The reset
// comes first and is not optional: without it an ambient credential helper, a
// keychain or a stale token, answers before gitlife is asked.
fn (c Cache) args(rest []string) []string {
	mut all := credentials.helper_args(c.exe)
	all << rest
	return all
}

fn (c Cache) is_filtered(dir string) bool {
	result := c.git.at_with(dir, ['config', '--get', 'remote.origin.partialclonefilter'],
		map[string]string{}) or { return false }
	return result.stdout.trim_space() != ''
}

fn sanitize(part string) string {
	// '.' and '..' are meaningful to the filesystem and must never survive as
	// themselves, whatever else they contain.
	if part == '.' || part == '..' {
		return '_'
	}
	mut out := []u8{cap: part.len}
	for ch in part {
		if (ch >= `a` && ch <= `z`) || (ch >= `A` && ch <= `Z`)
			|| (ch >= `0` && ch <= `9`) || ch in [`.`, `_`, `-`] {
			out << ch
		} else {
			out << `_`
		}
	}
	return out.bytestr()
}
