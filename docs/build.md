# Build

```console
v -prod -o gitlife .
```

Linux and macOS. Windows is not supported: gitlife starts processes and lays out
its directories the POSIX way and no works has done to change that.

Requires `git` on PATH and SQLite (Arch: `pacman -S sqlite`, Debian:
`apt install libsqlite3-dev`). Add `-old-compiler` if your V miscompiles this.

Use the stable V release, 0.5.2. V master moves fast and `v fmt` there is
frequently broken, badly enough to rewrite working code into something that no
longer compiles. A master build may still work; the formatter is the part to
distrust.

`-prod` turns on the C optimizer and link time optimization. It also promotes
most V warnings to errors, so a tree that builds clean without it can still fail
with it. Drop `-prod` while developing:

```console
v -o gitlife .
```

## The commit stamp

`gitlife version` reports the version from `v.mod`. To have it report the commit
it was built from, stamp it in:

```console
GITLIFE_COMMIT=$(git describe --always --dirty) v -prod -o gitlife .
```

```console
$ gitlife version
gitlife v0.0.0 (fc2268d)
```

A build that skips this prints the version alone. The commit is never read at
runtime, because gitlife runs inside other repositories and would report theirs.
