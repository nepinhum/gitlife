module syncer

import os
import runtime
import time
import cache
import config
import credentials
import discover
import gitrepo
import index
import source

// max_jobs caps the automatic worker count. Beyond a handful of parallel clones
// the limit is the network or the remote's patience, not this machine.
const max_jobs = 8

pub struct Options {
pub:
	selector string // sync only this source id; empty means every active one
	jobs     int    // 0 chooses a worker per CPU, to max_jobs
	deps     Deps
}

pub struct Outcome {
pub:
	source      string
	repository  string
	status      string // ok | unchanged | failed
	message     string
	action      string // cloned | fetched | read
	commits     int    // commits the location holds
	new_commits int    // of those, the ones the index had never seen
	elapsed_ms  int
}

pub struct Report {
pub mut:
	outcomes []Outcome
	// notes are source level remarks. They are deliberately not outcomes: the
	// counts below are about repositories and folding a source into them would
	// report one more "updated" than there were repositories.
	notes       []string
	updated     int
	unchanged   int
	failed      int
	new_commits int
	jobs        int
	elapsed_ms  int
}

fn (mut r Report) add(o Outcome) {
	r.outcomes << o
	r.new_commits += o.new_commits
	match o.status {
		'ok' { r.updated++ }
		'unchanged' { r.unchanged++ }
		else { r.failed++ }
	}
}

// A Pass is everything one run settles before it touches a source: the tools it
// found, where clones live, what a child process inherits, how to reach a
// provider and the instant the whole run is stamped with. It never changes once
// the run has begun which is what makes it safe to hand to a worker.
struct Pass {
	git   gitrepo.Git
	store cache.Cache
	deps  Deps
	// token is resolved once. 'gh' is a subprocess and asking it again for every
	// source would cost a process each time. Its failure is carried rather than
	// raised because only a source that needs a credential should fail for want
	// of one.
	token       credentials.Token
	token_error string
	env         map[string]string
	jobs        int
	now         i64
}

// A Job is one repository a source named, waiting to be prepared.
struct Job {
	source_id string
	found     discover.Found
}

// Prepared is what a worker produces: a repository made readable and fingerprinted,
// and nothing that required the database to decide.
struct Prepared {
	source_id     string
	found         discover.Found
	dir           string // where the commits can actually be read
	action        string
	remotes       map[string]string
	object_format string
	digest        string
	elapsed_ms    int
	error         string
}

// A Task is one scannable location of one repository, registered and dated.
struct Task {
	source_id     string
	repository_id i64
	name          string
	location_key  string
	dir           string
	object_format string
	digest        string
	action        string
	elapsed_ms    int // what preparing it already cost
	changed       bool
	// fresh marks the first location of its repository to be written this run.
	// Only that one clears the previous membership; the rest add to it.
	fresh bool
}

// Scanned is a worker's walk of one task's commits. It lives from the moment its
// worker hands it over until the writer is done with it and no longer.
struct Scanned {
	commits    []gitrepo.Commit
	elapsed_ms int
	error      string
}

// run processes every active source or the single source named by the options.
// There is no separate "all" path: all active sources are the default set.
pub fn run(c config.Config, mut d index.DB, o Options) !Report {
	started := time.ticks()
	git := gitrepo.find()!
	now := time.now().unix()

	mut names := []string{}
	mut emails := []string{}
	for i in c.identities {
		if i.name != '' {
			names << i.name
		}
		if i.email != '' {
			emails << i.email
		}
	}
	d.set_accepted(names, emails)!

	mut ids := []string{}
	for s in c.sources {
		d.upsert_source(s.id(), s.kind, s.spec, s.active, now)!
		ids << s.id()
	}
	d.deactivate_sources_except(ids)!

	mut selected := c.sources.filter(it.active)
	if o.selector != '' {
		selected = selected.filter(it.id() == o.selector)
		if selected.len == 0 {
			return error("no active source with id '${o.selector}'")
		}
	}

	mut token := credentials.Token{}
	mut token_error := ''
	if selected.any(it.kind in ['git', 'github']) {
		token = o.deps.token() or {
			token_error = err.msg()
			credentials.Token{}
		}
	}
	mut env := map[string]string{}
	if token.value != '' {
		env['GITLIFE_GITHUB_TOKEN'] = token.value
	}

	p := Pass{
		git:         git
		store:       cache.Cache{
			root: c.paths.repos_dir()
			git:  git
			exe:  os.executable()
		}
		deps:        o.deps
		token:       token
		token_error: token_error
		env:         env
		jobs:        workers(o.jobs)
		now:         now
	}

	mut report := Report{
		jobs: p.jobs
	}

	mut broken := map[string]bool{}

	mut queue := []Job{}
	for s in selected {
		for f in discover_source(p, s, mut d, mut report, mut broken) {
			queue << Job{
				source_id: s.id()
				found:     f
			}
		}
	}

	tasks := register(prepare_all(p, queue), mut d, mut report, mut broken, p.now)
	scan, unchanged := plan(tasks)
	for task in unchanged {
		report.add(Outcome{
			source:     task.source_id
			repository: task.name
			status:     'unchanged'
			action:     task.action
			elapsed_ms: task.elapsed_ms
		})
		d.record_sync('repository', task.location_key, 'ok', '', p.now) or {}
	}
	write(p, scan, mut d, mut report, mut broken, p.now)

	for s in selected {
		id := s.id()
		d.record_sync('source', id, if id in broken { 'failed' } else { 'ok' }, '', p.now) or {}
	}
	report.elapsed_ms = int(time.ticks() - started)
	return report
}

// workers decides how many repositories are handled at once. Repositories are
// independent of each other and mostly waiting, on a network or on git, which is
// why more workers than cores still helps, up to a point.
fn workers(requested int) int {
	if requested > 0 {
		return requested
	}
	cpus := runtime.nr_cpus()
	if cpus < 1 {
		return 1
	}
	return if cpus > max_jobs { max_jobs } else { cpus }
}

fn discover_source(p Pass, s config.Source, mut d index.DB, mut report Report, mut broken map[string]bool) []discover.Found {
	id := s.id()
	return match s.kind {
		'local' {
			discover.local(s.spec) or {
				fail_source(mut d, mut report, mut broken, id, err.msg(), p.now)
				[]discover.Found{}
			}
		}
		'git' {
			discover.git_remote(s.spec)
		}
		'github' {
			discover_github(p, s, id, mut d, mut report, mut broken)
		}
		else {
			fail_source(mut d, mut report, mut broken, id,
				"source kind '${s.kind}' is not supported yet", p.now)
			[]discover.Found{}
		}
	}
}

// prepare_all makes every discovered repository readable, in parallel. Nothing
// here touches the database, which is the whole reason it can run at once.
fn prepare_all(p Pass, jobs []Job) []Prepared {
	if jobs.len == 0 {
		return []Prepared{}
	}
	if p.jobs <= 1 || jobs.len == 1 {
		return prepare_stride(p, jobs, 0, 1)
	}
	stride := if p.jobs < jobs.len { p.jobs } else { jobs.len }
	mut threads := []thread []Prepared{}
	for w in 0 .. stride {
		threads << spawn prepare_stride(p, jobs, w, stride)
	}
	return regroup(threads.wait(), stride, jobs.len)
}

// prepare_stride is one worker's share: every 'stride'-th job starting at 'first'.
// Round robin rather than a contiguous block because the cost of a repository is
// not knowable in advance and one block of large ones would idle every other
// worker.
fn prepare_stride(p Pass, jobs []Job, first int, stride int) []Prepared {
	mut out := []Prepared{}
	for i := first; i < jobs.len; i += stride {
		out << prepare(p, jobs[i])
	}
	return out
}

fn prepare(p Pass, job Job) Prepared {
	started := time.ticks()
	base := gather(p, job) or {
		Prepared{
			error: err.msg()
		}
	}
	return Prepared{
		...base
		source_id:  job.source_id
		found:      job.found
		elapsed_ms: int(time.ticks() - started)
	}
}

fn gather(p Pass, job Job) !Prepared {
	f := job.found
	mut dir := f.dir
	mut action := 'read'
	mut remotes := map[string]string{}
	if f.dir != '' {
		remotes = p.git.remotes(f.dir)!
	} else {
		entry := p.store.ensure(f.url, p.env)!
		dir = entry.dir
		action = if entry.cloned { 'cloned' } else { 'fetched' }
	}
	return Prepared{
		dir:           dir
		action:        action
		remotes:       remotes
		object_format: p.git.object_format(dir)!
		digest:        p.git.refs_digest(dir)!
	}
}

fn register(prepared []Prepared, mut d index.DB, mut report Report, mut broken map[string]bool, now i64) []Task {
	mut tasks := []Task{}
	for item in prepared {
		if item.error != '' {
			fail_repository(mut d, mut report, mut broken, item.source_id, item.found.name,
				location_key(item.found), item.error, now)
			continue
		}
		tasks << enter(item, mut d, now) or {
			fail_repository(mut d, mut report, mut broken, item.source_id, item.found.name,
				location_key(item.found), err.msg(), now)
			continue
		}
	}
	return tasks
}

fn enter(item Prepared, mut d index.DB, now i64) !Task {
	f := item.found
	mut locations := []index.Location{}
	if f.dir != '' {
		locations << index.Location{
			kind:  if f.bare { 'bare' } else { 'worktree' }
			key:   'dir:' + f.dir
			value: f.dir
		}
		// The primary remote is what ties this working tree to the same repository
		// reached through a URL. Every other remote is recorded as evidence below
		// and merges nothing.
		primary := gitrepo.primary_remote(item.remotes)
		if primary != '' {
			locations << index.Location{
				kind:  'remote'
				key:   source.location_key(primary)
				value: source.redact_url(primary)
			}
		}
	} else {
		locations << index.Location{
			kind:  'remote'
			key:   source.location_key(f.url)
			value: source.redact_url(f.url)
		}
	}

	repository_id := d.resolve_repository(locations, f.name, item.object_format, now)!
	d.record_discovery_with(item.source_id, repository_id, f.metadata, now)!
	if item.remotes.len > 0 {
		d.replace_remotes(repository_id, item.remotes)!
	}

	scanned := locations[0].key
	return Task{
		source_id:     item.source_id
		repository_id: repository_id
		name:          f.name
		location_key:  scanned
		dir:           item.dir
		object_format: item.object_format
		digest:        item.digest
		action:        item.action
		elapsed_ms:    item.elapsed_ms
		changed:       item.digest != d.location_digest(scanned)!
	}
}

// plan splits the registered tasks into the ones to walk and the ones to leave
// alone. A repository whose locations all still hold the refs they held last time
// is not walked at all; if any one of them moved, every location of it is walked
// because membership is replaced from their union and a partial union would lose
// commits.
fn plan(tasks []Task) ([]Task, []Task) {
	mut grouped := map[string][]Task{}
	for task in tasks {
		grouped[task.repository_id.str()] << task
	}
	mut scan := []Task{}
	mut unchanged := []Task{}
	for _, group in grouped {
		if !group.any(it.changed) {
			unchanged << group
			continue
		}
		for i, task in group {
			scan << Task{
				...task
				fresh: i == 0
			}
		}
	}
	return scan, unchanged
}

// read walks one location's commits and times the walk.
fn read(p Pass, task Task) Scanned {
	started := time.ticks()
	commits := p.git.commits(task.dir) or {
		return Scanned{
			error: err.msg()
		}
	}
	return Scanned{
		commits:    commits
		elapsed_ms: int(time.ticks() - started)
	}
}

// read_stride is one worker's share, handed over one walk at a time. Same round
// robin as prepare_stride, for the same reason.
fn read_stride(p Pass, tasks []Task, first int, stride int, out chan Scanned) {
	for i := first; i < tasks.len; i += stride {
		out <- read(p, tasks[i])
	}
}

fn regroup[T](parts [][]T, stride int, total int) []T {
	mut out := []T{len: total}
	for w, part in parts {
		for k, item in part {
			out[w + k * stride] = item
		}
	}
	return out
}

fn write(p Pass, tasks []Task, mut d index.DB, mut report Report, mut broken map[string]bool, now i64) {
	if tasks.len == 0 {
		return
	}
	if p.jobs <= 1 || tasks.len == 1 {
		for task in tasks {
			store(task, read(p, task), mut d, mut report, mut broken, now)
		}
		return
	}
	stride := if p.jobs < tasks.len { p.jobs } else { tasks.len }

	mut handovers := []chan Scanned{cap: stride}
	for _ in 0 .. stride {
		handovers << chan Scanned{}
	}
	mut threads := []thread{cap: stride}
	for w in 0 .. stride {
		threads << spawn read_stride(p, tasks, w, stride, handovers[w])
	}
	for i, task in tasks {
		store(task, <-handovers[i % stride], mut d, mut report, mut broken, now)
	}
	threads.wait()
}

// store puts one walked location in the index and reports what it cost.
fn store(task Task, scan Scanned, mut d index.DB, mut report Report, mut broken map[string]bool, now i64) {
	if scan.error != '' {
		fail_repository(mut d, mut report, mut broken, task.source_id, task.name, task.location_key,
			scan.error, now)
		return
	}
	fresh := d.write_snapshot(task.repository_id, gitrepo.Scan{
		object_format: task.object_format
		refs_digest:   task.digest
		commits:       scan.commits
	}, task.fresh) or {
		fail_repository(mut d, mut report, mut broken, task.source_id, task.name, task.location_key,
			err.msg(), now)
		return
	}
	d.set_location_digest(task.location_key, task.digest) or {}
	report.add(Outcome{
		source:      task.source_id
		repository:  task.name
		status:      'ok'
		action:      task.action
		commits:     scan.commits.len
		new_commits: fresh
		elapsed_ms:  task.elapsed_ms + scan.elapsed_ms
	})
	d.record_sync('repository', task.location_key, 'ok', '', now) or {}
}

fn discover_github(p Pass, s config.Source, id string, mut d index.DB, mut report Report, mut broken map[string]bool) []discover.Found {
	if p.token.value == '' {
		reason := if p.token_error != '' { p.token_error } else { 'no GitHub credential' }
		fail_source(mut d, mut report, mut broken, id, reason, p.now)
		return []discover.Found{}
	}
	mut client := p.deps.github(p.token) or {
		fail_source(mut d, mut report, mut broken, id, err.msg(), p.now)
		return []discover.Found{}
	}
	result := discover.github_repos(mut client, s.spec) or {
		// The token's source is named, never its value. In CI the failing token is
		// usually GITHUB_TOKEN, injected by the runner rather than by the user.
		fail_source(mut d, mut report, mut broken, id,
			'${err.msg()} [token from ${p.token.source}]', p.now)
		return []discover.Found{}
	}
	mut note := '${id}: ${plural(result.found.len, 'repository')} found in ${plural(client.requests,
		'API call')}'
	if result.remaining >= 0 {
		note += ', ${result.remaining} rate budget left'
	}
	if client.waits.len > 0 {
		note += ', throttled ${plural(client.waits.len, 'time')}'
	}
	report.notes << note
	return result.found
}

fn location_key(f discover.Found) string {
	return if f.dir != '' { 'dir:' + f.dir } else { source.location_key(f.url) }
}

fn plural(n int, word string) string {
	return if n == 1 { '1 ${word}' } else { '${n} ${word}s' }
}

fn fail_source(mut d index.DB, mut report Report, mut broken map[string]bool, id string, msg string, now i64) {
	broken[id] = true
	report.add(Outcome{
		source:  id
		status:  'failed'
		message: msg
	})
	d.record_sync('source', id, 'failed', msg, now) or {}
}

fn fail_repository(mut d index.DB, mut report Report, mut broken map[string]bool, source_id string, name string, ref_id string, msg string, now i64) {
	broken[source_id] = true
	report.add(Outcome{
		source:     source_id
		repository: name
		status:     'failed'
		message:    msg
	})
	d.record_sync('repository', ref_id, 'failed', msg, now) or {}
}
