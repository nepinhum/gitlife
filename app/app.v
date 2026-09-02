module app

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
	// TODO : one arm per command as its module lands
	return error("'${command}' is not implemented yet")
}
