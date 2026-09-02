module app

import os
import cache
import config
import credentials
import index
import report
import source
import syncer

// The command surface, verbatim. A raw string: v fmt (for now) collapses an ordinary
// multiline literal into one line of \n escapes.
const help = r"usage:
  gitlife source add <local|git|github> <spec>
  gitlife source list
  gitlife source remove <source-id>
  gitlife identity add --name <name> | --email <email>
  gitlife identity list
  gitlife identity candidates
  gitlife sync [source-id] [--jobs n]
  gitlife summary [filters]
  gitlife repos [filters]
  gitlife commits [filters] [--limit n]
  gitlife timeline [filters] [--by day|month|year]
  gitlife purge [--dry-run]

plumbing:
  gitlife credential-helper get   git's credential protocol, invoked by git

filters:
  --source <id>      restrict to repositories discovered by one source
  --repo <name|id>   restrict to one repository
  --since <date>     YYYY-MM-DD, inclusive
  --until <date>     YYYY-MM-DD, inclusive
  --author           count the author role (default)
  --committer        count the committer role
  --format table|json
  --limit <n>        how many commits to list (default 50)
  --by <period>      timeline bucket: day, month (default) or year
  --jobs <n>         repositories to sync at once (default: one per CPU)
"

fn usage() string {
	return '${build_info()} - a provider independent history of your work in Git\n\n' + help
}

pub fn run(args []string) int {
	if args.len == 0 || args[0] in ['help', '-h', '--help'] {
		println(usage())
		return 0
	}
	if args[0] in ['version', '--version'] {
		println(build_info())
		return 0
	}
	// Git invokes this and expects nothing on stdout but its own protocol. It
	// runs before the config is loaded.
	if args[0] == 'credential-helper' {
		return credential_helper(args[1..])
	}
	f := parse(args[1..]) or {
		eprintln('gitlife: ${err.msg()}')
		return 2
	}
	code := dispatch(args[0], f) or {
		eprintln('gitlife: ${err.msg()}')
		return 1
	}
	return code
}

// credential_helper implements git's credential helper protocol. Only 'get'
// answers. 'store' and 'erase' succeed silently because gitlife persists no
// credential.
fn credential_helper(args []string) int {
	operation := if args.len > 0 { args[0] } else { '' }
	if operation != 'get' {
		return 0
	}
	reply := credentials.answer(os.get_raw_lines_joined(), [
		credentials.github_host(true),
	])
	if reply != '' {
		print(reply)
	}
	return 0
}

// dispatch runs one command and answers with its exit code. A command that fails
// returns an error and run turns it into 1, argv that cannot be parsed never
// reaches here and is 2.
fn dispatch(command string, f Flags) !int {
	paths := config.paths()
	mut c := config.load(paths)!
	match command {
		'source' {
			return source_cmd(mut c, f)
		}
		'identity' {
			return identity_cmd(mut c, f)
		}
		'sync' {
			return sync_cmd(c, paths, f)
		}
		'purge' {
			return purge_cmd(c, paths, f)
		}
		'summary', 'repos', 'commits', 'timeline' {
			return report_cmd(command, c, paths, f)
		}
		else {
			return error("unknown command '${command}'; try 'gitlife help'")
		}
	}
}

fn source_cmd(mut c config.Config, f Flags) !int {
	if f.rest.len == 0 {
		return error('usage: gitlife source <add|list|remove>')
	}
	match f.rest[0] {
		'add' {
			if f.rest.len != 3 {
				return error('usage: gitlife source add <local|git|github> <spec>')
			}
			kind := f.rest[1]
			if kind !in ['local', 'git', 'github'] {
				return error("unknown source kind '${kind}'")
			}
			// A local spec is canonicalized here which keeps one directory reached
			// by two paths a single source. A remote spec is redacted because a
			// source id is printed in every sync line and report.
			spec := match kind {
				'local' { os.real_path(f.rest[2]) }
				'git' { source.redact_url(f.rest[2]) }
				else { f.rest[2] }
			}
			if kind == 'local' && !os.is_dir(spec) {
				return error('${f.rest[2]}: not a directory')
			}
			s := config.Source{
				kind: kind
				spec: spec
			}
			if c.sources.any(it.id() == s.id()) {
				println('already configured: ${s.id()}')
				return 0
			}
			c.sources << s
			c.save()!
			println('added ${s.id()}')
			return 0
		}
		'list' {
			if c.sources.len == 0 {
				println('no sources configured')
				return 0
			}
			for s in c.sources {
				state := if s.active { '' } else { '  (inactive)' }
				println('${s.id()}${state}')
			}
			return 0
		}
		'remove' {
			if f.rest.len != 2 {
				return error('usage: gitlife source remove <source-id>')
			}
			id := f.rest[1]
			before := c.sources.len
			c.sources = c.sources.filter(it.id() != id)
			if c.sources.len == before {
				return error("no configured source with id '${id}'")
			}
			c.save()!
			// Indexed history is kept. The database marks the source inactive on the
			// next sync and purging is a separate command.
			println('removed ${id}; indexed history was kept')
			return 0
		}
		else {
			return error('usage: gitlife source <add|list|remove>')
		}
	}
}

fn identity_cmd(mut c config.Config, f Flags) !int {
	if f.rest.len == 0 {
		return error('usage: gitlife identity <add|list|candidates>')
	}
	match f.rest[0] {
		'add' {
			if f.name == '' && f.email == '' {
				return error('usage: gitlife identity add --name <name> | --email <email>')
			}
			i := config.Identity{
				name: f.name
				email: f.email
			}
			if c.identities.any(it.name == i.name && it.email == i.email) {
				println('already accepted')
				return 0
			}
			c.identities << i
			c.save()!
			println('accepted ${describe(i)}')
			return 0
		}
		'list' {
			if c.identities.len == 0 {
				println('no identities accepted')
				return 0
			}
			for i in c.identities {
				println(describe(i))
			}
			return 0
		}
		'candidates' {
			mut d := index.open(c.paths.db_file())!
			defer {
				d.close() or {}
			}
			cands := d.identity_candidates()!
			if cands.len == 0 {
				println('no unmatched identities')
				return 0
			}
			println('  authored  committed  repos  identity')
			for cand in cands {
				println('  ${cand.authored:8}  ${cand.committed:9}  ${cand.repositories:5}  ${cand.name} <${cand.email}>')
			}
			return 0
		}
		else {
			return error('usage: gitlife identity <add|list|candidates>')
		}
	}
}

fn sync_cmd(c config.Config, paths config.Paths, f Flags) !int {
	if c.sources.len == 0 {
		return error("no sources configured; try 'gitlife source add local ~/dev'")
	}
	selector := if f.rest.len > 0 { f.rest[0] } else { '' }
	mut d := index.open(paths.db_file())!
	defer {
		d.close() or {}
	}
	r := syncer.run(c, mut d, syncer.Options{
		selector: selector
		jobs: f.jobs
	})!
	println(if f.format == 'json' { report.sync_json(r) } else { report.sync_table(r) })
	// A failed source or repository makes the whole run nonzero, it lets a
	// script tell a partial sync from a clean one.
	return if r.failed > 0 { 1 } else { 0 }
}

// purge_cmd forgets what no configured source can still reach: the repositories
// of a removed source, the commits only they held and the clones nothing points
// at. A sync can rebuild all of it, but it is deleted, that is what --dry-run
// counts first.
fn purge_cmd(c config.Config, paths config.Paths, f Flags) !int {
	mut d := index.open(paths.db_file())!
	defer {
		d.close() or {}
	}
	// The config is the truth about what's configured. The database's 'active'
	// flag is only as fresh as the last sync and a source removed since then
	// must not keep its history alive.
	d.deactivate_sources_except(c.sources.filter(it.active).map(it.id()))!

	p := d.purge(f.dry_run)!
	store := cache.Cache{
		root: paths.repos_dir()
	}
	pruned := store.prune(p.keep, f.dry_run)!
	println(if f.format == 'json' {
		report.purge_json(p, pruned, f.dry_run)
	} else {
		report.purge_table(p, pruned, f.dry_run)
	})
	return 0
}

// Every report answers the same question about the same commits and differs
// only in how much is shown. One path: open the index, build the filter,
// render.
fn report_cmd(command string, c config.Config, paths config.Paths, f Flags) !int {
	mut d := index.open(paths.db_file())!
	defer {
		d.close() or {}
	}
	filter := narrow(c, mut d, f)!
	json := f.format == 'json'
	out := match command {
		'repos' {
			rows := d.repos(filter)!
			if json { report.repos_json(rows) } else { report.repos_table(rows) }
		}
		'commits' {
			rows := d.commits(filter, f.limit)!
			if json { report.commits_json(rows) } else { report.commits_table(rows) }
		}
		'timeline' {
			rows := d.timeline(filter, f.by)!
			if json { report.timeline_json(rows) } else { report.timeline_table(rows) }
		}
		else {
			s := d.summary(filter)!
			if json { report.summary_json(s) } else { report.summary_table(s) }
		}
	}
	println(out)
	return 0
}

// narrow turns the shared filter flags into a Filter. Accepted identities are
// pushed into the database first: the user writes them in config.toml, the
// queries read them from a table.
fn narrow(c config.Config, mut d index.DB, f Flags) !index.Filter {
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

	mut repo_ids := []i64{}
	if f.repo != '' {
		repo_ids = d.resolve_repositories(f.repo)!
	}
	if f.source != '' {
		ids := d.repositories_of_source(f.source)!
		repo_ids = if repo_ids.len == 0 { ids.clone() } else { repo_ids.filter(it in ids) }
	}
	return index.Filter{
		since: f.since
		until: f.until
		repository_ids: repo_ids
		role: f.role
	}
}

fn describe(i config.Identity) string {
	if i.name != '' && i.email != '' {
		return '${i.name} <${i.email}>'
	}
	return if i.name != '' { 'name ${i.name}' } else { 'email ${i.email}' }
}
