#!/bin/sh
# Runs the sync benchmark against the repositories bench/gen.sh built.
#
#   bench/gen.sh /tmp/gl-bench 1000 10000
#   bench/run.sh /tmp/gl-bench
#   bench/run.sh /tmp/gl-bench unchanged plus1
#
# Run it from the repository root, or point GITLIFE_BIN at the binary. Results
# append to <workdir>/results.tsv, one line per case, so two runs of the same
# tree stay side by side.
#
# The cases, in the order the default run takes them:
#
#   first-j1        a fresh index, one repository at a time
#   first-j8        a fresh index, eight at a time
#   unchanged       nothing moved since, the ref digest fast path
#   plus1           one new commit on master in every repository
#   branch-delete   side is gone, so its commits must lose their membership
#   force-rewrite   master's tip replaced by a different commit
#   restore         puts the refs back, so the next run starts where this one did
#
# Every case after first-j8 measures an incremental sync, which is the thing
# issues #1 and #5 are about. They mutate the repositories, and 'restore' undoes
# that from the snapshot taken before the first mutation.
set -eu

if [ $# -lt 1 ]; then
	echo "usage: bench/run.sh <workdir> [case...]" >&2
	exit 2
fi

work=$1
shift
here=$(dirname "$0")
bin=${GITLIFE_BIN:-./gitlife}
repos="$work/repos"
results="$work/results.tsv"

if [ ! -d "$repos" ]; then
	echo "no repositories in $repos; run bench/gen.sh first" >&2
	exit 1
fi
if [ ! -x "$bin" ]; then
	echo "$bin is not executable; build it or set GITLIFE_BIN" >&2
	exit 1
fi

# A disposable everything. Nothing here touches the real config, index or cache
# and git never reads the developer's own config or credential store.
GITLIFE_CONFIG_DIR="$work/config"
GITLIFE_STATE_DIR="$work/state"
GITLIFE_CACHE_DIR="$work/cache"
GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_SYSTEM=/dev/null
GIT_AUTHOR_NAME=You
GIT_AUTHOR_EMAIL=you@example.com
GIT_COMMITTER_NAME=You
GIT_COMMITTER_EMAIL=you@example.com
GIT_COMMITTER_DATE='1500000000 +0000'
GIT_AUTHOR_DATE='1500000000 +0000'
export GITLIFE_CONFIG_DIR GITLIFE_STATE_DIR GITLIFE_CACHE_DIR
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
export GIT_COMMITTER_DATE GIT_AUTHOR_DATE

repo_list() {
	find "$repos" -mindepth 1 -maxdepth 1 -type d | sort
}

repo_count=$(repo_list | wc -l | tr -d ' ')

fresh() {
	rm -rf "$GITLIFE_CONFIG_DIR" "$GITLIFE_STATE_DIR" "$GITLIFE_CACHE_DIR"
	mkdir -p "$GITLIFE_CONFIG_DIR" "$GITLIFE_STATE_DIR" "$GITLIFE_CACHE_DIR"
	"$bin" source add local "$repos" >/dev/null
	"$bin" identity add --email you@example.com >/dev/null
}

# The refs as they were before any case moved them. Taken once and kept, so a
# restore always returns to the generated state rather than to the last run.
snapshot() {
	[ -d "$work/refs" ] && return 0
	mkdir -p "$work/refs"
	for repo in $(repo_list); do
		git -C "$repo" show-ref >"$work/refs/$(basename "$repo")"
	done
}

restore() {
	for repo in $(repo_list); do
		file="$work/refs/$(basename "$repo")"
		[ -f "$file" ] || continue
		for ref in $(git -C "$repo" for-each-ref --format='%(refname)'); do
			git -C "$repo" update-ref -d "$ref"
		done
		while read -r sha ref; do
			git -C "$repo" update-ref "$ref" "$sha"
		done <"$file"
	done
	echo "refs restored"
}

mutate_plus1() {
	for repo in $(repo_list); do
		tip=$(git -C "$repo" rev-parse master)
		tree=$(git -C "$repo" rev-parse 'master^{tree}')
		new=$(git -C "$repo" commit-tree "$tree" -p "$tip" -m 'one more')
		git -C "$repo" update-ref refs/heads/master "$new"
	done
}

mutate_delete_side() {
	for repo in $(repo_list); do
		git -C "$repo" update-ref -d refs/heads/side 2>/dev/null || true
	done
}

mutate_rewrite() {
	for repo in $(repo_list); do
		base=$(git -C "$repo" rev-parse 'master^')
		tree=$(git -C "$repo" rev-parse 'master^{tree}')
		new=$(git -C "$repo" commit-tree "$tree" -p "$base" -m 'rewritten')
		git -C "$repo" update-ref refs/heads/master "$new"
	done
}

# One measured sync. Wall time and both memory numbers come from measure.py, the
# database size from the file it just wrote.
record() {
	name=$1
	jobs=$2
	limit=${GITLIFE_TIMEOUT:-600}
	line=$(MEASURE_LOG="$work/sync.log" python3 "$here/measure.py" \
		timeout "$limit" "$bin" sync --jobs "$jobs" || true)
	secs=$(printf '%s' "$line" | cut -f1)
	tree_kb=$(printf '%s' "$line" | cut -f2)
	waited_kb=$(printf '%s' "$line" | cut -f3)
	status=$(printf '%s' "$line" | cut -f4)
	db=$(stat -c %s "$GITLIFE_STATE_DIR/gitlife.db" 2>/dev/null || echo 0)
	commits=$("$bin" summary --format json 2>/dev/null | tr ',' '\n' | sed -n 's/.*"authored"[: ]*\([0-9]*\).*/\1/p' | head -1)
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$(date +%Y-%m-%dT%H:%M:%S)" "$name" "$jobs" "$repo_count" "${commits:-0}" \
		"$secs" "$tree_kb" "$waited_kb" "$db" >>"$results"
	echo "$name: ${secs}s, tree peak ${tree_kb}K, largest process ${waited_kb}K, db ${db}B"
	if [ "${status:-1}" != 0 ]; then
		echo "  warning: sync exited ${status}, so this line measures a failure" >&2
		if [ "${status:-1}" = 124 ]; then
			echo "  it ran past ${limit}s and was killed. Parallel sync can deadlock" >&2
		fi
	fi
}

if [ ! -f "$results" ]; then
	printf 'when\tcase\tjobs\trepos\tauthored\tseconds\trss_tree_kb\trss_max_kb\tdb_bytes\n' >"$results"
fi

cases=$*
[ -n "$cases" ] || cases='first-j1 first-j8 unchanged plus1 branch-delete force-rewrite restore'

snapshot

for name in $cases; do
	case $name in
	first-j1)
		fresh
		record first-j1 1
		;;
	first-j8)
		fresh
		record first-j8 8
		;;
	unchanged)
		record unchanged 8
		;;
	plus1)
		mutate_plus1
		record plus1 8
		;;
	branch-delete)
		mutate_delete_side
		record branch-delete 8
		;;
	force-rewrite)
		mutate_rewrite
		record force-rewrite 8
		;;
	restore)
		restore
		;;
	*)
		echo "unknown case '$name'" >&2
		exit 2
		;;
	esac
done

echo
column -t -s "$(printf '\t')" "$results"
