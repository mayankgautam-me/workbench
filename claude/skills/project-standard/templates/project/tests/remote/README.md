# tests/remote

The full deployed test suite, run by `make test-remote ENV=staging` after a staging deploy (CI runs
it in the deploy-staging stage). It may create and delete test data on staging. Production is refused
unless `CONFIRM=production` is given on the command line.
