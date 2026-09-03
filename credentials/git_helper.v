module credentials

// Git asks for credentials through a small line protocol: it writes a request of
// 'key=value' lines to a helper's stdin and reads the same shape back. This is
// the bridge between that protocol and the provider chain. It lets one
// credential source serve both API discovery and Git transport.
//
// A token that discovers a private repository through GraphQL doesn't, by
// itself, let 'git fetch' read it.
pub struct HostCredential {
pub:
	host     string
	username string
	chain    []Provider
}

// github_host is the credential gitlife offers for github.com. GitHub accepts any
// username alongside a token; 'x-access-token' is the conventional one.
pub fn github_host(allow_gh bool) HostCredential {
	return HostCredential{
		host:     'github.com'
		username: 'x-access-token'
		chain:    github_chain(allow_gh)
	}
}

// answer handles one 'get', returning what git expects on stdout.
//
// An empty answer means "nothing known here", tells git to carry on and try
// something else. That is deliberately different from a wrong answer and makes
// git fail against the server with a confusing error.
pub fn answer(request string, hosts []HostCredential) string {
	fields := parse_request(request)
	// Only https carries a token. ssh authenticates through the user's agent and
	// answering for it would replace a working key with a useless password.
	if fields['protocol'] or { '' } != 'https' {
		return ''
	}
	host := fields['host'] or { '' }
	for candidate in hosts {
		if candidate.host != host {
			continue
		}
		token := resolve(candidate.chain) or { return '' }
		return 'username=${candidate.username}\npassword=${token.value}\n'
	}
	return ''
}

fn parse_request(request string) map[string]string {
	mut fields := map[string]string{}
	for line in request.split_into_lines() {
		// A blank line ends the request; anything after it is not ours to read.
		if line.trim_space() == '' {
			break
		}
		index := line.index('=') or { continue }
		fields[line[..index]] = line[index + 1..]
	}
	return fields
}

// helper_config is the value gitlife gives git for 'credential.helper'.
//
// It must be paired with an empty value first which resets the inherited helper
// list. Without that reset an ambient helper, a keychain or a stale token,
// answers before this one is consulted.
//
// The '!' form runs through a shell, which is what lets the executable path be
// quoted. Git otherwise splits a helper command on spaces and a gitlife
// installed under a path with a space would silently never be found.
pub fn helper_config(executable string) string {
	return '!' + shell_quote(executable) + ' credential-helper'
}

// helper_args are the arguments that put the bridge in front of a git invocation.
pub fn helper_args(executable string) []string {
	return ['-c', 'credential.helper=', '-c', 'credential.helper=' + helper_config(executable)]
}

fn shell_quote(s string) string {
	return "'" + s.replace("'", "'\\''") + "'"
}
