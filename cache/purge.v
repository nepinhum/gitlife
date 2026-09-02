module cache

import os

pub struct Pruned {
pub:
	clones int
	bytes  i64
	dirs   []string
}

// prune removes every managed clone that no surviving remote maps to. 'keep' is
// the addresses that are still indexed; a clone is identified by the path its
// address produces which is the same mapping 'ensure' used to create it.
//
// Nothing outside the cache root is considered, a directory is removed only when
// it is itself a bare repository and a symlink is never followed. This function
// deletes and trusts nothing it has not checked.
pub fn (c Cache) prune(keep []string, dry_run bool) !Pruned {
	if !os.is_dir(c.root) {
		return Pruned{}
	}
	mut wanted := map[string]bool{}
	for address in keep {
		wanted[c.path_for(address)] = true
	}
	mut removed := []string{}
	mut bytes := i64(0)
	for dir in clones(c.root) {
		if dir in wanted {
			continue
		}
		bytes += size(dir)
		removed << dir
		if !dry_run {
			os.rmdir_all(dir)!
			prune_empty(os.dir(dir), c.root)
		}
	}
	return Pruned{
		clones: removed.len
		bytes: bytes
		dirs: removed
	}
}

// clones finds the bare repositories under 'dir'. A directory holding a 'HEAD' is
// one and nothing inside it is looked at further: its own subdirectories are
// git's, not gitlife's.
fn clones(dir string) []string {
	mut out := []string{}
	for entry in os.ls(dir) or { return out } {
		path := os.join_path(dir, entry)
		if os.is_link(path) || !os.is_dir(path) {
			continue
		}
		if os.exists(os.join_path(path, 'HEAD')) {
			out << path
			continue
		}
		out << clones(path)
	}
	return out
}

// prune_empty removes the directories a departed clone left behind, upwards until
// something is still in them or the cache root is reached. The root itself stays:
// it is gitlife's, not this call's, to create and destroy.
fn prune_empty(dir string, root string) {
	mut current := dir
	for current.len > root.len && current.starts_with(root) {
		entries := os.ls(current) or { return }
		if entries.len > 0 {
			return
		}
		os.rmdir(current) or { return }
		current = os.dir(current)
	}
}

fn size(dir string) i64 {
	mut total := i64(0)
	for entry in os.ls(dir) or { return total } {
		path := os.join_path(dir, entry)
		if os.is_link(path) {
			continue
		}
		if os.is_dir(path) {
			total += size(path)
		} else {
			total += i64(os.file_size(path))
		}
	}
	return total
}
