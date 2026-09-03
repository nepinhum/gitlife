#!/usr/bin/env python3
"""Runs one command and reports what the benchmark cares about.

Prints a single line: seconds, peak RSS of the whole process tree, peak RSS as
the kernel reports it for waited children, exit status.

Two memory numbers because they answer different questions. The kernel's
ru_maxrss is the largest single process that ran, which is the right number for
'how much does gitlife itself hold'. The sampled one adds up every process in
the tree at the same instant, which is the right number for '--jobs 8 with eight
git processes alive at once'. Sampling can miss a spike between two samples, so
treat it as a floor.

Child stdout goes to MEASURE_LOG, or is discarded. Its stderr passes through and
its exit status becomes ours.
"""

import os
import resource
import subprocess
import sys
import threading
import time

PAGE_KB = resource.getpagesize() // 1024
INTERVAL = 0.05


def read_procs():
    """pid -> (ppid, rss in pages) for everything running right now."""
    procs = {}
    for entry in os.listdir('/proc'):
        if not entry.isdigit():
            continue
        try:
            with open('/proc/' + entry + '/stat') as fh:
                line = fh.read()
        except OSError:
            continue  # it exited while we were reading which is normal
        # The command name is parenthesized and may contain spaces, so the
        # fields we want are counted from the last ')'.
        tail = line[line.rfind(')') + 2:].split()
        if len(tail) < 22:
            continue
        procs[int(entry)] = (int(tail[1]), int(tail[21]))
    return procs


def tree_rss_kb(root):
    procs = read_procs()
    children = {}
    for pid, (ppid, _) in procs.items():
        children.setdefault(ppid, []).append(pid)
    total, stack = 0, [root]
    while stack:
        pid = stack.pop()
        entry = procs.get(pid)
        if entry is None:
            continue
        total += entry[1] * PAGE_KB
        stack.extend(children.get(pid, []))
    return total


def main():
    if len(sys.argv) < 2:
        print('usage: measure.py <command> [args...]', file=sys.stderr)
        return 2

    log = os.environ.get('MEASURE_LOG', os.devnull)
    peak = [0]
    with open(log, 'a') as out:
        started = time.monotonic()
        child = subprocess.Popen(sys.argv[1:], stdout=out)

        def sample():
            while child.poll() is None:
                peak[0] = max(peak[0], tree_rss_kb(child.pid))
                time.sleep(INTERVAL)

        watcher = threading.Thread(target=sample, daemon=True)
        watcher.start()
        status = child.wait()
        watcher.join(timeout=1)
        elapsed = time.monotonic() - started

    waited = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    print('%.3f\t%d\t%d\t%d' % (elapsed, peak[0], waited, status))
    return status


if __name__ == '__main__':
    sys.exit(main())
