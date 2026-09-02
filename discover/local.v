module discover

import os

// A Found is one repository an adapter located. Exactly one of 'dir' and 'url' is
// set: local discovery finds directories, provider discovery finds remotes.
pub struct Found {
pub:
	name     string // cosmetic display name
	dir      string // realpath of the repository root or of the bare directory
	url      string // remote URL
	bare     bool
	metadata string // provider metadata as JSON, empty when there is none
}

// local walks a root and returns every Git repository beneath it.
//
// Directories are resolved to their realpath and visited at most once, which is
// what makes symlink loops terminate. Once a repository root is found, the walk
// does not descend into it: a nested repository is reached only by configuring
// the nested path as its own source.
pub fn local(root string) ![]Found {
	start := os.real_path(root)
	if !os.exists(start) {
		return error('${root}: no such path')
	}
	if !os.is_dir(start) {
		return error('${root}: not a directory')
	}
	mut seen := map[string]bool{}
	mut found := []Found{}
	walk(start, mut seen, mut found)
	found.sort(a.dir < b.dir)
	return found
}

fn walk(dir string, mut seen map[string]bool, mut found []Found) {
	if dir in seen {
		return
	}
	seen[dir] = true
	if kind := repo_kind(dir) {
		found << Found{
			dir: dir
			name: os.file_name(dir)
			bare: kind == 'bare'
		}
		return
	}
	// An unreadable directory is skipped rather than fatal: one bad directory
	// under a large root should not discard the rest of the walk.
	entries := os.ls(dir) or { return }
	for entry in entries {
		path := os.join_path(dir, entry)
		if !os.is_dir(path) {
			continue
		}
		walk(os.real_path(path), mut seen, mut found)
	}
}

// repo_kind returns 'worktree' or 'bare' or nothing when dir is neither.
// '.git' is accepted as a file as well as a directory because that is how
// worktrees and submodules point at their real git directory.
fn repo_kind(dir string) ?string {
	if os.exists(os.join_path(dir, '.git')) {
		return 'worktree'
	}
	if os.exists(os.join_path(dir, 'HEAD')) && os.is_dir(os.join_path(dir, 'objects')) && os.is_dir(os.join_path(dir, 'refs')) {
		return 'bare'
	}
	return none
}
