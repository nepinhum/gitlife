## Description

`config` owns the user editable half of gitlife's state: where things live on
disk, which sources are configured and which identities are the user's own.
Everything derived lives in SQLite instead.

Paths follow the XDG base directory specification. Each can be overridden with
`GITLIFE_CONFIG_DIR`, `GITLIFE_STATE_DIR` and `GITLIFE_CACHE_DIR` which is what
the tests use to stay out of a real home directory.

No credential is written here. A token belongs in the environment.
