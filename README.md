# gitlife

`gitlife` builds a provider independent history of your work in Git.

GitHub, Codeberg, GitLab and the rest are repository *discovery* providers. None
of them defines Git history. `gitlife` reads commits from Git itself, indexes them
once and reports across every repository you have. Local clones, direct remotes,
and provider discovered repositories alike.

```console
v -prod -o gitlife .

gitlife source add local ~/dev
gitlife identity add --email you@example.com
gitlife sync
gitlife summary
```

Local directories, direct Git remotes and GitHub accounts all index end to end,
and `summary`, `repos`, `commits` and `timeline` read across them. A remote is
read through a managed bare clone kept in the cache directory. Repositories sync
in parallel, and `gitlife purge` forgets what no configured source reaches any
more.

## Documentation

- [Build](docs/build.md), requirements, a production build, stamping the commit
- [Usage](docs/usage.md), sources, identities, syncing, the four reports and their filters
- [GitHub](docs/github.md), discovery, tokens and how the credential reaches Git
- [Concepts](docs/concepts.md), what the numbers mean and when two repositories are one
- [Storage](docs/storage.md), where the config, the index and the clones live

## Notes

- This project uses Claude for planning, descriptions and several performance-optimization tasks.

## License

MIT. See `LICENSE`.
