module github

import os
import json2

// These tests never open a socket. Every response below is a recording of what
// GitHub actually answers, replayed through the Transport seam.
fn fixture(name string) string {
	return os.read_file(os.join_path(os.dir(@FILE), 'testdata', name)) or { panic(err) }
}

fn ok(body string) Response {
	return Response{
		status: 200
		body: body
	}
}

fn client_for(script []Response) &Client {
	mut transport := &ScriptedTransport{
		script: script
	}
	return new_client(transport)
}

// Tests assert on what the client decided to wait, never on real elapsed time.
fn never_sleep(_ int) {}

fn ask(mut c Client) !json2.Any {
	return c.query('query { viewer { login } }', map[string]json2.Any{})
}

fn kind_of(mut c Client) FailureKind {
	ask(mut c) or {
		if err is Failure {
			return err.kind
		}
		panic('expected a github.Failure, got ${err}')
	}
	panic('expected a failure, got a result')
}

fn test_a_rejected_token_is_invalid_credentials() {
	mut c := client_for([Response{
		status: 401
		body: fixture('bad_credentials.json')
	}])
	assert kind_of(mut c) == .invalid_credentials
}

fn test_a_forbidden_field_is_insufficient_permissions() {
	mut c := client_for([ok(fixture('forbidden.json'))])
	assert kind_of(mut c) == .insufficient_permissions
}

// A 403 that carries no rate limit signal is a permission problem, not a limit.
fn test_a_bare_403_is_insufficient_permissions() {
	mut c := client_for([Response{
		status: 403
		body: '{"message":"Resource not accessible by integration"}'
	}])
	assert kind_of(mut c) == .insufficient_permissions
}

fn test_a_missing_account_is_not_found() {
	mut c := client_for([ok(fixture('not_found.json'))])
	assert kind_of(mut c) == .not_found
}

fn test_a_body_that_is_not_json_is_malformed() {
	mut c := client_for([ok(fixture('malformed.html'))])
	assert kind_of(mut c) == .malformed
}

fn test_a_rejected_query_is_malformed() {
	mut c := client_for([ok(fixture('bad_query.json'))])
	assert kind_of(mut c) == .malformed
}

fn test_neither_data_nor_errors_is_malformed() {
	mut c := client_for([ok('{"extensions":{}}')])
	assert kind_of(mut c) == .malformed
}

fn test_a_5xx_is_a_network_failure() {
	mut c := client_for([Response{
		status: 502
		body: fixture('malformed.html')
	}])
	assert kind_of(mut c) == .network
}

fn test_a_transport_that_cannot_connect_is_a_network_failure() {
	mut c := client_for([])
	assert kind_of(mut c) == .network
}

// A primary rate limit can be an hour away. Sleeping through it inside a sync
// would be worse than failing, so it fails and says when the budget returns.
fn test_a_primary_rate_limit_fails_without_sleeping() {
	mut c := client_for([Response{
		status: 403
		body: '{"message":"API rate limit exceeded"}'
		headers: {
			'x-ratelimit-remaining': '0'
			'x-ratelimit-reset':     '1900000000'
		}
	}])
	c.sleeper = never_sleep
	ask(mut c) or {
		if err is Failure {
			assert err.kind == .rate_limited
			assert err.reset_at == 1900000000
			assert err.retry_after == 0
		}
		assert c.waits.len == 0, 'a primary rate limit must never be waited out'
		return
	}
	assert false, 'expected a rate limit failure'
}

fn test_a_graphql_rate_limit_error_is_rate_limited() {
	mut c := client_for([ok(fixture('rate_limited.json'))])
	assert kind_of(mut c) == .rate_limited
}

// A secondary limit is measured in seconds and the server names the delay, so it
// is waited out and retried.
fn test_a_secondary_rate_limit_is_retried() {
	mut c := client_for([
		Response{
			status: 403
			body: fixture('secondary_rate_limit.json')
			headers: {
				'retry-after': '2'
			}
		},
		ok(fixture('viewer.json')),
	])
	c.sleeper = never_sleep
	data := ask(mut c)!
	assert c.waits == [2]
	assert c.requests == 2
	assert (data.as_map()['viewer'] or { json2.Any('') }).as_map()['login']!.str() == 'nepinhum'
}

fn test_a_delay_is_capped_and_the_client_eventually_gives_up() {
	mut script := []Response{}
	for _ in 0 .. 6 {
		script << Response{
			status: 429
			body: fixture('secondary_rate_limit.json')
			headers: {
				'retry-after': '3600'
			}
		}
	}
	mut c := client_for(script)
	c.sleeper = never_sleep
	ask(mut c) or {
		assert c.waits == [60, 60, 60], 'a retry waits the cap, not the hour the server named'
		return
	}
	assert false, 'expected a rate limit failure'
}

fn test_the_rate_budget_is_read_from_the_query_itself() {
	mut c := client_for([ok(fixture('owner_page1.json'))])
	ask(mut c)!
	assert c.rate.remaining == 4998
	assert c.rate.reset_at > 0
}

fn test_the_request_body_carries_the_operation_and_variables() {
	mut transport := &ScriptedTransport{
		script: [ok(fixture('viewer.json'))]
	}
	mut c := new_client(transport)
	c.query('query(\$login: String!) { user(login: \$login) { login } }', {
		'login': json2.Any('nepinhum')
	})!
	sent := json2.decode[json2.Any](transport.sent[0])!.as_map()
	assert sent['query']!.str().contains('user(login: \$login)')
	assert sent['variables']!.as_map()['login']!.str() == 'nepinhum'
}

// A token must not be able to reach a log or an error through interpolation.
fn test_an_excerpt_is_bounded() {
	long := 'x'.repeat(5000)
	assert excerpt(long).len < 250
}
