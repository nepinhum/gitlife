module report

import json2
import cache
import index
import syncer

pub fn summary_json(s index.Summary) string {
	return json2.encode(s, prettify: true, escape_unicode: true)
}

pub fn summary_table(s index.Summary) string {
	mut b := []string{}
	b << row('accepted identities', s.accepted.str())
	b << row('authored commits', s.authored_commits.str())
	b << row('committed commits', s.committed_commits.str())
	b << row('repositories', s.repositories.str())
	if s.first.object_id != '' {
		b << row('first', '${s.first.date}  ${short(s.first.object_id)}  ${s.first.subject}')
		b << row('latest', '${s.latest.date}  ${short(s.latest.object_id)}  ${s.latest.subject}')
	}
	append(mut b, 'activity by year', s.by_year)
	append(mut b, 'most active repositories', s.top_repositories)
	append(mut b, 'repositories by source', s.repos_by_source)
	if s.candidates.len > 0 {
		b << ''
		b << 'unmatched identities'
		b << '  authored  committed  repos  identity'
		for c in s.candidates {
			b << '  ${c.authored:8}  ${c.committed:9}  ${c.repositories:5}  ${c.name} <${c.email}>'
		}
	}
	if s.accepted == 0 {
		b << ''
		b << 'No identity has been accepted, so every total is zero.'
		b << 'Add one with: gitlife identity add --email you@example.com'
	}
	return b.join('\n')
}

pub fn sync_table(r syncer.Report) string {
	mut b := []string{}
	for note in r.notes {
		b << note
	}
	if r.notes.len > 0 && r.outcomes.len > 0 {
		b << ''
	}
	mut width := 0
	for o in r.outcomes {
		if name_of(o).len > width {
			width = name_of(o).len
		}
	}
	for o in r.outcomes {
		note := if o.message != '' { o.message } else { what(o) }
		b << '${o.status:-9}  ${pad(name_of(o), width)}  ${note}'.trim_right(' ')
	}
	if b.len > 0 {
		b << ''
	}
	mut totals := '${r.updated} updated, ${r.unchanged} unchanged, ${r.failed} failed'
	if r.new_commits > 0 {
		totals += ', ${r.new_commits} new commits'
	}
	b << '${totals} in ${seconds(r.elapsed_ms)}'
	return b.join('\n')
}

fn name_of(o syncer.Outcome) string {
	return if o.repository != '' { o.repository } else { o.source }
}

// detail says what the work actually was. A sync that reports only 'ok' can't
// be told from one that did nothing and 'unchanged' is the most common outcome
// there is, which makes what a repository cost worth showing.
fn what(o syncer.Outcome) string {
	mut parts := []string{}
	if o.action != '' && o.action != 'read' {
		parts << o.action
	}
	if o.status == 'ok' {
		parts << if o.new_commits > 0 {
			'${o.new_commits} new of ${count(o.commits, 'commit')}'
		} else {
			count(o.commits, 'commit')
		}
	}
	if o.elapsed_ms >= 100 {
		parts << seconds(o.elapsed_ms)
	}
	return parts.join(', ')
}

fn count(n int, word string) string {
	return if n == 1 { '1 ${word}' } else { '${n} ${word}s' }
}

fn seconds(ms int) string {
	return '${f64(ms) / 1000.0:.2}s'
}

pub fn sync_json(r syncer.Report) string {
	return json2.encode(r, prettify: true, escape_unicode: true)
}

fn append(mut b []string, title string, counts []index.Count) {
	if counts.len == 0 {
		return
	}
	b << ''
	b << title
	for c in counts {
		b << '  ${c.label:-24}  ${c.count}'
	}
}

fn row(label string, value string) string {
	return '${label:-20}  ${value}'
}

fn short(oid string) string {
	return if oid.len > 12 { oid[..12] } else { oid }
}

pub fn repos_json(repos []index.Repo) string {
	return json2.encode(repos, prettify: true, escape_unicode: true)
}

pub fn repos_table(repos []index.Repo) string {
	if repos.len == 0 {
		return 'no repository holds a commit matching this filter'
	}
	mut b := ['    id  authored  committed  first       latest      repository']
	for r in repos {
		b << '  ${r.id:4}  ${r.authored:8}  ${r.committed:9}  ${blank(r.first):-10}  ${blank(r.latest):-10}  ${r.name}'
	}
	return b.join('\n')
}

pub fn commits_json(rows []index.CommitRow) string {
	return json2.encode(rows, prettify: true, escape_unicode: true)
}

pub fn commits_table(rows []index.CommitRow) string {
	if rows.len == 0 {
		return 'no commit matches this filter'
	}

	mut labels := []string{cap: rows.len}
	mut width := 0
	for r in rows {
		others := if r.repositories > 1 { ' +${r.repositories - 1}' } else { '' }
		label := r.repository + others
		if label.len > width {
			width = label.len
		}
		labels << label
	}
	mut b := []string{cap: rows.len}
	for i, r in rows {
		b << '${r.date}  ${short(r.object_id)}  ${pad(labels[i], width)}  ${r.subject}'
	}
	return b.join('\n')
}

fn pad(s string, width int) string {
	return if s.len >= width { s } else { s + ' '.repeat(width - s.len) }
}

pub fn timeline_json(counts []index.Count) string {
	return json2.encode(counts, prettify: true, escape_unicode: true)
}

pub fn timeline_table(counts []index.Count) string {
	if counts.len == 0 {
		return 'no commit matches this filter'
	}
	mut peak := 1
	for c in counts {
		if c.count > peak {
			peak = c.count
		}
	}
	mut b := []string{}
	for c in counts {
		mut bar := c.count * 40 / peak
		if bar == 0 && c.count > 0 {
			bar = 1
		}
		b << '  ${c.label:-8}  ${c.count:6}  ${'#'.repeat(bar)}'
	}
	return b.join('\n')
}

fn blank(s string) string {
	return if s == '' { '-' } else { s }
}

pub fn purge_table(p index.Purge, c cache.Pruned, dry_run bool) string {
	verb := if dry_run { 'would remove' } else { 'removed' }
	mut b := [verb]
	b << row('  repositories', p.repositories.str())
	b << row('  commits', p.commits.str())
	b << row('  identities', p.identities.str())
	b << row('  sources', p.sources.str())
	b << row('  cached clones', '${c.clones}  (${bytes(c.bytes)})')
	for dir in c.dirs {
		b << '    ${dir}'
	}
	if dry_run {
		b << ''
		b << "Nothing was removed. Run 'gitlife purge' without --dry-run to do it."
	}
	return b.join('\n')
}

fn bytes(n i64) string {
	if n < 1024 {
		return '${n} B'
	}
	if n < 1024 * 1024 {
		return '${f64(n) / 1024.0:.1} KB'
	}
	return '${f64(n) / (1024.0 * 1024.0):.1} MB'
}

pub fn purge_json(p index.Purge, c cache.Pruned, dry_run bool) string {
	return json2.encode({
		'dry_run':      json2.Any(dry_run)
		'repositories': p.repositories
		'commits':      p.commits
		'identities':   p.identities
		'sources':      p.sources
		'clones':       c.clones
		'bytes':        c.bytes
		'directories':  json2.Any(c.dirs.map(json2.Any(it)))
	},
		prettify:       true
		escape_unicode: true
	)
}
