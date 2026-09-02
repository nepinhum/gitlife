module discover

import json2
import github
import source

// GitHub is a discovery provider, not a source of history. Everything here
// returns repository locations; commits are read from Git afterwards, never from
// these responses.
//
// Discovery is deliberately three overlapping queries. Owned repositories miss
// the ones a user only contributes to; viewer affiliations miss what belongs to
// an account that is not the authenticated one; contribution years catch work in
// repositories the account no longer has access to list. Together they are a best
// effort and a repository all three miss can still be added as a 'git' source.
const owner_repos_query = 'query($login: String!, $cursor: String) {
  rateLimit { remaining resetAt }
  repositoryOwner(login: $login) {
    __typename
    ... on User {
      repositories(first: 100, after: $cursor, ownerAffiliations: [OWNER]) {
        pageInfo { hasNextPage endCursor }
        nodes { nameWithOwner url isFork isPrivate isArchived }
      }
    }
    ... on Organization {
      repositories(first: 100, after: $cursor, ownerAffiliations: [OWNER]) {
        pageInfo { hasNextPage endCursor }
        nodes { nameWithOwner url isFork isPrivate isArchived }
      }
    }
  }
}'

const viewer_repos_query = 'query($cursor: String) {
  rateLimit { remaining resetAt }
  viewer {
    repositories(first: 100, after: $cursor, ownerAffiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER]) {
      pageInfo { hasNextPage endCursor }
      nodes { nameWithOwner url isFork isPrivate isArchived }
    }
  }
}'

const viewer_login_query = 'query { viewer { login } }'

const contribution_years_query = 'query($login: String!) {
  rateLimit { remaining resetAt }
  user(login: $login) { contributionsCollection { contributionYears } }
}'

const contributions_query = 'query($login: String!, $from: DateTime!, $to: DateTime!) {
  rateLimit { remaining resetAt }
  user(login: $login) {
    contributionsCollection(from: $from, to: $to) {
      commitContributionsByRepository(maxRepositories: 100) {
        repository { nameWithOwner url isFork isPrivate isArchived }
      }
    }
  }
}'

// max_pages stops a broken or hostile cursor from paginating forever. A hundred
// pages is ten thousand repositories, which no account reaches by accident.
const max_pages = 100

pub struct GithubResult {
pub:
	found     []Found
	viewer    string
	remaining int // API budget left when discovery finished
}

pub fn github_repos(mut client github.Client, login string) !GithubResult {
	// The cheapest possible query, run first. It settles whether the token works
	// at all, reporting an authentication problem before any paging begins.
	viewer_data := client.query(viewer_login_query, map[string]json2.Any{})!
	viewer := text(dig(viewer_data, 'viewer.login') or { json2.Any('') })

	mut repos := map[string]Found{}
	is_user := collect_owner(mut client, login, mut repos)!

	if viewer != '' && viewer.to_lower() == login.to_lower() {
		collect_pages(mut client, viewer_repos_query, map[string]json2.Any{}, 'viewer.repositories', mut repos)!
	}

	// contributionsCollection exists only for a User; an Organization has none.
	if is_user {
		collect_contributions(mut client, login, mut repos)!
	}

	mut found := repos.values()
	found.sort(a.name < b.name)
	return GithubResult{
		found: found
		viewer: viewer
		remaining: client.rate.remaining
	}
}

// collect_owner pages the account's own repositories and reports whether the
// account is a User, which decides whether contribution queries apply.
fn collect_owner(mut client github.Client, login string, mut repos map[string]Found) !bool {
	mut cursor := json2.Any(json2.null)
	mut is_user := false
	for page := 0; page < max_pages; page++ {
		data := client.query(owner_repos_query, {
			'login':  json2.Any(login)
			'cursor': cursor
		})!
		owner := dig(data, 'repositoryOwner') or {
			return github.Failure{
				kind: .not_found
				message: "GitHub has no account named '${login}', or this token cannot see it"
			}
		}
		if owner.as_map().len == 0 {
			return github.Failure{
				kind: .not_found
				message: "GitHub has no account named '${login}', or this token cannot see it"
			}
		}
		is_user = text(owner.as_map()['__typename'] or { json2.Any('') }) == 'User'
		connection := dig(owner, 'repositories') or { break }
		absorb(connection, mut repos)
		next := next_cursor(connection) or { break }
		cursor = json2.Any(next)
	}
	return is_user
}

fn collect_contributions(mut client github.Client, login string, mut repos map[string]Found) ! {
	years_data := client.query(contribution_years_query, {
		'login': json2.Any(login)
	})!
	years := (dig(years_data, 'user.contributionsCollection.contributionYears') or {
		json2.Any([]json2.Any{})
	}).as_array()
	for year in years {
		y := year.int()
		if y == 0 {
			continue
		}
		// contributionsCollection accepts at most a one year window.
		data := client.query(contributions_query, {
			'login': json2.Any(login)
			'from':  json2.Any('${y}-01-01T00:00:00Z')
			'to':    json2.Any('${y}-12-31T23:59:59Z')
		})!
		entries := (dig(data, 'user.contributionsCollection.commitContributionsByRepository') or {
			continue
		}).as_array()
		for entry in entries {
			node := dig(entry, 'repository') or { continue }
			remember(node, mut repos)
		}
	}
}

fn collect_pages(mut client github.Client, operation string, extra map[string]json2.Any, path string, mut repos map[string]Found) ! {
	mut cursor := json2.Any(json2.null)
	for page := 0; page < max_pages; page++ {
		mut variables := extra.clone()
		variables['cursor'] = cursor
		data := client.query(operation, variables)!
		connection := dig(data, path) or { return }
		absorb(connection, mut repos)
		next := next_cursor(connection) or { return }
		cursor = json2.Any(next)
	}
}

fn absorb(connection json2.Any, mut repos map[string]Found) {
	nodes := (connection.as_map()['nodes'] or { return }).as_array()
	for node in nodes {
		remember(node, mut repos)
	}
}

fn remember(node json2.Any, mut repos map[string]Found) {
	fields := node.as_map()
	url := text(fields['url'] or { json2.Any('') })
	if url == '' {
		return
	}
	name := text(fields['nameWithOwner'] or { json2.Any('') })
	key := source.normalize_url(url)
	if key in repos {
		return
	}
	metadata := json2.Any({
		'nameWithOwner': json2.Any(name)
		'isFork':        fields['isFork'] or { json2.Any(false) }
		'isPrivate':     fields['isPrivate'] or { json2.Any(false) }
		'isArchived':    fields['isArchived'] or { json2.Any(false) }
	}).json_str()
	repos[key] = Found{
		name: if name != '' { name } else { source.display_name(url) }
		url: url
		metadata: metadata
	}
}

// next_cursor returns the cursor for the following page or nothing when this was
// the last one. A page that claims to have a successor but names no cursor ends
// the walk rather than repeating itself forever.
fn next_cursor(connection json2.Any) ?string {
	info := (connection.as_map()['pageInfo'] or { return none }).as_map()
	if !(info['hasNextPage'] or { return none }).bool() {
		return none
	}
	cursor := text(info['endCursor'] or { return none })
	if cursor == '' {
		return none
	}
	return cursor
}

// text reads a string field, treating JSON null as absent. Without this, a null
// reaches V as the four characters 'null' and is indistinguishable from a real
// value. For a pagination cursor that means never stopping.
fn text(value json2.Any) string {
	if value is json2.Null {
		return ''
	}
	return value.str()
}

// dig walks a dotted path, returning nothing when any step is absent.
fn dig(value json2.Any, path string) ?json2.Any {
	mut current := value
	for key in path.split('.') {
		current = current.as_map()[key] or { return none }
	}
	return current
}
