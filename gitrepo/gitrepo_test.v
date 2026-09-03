module gitrepo

fn test_parse_tz() {
	assert parse_tz('+0300') == 180
	assert parse_tz('-0430') == -270
	assert parse_tz('+0000') == 0
	assert parse_tz('') == 0
}

fn test_parse_commits_reads_every_field() {
	out := 'abc123\ndef456 789abc\nAda\nada@example.com\n1700000000\n+0200\n' +
		'Bob\nbob@example.com\n1700000060\n-0500\nSubject line\n'
	commits := parse_commits(out)!
	assert commits.len == 1
	c := commits[0]
	assert c.object_id == 'abc123'
	assert c.parents == 'def456 789abc'
	assert c.author_name == 'Ada'
	assert c.author_email == 'ada@example.com'
	assert c.author_time == 1700000000
	assert c.author_tz == 120
	assert c.committer_name == 'Bob'
	assert c.committer_time == 1700000060
	assert c.committer_tz == -300
	assert c.subject == 'Subject line'
}

// A root commit has no parents and a subject may be empty, so the record must
// still be exactly eleven lines. Fixed arity is the whole reason this parses.
fn test_parse_commits_handles_empty_fields() {
	out := 'aaa\n\nAda\nada@example.com\n1\n+0000\nAda\nada@example.com\n1\n+0000\n\n' +
		'bbb\naaa\nAda\nada@example.com\n2\n+0000\nAda\nada@example.com\n2\n+0000\nsecond\n'
	commits := parse_commits(out)!
	assert commits.len == 2
	assert commits[0].parents == ''
	assert commits[0].subject == ''
	assert commits[1].parents == 'aaa'
}

fn test_parse_commits_rejects_a_truncated_record() {
	if _ := parse_commits('aaa\nbbb\nccc\n') {
		assert false, 'a partial record must not parse'
	}
}

fn test_parse_commits_of_an_empty_repository() {
	commits := parse_commits('')!
	assert commits.len == 0
}
