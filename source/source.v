module source

import os

pub fn normalize_url(raw string) string {
	mut url := raw.trim_space()
	if url == '' {
		return ''
	}
	if !url.contains('://') {
		// scp style: user@host:path
		if idx := url.index(':') {
			at := url.index('@') or { -1 }
			if at > 0 && at < idx {
				url = 'ssh://' + url[at + 1..idx] + '/' + url[idx + 1..]
			}
		}
	}
	scheme_end := url.index('://') or { return trim_path(url) }
	scheme := url[..scheme_end].to_lower()
	rest := url[scheme_end + 3..]
	slash := rest.index('/') or { rest.len }
	mut authority := rest[..slash]
	path := rest[slash..]
	if at := authority.last_index('@') {
		authority = authority[at + 1..]
	}
	mut host := authority.to_lower()
	if colon := host.last_index(':') {
		port := host[colon + 1..]
		if port == default_port(scheme) {
			host = host[..colon]
		}
	}
	return '${scheme}://${host}${trim_path(path)}'
}

// location_key is the merge key for an address.
pub fn location_key(raw string) string {
	if path := local_path(raw) {
		return 'dir:' + os.real_path(path)
	}
	normalized := normalize_url(raw)
	if at := normalized.index('://') {
		return 'url:' + normalized[at + 3..]
	}
	return 'url:' + normalized
}

// local_path recognizes the addresses that name a directory on this machine
// rather than a server.
pub fn local_path(raw string) ?string {
	address := raw.trim_space()
	if address.starts_with('file://') {
		return address['file://'.len..]
	}
	if address.contains('://') {
		return none
	}
	if address.starts_with('/') || address.starts_with('./') || address.starts_with('../') || address.starts_with('~/') {
		return address
	}
	// Anything else is a remote: 'host:path', 'user@host:path', a bare name.
	return none
}

// fold_transport rewrites a location key that was stored before the transport
// was dropped from one. Only the v3 migration in index has any use for it.
pub fn fold_transport(key string) string {
	if !key.starts_with('url:') {
		return key
	}
	if at := key.index('://') {
		return 'url:' + key[at + 3..]
	}
	return key
}

pub fn redact_url(raw string) string {
	scheme_end := raw.index('://') or { return raw }
	rest := raw[scheme_end + 3..]
	slash := rest.index('/') or { rest.len }
	authority := rest[..slash]
	at := authority.last_index('@') or { return raw }
	return raw[..scheme_end + 3] + authority[at + 1..] + rest[slash..]
}

pub fn display_name(raw string) string {
	normalized := normalize_url(raw)
	parts := normalized.all_after('://').split('/').filter(it != '')
	if parts.len >= 3 {
		return parts[parts.len - 2] + '/' + parts[parts.len - 1]
	}
	if parts.len == 2 {
		return parts[1]
	}
	return normalized
}

fn trim_path(path string) string {
	mut p := path
	for p.ends_with('/') {
		p = p[..p.len - 1]
	}
	if p.ends_with('.git') {
		p = p[..p.len - 4]
	}
	return p
}

fn default_port(scheme string) string {
	return match scheme {
		'https' { '443' }
		'http' { '80' }
		'ssh' { '22' }
		'git' { '9418' }
		else { '' }
	}
}
