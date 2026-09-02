## Description

`proc` is the only place in gitlife that starts a process.

It never goes through a shell. argv is passed to the child directly and no
amount of quoting in a path or a URL can change what runs. stdout and stderr are
kept apart because a stray `warning:` line from git merged into stdout would
corrupt every record stream that follows it.

The two pipes are drained together, alternating between them. Draining one to EOF
before reading the other deadlocks as soon as a child fills the pipe nobody is
reading.
