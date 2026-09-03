## Description

`proc` is the only place in gitlife that starts a process.

It never goes through a shell. argv is passed to the child directly and no
amount of quoting in a path or a URL can change what runs. stdout and stderr are
kept apart because a stray `warning:` line from git merged into stdout would
corrupt every record stream that follows it.

The two pipes are drained together, in one `poll` over both. Draining one to EOF
before reading the other deadlocks as soon as a child fills the pipe nobody is
reading.

The child comes from `posix_spawn`. A fork copies the calling
thread and nothing else, a child that allocates on its way to `exec` can wait
forever on a lock some other thread was holding when the fork happened. That is
what `sync --jobs 8` used to do, hanging about half the time with a child forked
and never exec'd. `posix_spawn` leaves the whole business to libc and runs no V
code in the child.
