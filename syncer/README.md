## Description

`syncer` orchestrates one pass: discover, fetch, scan, index. It is the only
module that knows about all the others and it owns nothing itself.

The pass runs in five phases. The split is what makes it safe to run in parallel:
the slow phases touch only Git and the filesystem, the fast ones only the
database, and no worker thread ever holds the connection.

```
discover  what repositories exist              (serial, one call per source)
prepare   clone or fetch, fingerprint refs     (parallel, no database)
register  resolve identity, decide what moved  (serial, database)
read      walk the commits                     (parallel, no database)
write     bring the snapshots up to date       (serial, database)
```

Read and write are one loop rather than two phases: workers walk repositories
while the writer takes each walk, in task order and inserts it. A history is
held from the moment its worker finished with it until it is in the database,
and not a moment longer, so a run costs a history per worker rather than one per
repository.

Registration is separate from preparation because a repository can be reachable
through more than one location. A working tree and a cached clone of the same
origin are one repository and its membership is the union of them, not whichever
was scanned last.

Work is handed out round robin and taken back in that same order, making the
output of `--jobs 8` byte identical to the output of `--jobs 1`.

`Deps` carries the credential and the provider client as values rather than as
constructions inside the sync, lets a test supply a fixture transport and a
fake token.
