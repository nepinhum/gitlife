// The reports beyond 'summary': what repositories the work is in, the commits
// themselves and when they happened. Every one counts the same set of commits
// 'summary' counts, Filter.mine, which keeps two reports from disagreeing about
// what belongs to the user.
module index

pub struct Repo {
pub:
	id        i64
	name      string
	authored  int
	committed int
	first     string // date of the earliest commit in the selected role
	latest    string
	location  string // where it is: a remote address or a working tree
}

pub struct CommitRow {
pub:
	object_id  string
	date       string
	subject    string
	repository string
	// A commit can belong to several repositories at once, a fork or a clone
	// alongside its origin. It is listed once and this says how many hold it.
	repositories int
}

// which settles the role once. The field is free text on a public struct and a
// typo must not silently produce a query about a column that doesn't exist.
pub fn (f Filter) which() string {
	return if f.role == 'committer' { 'committer' } else { 'author' }
}

// repos lists the repositories the filtered commits are in.
pub fn (mut d DB) repos(f Filter) ![]Repo {
	authored, authored_params := f.mine('author')
	committed, committed_params := f.mine('committer')
	dates := if f.which() == 'committer' { 'co' } else { 'au' }
	q := "WITH a AS (${authored}), c AS (${committed}),\n\t\tau AS (SELECT rc.repository_id AS rid, COUNT(DISTINCT rc.commit_id) AS n,\n\t\t\t\tMIN(a.d) AS first_date, MAX(a.d) AS last_date\n\t\t\tFROM repository_commits rc JOIN a ON a.id = rc.commit_id\n\t\t\tGROUP BY rc.repository_id),\n\t\tco AS (SELECT rc.repository_id AS rid, COUNT(DISTINCT rc.commit_id) AS n,\n\t\t\t\tMIN(c.d) AS first_date, MAX(c.d) AS last_date\n\t\t\tFROM repository_commits rc JOIN c ON c.id = rc.commit_id\n\t\t\tGROUP BY rc.repository_id)\n\t\tSELECT r.id, r.display_name, COALESCE(au.n, 0), COALESCE(co.n, 0),\n\t\t\tCOALESCE(${dates}.first_date, ''), COALESCE(${dates}.last_date, ''),\n\t\t\tCOALESCE((SELECT l.value FROM repository_locations l\n\t\t\t\tWHERE l.repository_id = r.id\n\t\t\t\tORDER BY CASE l.kind WHEN 'remote' THEN 0 WHEN 'worktree' THEN 1 ELSE 2 END,\n\t\t\t\t\tl.id LIMIT 1), '')\n\t\tFROM repositories r\n\t\tLEFT JOIN au ON au.rid = r.id\n\t\tLEFT JOIN co ON co.rid = r.id\n\t\tWHERE COALESCE(au.n, 0) + COALESCE(co.n, 0) > 0\n\t\tORDER BY COALESCE(au.n, 0) DESC, COALESCE(co.n, 0) DESC, r.display_name"
	// The parameters follow the order the two CTEs appear in because SQLite binds
	// '?' positionally and both carry the same date bounds.
	mut params := authored_params.clone()
	params << committed_params
	rows := d.conn.exec_param_many(q, params)!
	return rows.map(Repo{
		id: it.val(0).i64()
		name: it.val(1)
		authored: it.val(2).int()
		committed: it.val(3).int()
		first: it.val(4)
		latest: it.val(5)
		location: it.val(6)
	})
}

// commits lists the matching commits, newest first. 'limit' is not optional: this
// is the one report whose natural size is a lifetime of work.
pub fn (mut d DB) commits(f Filter, limit int) ![]CommitRow {
	sel, params := f.mine(f.which())
	q := with(sel, "SELECT m.object_id, m.d, m.subject,\n\t\tCOALESCE((SELECT r.display_name FROM repository_commits rc\n\t\t\tJOIN repositories r ON r.id = rc.repository_id\n\t\t\tWHERE rc.commit_id = m.id ORDER BY r.display_name LIMIT 1), ''),\n\t\t(SELECT COUNT(*) FROM repository_commits rc WHERE rc.commit_id = m.id)\n\t\tFROM mine m GROUP BY m.id\n\t\tORDER BY m.t DESC, m.object_id ASC LIMIT ${limit}")
	rows := d.conn.exec_param_many(q, params)!
	return rows.map(CommitRow{
		object_id: it.val(0)
		date: it.val(1)
		subject: it.val(2)
		repository: it.val(3)
		repositories: it.val(4).int()
	})
}

// timeline counts the matching commits per period. Periods with no activity are
// filled in for years and months because a chart that silently omits an idle
// year reads as a busy one.
pub fn (mut d DB) timeline(f Filter, by string) ![]Count {
	sel, params := f.mine(f.which())
	expr := match by {
		'year' { 'substr(d, 1, 4)' }
		'day' { 'd' }
		else { 'substr(d, 1, 7)' }
	}
	q := with(sel, 'SELECT ${expr}, COUNT(DISTINCT id) FROM mine GROUP BY 1 ORDER BY 1')
	return fill(d.counts(q, params)!, by)
}

fn fill(counts []Count, by string) []Count {
	if counts.len < 2 || by == 'day' {
		return counts
	}
	mut out := []Count{}
	for i, c in counts {
		if i > 0 {
			mut label := next(counts[i - 1].label, by)
			for label != c.label && out.len < 4096 {
				out << Count{
					label: label
				}
				label = next(label, by)
			}
		}
		out << c
	}
	return out
}

fn next(label string, by string) string {
	if by == 'year' {
		return (label.int() + 1).str()
	}
	year := label[..4].int()
	month := label[5..].int()
	return if month == 12 {
		'${year + 1}-01'
	} else {
		'${year}-${month + 1:02}'
	}
}
