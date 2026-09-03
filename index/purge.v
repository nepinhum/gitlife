// Purging is a separate, explicit act. Removing a source leaves its indexed
// history in place because the config said stop looking there rather than forget
// what was found. This is what forgets it.
module index

pub struct Purge {
pub:
	repositories int
	commits      int
	identities   int
	sources      int
	// keep is the remote locations that survived, which lets a cache prune be
	// decided from the same transaction that decided the rest. Reading them
	// afterwards would answer for the database as it is, not as the purge left
	// it and on a dry run those differ.
	keep []string
}

// dead is a repository no active source has discovered. A repository is reachable
// only through a source, and this is the whole of unreachability.
const dead = 'SELECT r.id FROM repositories r WHERE NOT EXISTS (
	SELECT 1 FROM discoveries dc JOIN sources s ON s.id = dc.source_id
	WHERE dc.repository_id = r.id AND s.active = 1)'

// purge removes everything no active source can still reach. A dry run is the
// same work with the transaction rolled back at the end. The numbers it reports
// are counted rather than predicted.
pub fn (mut d DB) purge(dry_run bool) !Purge {
	d.conn.begin()!
	result := d.apply_purge() or {
		d.conn.rollback() or {}
		return err
	}
	if dry_run {
		d.conn.rollback()!
	} else {
		d.conn.commit()!
	}
	return result
}

fn (mut d DB) apply_purge() !Purge {
	// The dead set is materialized first. Deleting rows changes what the predicate
	// above would answer and a set that shifts underneath its own deletions is not
	// a set.
	d.conn.exec('CREATE TEMP TABLE dead_repositories AS ${dead}')!
	defer {
		d.conn.exec('DROP TABLE IF EXISTS dead_repositories') or {}
	}
	of_dead := 'IN (SELECT id FROM dead_repositories)'

	d.conn.exec('DELETE FROM repository_commits WHERE repository_id ${of_dead}')!
	d.conn.exec('DELETE FROM repository_locations WHERE repository_id ${of_dead}')!
	d.conn.exec('DELETE FROM repository_remotes WHERE repository_id ${of_dead}')!
	d.conn.exec('DELETE FROM discoveries WHERE repository_id ${of_dead}')!
	d.conn.exec('DELETE FROM repositories WHERE id ${of_dead}')!
	repositories := d.conn.get_affected_rows_count()

	// A commit belongs to no one now. No report can reach it, Git remains its real
	// home and a resync restores anything lost.
	d.conn.exec('DELETE FROM commits WHERE id NOT IN (SELECT commit_id FROM repository_commits)')!
	commits := d.conn.get_affected_rows_count()

	d.conn.exec('DELETE FROM git_identities WHERE id NOT IN (
		SELECT author_identity_id FROM commits
		UNION SELECT committer_identity_id FROM commits)')!
	identities := d.conn.get_affected_rows_count()

	d.conn.exec('DELETE FROM sources WHERE active = 0
		AND id NOT IN (SELECT source_id FROM discoveries)')!
	sources := d.conn.get_affected_rows_count()

	// Sync results outlive what they describe unless they are swept with it.
	d.conn.exec("DELETE FROM sync_results WHERE scope = 'repository'
		AND ref_id NOT IN (SELECT key FROM repository_locations)")!
	d.conn.exec("DELETE FROM sync_results WHERE scope = 'source'
		AND ref_id NOT IN (SELECT id FROM sources)")!

	rows := d.conn.exec("SELECT value FROM repository_locations WHERE kind = 'remote'")!
	return Purge{
		repositories: repositories
		commits:      commits
		identities:   identities
		sources:      sources
		keep:         rows.map(it.val(0))
	}
}
