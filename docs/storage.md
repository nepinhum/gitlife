# Storage

```text
$XDG_CONFIG_HOME/gitlife/config.toml
$XDG_STATE_HOME/gitlife/gitlife.db
$XDG_CACHE_HOME/gitlife/repos/
```

`GITLIFE_CONFIG_DIR`, `GITLIFE_STATE_DIR` and `GITLIFE_CACHE_DIR` override these,
each independently.

## config.toml

The user editable half of the state: which sources are configured and which
identities are your own. `gitlife source add` and `gitlife identity add` write it,
and you can edit it by hand.

```toml
# gitlife configuration

[[source]]
kind = "local"
spec = "/home/you/dev"

[[identity]]
email = "you@example.com"
```

No credential is written here. A token belongs in the environment.

## gitlife.db

Everything derived: repositories, commits, which repository holds which commit,
and what each sync did. It is a cache in the sense that a sync rebuilds it from
Git, and it is the thing every report reads.

## repos/

Managed bare clones of the remotes you configured, one per address. A local
directory is read where it sits and is never copied here.
