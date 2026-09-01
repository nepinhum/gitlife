module app

import v.vmod

// The version is read from v.mod, the one place it is written down.
//
// The commit is stamped in by the build rather than read at runtime. gitlife runs
// inside other repositories and a hash asked for at runtime would be theirs. A
// build that doesn't stamp it says nothing instead of something wrong.
//
//	GITLIFE_COMMIT=$(git describe --always --dirty) v -o gitlife .
pub const program = 'gitlife'
pub const version = manifest_version()
pub const commit = $env('GITLIFE_COMMIT')

fn manifest_version() string {
	manifest := vmod.decode(@VMOD_FILE) or { return 'unknown' }
	return if manifest.version == '' { 'unknown' } else { manifest.version }
}

fn build_info() string {
	return if commit == '' {
		'${program} v${version}'
	} else {
		'${program} v${version} (${commit})'
	}
}
