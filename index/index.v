module index

import db.sqlite
import os
import gitrepo
import identity
import source

pub struct DB {
mut:
	conn sqlite.DB
}

// A Location is an identity bearing reference to a repository. Its 'key' is the
// merge key: two locations sharing a key are the same repository by definition.
pub struct Location {
pub:
	kind  string // worktree | bare | remote
	key   string
	value string
}

pub fn open(path string) !&DB {
	if path != ':memory:' {
		os.mkdir_all(os.dir(path))!
	}
	mut conn := sqlite.connect(path)!
	conn.busy_timeout(5000)
	conn.exec('PRAGMA journal_mode = WAL')!
	conn.exec('PRAGMA foreign_keys = ON')!
	// Scratch space for diffing a repository's membership. It belongs to this
	// connection rather than to the file, so it is not schema and needs no
	// migration. The commit id is the rowid which is the whole index it needs.
	conn.exec('CREATE TEMP TABLE scanned_commits (commit_id INTEGER PRIMARY KEY)')!
	mut d := &DB{
		conn: conn
	}
	d.migrate()!
	return d
}

pub fn (mut d DB) close() ! {
	d.conn.close()!
}

fn (mut d DB) migrate() ! {
	current := d.conn.q_int('PRAGMA user_version')!
	if current > schema_version {
		return error('database schema is version ${current}, newer than this gitlife supports (${schema_version})')
	}
	if current == schema_version {
		return
	}
	d.conn.begin()!
	for v := current; v < schema_version; v++ {
		for stmt in migrations[v] {
			d.conn.exec(stmt) or {
				d.conn.rollback() or {}
				return err
			}
		}
		if v + 1 == 3 {
			d.fold_transport_keys() or {
				d.conn.rollback() or {}
				return err
			}
		}
	}
	d.conn.exec('PRAGMA user_version = ${schema_version}') or {
		d.conn.rollback() or {}
		return err
	}
	d.conn.commit()!
}

// upsert_source records a configured source. The database keeps history for
// sources the config no longer lists and 'active' distinguishes them rather
// than deletion.
pub fn (mut d DB) upsert_source(id string, kind string, spec string, active bool, now i64) ! {
	d.conn.exec_param_many('INSERT INTO sources (id, kind, spec, active, created_at)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, spec = excluded.spec,
		                              active = excluded.active', [
		id,
		kind,
		spec,
		bit(active),
		now.str(),
	])!
}

pub fn (mut d DB) deactivate_sources_except(ids []string) ! {
	mut q := 'UPDATE sources SET active = 0'
	if ids.len > 0 {
		q += ' WHERE id NOT IN (' + '?, '.repeat(ids.len).trim_string_right(', ') + ')'
	}
	d.conn.exec_param_many(q, ids)!
}

// resolve_repository resolves a set of locations to one repository, creating it
// when all of them are new.
//
// Repositories merge only through a shared location key, never through
// overlapping commits, which would collapse a fork into its upstream. When two
// locations that were separate repositories turn out to be joined by a primary
// remote, the older absorbs the newer rather than the two being left to
// double count the same work.
pub fn (mut d DB) resolve_repository(locations []Location, name string, object_format string, now i64) !i64 {
	mut owners := []i64{}
	for location in locations {
		rows := d.conn.exec_param('SELECT repository_id FROM repository_locations WHERE key = ?', location.key)!
		if rows.len == 0 {
			continue
		}
		owner := rows[0].val(0).i64()
		if owner !in owners {
			owners << owner
		}
	}

	mut id := i64(0)
	if owners.len == 0 {
		d.conn.exec_param_many('INSERT INTO repositories (display_name, object_format, created_at)
			VALUES (?, ?, ?)', [
			name,
			object_format,
			now.str(),
		])!
		id = d.conn.last_insert_rowid()
	} else {
		owners.sort()
		id = owners[0]
		for absorbed in owners[1..] {
			d.merge_repositories(id, absorbed)!
		}
	}

	for location in locations {
		d.conn.exec_param_many('INSERT OR IGNORE INTO repository_locations (repository_id, kind, key, value)
			VALUES (?, ?, ?, ?)', [
			id.str(),
			location.kind,
			location.key,
			location.value,
		])!
	}
	if object_format != '' {
		d.conn.exec_param_many("UPDATE repositories SET object_format = ?
			WHERE id = ? AND object_format = ''", [
			object_format,
			id.str(),
		])!
	}
	return id
}

// merge_repositories folds 'absorbed' into 'keep'. Repository ids are ours and
// the one thing here safe to write straight into the SQL.
fn (mut d DB) merge_repositories(keep i64, absorbed i64) ! {
	d.conn.exec('INSERT OR IGNORE INTO repository_commits (repository_id, commit_id)\n\t\tSELECT ${keep}, commit_id FROM repository_commits WHERE repository_id = ${absorbed}')!
	d.conn.exec('DELETE FROM repository_commits WHERE repository_id = ${absorbed}')!
	d.conn.exec('INSERT OR IGNORE INTO discoveries (source_id, repository_id, first_seen, last_seen, metadata)\n\t\tSELECT source_id, ${keep}, first_seen, last_seen, metadata FROM discoveries\n\t\tWHERE repository_id = ${absorbed}')!
	d.conn.exec('DELETE FROM discoveries WHERE repository_id = ${absorbed}')!
	d.conn.exec('INSERT OR IGNORE INTO repository_remotes (repository_id, name, url, url_norm)\n\t\tSELECT ${keep}, name, url, url_norm FROM repository_remotes WHERE repository_id = ${absorbed}')!
	d.conn.exec('DELETE FROM repository_remotes WHERE repository_id = ${absorbed}')!
	d.conn.exec('UPDATE repository_locations SET repository_id = ${keep} WHERE repository_id = ${absorbed}')!
	d.conn.exec("UPDATE repositories SET object_format =\n\t\t\t(SELECT object_format FROM repositories WHERE id = ${absorbed})\n\t\tWHERE id = ${keep} AND object_format = ''")!
	d.conn.exec('DELETE FROM repositories WHERE id = ${absorbed}')!
}

// fold_transport_keys is the v3 migration. A remote key used to carry the
// transport, so one repository reached over ssh and over https was two rows,
// two repositories and two histories. Rows whose keys fold onto each other are
// merged into the oldest of them.
//
// Every remaining remote row loses its digest and is walked again on the next
// sync. A repository that just absorbed another has a different set of commits
// than the digest was taken for and one rescan is the safe direction to be
// wrong in.
fn (mut d DB) fold_transport_keys() ! {
	rows := d.conn.exec("SELECT id, key FROM repository_locations
		WHERE kind = 'remote' ORDER BY id")!
	mut keeper := map[string]i64{}
	for row in rows {
		id := row.val(0).i64()
		folded := source.fold_transport(row.val(1))
		if folded !in keeper {
			keeper[folded] = id
			continue
		}
		// Read both repositories now rather than trusting what they were at the
		// top of the loop: an earlier merge may have moved either of them.
		keep := d.repository_of_location(keeper[folded])!
		absorbed := d.repository_of_location(id)!
		if keep != 0 && absorbed != 0 && keep != absorbed {
			d.merge_repositories(keep, absorbed)!
		}
		d.conn.exec('DELETE FROM repository_locations WHERE id = ${id}')!
	}
	for folded, id in keeper {
		d.conn.exec_param_many("UPDATE repository_locations SET key = ?, refs_digest = ''\n\t\t\tWHERE id = ${id}", [
			folded,
		])!
	}
}

fn (mut d DB) repository_of_location(id i64) !i64 {
	rows := d.conn.exec('SELECT repository_id FROM repository_locations WHERE id = ${id}')!
	if rows.len == 0 {
		return 0
	}
	return rows[0].val(0).i64()
}

// LocationState is what the last successful scan of a location left behind: the
// fingerprint of the refs it saw and the tips it stopped at.
pub struct LocationState {
pub:
	digest string
	tips   []string
}

pub fn (mut d DB) location_state(key string) !LocationState {
	rows := d.conn.exec_param('SELECT refs_digest, ref_tips FROM repository_locations WHERE key = ?',
		key)!
	if rows.len == 0 {
		return LocationState{}
	}
	return LocationState{
		digest: rows[0].val(0)
		tips:   rows[0].val(1).split(' ').filter(it != '')
	}
}

// set_location_state records what a walk left behind. It also marks the location
// walked which an invalidating call is no less evidence of: the walk that could
// not say where it stopped still put its commits in the index.
pub fn (mut d DB) set_location_state(key string, digest string, tips []string) ! {
	d.conn.exec_param_many('UPDATE repository_locations SET refs_digest = ?, ref_tips = ?, walked = 1
		WHERE key = ?', [
		digest,
		tips.join(' '),
		key,
	])!
}

// mark_walked records that a location is about to add to its repository's
// membership. It runs before the membership is written rather than after: a run
// that stopped in between would otherwise leave commits behind that no location
// admits to and a later run would replace the membership they belong to.
pub fn (mut d DB) mark_walked(key string) ! {
	d.conn.exec_param('UPDATE repository_locations SET walked = 1 WHERE key = ?', key)!
}

// walked_locations names the locations of a repository that have ever been
// walked.
pub fn (mut d DB) walked_locations(repository_id i64) ![]string {
	rows := d.conn.exec('SELECT key FROM repository_locations
		WHERE repository_id = ${repository_id} AND walked = 1')!
	return rows.map(it.val(0))
}

// scanned_locations counts the locations of a repository that have ever been
// walked. Membership is the union of them, a location can only reason about
// what a repository holds on its own when it is the only one. What counts is
// having walked, not holding a fingerprint: a location whose state was thrown
// away still holds the commits it added.
pub fn (mut d DB) scanned_locations(repository_id i64) !int {
	return d.conn.q_int('SELECT count(*) FROM repository_locations
		WHERE repository_id = ${repository_id} AND walked = 1')!
}

// replace_remotes records every remote a repository has, as evidence. These are
// deliberately not locations: a non primary remote must never merge two
// repositories or adding 'upstream' to a fork would fuse it with what it forked.
pub fn (mut d DB) replace_remotes(repository_id i64, remotes map[string]string) ! {
	d.conn.exec_param('DELETE FROM repository_remotes WHERE repository_id = ?', repository_id.str())!
	mut rows := [][]string{}
	for remote_name, url in remotes {
		rows << [repository_id.str(), remote_name, source.redact_url(url), source.normalize_url(url)]
	}
	if rows.len > 0 {
		d.conn.exec_param_many('INSERT OR IGNORE INTO repository_remotes (repository_id, name, url, url_norm)
			VALUES (?, ?, ?, ?)', rows)!
	}
}

pub fn (mut d DB) record_discovery(source_id string, repository_id i64, now i64) ! {
	d.record_discovery_with(source_id, repository_id, '', now)!
}

// record_discovery_with stores provider metadata alongside the discovery. The
// metadata is a provider's description of a repository; it is never evidence
// about that repository's commits.
pub fn (mut d DB) record_discovery_with(source_id string, repository_id i64, metadata string, now i64) ! {
	d.conn.exec_param_many('INSERT INTO discoveries (source_id, repository_id, first_seen, last_seen, metadata)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(source_id, repository_id) DO UPDATE SET last_seen = excluded.last_seen,
			metadata = excluded.metadata', [
		source_id,
		repository_id.str(),
		now.str(),
		now.str(),
		metadata,
	])!
}

pub fn (mut d DB) record_sync(scope string, ref_id string, status string, message string, now i64) ! {
	success := if status == 'ok' { now.str() } else { '0' }
	d.conn.exec_param_many('INSERT INTO sync_results (scope, ref_id, status, message, last_attempt_at, last_success_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(scope, ref_id) DO UPDATE SET
			status = excluded.status, message = excluded.message,
			last_attempt_at = excluded.last_attempt_at,
			last_success_at = MAX(sync_results.last_success_at, excluded.last_success_at)', [
		scope,
		ref_id,
		status,
		message,
		now.str(),
		success,
	])!
}

// set_accepted mirrors config.toml into the database so report queries stay pure
// SQL with no identity filtering done in V.
pub fn (mut d DB) set_accepted(names []string, emails []string) ! {
	d.conn.begin()!
	d.apply_accepted(names, emails) or {
		d.conn.rollback() or {}
		return err
	}
	d.conn.commit()!
}

fn (mut d DB) apply_accepted(names []string, emails []string) ! {
	d.conn.exec('DELETE FROM accepted_identities')!
	mut rows := [][]string{}
	for n in names {
		rows << ['name', n, identity.norm_name(n)]
	}
	for e in emails {
		rows << ['email', e, identity.norm_email(e)]
	}
	if rows.len > 0 {
		d.conn.exec_param_many('INSERT OR IGNORE INTO accepted_identities (kind, value, value_norm)
			VALUES (?, ?, ?)', rows)!
	}
}

// write_snapshot writes one location's scan atomically, and returns how many of
// the commits it held were ones the index had never seen. Either the repository
// ends up holding the scanned commits or it keeps the snapshot it had.
//
// 'fresh' says whether this is the first location of this repository written in
// this run. Only the first clears the previous membership; the rest add to it. A
// repository reachable through both a working tree and a cached clone then holds
// the union of what they contain, not whichever was scanned last.
pub fn (mut d DB) write_snapshot(repository_id i64, scan gitrepo.Scan, fresh bool) !int {
	d.conn.begin()!
	added := d.apply_snapshot(repository_id, scan, fresh) or {
		d.conn.rollback() or {}
		return err
	}
	d.conn.commit()!
	return added
}

fn (mut d DB) apply_snapshot(repository_id i64, scan gitrepo.Scan, fresh bool) !int {
	before := d.conn.q_int('SELECT COALESCE(MAX(id), 0) FROM commits')!
	d.insert_commits(scan.object_format, scan.commits)!

	// Membership is diffed against what the location holds, not replaced by it.
	d.conn.exec('DELETE FROM scanned_commits')!
	mut scanned := Batch{
		query: 'INSERT OR IGNORE INTO scanned_commits (commit_id)
			SELECT id FROM commits WHERE object_format = ? AND object_id = ?'
	}
	for c in scan.commits {
		scanned.add(mut d, [scan.object_format, c.object_id])!
	}
	scanned.send(mut d)!

	id := repository_id.str()
	d.conn.exec_param('INSERT OR IGNORE INTO repository_commits (repository_id, commit_id)
		SELECT ?, commit_id FROM scanned_commits', id)!
	if fresh {
		d.conn.exec_param('DELETE FROM repository_commits
			WHERE repository_id = ?
			AND commit_id NOT IN (SELECT commit_id FROM scanned_commits)', id)!
	}

	d.conn.exec_param_many('UPDATE repositories SET object_format = ? WHERE id = ?', [
		scan.object_format,
		id,
	])!
	return int(d.conn.q_int('SELECT COALESCE(MAX(id), 0) FROM commits')! - before)
}

// write_delta records what changed for a location instead of what it holds:
// the commits that came into scope and the ones that left it. It returns how
// many commits the index had never seen and how many the repository holds now.
//
// Only a repository with a single scanned location can be written this way. A
// commit leaving one location's scope says nothing about whether another
// location still reaches it, and membership is the union of them.
pub fn (mut d DB) write_delta(repository_id i64, object_format string, added []gitrepo.Commit, dropped []string) !(int, int) {
	d.conn.begin()!
	fresh, held := d.apply_delta(repository_id, object_format, added, dropped) or {
		d.conn.rollback() or {}
		return err
	}
	d.conn.commit()!
	return fresh, held
}

fn (mut d DB) apply_delta(repository_id i64, object_format string, added []gitrepo.Commit, dropped []string) !(int, int) {
	before := d.conn.q_int('SELECT COALESCE(MAX(id), 0) FROM commits')!
	d.insert_commits(object_format, added)!

	id := repository_id.str()
	mut members := Batch{
		query: 'INSERT OR IGNORE INTO repository_commits (repository_id, commit_id)
			VALUES (?, (SELECT id FROM commits WHERE object_format = ? AND object_id = ?))'
	}
	for c in added {
		members.add(mut d, [id, object_format, c.object_id])!
	}
	members.send(mut d)!

	// A commit nothing reaches any more stops counting for this repository. The
	// commit row itself stays: another repository may hold it and purge is what
	// forgets a commit for good.
	mut gone := Batch{
		query: 'DELETE FROM repository_commits
			WHERE repository_id = ?
			AND commit_id = (SELECT id FROM commits WHERE object_format = ? AND object_id = ?)'
	}
	for oid in dropped {
		gone.add(mut d, [id, object_format, oid])!
	}
	gone.send(mut d)!

	held := d.conn.q_int('SELECT count(*) FROM repository_commits WHERE repository_id = ${repository_id}')!
	return int(d.conn.q_int('SELECT COALESCE(MAX(id), 0) FROM commits')! - before), held
}

// insert_commits writes the commits themselves and the identities they name.
// A commit row is never updated, so the same commit reached twice costs a lookup
// and nothing else.
fn (mut d DB) insert_commits(object_format string, commits []gitrepo.Commit) ! {
	mut idents := Batch{
		query: 'INSERT OR IGNORE INTO git_identities (name, email, email_norm)
			VALUES (?, ?, ?)'
	}
	mut seen := map[string]bool{}
	for c in commits {
		add_identity(mut idents, mut d, mut seen, c.author_name, c.author_email)!
		add_identity(mut idents, mut d, mut seen, c.committer_name, c.committer_email)!
	}
	idents.send(mut d)!

	mut rows := Batch{
		query: "INSERT OR IGNORE INTO commits (
				object_format, object_id, parents,
				author_identity_id, author_time, author_tz, author_date,
				committer_identity_id, committer_time, committer_tz, committer_date,
				subject)
			VALUES (?, ?, ?,
				(SELECT id FROM git_identities WHERE name = ? AND email = ?), ?, ?, date(?, 'unixepoch'),
				(SELECT id FROM git_identities WHERE name = ? AND email = ?), ?, ?, date(?, 'unixepoch'),
				?)"
	}
	for c in commits {
		rows.add(mut d, [
			object_format,
			c.object_id,
			c.parents,
			c.author_name,
			c.author_email,
			c.author_time.str(),
			c.author_tz.str(),
			(c.author_time + c.author_tz * 60).str(),
			c.committer_name,
			c.committer_email,
			c.committer_time.str(),
			c.committer_tz.str(),
			(c.committer_time + c.committer_tz * 60).str(),
			c.subject,
		])!
	}
	rows.send(mut d)!
}

// rows_per_batch is how many rows an insert holds at once. The statement is
// prepared once per call and stepped once per row, so a smaller group costs one
// more prepare and saves a second copy of the history: every commit of a
// repository used to be turned into fourteen strings and every one of them kept
// until the last row was built.
const rows_per_batch = 2000

// A Batch feeds one statement in bounded groups.
struct Batch {
	query string
mut:
	pending [][]string
}

fn (mut b Batch) add(mut d DB, row []string) ! {
	b.pending << row
	if b.pending.len >= rows_per_batch {
		b.send(mut d)!
	}
}

// send writes what has piled up. The rows are dropped, not just forgotten: they
// are the whole reason the batch exists.
fn (mut b Batch) send(mut d DB) ! {
	if b.pending.len == 0 {
		return
	}
	d.conn.exec_param_many(b.query, b.pending)!
	b.pending = [][]string{cap: rows_per_batch}
}

fn add_identity(mut b Batch, mut d DB, mut seen map[string]bool, name string, email string) ! {
	key := name + '\x1f' + email
	if key in seen {
		return
	}
	seen[key] = true
	b.add(mut d, [name, email, identity.norm_email(email)])!
}

fn bit(b bool) string {
	return if b { '1' } else { '0' }
}
