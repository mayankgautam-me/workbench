# tests/smoke

Quick checks run against a deployed environment by `make smoke ENV=<env>` (and after every
`make deploy`). Keep them fast and read-only: health endpoints, a page that must render, a login
page that must answer. Each check is an executable file here that gets the deployed base URL of a
part in `SMOKE_URL` and exits non-zero on failure.
