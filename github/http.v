module github

import net.http
import time

// HttpTransport is the only place gitlife opens a socket to GitHub. GitHub's
// GraphQL API is ordinary HTTPS with a bearer token and needs no external
// executable.
pub struct HttpTransport {
pub:
	endpoint   string = 'https://api.github.com/graphql'
	token      string
	user_agent string = 'gitlife'
	timeout    i64 = 30 * time.second
}

// interesting names the response headers gitlife acts on. Only these are copied,
// so nothing else from a response can end up somewhere it was not expected.
const interesting = ['x-ratelimit-remaining', 'x-ratelimit-reset', 'x-ratelimit-used', 'retry-after',
	'x-oauth-scopes']

pub fn (mut t HttpTransport) post(body string) !Response {
	mut header := http.new_header()
	header.add_custom('Authorization', 'Bearer ${t.token}')!
	header.add_custom('Content-Type', 'application/json')!
	response := http.fetch(http.FetchConfig{
		url: t.endpoint
		method: .post
		header: header
		data: body
		user_agent: t.user_agent
		read_timeout: t.timeout
	})!
	mut headers := map[string]string{}
	for name in interesting {
		if value := response.header.get_custom(name, http.HeaderQueryConfig{ exact: false }) {
			headers[name] = value
		}
	}
	return Response{
		status: response.status_code
		body: response.body
		headers: headers
	}
}
