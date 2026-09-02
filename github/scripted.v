module github

// ScriptedTransport replays recorded responses in order and remembers what was
// sent. The Transport seam exists so that everything above it can be exercised
// without a network or a credential; this is the reference implementation of the
// other side of that seam.
pub struct ScriptedTransport {
pub mut:
	script []Response
	sent   []string // request bodies, in the order they were sent
	calls  int
}

pub fn (mut s ScriptedTransport) post(body string) !Response {
	s.sent << body
	if s.calls >= s.script.len {
		return error('the script ran out after ${s.calls} responses')
	}
	response := s.script[s.calls]
	s.calls++
	return response
}
