module index

// schema_version is bumped whenever a migration is appended. A database written
// by a newer gitlife is refused rather than guessed at.
const schema_version = 2

// migrations[v - 1] holds the statements that take the schema to version v.
// Statements are listed one per entry because SQLite prepares a single statement
// at a time.
const migrations = [
	v1,
	v2,
]

const v1 = [
	'CREATE TABLE sources (
		id          TEXT PRIMARY KEY,
		kind        TEXT NOT NULL,
		spec        TEXT NOT NULL,
		active      INTEGER NOT NULL DEFAULT 1,
		created_at  INTEGER NOT NULL
	)',
	"CREATE TABLE repositories (
		id            INTEGER PRIMARY KEY,
		display_name  TEXT NOT NULL,
		object_format TEXT NOT NULL,
		refs_digest   TEXT NOT NULL DEFAULT (''),
		created_at    INTEGER NOT NULL
	)",
	'CREATE TABLE repository_locations (
		id            INTEGER PRIMARY KEY,
		repository_id INTEGER NOT NULL REFERENCES repositories(id),
		kind          TEXT NOT NULL,
		key           TEXT NOT NULL UNIQUE,
		value         TEXT NOT NULL
	)',
	'CREATE TABLE repository_remotes (
		repository_id INTEGER NOT NULL REFERENCES repositories(id),
		name          TEXT NOT NULL,
		url           TEXT NOT NULL,
		url_norm      TEXT NOT NULL,
		PRIMARY KEY (repository_id, name)
	)',
	"CREATE TABLE discoveries (
		source_id     TEXT NOT NULL,
		repository_id INTEGER NOT NULL REFERENCES repositories(id),
		first_seen    INTEGER NOT NULL,
		last_seen     INTEGER NOT NULL,
		metadata      TEXT NOT NULL DEFAULT (''),
		PRIMARY KEY (source_id, repository_id)
	)",
	'CREATE TABLE git_identities (
		id         INTEGER PRIMARY KEY,
		name       TEXT NOT NULL,
		email      TEXT NOT NULL,
		email_norm TEXT NOT NULL,
		UNIQUE (name, email)
	)',
	"CREATE TABLE commits (
		id                    INTEGER PRIMARY KEY,
		object_format         TEXT NOT NULL,
		object_id             TEXT NOT NULL,
		parents               TEXT NOT NULL DEFAULT (''),
		author_identity_id    INTEGER NOT NULL REFERENCES git_identities(id),
		author_time           INTEGER NOT NULL,
		author_tz             INTEGER NOT NULL,
		author_date           TEXT NOT NULL,
		committer_identity_id INTEGER NOT NULL REFERENCES git_identities(id),
		committer_time        INTEGER NOT NULL,
		committer_tz          INTEGER NOT NULL,
		committer_date        TEXT NOT NULL,
		subject               TEXT NOT NULL,
		UNIQUE (object_format, object_id)
	)",
	'CREATE TABLE repository_commits (
		repository_id INTEGER NOT NULL REFERENCES repositories(id),
		commit_id     INTEGER NOT NULL REFERENCES commits(id),
		PRIMARY KEY (repository_id, commit_id)
	)',
	// Mirror of config.toml, so report queries stay pure SQL.
	'CREATE TABLE accepted_identities (
		kind       TEXT NOT NULL,
		value      TEXT NOT NULL,
		value_norm TEXT NOT NULL,
		PRIMARY KEY (kind, value_norm)
	)',
	"CREATE TABLE sync_results (
		scope           TEXT NOT NULL,
		ref_id          TEXT NOT NULL,
		status          TEXT NOT NULL,
		message         TEXT NOT NULL DEFAULT (''),
		last_attempt_at INTEGER NOT NULL,
		last_success_at INTEGER NOT NULL DEFAULT 0,
		PRIMARY KEY (scope, ref_id)
	)",
	'CREATE INDEX commits_author ON commits (author_identity_id, author_date)',
	'CREATE INDEX commits_committer ON commits (committer_identity_id, committer_date)',
	'CREATE INDEX repository_commits_commit ON repository_commits (commit_id)',
]

// v2 moves the ref digest from a repository to a location. One repository can be
// reachable through a working tree and a cached clone at the same time and those
// move independently: a single digest per repository cannot say which of them
// changed. Existing digests are dropped, costing one full rescan and is the
// safe direction to be wrong in.
const v2 = [
	"ALTER TABLE repository_locations ADD COLUMN refs_digest TEXT NOT NULL DEFAULT ''",
	'ALTER TABLE repositories DROP COLUMN refs_digest',
]
