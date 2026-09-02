module source

import os

// The normalized URL is a repository's merge key. What it does and does not
// collapse is the identity rule in miniature.
fn test_spellings_of_one_remote_collapse() {
	canonical := 'https://github.com/nepinhum/gitlife'
	for spelling in ['https://github.com/nepinhum/gitlife', 'https://github.com/nepinhum/gitlife.git',
		'https://github.com/nepinhum/gitlife/', 'https://GitHub.com/nepinhum/gitlife',
		'HTTPS://github.com/nepinhum/gitlife', 'https://github.com:443/nepinhum/gitlife',
		'https://token@github.com/nepinhum/gitlife.git',
		'https://user:secret@github.com/nepinhum/gitlife'] {
		assert normalize_url(spelling) == canonical, spelling
	}
}

fn test_an_scp_address_becomes_an_ssh_url() {
	assert normalize_url('git@github.com:nepinhum/gitlife.git') == 'ssh://github.com/nepinhum/gitlife'
	assert normalize_url('ssh://git@github.com:22/nepinhum/gitlife') == 'ssh://github.com/nepinhum/gitlife'
}

// Credentials must never survive into a stored key.
fn test_credentials_are_dropped() {
	assert !normalize_url('https://user:secret@github.com/a/b').contains('secret')
}

// Two repositories that differ only in path case are two repositories: paths are
// case-sensitive nearly everywhere, and folding them would merge distinct work.
fn test_path_case_is_preserved() {
	assert normalize_url('https://github.com/Nepinhum/GitLife') == 'https://github.com/Nepinhum/GitLife'
	assert normalize_url('https://github.com/a/b') != normalize_url('https://github.com/A/B')
}

// A fork and its upstream are different URLs, and different keys. Nothing about
// commit overlap enters into it.
fn test_a_fork_and_its_upstream_do_not_collapse() {
	assert location_key('https://github.com/nepinhum/v') != location_key('https://github.com/vlang/v')
}

fn test_the_key_is_namespaced() {
	assert location_key('https://github.com/a/b') == 'url:https://github.com/a/b'
}

fn test_display_name_is_owner_and_repository() {
	assert display_name('https://github.com/nepinhum/gitlife.git') == 'nepinhum/gitlife'
	assert display_name('git@github.com:vlang/v.git') == 'vlang/v'
	assert display_name('https://example.org/deep/group/project') == 'group/project'
}

fn test_an_empty_url_stays_empty() {
	assert normalize_url('') == ''
	assert normalize_url('   ') == ''
}

// gitlife never persists an authenticated URL. A credential reaches git out of
// band, per invocation, and nothing that touches disk may carry one.
fn test_a_credential_is_stripped_but_the_url_still_works() {
	assert redact_url('https://x-access-token:ghp_secret@github.com/owner/repo.git') == 'https://github.com/owner/repo.git'
	assert redact_url('https://token@github.com/owner/repo.git') == 'https://github.com/owner/repo.git'
	// Everything other than the credential survives. The result is still the exact
	// address the remote expects.
	assert redact_url('https://user:pw@example.org:8443/deep/path/repo.git') == 'https://example.org:8443/deep/path/repo.git'
	assert redact_url('https://github.com/owner/repo.git') == 'https://github.com/owner/repo.git'
	assert redact_url('git@github.com:owner/repo.git') == 'git@github.com:owner/repo.git'
}

fn test_no_stored_form_of_a_url_can_carry_a_secret() {
	authenticated := 'https://x-access-token:ghp_supersecret@github.com/owner/repo.git'
	for stored in [redact_url(authenticated), normalize_url(authenticated),
		location_key(authenticated), display_name(authenticated)] {
		assert !stored.contains('ghp_supersecret'), stored
		assert !stored.contains('x-access-token'), stored
	}
}

// A clone names its origin with whatever address it was given. When that address
// is a directory, the clone and the working tree it came from are one repository.
fn test_a_local_address_keys_as_a_directory() {
	here := os.real_path('.')
	assert location_key(here) == 'dir:' + here
	assert location_key('file://' + here) == 'dir:' + here
	assert location_key(here) == location_key(here + '/')
}

fn test_a_remote_address_is_never_mistaken_for_a_path() {
	assert local_path('https://github.com/a/b') == none
	assert local_path('git@github.com:a/b.git') == none
	assert local_path('ssh://github.com/a/b') == none
	assert location_key('https://github.com/a/b').starts_with('url:')
}

// For a bare repository, 'repo.git' is the directory's real name, so the suffix
// must survive where it would be stripped from a URL.
fn test_a_bare_directory_keeps_its_git_suffix() {
	assert local_path('/srv/repos/project.git')? == '/srv/repos/project.git'
	assert normalize_url('https://example.org/project.git') == 'https://example.org/project'
}
