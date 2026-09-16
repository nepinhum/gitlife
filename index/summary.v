module index

// accepted is the predicate that decides whether an observed Git identity is one
// the user has claimed. Nothing here infers: an identity matches only a name or
// an email the user wrote down.
const accepted = "EXISTS (SELECT 1 FROM accepted_identities a
	WHERE (a.kind = 'email' AND a.value_norm = gi.email_norm)
	   OR (a.kind = 'name' AND a.value_norm = gi.name))"

pub struct Filter {
pub:
	since          string // YYYY-MM-DD, inclusive
	until          string // YYYY-MM-DD, inclusive
	repository_ids []i64
	role           string = 'author' // author | committer
}

pub struct Count {
pub:
	label string
	count int
}

pub struct CommitRef {
pub:
	object_id string
	date      string
	subject   string
}

pub struct Candidate {
pub:
	name         string
	email        string
	authored     int
	committed    int
	repositories int
}

pub struct Summary {
pub:
	role              string
	authored_commits  int
	committed_commits int
	repositories      int
	repos_by_source   []Count
	first             CommitRef
	latest            CommitRef
	by_year           []Count
	top_repositories  []Count
	candidates        []Candidate
	accepted          int
}

fn (f Filter) mine(role string) (string, []string) {
	mut params := []string{}
	mut where := ['gi.id = c.${role}_identity_id', accepted]
	if f.since != '' {
		where << 'c.${role}_date >= ?'
		params << f.since
	}
	if f.until != '' {
		where << 'c.${role}_date <= ?'
		params << f.until
	}
	if f.repository_ids.len > 0 {
		where << 'EXISTS (SELECT 1 FROM repository_commits rc WHERE rc.commit_id = c.id\n\t\t\tAND rc.repository_id IN (${ids(f.repository_ids)}))'
	}
	q :=
		'SELECT c.id AS id, c.object_id AS object_id, c.subject AS subject,\n\t\t\tc.${role}_date AS d, c.${role}_time AS t\n\t\tFROM commits c, git_identities gi\n\t\tWHERE ' +
		where.join(' AND ')
	return q, params
}

fn (f Filter) repo_scope() string {
	if f.repository_ids.len == 0 {
		return '1 = 1'
	}
	return 'dc.repository_id IN (${ids(f.repository_ids)})'
}

fn ids(v []i64) string {
	return v.map(it.str()).join(', ')
}

pub fn (mut d DB) summary(f Filter) !Summary {
	role := f.which()
	other := if role == 'author' { 'committer' } else { 'author' }
	sel, params := f.mine(role)
	rest, rest_params := f.mine(other)
	scope := f.repo_scope()

	// Six of the answers below are about one set of commits. The set is gathered
	// once and then read from rather than selected again for every answer: the
	// report used to walk the history seven times to describe it once. The role
	// the report is not about keeps its own scan, which is one scan for one
	// number.
	d.conn.exec('DROP TABLE IF EXISTS selected')!
	d.conn.exec('CREATE TEMP TABLE selected (
		id INTEGER PRIMARY KEY,
		d  TEXT NOT NULL,
		t  INTEGER NOT NULL
	)')!
	// Only what the aggregates read is kept. The object id and the subject belong
	// to two commits out of however many the set holds and those two are looked
	// up when they are asked for.
	d.conn.exec_param_many('INSERT INTO selected (id, d, t) SELECT id, d, t FROM (${sel})',
		params)!
	// The first and the last commit are the same order read from either end.
	d.conn.exec('CREATE INDEX selected_time ON selected (t, id)')!

	held := d.count('SELECT COUNT(*) FROM selected', [])!
	counterpart := d.count(with(rest, 'SELECT COUNT(DISTINCT id) FROM mine'), rest_params)!

	// How many repositories the work is spread over and which of them hold most
	// of it are the same grouping, counted and then cut.
	per_repository := d.counts('SELECT r.display_name, COUNT(*) FROM repository_commits rc
		JOIN repositories r ON r.id = rc.repository_id
		WHERE rc.commit_id IN (SELECT id FROM selected)
		GROUP BY r.id ORDER BY 2 DESC, 1 ASC', [])!

	by_source := 'SELECT s.kind, COUNT(DISTINCT dc.repository_id)\n\t\tFROM discoveries dc JOIN sources s ON s.id = dc.source_id\n\t\tWHERE ${scope} GROUP BY s.kind ORDER BY s.kind'
	years := 'SELECT substr(d, 1, 4), COUNT(*) FROM selected GROUP BY 1 ORDER BY 1'
	edge := 'SELECT c.object_id, s.d, c.subject FROM selected s
		JOIN commits c ON c.id = s.id
		ORDER BY s.t'

	return Summary{
		role:              role
		authored_commits:  if role == 'author' { held } else { counterpart }
		committed_commits: if role == 'committer' { held } else { counterpart }
		repositories:      per_repository.len
		repos_by_source:   d.counts(by_source, [])!
		first:             d.commit_ref(edge + ' ASC, c.object_id ASC LIMIT 1', [])!
		latest:            d.commit_ref(edge + ' DESC, c.object_id ASC LIMIT 1', [])!
		by_year:           d.counts(years, [])!
		top_repositories:  if per_repository.len > 10 { per_repository[..10] } else { per_repository }
		candidates:        d.identity_candidates()!
		accepted:          d.count('SELECT COUNT(*) FROM accepted_identities', [])!
	}
}

fn with(mine string, query string) string {
	return 'WITH mine AS (${mine}) ${query}'
}

pub fn (mut d DB) identity_candidates() ![]Candidate {
	// The two counts a candidate is ranked by come from covering indexes, a lookup
	// each. How many repositories a person appears in does not: it walks both
	// roles and folds them into a distinct count which is why it is asked only
	// of the twenty rows that survive the ranking rather than of every identity
	// the index has ever seen.
	rows := d.conn.exec('WITH ranked AS (
			SELECT gi.id AS id, gi.name AS name, gi.email AS email,
				(SELECT COUNT(*) FROM commits c WHERE c.author_identity_id = gi.id) AS authored,
				(SELECT COUNT(*) FROM commits c WHERE c.committer_identity_id = gi.id) AS committed
			FROM git_identities gi
			WHERE NOT ${accepted}
			ORDER BY authored DESC, committed DESC, email ASC
			LIMIT 20)
		SELECT name, email, authored, committed,
			(SELECT COUNT(DISTINCT rc.repository_id) FROM repository_commits rc
			 JOIN commits c ON c.id = rc.commit_id
			 WHERE c.author_identity_id = ranked.id OR c.committer_identity_id = ranked.id)
		FROM ranked
		ORDER BY authored DESC, committed DESC, email ASC')!
	return rows.map(Candidate{
		name:         it.val(0)
		email:        it.val(1)
		authored:     it.val(2).int()
		committed:    it.val(3).int()
		repositories: it.val(4).int()
	})
}

pub fn (mut d DB) resolve_repositories(name_or_id string) ![]i64 {
	rows := d.conn.exec_param2('SELECT id FROM repositories WHERE display_name = ? OR id = ?',
		name_or_id, name_or_id)!
	if rows.len == 0 {
		return error("no repository matches '${name_or_id}'")
	}
	if rows.len > 1 {
		return error("'${name_or_id}' matches ${rows.len} repositories; use a repository id")
	}
	return rows.map(it.val(0).i64())
}

pub fn (mut d DB) repositories_of_source(source_id string) ![]i64 {
	rows := d.conn.exec_param('SELECT repository_id FROM discoveries WHERE source_id = ?',
		source_id)!
	if rows.len == 0 {
		return error("source '${source_id}' has no discovered repositories")
	}
	return rows.map(it.val(0).i64())
}

fn (mut d DB) count(q string, params []string) !int {
	rows := d.conn.exec_param_many(q, params)!
	if rows.len == 0 {
		return 0
	}
	return rows[0].val(0).int()
}

fn (mut d DB) counts(q string, params []string) ![]Count {
	rows := d.conn.exec_param_many(q, params)!
	return rows.map(Count{
		label: it.val(0)
		count: it.val(1).int()
	})
}

fn (mut d DB) commit_ref(q string, params []string) !CommitRef {
	rows := d.conn.exec_param_many(q, params)!
	if rows.len == 0 {
		return CommitRef{}
	}
	return CommitRef{
		object_id: rows[0].val(0)
		date:      rows[0].val(1)
		subject:   rows[0].val(2)
	}
}
