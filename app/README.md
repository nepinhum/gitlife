## Description

`app` parses argv and dispatches. It holds no logic of its own beyond turning
words into calls and results into an exit code.

`run(args)` returns the exit code instead of calling `exit` itself, which keeps
the whole command surface a function: 0 for success, 1 for a failed command, 2
for argv that could not be parsed.
