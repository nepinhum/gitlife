## Description

`credentials` resolves an access token without deciding what it is for.

A provider is a place a token might live. The chain is ordered and every link is
optional. A link with nothing to offer says so rather than failing and only an
exhausted chain is an error. For GitHub the chain is `GITLIFE_GITHUB_TOKEN`, then
`GITHUB_TOKEN`, then `gh auth token` if `gh` happens to be installed. `gh` is
never required.

The same resolved token serves both API discovery and Git transport. Transport
goes through git's credential-helper protocol, `gitlife credential-helper get`,
which git invokes on demand. A token is never embedded in a remote URL, written
to the database or printed through git's stderr.
