## Description

`gitrepo` reads history out of a Git repository. It knows nothing about
providers, sources or the index. Git is the only authority for commits and this
module is the only thing that talks to it.

Records are read with a fixed arity of eleven lines per commit rather than a
NUL-delimited format because V's process helpers truncate at the first NUL.
Every calendar facing value keeps the commit's own timezone offset, which makes a
day the day the author experienced rather than the day it was in UTC.

A repository the index has seen before is walked as a difference. `refs` keeps
the tips a walk stopped at and the next one asks git for the commits that came
into scope since (`added`) and the ones that left it (`dropped`) rather than for
the whole history again. Both fail when a tip is no longer in the repository,
which is what a rewrite followed by a `git gc` leaves behind and the caller
walks everything instead. `refs` also says whether the history is truncated: a
fetch can deepen a shallow repository without moving a ref and what it puts in
reach are ancestors of the very tips a difference would exclude.

Every walk shares one ref scope. An incremental walk that disagreed with the full
one about which refs count would add commits that a later full walk removes.
