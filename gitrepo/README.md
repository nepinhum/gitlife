## Description

`gitrepo` reads history out of a Git repository. It knows nothing about
providers, sources or the index. Git is the only authority for commits and this
module is the only thing that talks to it.

Records are read with a fixed arity of eleven lines per commit rather than a
NUL-delimited format because V's process helpers truncate at the first NUL.
Every calendar facing value keeps the commit's own timezone offset, which makes a
day the day the author experienced rather than the day it was in UTC.
