## Description

`index` is the only part of gitlife that speaks SQL. It owns the schema, the
migrations and every read and write against them.

A commit is keyed globally by `(object_format, object_id)` and written with
`INSERT OR IGNORE`. A commit row is never updated because the same commit found
in two repositories is the same commit. What changes is membership:
`repository_commits` holds, per repository, the union of what that repository's
locations reach.

Membership is diffed rather than rewritten. A location's set goes into the
`scanned_commits` scratch table, the commits missing from membership are added,
the ones the location no longer reaches are removed, and everything else is left
where it is. One new commit used to mean deleting every membership row a
repository had and writing all of them back.

A snapshot is written through `Batch` which holds a few thousand rows and no
more. Every commit of a repository used to become a row of strings before the
first of them was written, a second copy of the history on top of the walk that
produced it. That copy is now a fixed size whatever the repository holds.

Every report counts the same set of commits through `Filter.mine`, keeping
two reports from disagreeing about what belongs to the user.

`purge` forgets what no configured source can still reach. It is deliberately a
separate act from removing a source. `--dry-run` is the same code path with the
transaction rolled back instead of committed.
