module github

import json2
import time

pub struct Response {
pub:
	status  int
	body    string
	headers map[string]string // lowercased keys
}

pub interface Transport {
mut:
	post(body string) !Response
}

// FailureKind separates the things that go wrong, because they have different
// remedies. Collapsing them into one "GitHub error" would tell a user to check
// their token when the real problem was a rate limit.
pub enum FailureKind {
	missing_credentials // no token anywhere in the chain
	invalid_credentials // GitHub rejected the token
	insufficient_permissions // the token is valid but not allowed to see this
	not_found // no such account or one this token cannot see
	rate_limited // too many requests, primary or secondary
	network // GitHub was unreachable or answered 5xx
	malformed // GitHub answered something we cannot read
}

pub struct Failure {
pub:
	kind        FailureKind
	message     string
	retry_after int // seconds the server asked us to wait; 0 when it did not
	reset_at    i64 // epoch when a primary rate limit refills; 0 when unknown
}

pub fn (f Failure) msg() string {
	return f.message
}

pub fn (f Failure) code() int {
	return int(f.kind)
}

pub struct RateLimit {
pub mut:
	remaining int = -1
	reset_at  i64
}

pub struct Client {
pub mut:
	transport   Transport
	max_retries int = 3
	// A secondary rate limit is measured in seconds and is worth waiting out. A
	// primary one can be an hour away and is never slept on.
	max_wait int = 60
	sleeper  fn(int) = default_sleep
	rate     RateLimit
	requests int
	// waits records every throttle this client sat through, in seconds. A sync can
	// then say it was slow because GitHub asked it to be.
	waits []int
}

pub fn new_client(transport Transport) &Client {
	return &Client{
		transport: transport
	}
}

fn default_sleep(seconds int) {
	time.sleep(seconds * time.second)
}

// query runs one GraphQL operation and returns its 'data'.
pub fn (mut c Client) query(operation string, variables map[string]json2.Any) !json2.Any {
	envelope_out := {
		'query':     json2.Any(operation)
		'variables': json2.Any(variables)
	}
	body := json2.Any(envelope_out).json_str()

	for attempt := 0; ; attempt++ {
		c.requests++
		response := c.transport.post(body) or {
			return Failure{
				kind: .network
				message: 'could not reach GitHub: ${err.msg()}'
			}
		}
		data := c.interpret(response) or {
			// Only a server-specified wait is ever slept on, and only briefly.
			if err is Failure {
				if err.kind == .rate_limited && err.retry_after > 0 && attempt < c.max_retries {
					pause := if err.retry_after < c.max_wait { err.retry_after } else { c.max_wait }
					c.waits << pause
					c.sleeper(pause)
					continue
				}
			}
			return err
		}
		return data
	}
	return Failure{
		kind: .rate_limited
		message: 'gave up after ${c.max_retries} retries'
	}
}

fn (mut c Client) interpret(response Response) !json2.Any {
	c.read_rate_headers(response.headers)
	match true {
		response.status == 401 {
			return Failure{
				kind: .invalid_credentials
				message: 'GitHub rejected the token (HTTP 401: ${excerpt(response.body)})'
			}
		}
		response.status in [403, 429] {
			return c.forbidden_or_limited(response)
		}
		response.status >= 500 {
			return Failure{
				kind: .network
				message: 'GitHub returned HTTP ${response.status}'
			}
		}
		response.status != 200 {
			return Failure{
				kind: .malformed
				message: 'GitHub returned an unexpected HTTP ${response.status}: ${excerpt(response.body)}'
			}
		}
		else {}
	}

	decoded := json2.decode[json2.Any](response.body) or {
		return Failure{
			kind: .malformed
			message: 'GitHub returned a body that is not JSON: ${excerpt(response.body)}'
		}
	}
	envelope := decoded.as_map()
	if envelope.len == 0 {
		return Failure{
			kind: .malformed
			message: 'GitHub returned a JSON body that is not an object: ${excerpt(response.body)}'
		}
	}

	if errors := envelope['errors'] {
		list := errors.as_array()
		if list.len > 0 {
			return c.graphql_failure(list)
		}
	}
	data := envelope['data'] or {
		return Failure{
			kind: .malformed
			message: "GitHub returned neither 'data' nor 'errors': ${excerpt(response.body)}"
		}
	}
	if data.as_map().len == 0 {
		return Failure{
			kind: .malformed
			message: "GitHub returned an empty 'data': ${excerpt(response.body)}"
		}
	}
	c.read_rate_field(data)
	return data
}

// forbidden_or_limited untangles the two very different things GitHub says with a
// 403: "you may not do that" and "you have done that too often".
fn (mut c Client) forbidden_or_limited(response Response) !json2.Any {
	retry_after := (response.headers['retry-after'] or { '' }).int()
	if retry_after > 0 {
		return Failure{
			kind: .rate_limited
			message: 'GitHub asked us to wait ${retry_after}s (secondary rate limit)'
			retry_after: retry_after
		}
	}
	if (response.headers['x-ratelimit-remaining'] or { '' }) == '0' {
		reset := (response.headers['x-ratelimit-reset'] or { '' }).i64()
		return Failure{
			kind: .rate_limited
			message: 'GitHub rate limit is exhausted; it resets at ${stamp(reset)}'
			reset_at: reset
		}
	}
	if response.body.to_lower().contains('secondary rate limit') {
		return Failure{
			kind: .rate_limited
			message: 'GitHub applied a secondary rate limit'
			retry_after: 30
		}
	}
	return Failure{
		kind: .insufficient_permissions
		message: 'the token is not allowed to read this (HTTP ${response.status}: ${excerpt(response.body)})'
	}
}

fn (mut c Client) graphql_failure(errors []json2.Any) !json2.Any {
	mut types := []string{}
	mut messages := []string{}
	for entry in errors {
		fields := entry.as_map()
		types << plain(fields['type'] or { json2.Any('') })
		messages << plain(fields['message'] or { json2.Any('') })
	}
	detail := messages.filter(it != '').join('; ')
	if 'RATE_LIMITED' in types {
		return Failure{
			kind: .rate_limited
			message: 'GitHub rate limit is exhausted; it resets at ${stamp(c.rate.reset_at)}'
			reset_at: c.rate.reset_at
		}
	}
	if 'FORBIDDEN' in types {
		return Failure{
			kind: .insufficient_permissions
			message: 'the token is not allowed to read this: ${detail}'
		}
	}
	if 'NOT_FOUND' in types {
		// GitHub answers NOT_FOUND both for an account that does not exist and for
		// one this token may not see. It does not distinguish them and neither
		// can we. Naming both is more useful than picking one.
		return Failure{
			kind: .not_found
			message: 'GitHub found nothing under that name. It does not exist, or this token cannot see it: ${detail}'
		}
	}
	return Failure{
		kind: .malformed
		message: 'GitHub rejected the query: ${detail}'
	}
}

fn (mut c Client) read_rate_headers(headers map[string]string) {
	if remaining := headers['x-ratelimit-remaining'] {
		c.rate.remaining = remaining.int()
	}
	if reset := headers['x-ratelimit-reset'] {
		c.rate.reset_at = reset.i64()
	}
}

// read_rate_field prefers what the query itself reported, which is exact for
// GraphQL where header based accounting is not.
fn (mut c Client) read_rate_field(data json2.Any) {
	limit := (data.as_map()['rateLimit'] or { return }).as_map()
	if remaining := limit['remaining'] {
		c.rate.remaining = remaining.int()
	}
	if reset := limit['resetAt'] {
		c.rate.reset_at = time.parse_iso8601(plain(reset)) or { return }.unix()
	}
}

// plain reads a string field, treating JSON null as absent rather than as the
// four characters 'null'.
fn plain(value json2.Any) string {
	if value is json2.Null {
		return ''
	}
	return value.str()
}

fn stamp(epoch i64) string {
	if epoch <= 0 {
		return 'an unknown time'
	}
	return time.unix(epoch).format()
}

// excerpt bounds what a failure can quote. An error is for a human to read, not a
// place to paste a response body.
fn excerpt(body string) string {
	trimmed := body.trim_space().replace('\n', ' ')
	if trimmed.len <= 200 {
		return trimmed
	}
	return trimmed[..200] + '..'
}
