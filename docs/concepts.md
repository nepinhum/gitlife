# Concepts

## What the numbers mean

- A commit is globally identified by its object format and object id, so a commit
  living in a fork, a mirror and a working tree counts **once** in a lifetime
  total, and still counts in **each** repository that contains it.
- A commit belongs to the calendar day its author was living. A commit made at
  23:30 in Istanbul is that day's commit, not the next day's in UTC.
- Email matching folds case, domains being case insensitive by RFC and every
  forge in scope treating the local part that way too. Name matching does not
  fold: a name is a chosen display string, and folding it would merge two people
  who picked the same letters.

## When two repositories are one

A working tree and a remote you also configured directly are recognized as **one**
repository when the working tree's `origin` points at that remote.

Only `origin` merges. People routinely add `upstream` to a fork, and a rule that
merged on any remote would fuse the fork with what it forked.

Spellings of one address are canonicalized first, so `git@github.com:user/repo.git`
and `https://github.com/user/repo` resolve to the same key.

## Discovery is not history

Providers answer one question: which repositories exist. Everything counted comes
from Git itself, read out of a clone. A provider that goes away, or a token that
expires, costs you discovery of new repositories, never the history already
indexed.
