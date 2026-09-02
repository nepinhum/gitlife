module discover

import os
import json2
import github

// The adapter is exercised end to end against recorded GitHub responses. No test
// here opens a socket or needs a credential.
fn fixture(name string) string {
	return os.read_file(os.join_path(os.dir(@FILE), '..', 'github', 'testdata', name)) or {
		panic(err)
	}
}

fn ok(name string) github.Response {
	return github.Response{
		status: 200
		body: fixture(name)
	}
}

fn scripted(script []github.Response) (&github.Client, &github.ScriptedTransport) {
	mut transport := &github.ScriptedTransport{
		script: script
	}
	return github.new_client(transport), transport
}

fn names_of(found []Found) []string {
	return found.map(it.name)
}

fn test_discovery_pages_and_merges_three_queries() {
	mut client, transport := scripted([
		ok('viewer.json'),
		ok('owner_page1.json'),
		ok('owner_page2.json'),
		ok('viewer_repos.json'),
		ok('contribution_years.json'),
		ok('contributions_2024.json'),
	])
	result := github_repos(mut client, 'nepinhum')!

	// gitlife appears in both the owner page and the viewer page, spelled
	// 'https://github.com/nepinhum/gitlife.git' the second time; vlang/v appears in
	// both the viewer page and the contributions. Both collapse.
	assert names_of(result.found) == ['nepinhum/dotfiles', 'nepinhum/gitlife', 'nepinhum/v',
		'someorg/secret-tool', 'vlang/v']
	assert result.viewer == 'nepinhum'
	assert transport.calls == 6

	// The second owner page must actually carry the cursor the first one returned.
	second := json2.decode[json2.Any](transport.sent[2])!.as_map()
	assert second['variables']!.as_map()['cursor']!.str() == 'Y3Vyc29yOjE='

	// Provider metadata is recorded, but it is never evidence about commits.
	private := result.found.filter(it.name == 'someorg/secret-tool')[0]
	assert private.url == 'https://github.com/someorg/secret-tool'
	assert private.dir == '', 'provider discovery finds remotes, never directories'
	assert json2.decode[json2.Any](private.metadata)!.as_map()['isPrivate']!.bool()
}

// Asking about somebody else means the viewer's own affiliations say nothing
// about them, so that query is not run.
fn test_another_account_skips_the_viewer_query() {
	mut client, transport := scripted([
		ok('viewer.json'),
		ok('owner_page2.json'),
		ok('contribution_years.json'),
		ok('contributions_2024.json'),
	])
	result := github_repos(mut client, 'someone-else')!
	assert transport.calls == 4
	assert 'nepinhum/v' in names_of(result.found)
}

// An organization has no contributionsCollection, so those queries are skipped
// rather than sent and failed.
fn test_an_org_skips_the_contribution_queries() {
	mut client, transport := scripted([
		ok('viewer.json'),
		ok('owner_org.json'),
	])
	result := github_repos(mut client, 'vlang')!
	assert transport.calls == 2
	assert names_of(result.found) == ['vlang/v']
}

fn test_an_unknown_acc_is_reported_as_not_found() {
	mut client, _ := scripted([ok('viewer.json'), ok('not_found.json')])
	github_repos(mut client, 'ghost') or {
		assert err is github.Failure
		if err is github.Failure {
			assert err.kind == .not_found
		}
		return
	}
	assert false, 'expected a not_found failure'
}

// A page claiming a successor but naming no cursor would otherwise be requested
// forever.
fn test_a_page_without_a_cursor_ends_the_walk() {
	mut client, transport := scripted([
		ok('viewer.json'),
		ok('owner_page_no_cursor.json'),
		ok('contribution_years.json'),
		ok('contributions_2024.json'),
	])
	result := github_repos(mut client, 'nepinhum')!
	assert transport.calls == 4
	assert 'nepinhum/only' in names_of(result.found)
}

fn test_a_credential_failure_stops_before_any_paging() {
	mut client, transport := scripted([
		github.Response{
			status: 401
			body: fixture('bad_credentials.json')
		},
	])
	github_repos(mut client, 'nepinhum') or {
		if err is github.Failure {
			assert err.kind == .invalid_credentials
		}
		assert transport.calls == 1, 'a bad token must not cost more than one call'
		return
	}
	assert false, 'expected an invalid_credentials failure'
}
