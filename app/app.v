module app

import os
import config
import source

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

const commands = ['source', 'identity', 'sync', 'purge', 'summary', 'repos', 'commits', 'timeline']

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

// dispatch runs one command and answers with its exit code. A command that fails
// returns an error and run turns it into 1, argv that cannot be parsed never
// reaches here and is 2.
fn dispatch(command string, f Flags) !int {
	if command !in commands {
		return error("unknown command '${command}'; try 'gitlife help'")
	}
	paths := config.paths()
	mut c := config.load(paths)!
	match command {
		'source' {
			return source_cmd(mut c, f)
		}
		else {
			// TODO : one arm per command as its module lands
			return error("'${command}' is not implemented yet")
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
