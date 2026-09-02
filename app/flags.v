module app

const valued = ['format', 'since', 'until', 'repo', 'source', 'name', 'email', 'limit', 'by', 'jobs']

struct Flags {
mut:
	format  string = 'table'
	since   string
	until   string
	repo    string
	source  string
	role    string = 'author'
	name    string
	email   string
	limit   int = 50
	by      string = 'month'
	jobs    int
	dry_run bool
	rest    []string
}

// parse accepts '--flag value' and '--flag=value'. Anything that is not a flag is
// a positional argument, in order.
fn parse(args []string) !Flags {
	mut f := Flags{}
	mut i := 0
	for i < args.len {
		arg := args[i]
		i++
		if !arg.starts_with('--') {
			f.rest << arg
			continue
		}
		mut name := arg[2..]
		mut value := ''
		mut have_value := false
		if idx := name.index('=') {
			value = name[idx + 1..]
			name = name[..idx]
			have_value = true
		}
		// The role selectors take no value; every other known flag does. An
		// unknown flag is rejected before a value is consumed which reports the
		// typo rather than a missing value.
		if name in ['author', 'committer'] {
			f.role = name
			continue
		}
		if name == 'dry-run' {
			f.dry_run = true
			continue
		}
		if name !in valued {
			return error("unknown flag '--${name}'")
		}
		if !have_value {
			if i >= args.len {
				return error('--${name} needs a value')
			}
			value = args[i]
			i++
		}
		match name {
			'format' {
				if value !in ['table', 'json'] {
					return error('--format must be table or json')
				}
				f.format = value
			}
			'since' {
				f.since = check_date(value)!
			}
			'until' {
				f.until = check_date(value)!
			}
			'repo' {
				f.repo = value
			}
			'source' {
				f.source = value
			}
			'name' {
				f.name = value
			}
			'email' {
				f.email = value
			}
			'limit' {
				f.limit = value.int()
				if f.limit < 1 {
					return error("--limit must be a positive number, not '${value}'")
				}
			}
			'jobs' {
				f.jobs = value.int()
				if f.jobs < 1 {
					return error("--jobs must be a positive number, not '${value}'")
				}
			}
			'by' {
				if value !in ['day', 'month', 'year'] {
					return error('--by must be day, month or year')
				}
				f.by = value
			}
			else {
				return error("unknown flag '--${name}'")
			}
		}
	}
	return f
}

fn check_date(s string) !string {
	if s.len != 10 || s[4] != `-` || s[7] != `-` {
		return error("'${s}' is not a date; use YYYY-MM-DD")
	}
	return s
}
