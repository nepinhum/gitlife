## Description

`github` is a GraphQL client for GitHub's API, split so the wire is replaceable.
Everything above `Transport` is testable without a network or a credential and
`HttpTransport` is the only thing that opens a socket.

That split lets the tests exercise pagination, the failure taxonomy and the
discovery adapter against recorded fixtures, with no socket and no token.
