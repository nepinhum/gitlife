module gitrepo

import crypto.sha256
import proc

// Fields are newline separated, eleven per commit. Git strips CR and LF from
// ident names and emails and %s flattens the subject to a single line.
// NUL separation would be stricter but V's process capture truncates at the
// first NUL byte.
const commit_format = '%H%n%P%n%an%n%ae%n%at%n%az%n%cn%n%ce%n%ct%n%cz%n%s'

const commit_fields = 11

// ref_scope is what a scan considers reachable. Every walk uses the same
// scope or an incremental one would disagree with the full one about what a
// repository holds. Replacements are left out with the rest of what is not
// history: a graft rewrites the graph git reports and a difference taken across
// a graft being added or dropped would be a difference between two graphs.
const ref_scope = ['--exclude=refs/stash', '--exclude=refs/notes/*', '--exclude=refs/replace/*',
	'--all']

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

// Refs is where a location's refs stood at a scan: the fingerprint that says
// whether anything moved and the tips a later scan walks from.
pub struct Refs {
pub:
	digest string
	tips   []string
	// shallow says the history is truncated. What such a repository holds can
	// grow without a ref moving, so its digest can't be trusted to say that
	// nothing changed.
	shallow bool
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
		exe: g.exe
		args: args
		cwd: dir
		env: git_env(extra)
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

// refs fingerprints every ref plus HEAD and keeps the tips inside the scan's
// scope. An unchanged digest means no ref moved, meaning there is nothing to
// walk. The tips are what the next scan asks git to walk from.
pub fn (g Git) refs(dir string) !Refs {
	r := g.at(dir, ['for-each-ref', '--format=%(objectname) %(refname)'])!
	mut lines := r.stdout.split_into_lines().filter(it != '')
	lines.sort()
	mut tips := []string{}
	mut seen := map[string]bool{}
	for line in lines {
		space := line.index(' ') or { continue }
		if in_scope(line[space + 1..]) {
			add_tip(mut tips, mut seen, line[..space])
		}
	}
	head := proc.run(proc.Cmd{
		exe: g.exe
		args: ['rev-parse', '--is-shallow-repository', '--verify', '--quiet', 'HEAD']
		cwd: dir
		env: git_env(map[string]string{})
	})!
	answers := head.stdout.split_into_lines().filter(it != '')
	oid := if answers.len > 1 { answers[1] } else { '' }
	add_tip(mut tips, mut seen, oid)
	lines << 'HEAD ' + oid
	return Refs{
		digest:  sha256.sum256(lines.join('\n').bytes()).hex()
		tips:    tips
		shallow: answers.len > 0 && answers[0] == 'true'
	}
}

// in_scope mirrors ref_scope which git applies and we can't ask it about.
fn in_scope(name string) bool {
	return name != 'refs/stash' && !name.starts_with('refs/notes/')
		&& !name.starts_with('refs/replace/')
}

// add_tip keeps one entry per object. Ten branches on one commit are one tip.
fn add_tip(mut tips []string, mut seen map[string]bool, oid string) {
	if oid == '' || oid in seen {
		return
	}
	seen[oid] = true
	tips << oid
}

// remotes lists a repository's remotes by name.
pub fn (g Git) remotes(dir string) !map[string]string {
	result := proc.run(proc.Cmd{
		exe: g.exe
		args: ['config', '--get-regexp', r'^remote\..*\.url']
		cwd: dir
		env: git_env(map[string]string{})
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

// commits walks everything in scope. The log is read as it arrives: a repository
// with a million commits would otherwise exist three times over, as git's output
// in one string, as that string cut into lines and as the commits themselves.
pub fn (g Git) commits(dir string) ![]Commit {
	return g.log(dir, [])!
}

// added walks the commits that came into scope since a scan whose tips these
// were. Everything the old tips reach is indexed already, so git is asked to
// mark it uninteresting and print the rest.
//
// It fails when a tip is no longer in the repository.
pub fn (g Git) added(dir string, previous []string) ![]Commit {
	mut exclude := ['--not']
	exclude << previous
	return g.log(dir, exclude)!
}

// dropped names the commits the old tips reached that nothing reaches now: a
// deleted branch or history rewritten out from under one. Only the object ids,
// since these are commits the index already holds and is about to stop counting
// for this repository.
pub fn (g Git) dropped(dir string, previous []string) ![]string {
	mut args := ['rev-list']
	args << previous
	args << '--not'
	args << ref_scope
	mut oids := Oids{}
	proc.check_stream(proc.Cmd{
		exe:  g.exe
		args: args
		cwd:  dir
		env:  git_env(map[string]string{})
	}, mut oids)!
	return oids.list
}

fn (g Git) log(dir string, extra []string) ![]Commit {
	mut args := ['log']
	args << ref_scope
	args << ['--no-use-mailmap', '--no-show-signature', '--format=' + commit_format]
	args << extra
	mut reader := CommitReader{}
	proc.check_stream(proc.Cmd{
		exe:  g.exe
		args: args
		cwd:  dir
		env:  git_env(map[string]string{})
	}, mut reader)!
	return reader.done()
}

// An Oids collects a walk that prints one object id per line.
struct Oids {
mut:
	list []string
}

fn (mut o Oids) take(line string) ! {
	if line != '' {
		o.list << line
	}
}

pub fn (g Git) scan(dir string) !Scan {
	return Scan{
		object_format: g.object_format(dir)!
		refs_digest: g.refs(dir)!.digest
		commits: g.commits(dir)!
	}
}

// A CommitReader turns lines into commits as they come. It holds the record it
// is in the middle of and the commits so far, never the log.
struct CommitReader {
mut:
	fields  []string
	commits []Commit
}

fn (mut r CommitReader) take(line string) ! {
	r.fields << line
	if r.fields.len < commit_fields {
		return
	}
	r.commits << Commit{
		object_id: r.fields[0]
		parents: r.fields[1]
		author_name: r.fields[2]
		author_email: r.fields[3]
		author_time: r.fields[4].i64()
		author_tz: parse_tz(r.fields[5])
		committer_name: r.fields[6]
		committer_email: r.fields[7]
		committer_time: r.fields[8].i64()
		committer_tz: parse_tz(r.fields[9])
		subject: r.fields[10]
	}
	r.fields = []string{cap: commit_fields}
}

// done refuses a record git left half written rather than reporting a commit
// with fields belonging to another one.
fn (r CommitReader) done() ![]Commit {
	if r.fields.len != 0 {
		return error('git log ended inside a record, after ${r.fields.len} of ${commit_fields} lines')
	}
	return r.commits
}

// parse_commits is pure so it can be tested without a repository.
pub fn parse_commits(out string) ![]Commit {
	mut reader := CommitReader{}
	if out.trim_space() == '' {
		return reader.done()
	}
	mut lines := out.split('\n')
	// git terminates the last record with a newline, leaving one empty tail field.
	if lines.len > 0 && lines.last() == '' {
		lines.delete_last()
	}
	for line in lines {
		reader.take(line)!
	}
	return reader.done()
}

// parse_tz turns git's +HHMM into minutes east of UTC.
pub fn parse_tz(s string) int {
	if s.len != 5 {
		return 0
	}
	minutes := s[1..3].int() * 60 + s[3..5].int()
	return if s[0] == `-` { -minutes } else { minutes }
}
