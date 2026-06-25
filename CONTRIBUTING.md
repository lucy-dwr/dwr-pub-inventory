# Contributing

Thank you for your interest in helping to maintain or extend the DWR
Publication Inventory. This project supports a curated publication record for
California Department of Water Resources research, so contributions should
preserve reproducibility, reviewability, and data provenance.

## Ways to Contribute

- Report problems with publication records, classifications, affiliations, or
  dashboard behavior by opening an issue.
- Propose documentation improvements that make the refresh workflow easier to
  run or audit by opening an issue or submitting a pull request.
- Submit focused code changes for pipeline functions, tests, Shiny apps,
  supporting documentation, or additional features by submitting a pull request.
- Add or improve tests for existing R functions by submitting a pull request.

## Opening an Issue

An issue is a GitHub discussion thread for reporting a problem, asking a
question, or proposing a change. To open one, go to the DWR publication inventory
repository on GitHub, select the **Issues** tab near the top of the page, then
choose **New issue**.

Issues are most useful when they give maintainers enough context to reproduce
the problem or evaluate the suggested change. A good issue usually includes:

- A short description of the problem, question, or proposed improvement.
- The exact command, app, pipeline target, or file you were working with.
- What you expected to happen and what actually happened.
- Any relevant error messages, warnings, screenshots, or log output.
- A minimal reproducible example, when possible, using a small input dataset or
  fixture instead of private, large, or generated project data.
- Your local context, such as R version, operating system, and whether the
  project dependencies were restored with `renv::restore()`.
- A suggested change, if known.

For data issues, include stable identifiers such as DOI, title, `record_key`, or
publication year when available. Do not include secrets, private HR-derived
lookup data, API keys, or other sensitive information.

For guidance on making small reproducible examples in R, see the
[tidyverse reprex guide](https://reprex.tidyverse.org/) and
[RStudio's guide to reproducible examples](https://support.posit.co/hc/en-us/articles/200526207-Using-reprex-to-create-reproducible-examples).

## Opening a Pull Request

If you are new to GitHub contributions, the usual workflow is:

1. Fork the repository to your GitHub account.
2. Clone your fork locally and create a short-lived branch for the change.
3. Make focused edits, commit them with a clear message, and push the branch to
   your fork.
4. Open a pull request back to this repository's `main` branch.
5. Respond to review comments by pushing additional commits to the same branch.

GitHub's documentation has more step-by-step detail:

- [Fork a repository](https://docs.github.com/en/get-started/quickstart/fork-a-repo)
- [Create a pull request from a fork](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/working-with-forks/creating-a-pull-request-from-a-fork)
- [About pull requests](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/proposing-changes-to-your-work-with-pull-requests/about-pull-requests)

## Development Setup

Open the repository from its root so `.Rprofile` activates `renv`, then restore
the locked R package environment:

```r
renv::restore()
```

The required R version is recorded under the `R` key in `renv.lock`. Using a
different R version may cause compiled packages to fail during `renv::restore()`
because binary packages are built per R version and source compilation can
expose API incompatibilities between R releases.

### Upgrading R

If you install a new major or minor R version and `renv::restore()` fails for
compiled packages, update those packages to versions that support the new R
release before snapshotting:

```r
install.packages(c("<failing-package>", ...))
```

`renv` will install the latest binaries available for your R version. Once the
failing packages install cleanly, re-run `renv::restore()` to pick up any
cascade dependencies, then snapshot to record the updated versions:

```r
renv::snapshot()
```

Commit the updated `renv.lock` so other contributors and CI pick up the new
versions.

If you run into compilation errors for specific packages, consult the upstream
installation documentation before opening an issue here.

R toolchain:

- macOS (compilers, gfortran): [CRAN R for macOS](https://cran.r-project.org/bin/macosx/)
- Windows (Rtools): [CRAN Rtools](https://cran.r-project.org/bin/windows/Rtools/)

Packages with complex system dependencies:

- **sf / terra / s2 / units** require GDAL, GEOS, PROJ, and libudunits2:
  [sf installation guide](https://r-spatial.github.io/sf/#installing)
- **arrow** wraps the Apache Arrow C++ library and can take 10–20 minutes to
  build from source when binaries are unavailable:
  [arrow R installation guide](https://arrow.apache.org/docs/r/articles/install.html)
- **igraph** requires a Fortran compiler (gfortran):
  [igraph installation guide](https://r.igraph.org/articles/installation-troubleshooting.html)
- **data.table** has OpenMP and system library requirements:
  [data.table installation wiki](https://github.com/Rdatatable/data.table/wiki/Installation)

### Credentials

Some full pipeline and classification steps require local credentials:

- `SCOPUS_API_KEY`
- `SCOPUS_INSTTOKEN`
- `PUBCLASSIFY_EMAIL`
- `PUBCLASSIFY_LLM_KEY`

Do not commit secrets, local `.Renviron` files, private HR-derived lookup files,
or unreviewed generated data.

## Testing

Run the unit test suite before opening a pull request:

```r
testthat::test_dir("tests/testthat")
```

The unit tests use local fixtures and do not require Scopus or LLM credentials.
If your change affects refresh logic, review queues, decision files, or dashboard
exports, include tests that cover the changed behavior where practical, and
ensure that any test changes prove that no regression has occurred.

## Pipeline Safety

Scopus API calls are disabled by default in `config/pipeline.yml`. Only set
`scopus.allow_api_calls: true` when intentionally harvesting fresh records. Set
it back to `false` before committing changes.

Avoid committing transient review queues, local pipeline caches, credentials, or
private lookup data. When updating durable data files, describe the source and
review step in the pull request.

## Pull Request Guidelines

- Keep changes focused and explain the publication-inventory workflow they
  affect.
- Include test results in the pull request description.
- Update documentation when commands, data schemas, or review steps change.
- Call out any manual review required after the change is merged.

By participating in this project, contributors agree to follow the
[Code of Conduct](CODE_OF_CONDUCT.md).
