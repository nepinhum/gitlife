module credentials

import os

// The bridge is testable without a network and without a real credential: the
// seam is the credential answer and that is fully observable.
//
// Every test that runs 'git credential fill' MUST isolate GIT_CONFIG_GLOBAL and
// GIT_CONFIG_SYSTEM. Without that, git consults the developer's real credential
// store and prints their live token.
fn hosts() []HostCredential {
	return [
		HostCredential{
			host:     'github.com'
			username: 'x-access-token'
			chain:    [Provider(EnvVar{'GITLIFE_TEST_TOKEN'})]
		},
	]
}

fn test_a_known_host_over_https_is_answered() {
	os.setenv('GITLIFE_TEST_TOKEN', 'ghp_answer', true)
	reply := answer('protocol=https\nhost=github.com\n\n', hosts())
	assert reply == 'username=x-access-token\npassword=ghp_answer\n'
	os.unsetenv('GITLIFE_TEST_TOKEN')
}

// Silence tells git to carry on and try something else. A wrong answer makes it
// fail against the server with a confusing error, so these must stay silent.
fn test_nothing_is_said_when_nothing_is_known() {
	os.setenv('GITLIFE_TEST_TOKEN', 'ghp_answer', true)
	assert answer('protocol=https\nhost=gitlab.com\n\n', hosts()) == '', 'another forge'
	assert answer('protocol=ssh\nhost=github.com\n\n', hosts()) == '', 'ssh uses the agent'
	assert answer('protocol=https\nhost=github.com:8443\n\n', hosts()) == '', 'another port'
	assert answer('', hosts()) == '', 'an empty request'
	os.unsetenv('GITLIFE_TEST_TOKEN')

	assert answer('protocol=https\nhost=github.com\n\n', hosts()) == '', 'no token anywhere'
}

fn test_a_request_is_read_up_to_its_blank_line() {
	os.setenv('GITLIFE_TEST_TOKEN', 'ghp_answer', true)
	// git terminates the request with a blank line; anything after is not ours.
	reply := answer('protocol=https\nhost=github.com\n\nhost=evil.example\n', hosts())
	assert reply.contains('ghp_answer')
	os.unsetenv('GITLIFE_TEST_TOKEN')
}

fn test_the_helper_command_quotes_its_executable() {
	assert helper_config('/opt/dir with space/gitlife') == "!'/opt/dir with space/gitlife' credential-helper"
	assert helper_config("/weird/it's here/gitlife") == "!'/weird/it'\\''s here/gitlife' credential-helper"
}

// The reset comes first and isn't optional. This is the entire reason the
// arguments are built by a function rather than written out at each call site.
fn test_the_arguments_reset_the_inherited_helper_list_first() {
	args := helper_args('/usr/local/bin/gitlife')
	assert args[0] == '-c'
	assert args[1] == 'credential.helper=', 'the empty value must come first'
	assert args[2] == '-c'
	assert args[3].starts_with('credential.helper=!')
}

// The end to end check: real git, a planted ambient helper that must lose and a
// helper path containing a space.
fn test_git_asks_our_helper_and_not_the_one_already_configured() {
	root := os.join_path(os.vtmp_dir(), 'gitlife-bridge-test')
	os.rmdir_all(root) or {}
	os.mkdir_all(os.join_path(root, 'dir with space')) or { panic(err) }

	ours := os.join_path(root, 'dir with space', 'helper')
	os.write_file(ours, '#!/bin/sh\nprintf "username=x-access-token\\npassword=ghp_ours\\n"\n') or {
		panic(err)
	}
	os.chmod(ours, 0o755) or { panic(err) }

	intruder := os.join_path(root, 'intruder')
	os.write_file(intruder, '#!/bin/sh\nprintf "username=stale\\npassword=ghp_stale\\n"\n') or {
		panic(err)
	}
	os.chmod(intruder, 0o755) or { panic(err) }

	config := os.join_path(root, 'gitconfig')
	isolated := 'GIT_CONFIG_GLOBAL=${config} GIT_CONFIG_SYSTEM=/dev/null'
	os.execute('${isolated} git config --file ${config} credential.helper ${intruder}')

	request := 'printf "protocol=https\\nhost=github.com\\n\\n"'
	args := helper_args(ours)
	command := '${request} | ${isolated} git ${args[0]} "${args[1]}" ${args[2]} "${args[3]}" credential fill'
	filled := os.execute(command)
	assert filled.exit_code == 0, filled.output
	assert filled.output.contains('password=ghp_ours'), filled.output
	assert !filled.output.contains('ghp_stale'), 'an ambient helper must not answer first'

	// And the proof that the reset is what did it.
	without_reset :=
		os.execute('${request} | ${isolated} git ${args[2]} "${args[3]}" credential fill')
	assert without_reset.output.contains('ghp_stale'), 'without the reset the planted helper wins'
}
