# bench

A sync benchmark. It exists so the performance issues can be argued with numbers
rather than with intuition and so a change can be shown to have helped.

Nothing here is built or shipped. It is three files: repository generation,
the run and the measurement.

## Running it

```console
v -old-compiler -prod -o gitlife .
bench/gen.sh ~/gl-bench 1000 10000
bench/run.sh ~/gl-bench
```

`gen.sh` writes one bare repository per size through `git fast-import` which is
the only way to get 100k commits in seconds. A repository that already exists is
left alone. Sizes are commits on `master`; each repository also carries a `side`
branch with three commits `master` cannot reach.

`run.sh` takes the cases in order and appends one line per case to
`<workdir>/results.tsv`:

| case | what it measures |
|---|---|
| `first-j1` | a fresh index, one repository at a time |
| `first-j8` | a fresh index, eight at a time |
| `unchanged` | nothing moved, the ref digest fast path |
| `plus1` | one new commit per repository, the incremental case of issue #1 |
| `branch-delete` | `side` gone, so its commits must lose membership |
| `force-rewrite` | `master`'s tip replaced, history partly unreachable |
| `restore` | puts the refs back so the next run starts where this one did |

Name cases to run a subset: `bench/run.sh ~/gl-bench unchanged plus1`.

Everything runs against `GITLIFE_CONFIG_DIR`, `GITLIFE_STATE_DIR` and
`GITLIFE_CACHE_DIR` inside the work directory with `GIT_CONFIG_GLOBAL` and
`GIT_CONFIG_SYSTEM` at `/dev/null`. It can't touch a real index and git never
reads a real credential store.

`GITLIFE_BIN` picks a different binary. `GITLIFE_TIMEOUT` caps one sync,
600 seconds by default.

## Sizes, and what they cost

Generation is cheap. The sync is what needs the memory and today a repository's
whole history is held in RAM while it is written, so size and `--jobs` multiply.

| commits | repository on disk | rough advice |
|---|---|---|
| 1k | under 1 MB | always |
| 10k | a few MB | always |
| 100k | tens of MB | one at a time, watch `rss_tree_kb` |
| 500k | hundreds of MB | not on 8 GB, not yet |

Start at 1k and 10k, read the memory column, then decide whether the next size
up is safe. That column is the whole reason this harness exists.

## The two memory numbers

`rss_max_kb` is the largest single process that ran, the same number
`/usr/bin/time -v` calls maximum resident set size. It answers how much gitlife
itself holds.

`rss_tree_kb` adds up every process in the tree at one instant, sampled every
50 ms. It answers what `--jobs 8` costs with eight git processes alive at once.
Sampling can miss a spike between two samples, so read it as a floor.

## Reading a result

The interesting comparisons, not the absolute seconds:

- `unchanged` against `first-j8`. The gap is what the ref digest fast path buys.
- `plus1` against `first-j8`. They are nearly equal today, which is issue #1:
  one new commit costs a full history rescan.
- `rss_tree_kb` at `first-j1` against `first-j8`. Growth with jobs is issue #2.
- `db_bytes` between runs. It should not grow when nothing new was indexed.

## A warning about --jobs

Parallel sync deadlocks. `--jobs 1` is stable; anything above it hangs a fair
part of the time, forked but not yet exec'd, so a benchmark run can stall until
`GITLIFE_TIMEOUT` kills it. A killed case is still written to the results file
and flagged on stderr. Until that is fixed, the `-j8` cases will be flaky.
