#!/bin/sh
# Builds synthetic repositories for the sync benchmark.
#
#   bench/gen.sh <workdir> <commits>...
#   bench/gen.sh /tmp/gl-bench 1000 10000
#
# One bare repository per size, named after it, written through git fast-import
# rather than one commit at a time. A repository that already exists is left
# alone, generating 100k commits is not something to repeat by accident.
#
# Every repository gets a 'side' branch holding commits that master can't
# reach which is what the branch deletion case removes.
set -eu

if [ $# -lt 2 ]; then
	echo "usage: bench/gen.sh <workdir> <commits>..." >&2
	exit 2
fi

work=$1
shift

# Never the developer's real git config, and never their credential store.
GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM

mkdir -p "$work/repos"

stream() {
	awk -v n="$1" 'BEGIN {
		who[0] = "You <you@example.com>"
		who[1] = "Ada <ada@example.com>"
		who[2] = "Lin <lin@example.com>"
		start = 1400000000
		for (i = 1; i <= n; i++) {
			printf "commit refs/heads/master\n"
			printf "mark :%d\n", i
			printf "author %s %d +0000\n", who[i % 3], start + i * 600
			printf "committer %s %d +0000\n", who[i % 3], start + i * 600
			printf "data <<EOM\ncommit %d\nEOM\n", i
			if (i > 1)
				printf "from :%d\n", i - 1
			printf "M 100644 inline f%d.txt\ndata <<EOB\n%d\nEOB\n\n", i % 16, i
		}
		# Three commits reachable only from side, branched off the middle.
		base = int(n / 2)
		if (base < 1)
			base = 1
		for (i = 1; i <= 3; i++) {
			mark = n + i
			printf "commit refs/heads/side\n"
			printf "mark :%d\n", mark
			printf "author %s %d +0000\n", who[0], start + (n + i) * 600
			printf "committer %s %d +0000\n", who[0], start + (n + i) * 600
			printf "data <<EOM\nside %d\nEOM\n", i
			printf "from :%d\n", (i == 1 ? base : mark - 1)
			printf "M 100644 inline side.txt\ndata <<EOB\n%d\nEOB\n\n", i
		}
		printf "done\n"
	}'
}

for size in "$@"; do
	repo="$work/repos/r$size"
	if [ -d "$repo" ]; then
		echo "r$size exists, left alone"
		continue
	fi
	git init --quiet --bare --initial-branch=master "$repo"
	stream "$size" | git -C "$repo" fast-import --quiet --done
	echo "r$size built, $(git -C "$repo" rev-list --count --all) commits, $(du -sh "$repo" | cut -f1)"
done
