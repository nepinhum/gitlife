module gitrepo

import proc

// narrating_variables make git describe its own traffic. With GIT_TRACE_REDACT=0
// they defeat git's own redaction and the Authorization header, a base64 encoded
// token, lands in stderr. gitlife captures stderr into error messages and into
// sync_results.
//
// GIT_ASKPASS and SSH_ASKPASS are removed rather than emptied: git treats an empty
// value as a program named "", which fails confusingly instead of not prompting.
const scrubbed = ['GIT_TRACE', 'GIT_TRACE_CURL', 'GIT_TRACE_PACKET', 'GIT_TRACE_SETUP',
	'GIT_TRACE_PERFORMANCE', 'GIT_TRACE_PACK_ACCESS', 'GIT_TRACE2', 'GIT_TRACE2_EVENT',
	'GIT_TRACE2_PERF', 'GIT_CURL_VERBOSE', 'GIT_ASKPASS', 'SSH_ASKPASS']

// git_env is the environment every git invocation runs with: the caller's, minus
// what would make git narrate a secret, plus what keeps it from asking a question
// nobody is there to answer.
//
// SSH_AUTH_SOCK, HOME and PATH are preserved. ssh remotes keep working through
// the user's agent, and their gitconfig still supplies proxy and CA settings.
// Their credential.helper is neutralized per invocation instead.
pub fn git_env(extra map[string]string) map[string]string {
	mut add := {
		'GIT_TRACE_REDACT':       '1'
		// An unattended sync must never block on a prompt.
		'GIT_TERMINAL_PROMPT':    '0'
		// git rewrites ancestry from replacements and from the graft file before
		// it reports any of it. What is indexed is the history that is actually
		// there which is also the only one two walks taken at different times
		// can agree on.
		'GIT_NO_REPLACE_OBJECTS': '1'
		'GIT_GRAFT_FILE':         '/dev/null'
	}
	for name, value in extra {
		add[name] = value
	}
	return proc.child_env(scrubbed, add)
}
