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
	q := 'SELECT c.id AS id, c.object_id AS object_id, c.subject AS subject,\n\t\t\tc.${role}_date AS d, c.${role}_time AS t\n\t\tFROM commits c, git_identities gi\n\t\tWHERE ' + where.join(' AND ')
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
	authored, authored_params := f.mine('author')
	committed, committed_params := f.mine('committer')
	sel, params := f.mine(role)
	scope := f.repo_scope()

	total := 'SELECT COUNT(DISTINCT id) FROM mine'
	repos := 'SELECT COUNT(DISTINCT rc.repository_id) FROM repository_commits rc
		WHERE rc.commit_id IN (SELECT id FROM mine)'
	by_source := 'SELECT s.kind, COUNT(DISTINCT dc.repository_id)\n\t\tFROM discoveries dc JOIN sources s ON s.id = dc.source_id\n\t\tWHERE ${scope} GROUP BY s.kind ORDER BY s.kind'
	years := 'SELECT substr(d, 1, 4), COUNT(DISTINCT id) FROM mine GROUP BY 1 ORDER BY 1'
	top := 'SELECT r.display_name, COUNT(*) FROM repository_commits rc
		JOIN repositories r ON r.id = rc.repository_id
		WHERE rc.commit_id IN (SELECT id FROM mine)
		GROUP BY r.id ORDER BY 2 DESC, 1 ASC LIMIT 10'
	edge := 'SELECT object_id, d, subject FROM mine ORDER BY t'

	return Summary{
		role: role
		authored_commits: d.count(with(authored, total), authored_params)!
		committed_commits: d.count(with(committed, total), committed_params)!
		repositories: d.count(with(sel, repos), params)!
		repos_by_source: d.counts(by_source, [])!
		first: d.commit_ref(with(sel, edge + ' ASC, object_id ASC LIMIT 1'), params)!
		latest: d.commit_ref(with(sel, edge + ' DESC, object_id ASC LIMIT 1'), params)!
		by_year: d.counts(with(sel, years), params)!
		top_repositories: d.counts(with(sel, top), params)!
		candidates: d.identity_candidates()!
		accepted: d.count('SELECT COUNT(*) FROM accepted_identities', [])!
	}
}

fn with(mine string, query string) string {
	return 'WITH mine AS (${mine}) ${query}'
}

pub fn (mut d DB) identity_candidates() ![]Candidate {
	rows := d.conn.exec('SELECT gi.name, gi.email,\n\t\t\t(SELECT COUNT(*) FROM commits c WHERE c.author_identity_id = gi.id),\n\t\t\t(SELECT COUNT(*) FROM commits c WHERE c.committer_identity_id = gi.id),\n\t\t\t(SELECT COUNT(DISTINCT rc.repository_id) FROM repository_commits rc\n\t\t\t JOIN commits c ON c.id = rc.commit_id\n\t\t\t WHERE c.author_identity_id = gi.id OR c.committer_identity_id = gi.id)\n\t\tFROM git_identities gi\n\t\tWHERE NOT ${accepted}\n\t\tORDER BY 3 DESC, 4 DESC, 2 ASC\n\t\tLIMIT 20')!
	return rows.map(Candidate{
		name: it.val(0)
		email: it.val(1)
		authored: it.val(2).int()
		committed: it.val(3).int()
		repositories: it.val(4).int()
	})
}

pub fn (mut d DB) resolve_repositories(name_or_id string) ![]i64 {
	rows := d.conn.exec_param2('SELECT id FROM repositories WHERE display_name = ? OR id = ?', name_or_id, name_or_id)!
	if rows.len == 0 {
		return error("no repository matches '${name_or_id}'")
	}
	if rows.len > 1 {
		return error("'${name_or_id}' matches ${rows.len} repositories; use a repository id")
	}
	return rows.map(it.val(0).i64())
}

pub fn (mut d DB) repositories_of_source(source_id string) ![]i64 {
	rows := d.conn.exec_param('SELECT repository_id FROM discoveries WHERE source_id = ?', source_id)!
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
		date: rows[0].val(1)
		subject: rows[0].val(2)
	}
}
