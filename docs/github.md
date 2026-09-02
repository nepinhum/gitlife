# GitHub

GitHub is a discovery provider: it says which repositories exist, and Git remains
the only authority for what is in them. gitlife calls GitHub's GraphQL API
directly over HTTPS. `gh` is not required, and is never used to fetch data.

```console
GITLIFE_GITHUB_TOKEN=ghp_... gitlife source add github nepinhum
GITLIFE_GITHUB_TOKEN=ghp_... gitlife sync github:nepinhum
```

## Tokens

A token is looked for in this order, and each step is optional:

1. `GITLIFE_GITHUB_TOKEN`
2. `GITHUB_TOKEN`
3. `gh auth token`, if you already use `gh` and are logged in

A step with nothing to offer declines rather than failing. Only an exhausted chain
is an error.

A classic token needs the `repo` scope to see private repositories, a fine grained
token needs read access to the repositories you want listed. Every authentication
failure names which token it used, and says what went wrong. Token values are
never printed.

## How the credential reaches Git

Private repositories are fetched too. Git gets the credential through its own
credential-helper protocol, per invocation:

```console
gitlife credential-helper get
```

Git invokes that itself, it is not something you run. What it buys:

- No token is written into a remote URL.
- No token is written into a clone's configuration.
- No token is written into the database.
- The variables that would make Git print an `Authorization` header into its
  stderr are scrubbed from the environment it runs with.

The same resolved token serves both API discovery and Git transport.
