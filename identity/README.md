## Description

`identity` decides which Git identities are the user's own.

The rule is deliberately dumb: an identity matches only if the user said so.
Nothing is inferred from frequency, similarity or the shape of a name.

Emails fold to ASCII lowercase, their case carrying no meaning in practice. Names
never fold. Candidates, the identities that appear in the history and have not
been accepted, are derived by query and never stored, which is why accepting one
changes every report at once and unaccepting it changes them back.
