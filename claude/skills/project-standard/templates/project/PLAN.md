# @@PROJECT@@

Components and tasks of this project, drawn as the project map. A component is `## Name {#id}` with
`tech:`, `files:` and `kind:` lines; tasks are `- [ ]` (todo), `- [~]` (in progress), `- [x]` (done)
or `- [!]` (blocked).

## Project {#project}
tech: make (project-standard), mise, Homebrew, GitHub Actions, sops + age
files: [Makefile, make/**, Brewfile, mise.toml, secrets.schema, .github/**, .gitignore, .gitattributes, README.md, CLAUDE.md, PLAN.md, tests/**, docs/*.md, docs/images/**, scripts/**]
kind: tooling
- [ ] make setup and make doctor pass on this Mac {#project-setup}
- [ ] Secrets created with make secrets-init {#project-secrets}
- [ ] CI keys stored with make secrets-ci and the first CI run green {#project-ci}

@@COMPONENTS@@
