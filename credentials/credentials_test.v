module credentials

import os

fn test_the_environment_is_tried_in_order() {
	os.setenv('GITLIFE_GITHUB_TOKEN', 'first', true)
	os.setenv('GITHUB_TOKEN', 'second', true)
	token := resolve(github_chain(false))!
	assert token.value == 'first'
	assert token.source == 'GITLIFE_GITHUB_TOKEN'

	os.unsetenv('GITLIFE_GITHUB_TOKEN')
	fallback := resolve(github_chain(false))!
	assert fallback.value == 'second'
	assert fallback.source == 'GITHUB_TOKEN'
	os.unsetenv('GITHUB_TOKEN')
}

// An empty or blank variable is not a token. Treating it as one produces a
// confusing "bad credentials" where "no credentials" is the truth.
fn test_a_blank_variable_offers_nothing() {
	os.setenv('GITLIFE_GITHUB_TOKEN', '   ', true)
	assert EnvVar{'GITLIFE_GITHUB_TOKEN'}.token() == none
	os.unsetenv('GITLIFE_GITHUB_TOKEN')
}

fn test_a_token_is_trimmed() {
	os.setenv('GITLIFE_GITHUB_TOKEN', ' ghp_padded \n', true)
	token := resolve(github_chain(false))!
	assert token.value == 'ghp_padded'
	os.unsetenv('GITLIFE_GITHUB_TOKEN')
}

fn test_an_exhausted_chain_names_what_it_tried() {
	os.unsetenv('GITLIFE_GITHUB_TOKEN')
	os.unsetenv('GITHUB_TOKEN')
	resolve([Provider(EnvVar{'GITLIFE_GITHUB_TOKEN'}), Provider(EnvVar{'GITHUB_TOKEN'})]) or {
		assert err.msg().contains('GITLIFE_GITHUB_TOKEN')
		assert err.msg().contains('GITHUB_TOKEN')
		return
	}
	assert false, 'expected a missing credential error'
}

// The value must not be reachable by ordinary interpolation, which is how a token
// would otherwise end up in a log line or an error message.
fn test_a_token_never_prints_its_value() {
	token := Token{
		value: 'ghp_supersecret'
		source: 'GITLIFE_GITHUB_TOKEN'
	}
	assert '${token}' == 'Token(from GITLIFE_GITHUB_TOKEN)'
	assert !'${token}'.contains('supersecret')
	assert token.str() == 'Token(from GITLIFE_GITHUB_TOKEN)'
}

// gh is a convenience, never a requirement: when it is absent or logged out the
// link simply offers nothing and the chain moves on.
fn test_the_gh_link_is_optional() {
	assert github_chain(false).len == 2
	assert github_chain(true).len == 3
	assert github_chain(true).last().name() == 'gh auth token'
	if _ := proc_find_gh() {
	} else {
		assert GhCli{}.token() == none, 'no gh on PATH must not be an error'
	}
}

fn proc_find_gh() ?string {
	return os.find_abs_path_of_executable('gh') or { return none }
}
