## What this changes

<!-- What it does, and the why in a line or two. -->

## How it was checked

<!-- The commands you ran, and anything you could not check here. -->

```console
v fmt -w .
v (optional: -old-compiler) test .
v (optional: -old-compiler) -prod -o gitlife .
```

Build with the stable V release, 0.5.2. `v fmt` on V master is frequently broken
and will rewrite code it should have left alone, so format with a stable
toolchain if you have one and say which V you used above if you do not.

## Checklist

- [ ] `v fmt -w .` ran before the build and the build is clean with `-prod`
- [ ] Tests pass, and anything touching config, state or cache runs against a disposable `GITLIFE_*_DIR`
- [ ] A module nothing imports yet was checked on its own with `v -old-compiler -shared -check <module>/`
- [ ] A new module carries a `README.md`
- [ ] No token reaches a stored remote URL, SQLite or git's stderr
