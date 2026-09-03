module credentials

import os
import proc

pub struct Token {
pub:
	value  string
	source string // where it came from, for diagnostics
}

// str deliberately omits the value. A token must never reach a log, an error
// message or a report through ordinary string interpolation.
pub fn (t Token) str() string {
	return 'Token(from ${t.source})'
}

pub interface Provider {
	name() string
	token() ?Token
}

// EnvVar reads a token from the environment.
pub struct EnvVar {
pub:
	variable string
}

pub fn (e EnvVar) name() string {
	return e.variable
}

pub fn (e EnvVar) token() ?Token {
	raw := os.getenv_opt(e.variable) or { return none }
	value := raw.trim_space()
	if value == '' {
		return none
	}
	return Token{
		value:  value
		source: e.variable
	}
}

// GhCli borrows the token from an existing 'gh' login. A convenience for people
// who already run gh, not a requirement at all. If gh is absent or logged out, this link
// offers nothing.
pub struct GhCli {}

pub fn (g GhCli) name() string {
	return 'gh auth token'
}

pub fn (g GhCli) token() ?Token {
	exe := proc.find('gh') or { return none }
	// proc.run, not proc.check: gh prints the token on stdout and an error built
	// from a failed run must never be able to carry it.
	result := proc.run(proc.Cmd{
		exe:  exe
		args: ['auth', 'token']
	}) or { return none }
	if result.exit_code != 0 {
		return none
	}
	value := result.stdout.trim_space()
	if value == '' {
		return none
	}
	return Token{
		value:  value
		source: 'gh auth token'
	}
}

// github_chain is the order a GitHub token is looked for. GITHUB_TOKEN is
// honored because it is conventional and it is also what CI injects as a
// narrowly scoped ephemeral token. Every failure names the source it used.
pub fn github_chain(allow_gh bool) []Provider {
	mut chain := []Provider{}
	chain << EnvVar{'GITLIFE_GITHUB_TOKEN'}
	chain << EnvVar{'GITHUB_TOKEN'}
	if allow_gh {
		chain << GhCli{}
	}
	return chain
}

pub fn resolve(chain []Provider) !Token {
	for provider in chain {
		if token := provider.token() {
			return token
		}
	}
	tried := chain.map(it.name()).join(', ')
	return error("no GitHub token found (tried: ${tried}); set GITLIFE_GITHUB_TOKEN, or run 'gh auth login'")
}
