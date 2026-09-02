module cache

import os
import gitrepo

// These tests clone and fetch real repositories over file:// URLs. No network and
// no credential is involved because the seam that needs a credential is the
// credential answer, which is tested in 'credentials'.
fn workspace(name string) string {
	dir := os.join_path(os.vtmp_dir(), 'gitlife-cache-test', name)
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	return dir
}

fn run(command string) {
	result := os.execute('GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null ${command}')
	if result.exit_code != 0 {
		panic('${command}\n${result.output}')
	}
}

fn commit(dir string, message string) {
	os.write_file(os.join_path(dir, 'f.txt'), message) or { panic(err) }
	run('git -C ${dir} add -A')
	run('GIT_AUTHOR_NAME=a GIT_AUTHOR_EMAIL=a@example.com GIT_COMMITTER_NAME=a GIT_COMMITTER_EMAIL=a@example.com git -C ${dir} commit -q -m "${message}"')
}

fn origin(root string) string {
	dir := os.join_path(root, 'origin')
	os.mkdir_all(dir) or { panic(err) }
	run('git -C ${dir} init -q -b main .')
	commit(dir, 'one')
	run('git -C ${dir} branch feature')
	return dir
}

fn cache_for(root string) Cache {
	return Cache{
		root: os.join_path(root, 'repos')
		git: gitrepo.find() or { panic(err) }
		exe: os.executable()
	}
}

fn test_a_remote_is_cloned_then_fetched() {
	root := workspace('clone')
	remote := origin(root)
	url := 'file://${remote}'
	c := cache_for(root)

	first := c.ensure(url, map[string]string{})!
	assert first.cloned, 'the first call must clone'
	assert os.exists(os.join_path(first.dir, 'HEAD')), 'a bare repository has a HEAD'
	assert !os.exists(os.join_path(first.dir, '.git')), 'the clone must be bare'

	// The whole point of the cache: a scan reads it exactly like a local repository.
	git := gitrepo.find()!
	scan := git.scan(first.dir)!
	assert scan.commits.len == 1
	assert scan.commits[0].subject == 'one'

	// A second call updates in place rather than cloning again.
	commit(remote, 'two')
	run('git -C ${remote} branch -D feature -q')
	run('git -C ${remote} branch added')

	second := c.ensure(url, map[string]string{})!
	assert !second.cloned, 'an existing clone must be fetched, not recloned'
	assert second.dir == first.dir

	updated := git.scan(second.dir)!
	assert updated.commits.len == 2
	refs := git.at_with(second.dir, ['for-each-ref', '--format=%(refname)'], map[string]string{})!
	// --prune is what makes a deleted branch stop counting.
	assert !refs.stdout.contains('refs/heads/feature'), 'a deleted branch must be pruned'
	assert refs.stdout.contains('refs/heads/added')
}

// A repository that moved or vanished is an error the caller can report, not a
// half written directory left behind.
fn test_an_unreachable_remote_fails() {
	root := workspace('missing')
	c := cache_for(root)
	if _ := c.ensure('file://${root}/not-a-repository', map[string]string{}) {
		assert false, 'cloning something that is not a repository must fail'
	}
}

fn test_the_path_is_stable_and_browsable() {
	c := Cache{
		root: '/cache'
	}
	assert c.path_for('https://github.com/nepinhum/gitlife.git') == '/cache/github.com/nepinhum/gitlife.git'
	// One repository, one directory, however the URL was spelled.
	assert c.path_for('https://GitHub.com/nepinhum/gitlife/') == c.path_for('git@github.com:nepinhum/gitlife.git')
}

// The URL comes from a provider or a user, so a component of '..' must never be
// able to choose where on disk gitlife writes.
fn test_a_hostile_url_cannot_escape_the_cache_root() {
	c := Cache{
		root: '/cache'
	}
	for hostile in ['https://github.com/../../etc/passwd', 'https://github.com/a/../../../root',
		'https://../evil/repo'] {
		path := c.path_for(hostile)
		assert path.starts_with('/cache/'), path
		assert !path.contains('/../'), path
	}
}

// A credential must never reach git as an argument where 'ps' would show it.
fn test_a_credential_in_a_url_is_stripped_before_git_sees_it() {
	root := workspace('redact')
	remote := origin(root)
	c := cache_for(root)
	entry := c.ensure('file://x-access-token:ghp_secret@${remote}', map[string]string{})!
	stored := os.execute('git --git-dir=${entry.dir} config --get remote.origin.url')
	assert !stored.output.contains('ghp_secret'), stored.output
	assert !c.path_for('file://x-access-token:ghp_secret@${remote}').contains('ghp_secret')
}
