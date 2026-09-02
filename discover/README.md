## Description

`discover` answers where repositories may be found. Adapters return locations and
metadata; they never create commit records.

There are three. `local` walks a directory tree, `git` takes one remote address,
and `github` asks the provider what the account owns. What comes back is a
location and enough about it to decide whether anything moved. Reading history
out of it is `gitrepo`'s job.
