# Shared test infrastructure for DWR publication inventory tests.
#
# Sourced automatically by testthat before every test file.
# Run the full suite from the project root:
#   testthat::test_dir("tests/testthat")

# ── 1. Locate project root and source all pipeline functions ──────────────────

.proj_root <- local({
  dirs <- c(getwd())
  for (i in seq_len(6L)) dirs <- c(dirs, dirname(tail(dirs, 1L)))
  dirs <- unique(dirs)
  hit <- Filter(function(d) file.exists(file.path(d, "_targets.R")), dirs)
  if (length(hit) == 0L) {
    stop("Cannot locate project root (_targets.R not found). Run tests from the project root.")
  }
  normalizePath(hit[[1L]])
})

invisible(lapply(
  list.files(file.path(.proj_root, "R"), pattern = "\\.R$", full.names = TRUE),
  source
))

# ── 2. Fixture builders ───────────────────────────────────────────────────────

#' Minimal publications tibble with all columns needed by pipeline functions.
#' Affiliations are flat character vectors (post-add_record_keys shape).
make_pubs <- function() {
  tibble::tibble(
    record_key    = c("eid:2-s2.0-001", "doi:10.1000/def", "hash:abc123"),
    eid           = c("2-s2.0-001",     NA_character_,     NA_character_),
    doi           = c("10.1000/abc",    "10.1000/def",     NA_character_),
    title         = c(
      "Water resources in California",
      "Climate change study",
      "Hydrology review"
    ),
    abstract      = c(
      "Delta smelt population in the Sacramento-San Joaquin Delta",
      "Global warming impacts on sea level",
      NA_character_
    ),
    year          = c("2023", "2022", "2021"),
    authors       = list(
      c("Smith, John A."),
      c("Jones, Mary B.", "Chen, Wei"),
      c("Brown, K.")
    ),
    affiliations  = list(
      c("California Department of Water Resources, Sacramento, CA"),
      c("University of London, UK", "Peking University, China"),
      c("NOAA, Silver Spring, Maryland")
    ),
    funders       = list("California DWR", character(0L), character(0L)),
    grant_numbers = list("4600012345",    character(0L), character(0L)),
    journal       = c("Water Resources Research", "Nature Climate Change", "Hydrology"),
    query_source  = c("funder", "affiliation", "funder; affiliation")
  )
}

#' Write a decisions CSV to a temp file and return its path.
write_decisions_csv <- function(decisions, dir = tempdir()) {
  path <- tempfile(tmpdir = dir, fileext = ".csv")
  readr::write_csv(decisions, path)
  path
}

#' Write an author-division lookup CSV to a temp file and return its path.
#' Columns: division, year, name  (name in "FIRST [MIDDLE] LAST" uppercase form).
write_author_lookup_csv <- function(
    df = tibble::tibble(
      division = "Division of Planning and Local Assistance",
      year     = "2023",
      name     = "JOHN A SMITH"
    ),
    dir = tempdir()
) {
  path <- tempfile(tmpdir = dir, fileext = ".csv")
  readr::write_csv(df, path)
  path
}

#' Harvest candidates tibble used by funder and author queue tests.
#' Contains 2 funder-only, 1 affiliation-only, and 1 funder+affiliation record.
make_harvest_pubs <- function() {
  tibble::tibble(
    record_key    = c("eid:001", "doi:10.1/b", "eid:003", "eid:004"),
    doi           = c("10.1/a",  "10.1/b",    "10.1/c",  "10.1/d"),
    title         = c(
      "Water resources in California",
      "Pacific salmon spawning habitat in the Sacramento River",
      "Quantum computing benchmarks",
      "Sacramento Delta flood management"
    ),
    abstract      = rep(NA_character_, 4L),
    year          = rep("2023", 4L),
    authors       = replicate(4L, c("Smith, J."), simplify = FALSE),
    affiliations  = list(
      c("California Department of Water Resources, Sacramento, CA"),
      c("NOAA Fisheries, Silver Spring, Maryland"),
      c("Sorbonne Université, Paris, France"),
      c("California Department of Water Resources, Sacramento, CA")
    ),
    funders       = list("CA DWR", character(0L), character(0L), "CA DWR"),
    grant_numbers = replicate(4L, character(0L), simplify = FALSE),
    query_source  = c("funder", "affiliation", "funder", "funder; affiliation")
  )
}

#' Write a minimal accepted-publications parquet and return its path.
write_accepted_parquet <- function(record_keys, dir = tempdir()) {
  path <- tempfile(tmpdir = dir, fileext = ".parquet")
  arrow::write_parquet(
    tibble::tibble(record_key = as.character(record_keys)),
    path
  )
  path
}
