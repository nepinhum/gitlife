module gitrepo

import crypto.sha256
import proc

// Fields are newline separated, eleven per commit. Git strips CR and LF from
// ident names and emails and %s flattens the subject to a single line.
// NUL separation would be stricter but V's process capture truncates at the
// first NUL byte.
const commit_format = '%H%n%P%n%an%n%ae%n%at%n%az%n%cn%n%ce%n%ct%n%cz%n%s'

const commit_fields = 11

pub struct Commit {
pub:
	object_id       string
	parents         string // space separated oids, exactly as git prints them
	author_name     string
	author_email    string
	author_time     i64 // epoch seconds, UTC
	author_tz       int // offset from UTC in minutes
	committer_name  string
	committer_email string
	committer_time  i64
	committer_tz    int
	subject         string
}

pub struct Scan {
pub:
	object_format string
	refs_digest   string
	commits       []Commit
}

pub struct Git {
pub:
	exe string
}

pub fn find() !Git {
	return Git{
		exe: proc.find('git')!
	}
}

fn (g Git) at(dir string, args []string) !proc.Result {
	return g.at_with(dir, args, map[string]string{})
}

// at_with runs git with extra environment variables. That is the channel a
// credential travels through.
pub fn (g Git) at_with(dir string, args []string, extra map[string]string) !proc.Result {
	return proc.check(proc.Cmd{
		exe:  g.exe
		args: args
		cwd:  dir
		env:  git_env(extra)
	})
}

// object_format is sha1 or sha256. A repository whose format we don't understand
// is an explicit failure, never a silent omission.
pub fn (g Git) object_format(dir string) !string {
	r := g.at(dir, ['rev-parse', '--show-object-format'])!
	f := r.stdout.trim_space()
	if f !in ['sha1', 'sha256'] {
		return error("unsupported object format '${f}'")
	}
	return f
}

// refs_digest fingerprints every ref plus HEAD. An unchanged digest means no ref
// moved, meaning there is nothing to walk.
pub fn (g Git) refs_digest(dir string) !string {
	r := g.at(dir, ['for-each-ref', '--format=%(objectname) %(refname)'])!
	mut lines := r.stdout.split_into_lines().filter(it != '')
	lines.sort()
	// An empty repository has no HEAD to resolve; that is not a failure.
	head := proc.run(proc.Cmd{
		exe:  g.exe
		args: ['rev-parse', '--verify', '--quiet', 'HEAD']
		cwd:  dir
		env:  git_env(map[string]string{})
	})!
	lines << 'HEAD ' + head.stdout.trim_space()
	return sha256.sum256(lines.join('\n').bytes()).hex()
}

// remotes lists a repository's remotes by name.
pub fn (g Git) remotes(dir string) !map[string]string {
	result := proc.run(proc.Cmd{
		exe:  g.exe
		args: ['config', '--get-regexp', r'^remote\..*\.url']
		cwd:  dir
		env:  git_env(map[string]string{})
	})!
	mut remotes := map[string]string{}
	for line in result.stdout.split_into_lines() {
		space := line.index(' ') or { continue }
		key := line[..space]
		url := line[space + 1..].trim_space()
		if !key.starts_with('remote.') || !key.ends_with('.url') || url == '' {
			continue
		}
		remotes[key['remote.'.len..key.len - '.url'.len]] = url
	}
	return remotes
}

// primary_remote is the one remote that establishes repository identity.
//
// Only 'origin' or a lone remote when there is no 'origin'. The narrowness is
// the point: people routinely add 'upstream' to a fork and a rule that merged on
// any remote would fuse the fork with what it forked.
pub fn primary_remote(remotes map[string]string) string {
	if url := remotes['origin'] {
		return url
	}
	if remotes.len == 1 {
		for _, url in remotes {
			return url
		}
	}
	return ''
}

// commits walks every ref. refs/stash and refs/notes are excluded: they are
// scratch space and metadata, not a record of work.
pub fn (g Git) commits(dir string) ![]Commit {
	r := g.at(dir, ['log', '--exclude=refs/stash', '--exclude=refs/notes/*', '--all',
		'--no-use-mailmap', '--no-show-signature', '--format=' + commit_format])!
	return parse_commits(r.stdout)
}

pub fn (g Git) scan(dir string) !Scan {
	return Scan{
		object_format: g.object_format(dir)!
		refs_digest:   g.refs_digest(dir)!
		commits:       g.commits(dir)!
	}
}

// parse_commits is pure so it can be tested without a repository.
pub fn parse_commits(out string) ![]Commit {
	if out.trim_space() == '' {
		return []Commit{}
	}
	mut lines := out.split('\n')
	// git terminates the last record with a newline, leaving one empty tail field.
	if lines.len > 0 && lines.last() == '' {
		lines.delete_last()
	}
	if lines.len % commit_fields != 0 {
		return error('git log produced ${lines.len} lines, not a multiple of ${commit_fields}')
	}
	mut commits := []Commit{cap: lines.len / commit_fields}
	for i := 0; i < lines.len; i += commit_fields {
		commits << Commit{
			object_id:       lines[i]
			parents:         lines[i + 1]
			author_name:     lines[i + 2]
			author_email:    lines[i + 3]
			author_time:     lines[i + 4].i64()
			author_tz:       parse_tz(lines[i + 5])
			committer_name:  lines[i + 6]
			committer_email: lines[i + 7]
			committer_time:  lines[i + 8].i64()
			committer_tz:    parse_tz(lines[i + 9])
			subject:         lines[i + 10]
		}
	}
	return commits
}

// parse_tz turns git's +HHMM into minutes east of UTC.
pub fn parse_tz(s string) int {
	if s.len != 5 {
		return 0
	}
	minutes := s[1..3].int() * 60 + s[3..5].int()
	return if s[0] == `-` { -minutes } else { minutes }
}
