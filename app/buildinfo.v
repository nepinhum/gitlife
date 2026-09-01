module app

import v.vmod

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
