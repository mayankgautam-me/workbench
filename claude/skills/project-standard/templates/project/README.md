# @@PROJECT@@

@@PARTS_TABLE@@

## Getting started

```sh
make setup          # tools (brew bundle, mise), shared SDKs, dependencies, git hooks, LFS
make secrets-init   # create this project's secrets (~/.secrets/@@PROJECT@@/) and ask for missing values
make doctor         # check everything; prints the command that fixes each problem
make dev            # run the local stack
make check          # format, lint, typecheck and unit tests: run before every commit
```

`make help` lists every command, grouped by stage and by part. Every command runs from this folder;
a part's own commands are `make <part>-<verb>`, for example `make @@FIRST_PART@@-build`.

## Environments

`ENV=local` (the default), `ENV=staging` or `ENV=production`. Anything that touches production, and
any destroy, wipe, reset or erase, also needs `CONFIRM=<env>` on the command line:

```sh
make deploy ENV=staging                    # a push to main does this in CI (parts with staging)
make deploy ENV=production CONFIRM=production   # a hotfix by hand; normally a part's release tag deploys production
```

## Releases

Each part releases on its own tag, `<part>-v<version>`. Note changes under `## [Unreleased]` in the part's
`CHANGELOG.md`, then:

```sh
make @@FIRST_PART@@-bump LEVEL=patch      # version file + CHANGELOG, a commit and the tag; nothing pushed
make release-push                          # the branch, then each new release tag in its own push
make latest                                # each part's newest Release
```

The tag's release workflow creates the GitHub Release with the CHANGELOG notes and the part's files (firmware images,
fab files, app builds, ...), then copies them into the Release `latest`, which holds the newest files of every part and
carries GitHub's "Latest" badge. Its files keep their names across versions, so a link to
`.../releases/download/latest/<file>` always gets the newest. Publishing to devices, stores or production stays a
manual job in that workflow.

## Secrets

No secret is ever in this repository. `secrets.schema` names every secret; the values are encrypted
in the secrets repo and reach a command only through its environment. `make secrets-list` shows what
exists, `make secrets-set NAME=... ENV=...` sets one.

This project follows the project-standard layout (version in `make/VERSION`). Files marked
"managed" on their first line are refreshed by the standard; project-only commands go in
`make/local.mk`.
