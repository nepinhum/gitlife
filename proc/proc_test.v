module proc

import os

// Removing a variable from a child's environment is a security control here, not
// tidiness: it is what stops git narrating an Authorization header into a stderr
// that gitlife stores. So it is tested as one.
fn test_a_child_inherits_what_it_needs() {
	env := child_env([], map[string]string{})
	assert 'PATH' in env, 'a child that loses PATH cannot find anything'
	assert env.len == os.environ().len
}

fn test_a_removed_variable_is_gone_and_an_added_one_is_present() {
	os.setenv('GITLIFE_PROC_TEST_NOISY', 'loud', true)
	env := child_env(['GITLIFE_PROC_TEST_NOISY'], {
		'GITLIFE_PROC_TEST_QUIET': 'yes'
	})
	assert 'GITLIFE_PROC_TEST_NOISY' !in env
	assert env['GITLIFE_PROC_TEST_QUIET'] == 'yes'
	// The parent keeps its own environment; only the child's copy changed.
	assert os.getenv('GITLIFE_PROC_TEST_NOISY') == 'loud'
	os.unsetenv('GITLIFE_PROC_TEST_NOISY')
}

fn test_an_addition_overrides_an_inherited_value() {
	os.setenv('GITLIFE_PROC_TEST_OVERRIDE', 'inherited', true)
	env := child_env([], {
		'GITLIFE_PROC_TEST_OVERRIDE': 'forced'
	})
	assert env['GITLIFE_PROC_TEST_OVERRIDE'] == 'forced'
	os.unsetenv('GITLIFE_PROC_TEST_OVERRIDE')
}

// The env is what actually reaches the process, not just what the map says.
fn test_the_environment_reaches_the_child() {
	os.setenv('GITLIFE_PROC_TEST_SCRUBBED', 'should-not-survive', true)
	result := run(Cmd{
		exe:  find('sh')!
		args: ['-c', r'echo "[${GITLIFE_PROC_TEST_SCRUBBED-unset}][${GITLIFE_PROC_TEST_ADDED-unset}]"']
		env:  child_env(['GITLIFE_PROC_TEST_SCRUBBED'], {
			'GITLIFE_PROC_TEST_ADDED': 'arrived'
		})
	})!
	assert result.stdout.trim_space() == '[unset][arrived]'
	os.unsetenv('GITLIFE_PROC_TEST_SCRUBBED')
}

fn test_stdout_and_stderr_stay_apart() {
	result := run(Cmd{
		exe:  find('sh')!
		args: ['-c', 'echo out; echo err 1>&2; exit 3']
	})!
	assert result.exit_code == 3
	assert result.stdout.trim_space() == 'out'
	assert result.stderr.trim_space() == 'err'
}

// A regression test for a deadlock, not just a size check. Draining stdout to EOF
// before touching stderr hangs forever here: the child blocks writing past the
// 64KiB pipe buffer, never exits, and stdout never ends.
fn test_a_child_that_floods_stderr_neither_hangs_nor_is_kept_whole() {
	result := run(Cmd{
		exe:  find('sh')!
		args: ['-c', 'yes xxxxxxxxxx | head -c 100000 1>&2']
	})!
	assert result.stderr.len < max_stderr + 100
}

// The same hazard from the other side, and both at once.
fn test_a_child_that_floods_both_pipes_completes() {
	result := run(Cmd{
		exe:  find('sh')!
		args: ['-c', 'yes aaaaaaaaaa | head -c 200000; yes bbbbbbbbbb | head -c 200000 1>&2']
	})!
	assert result.exit_code == 0
	assert result.stdout.len == 200000, 'stdout is the data, and is kept whole'
	assert result.stderr.len < max_stderr + 100, 'stderr is diagnostics, and is bounded'
}
