# gitlife

`gitlife` builds a provider independent history of your work in Git.

GitHub, Codeberg, GitLab and the rest are repository *discovery* providers. None
of them defines Git history. gitlife reads commits from Git itself, indexes them
once, and reports across every repository you have: local clones, direct remotes
and provider discovered repositories alike.

## Shape

`main.v` calls `app.run(args)`, which returns an exit code rather than calling
`exit`: 0 success, 1 a failed command, 2 argv that could not be parsed.

| module | what it owns |
|---|---|
| `app` | argv, dispatch, exit codes. No logic of its own |
| `config` | the user editable half of the state: paths, sources, identities |
| `source` | canonicalizing the ways one repository can be named |
| `proc` | starting a child process. The only place that does |
| `identity` | which Git identities are the user's own |
| `gitrepo` | reading history out of a repository. The only thing that talks to git |
| `index` | the schema and every read and write against it. The only place that speaks SQL |
| `credentials` | resolving an access token, without deciding what it is for |
| `github` | the GitHub API |
| `discover` | turning a source into a list of repositories |
| `cache` | managed bare clones of remotes |
| `syncer` | the run: discover, prepare, register, read, write |
| `report` | rendering, as a table or as JSON |

A sync is five phases. Discover, register and write are serial and own the
database; prepare and read run in parallel and never touch it.

Each module carries a `README.md`. That is how V documents a module and how the
LSP reads it; a comment above `module x` is invisible to both.

## Build

Every V invocation passes `-old-compiler`. V3 is broken on linux-gnu.

Build with the stable V release, 0.5.2. On V master `v fmt` is frequently broken
and rewrites code that was fine, so never trust a master formatter's diff.

```sh
v fmt -w .
v -old-compiler -o gitlife .          # development
```

Release builds add `-prod`, which turns on `-O3` and `-flto` and compiles the
`$if prod` branches. It also promotes most V warnings to errors, so a build that
is clean without it can still fail with it.

```sh
GITLIFE_COMMIT=$(git describe --always --dirty) \
  v -old-compiler -prod -o gitlife .
```

The commit is stamped in at build time, never read at runtime: gitlife runs
inside other repositories and would report theirs. A build that skips the stamp
prints the version alone.

`-cc clang` is worth passing if clang is installed; it links faster and produces
a smaller binary than gcc here. gcc past 12.0 has inlining bugs under `-prod`,
worked around with `-cflags -fno-inline-small-functions` if a build breaks.

`v fmt` before compiling, always and compile after `v fmt`: it silently breaks
code around a few keywords and more of them on V master than on 0.5.2.

A module nothing imports yet is **not** reached by the binary build. Check it on
its own or it is unverified:

```sh
v -old-compiler -shared -check <module>/
```

Requires `git` on PATH and SQLite.

## Invariants

- `proc` is the only place that starts a process, and never through a shell.
- A token is never embedded in a stored remote URL, never written to SQLite,
  never printed through git's stderr. Transport goes through
  `gitlife credential-helper get`, which git invokes on demand.
- `gh` is never required. Every credential provider may decline; only an
  exhausted chain is an error.
- `Cmd.env`, when non empty, replaces the child environment entirely. Build it
  with `proc.child_env`, never a partial map.
- Testing anything that runs `git credential fill` requires
  `GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null`. Without it git reads
  the developer's real credential store and prints a live token.
- Anything touching config, state or cache runs with `GITLIFE_CONFIG_DIR`,
  `GITLIFE_STATE_DIR` and `GITLIFE_CACHE_DIR` pointed somewhere disposable.

## House style

Comments say what it does, with a small why and a small how when needed. Not what
the code used to be, not which plan or phase produced it.

- Quote with an apostrophe in V code and error messages: `'--jobs'`. Backticks
  belong to Markdown and to V's rune literals.
- A hyphen is only a real hyphen, as in `// Something - see this.v`. For an
  aside, a pair of commas does the job.
- Plain. No annotations nobody asked for.

Keep it small. A test file that exists to serve debugging does not belong in the tree.

## Commits

Honestly do whatever you want, just make sure it makes sense :D
