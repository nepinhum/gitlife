module discover

import source

// git_remote is the whole of the direct remote adapter. A configured URL is
// already the answer to "where is this repository", leaving nothing to discover.
// It exists to give every source kind the same path into sync.
pub fn git_remote(url string) []Found {
	return [
		Found{
			name: source.display_name(url)
			url:  url
		},
	]
}
