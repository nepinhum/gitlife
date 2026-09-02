## Description

`cache` manages the bare clones gitlife keeps for repositories it can't read in
place. A cached repository is a copy of history, not a source of truth: it is
rebuilt from its remote whenever that remote is reachable.

Nothing under the cache root is irreplaceable which makes `prune` safe by design.
It removes only directories that are themselves bare repositories, identified by
a `HEAD` file. It never descends into repositories, follows symlinks or operates
outside the cache root.
