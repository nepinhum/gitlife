## Description

`source` canonicalizes the ways a repository can be named, so two spellings of
one location resolve to one key.

`git@github.com:user/repo.git` and `https://github.com/user/repo` are one
address. A URL that arrives carrying a credential is redacted before it is stored
or printed because a source id appears in every sync line and every report.
