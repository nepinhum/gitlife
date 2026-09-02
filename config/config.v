module config

import os
import toml

pub struct Source {
pub mut:
	kind   string // local | git | github
	spec   string
	active bool = true
}

pub fn (s Source) id() string {
	return '${s.kind}:${s.spec}'
}

pub struct Identity {
pub:
	name  string
	email string
}

// Paths resolves to XDG locations with GITLIFE_* overrides so tests never touch
// the developer's real configuration, database or cache.
pub struct Paths {
pub:
	config_dir string
	state_dir  string
	cache_dir  string
}

pub fn paths() Paths {
	home := os.home_dir()
	return Paths{
		config_dir: pick('GITLIFE_CONFIG_DIR', 'XDG_CONFIG_HOME', os.join_path(home, '.config'), 'gitlife')
		state_dir: pick('GITLIFE_STATE_DIR', 'XDG_STATE_HOME', os.join_path(home, '.local', 'state'), 'gitlife')
		cache_dir: pick('GITLIFE_CACHE_DIR', 'XDG_CACHE_HOME', os.join_path(home, '.cache'), 'gitlife')
	}
}

fn pick(direct string, xdg string, fallback string, leaf string) string {
	if v := os.getenv_opt(direct) {
		return v
	}
	if v := os.getenv_opt(xdg) {
		return os.join_path(v, leaf)
	}
	return os.join_path(fallback, leaf)
}

pub fn (p Paths) config_file() string {
	return os.join_path(p.config_dir, 'config.toml')
}

pub fn (p Paths) db_file() string {
	return os.join_path(p.state_dir, 'gitlife.db')
}

pub fn (p Paths) repos_dir() string {
	return os.join_path(p.cache_dir, 'repos')
}

pub struct Config {
pub:
	paths Paths
pub mut:
	sources    []Source
	identities []Identity
}

// load reads config.toml. A missing file is an empty configuration.
pub fn load(p Paths) !Config {
	mut c := Config{
		paths: p
	}
	path := p.config_file()
	if !os.exists(path) {
		return c
	}
	doc := toml.parse_file(path) or { return error('${path}: ${err.msg()}') }
	// A missing table is an empty list, not a malformed file.
	for mut item in array_of(doc, 'source') {
		m := item.as_map()
		kind := m['kind'] or { toml.Any('') }.string()
		spec := m['spec'] or { toml.Any('') }.string()
		if kind == '' || spec == '' {
			return error("${path}: every [[source]] needs a 'kind' and a 'spec'")
		}
		if kind !in ['local', 'git', 'github'] {
			return error("${path}: unknown source kind '${kind}'")
		}
		c.sources << Source{
			kind: kind
			spec: spec
			active: m['active'] or { toml.Any(true) }.bool()
		}
	}
	for mut item in array_of(doc, 'identity') {
		m := item.as_map()
		name := m['name'] or { toml.Any('') }.string()
		email := m['email'] or { toml.Any('') }.string()
		if name == '' && email == '' {
			return error("${path}: every [[identity]] needs a 'name' or an 'email'")
		}
		c.identities << Identity{
			name: name
			email: email
		}
	}
	return c
}

// save rewrites config.toml. The writer is hand rolled: the file is small and
// the shape is fixed.
pub fn (c Config) save() ! {
	mut b := []string{}
	b << '# gitlife configuration'
	for s in c.sources {
		b << ''
		b << '[[source]]'
		b << 'kind = ${quote(s.kind)}'
		b << 'spec = ${quote(s.spec)}'
		if !s.active {
			b << 'active = false'
		}
	}
	for i in c.identities {
		b << ''
		b << '[[identity]]'
		if i.name != '' {
			b << 'name = ${quote(i.name)}'
		}
		if i.email != '' {
			b << 'email = ${quote(i.email)}'
		}
	}
	os.mkdir_all(c.paths.config_dir)!
	os.write_file(c.paths.config_file(), b.join('\n') + '\n')!
}

fn array_of(doc toml.Doc, key string) []toml.Any {
	v := doc.value_opt(key) or { return [] }
	if v is []toml.Any {
		return v
	}
	return []
}

fn quote(s string) string {
	return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
}
