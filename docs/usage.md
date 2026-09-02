# Usage

## Sources

A source is a place repositories come from. Three kinds:

```console
gitlife source add local ~/dev
gitlife source add git https://github.com/owner/project.git
gitlife source add github nepinhum
gitlife source list
gitlife source remove local:/home/you/dev
```

A local path is canonicalized when it is added, which keeps one directory reached
by two paths a single source. A remote URL carrying a credential is redacted
before it is stored, because a source id appears in every sync line and report.

Removing a source keeps the history already indexed. See `purge` below.

## Identities

A commit counts as yours only if you accepted its name or its email. Nothing is
inferred from frequency or similarity.

```console
gitlife identity add --email you@example.com
gitlife identity add --name "Your Name"
gitlife identity list
gitlife identity candidates
```

`candidates` lists the identities that appear in your indexed history and have not
been accepted, so you can see what you have not claimed. Accepting one changes
every report at once, and unaccepting it changes them back.

## Sync

```console
gitlife sync                 # every configured source
gitlife sync github:nepinhum # one of them
gitlife sync --jobs 4        # default is one worker per CPU, capped at 8
```

A run that had a failed source or repository exits nonzero, which lets a script
tell a partial sync from a clean one.

Work is handed out round robin and the results are put back in order, so the
output of `--jobs 8` is byte identical to the output of `--jobs 1`.

## Reports

```console
gitlife summary
gitlife repos
gitlife commits
gitlife timeline
```

`summary` is the lifetime view. `repos` lists the repositories your work is in,
with an id you can pass to `--repo` when two of them share a name. `commits` lists
the commits themselves, newest first, marking a commit that several repositories
hold. `timeline` counts commits per period and fills in the idle ones, because a
chart that skips an empty year reads as a busy one.

## Filters

Every report takes the same filters:

```console
gitlife summary --since 2024-01-01 --until 2024-12-31
gitlife summary --repo gitlife --committer
gitlife commits --repo gitlife --limit 20
gitlife timeline --by year
gitlife repos --format json
```

| flag | meaning |
|---|---|
| `--source <id>` | restrict to repositories one source discovered |
| `--repo <name\|id>` | restrict to one repository |
| `--since <date>` | `YYYY-MM-DD`, inclusive |
| `--until <date>` | `YYYY-MM-DD`, inclusive |
| `--author` | count the author role, the default |
| `--committer` | count the committer role |
| `--format table\|json` | how to render |
| `--limit <n>` | how many commits to list, default 50 |
| `--by day\|month\|year` | timeline bucket, default month |

## Purge

```console
gitlife purge --dry-run
gitlife purge
```

`purge` forgets everything no configured source can still reach: the repositories
only a removed source discovered, the commits that were only in them, and the
managed clones nothing points at. It is deliberately a separate act from removing
a source, and `--dry-run` is the same code path with the work rolled back instead
of committed.

Nothing it removes is irreplaceable, a sync rebuilds all of it from Git.
