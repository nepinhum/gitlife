// A sync depends on two things it can't see from the inside: the credential that
// opens a private repository and the provider client that answers what exists.
// Both are values here rather than constructions inside the sync. A test can
// supply a fixture transport and a fake token and the production wiring lives in
// one place. No sync path builds a transport of its own.
module syncer

import credentials
import github

pub struct Deps {
pub:
	token  fn () !credentials.Token               = live_token
	github fn (credentials.Token) !&github.Client = live_github
}

// live_token walks the GitHub credential chain: environment first, 'gh' last and
// 'gh' never required.
fn live_token() !credentials.Token {
	return credentials.resolve(credentials.github_chain(true))
}

// live_github is the only place in a sync where a socket opening transport is
// built. Everything above it, paging and rate limits and failure kinds, is
// reachable from a test through the same seam.
fn live_github(token credentials.Token) !&github.Client {
	mut transport := &github.HttpTransport{
		token: token.value
	}
	return github.new_client(transport)
}
