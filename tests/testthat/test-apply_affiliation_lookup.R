make_affil_pubs <- function(record_keys = c("eid:001", "eid:002"),
                            affiliations = list(
                              c("Dept of Water Res"),
                              c("Unknown Uni")
                            )) {
  tibble::tibble(record_key = record_keys, affiliations = affiliations)
}

write_affil_lookup <- function(df, dir = tempdir()) {
  path <- tempfile(tmpdir = dir, fileext = ".csv")
  readr::write_csv(df, path)
  path
}

# ── Core mapping ──────────────────────────────────────────────────────────────

test_that("replaces raw affiliation strings with their canonical names", {
  lookup <- tibble::tibble(
    record_key = NA_character_,
    raw        = "Dept of Water Res",
    canonical  = "California Department of Water Resources",
    new        = FALSE,
    manual_added = FALSE
  )
  pubs    <- make_affil_pubs(affiliations = list(c("Dept of Water Res"), c("Other Org")))
  path    <- write_affil_lookup(lookup)
  on.exit(unlink(path))

  result  <- apply_affiliation_lookup(pubs, path, require_reviewed = FALSE)
  expect_equal(result$affiliations[[1L]], "California Department of Water Resources")
})

test_that("occurrence-level lookup (with record_key) maps per-publication", {
  lookup <- tibble::tibble(
    record_key   = c("eid:001", "eid:002"),
    raw          = c("Uni A", "Uni A"),
    canonical    = c("University of Alpha", "University of Aleph"),
    new          = FALSE,
    manual_added = FALSE
  )
  pubs <- make_affil_pubs(affiliations = list(c("Uni A"), c("Uni A")))
  path <- write_affil_lookup(lookup)
  on.exit(unlink(path))

  result <- apply_affiliation_lookup(pubs, path, require_reviewed = FALSE)
  expect_equal(result$affiliations[[1L]], "University of Alpha")
  expect_equal(result$affiliations[[2L]], "University of Aleph")
})

test_that("legacy raw-only lookup applies globally when no record_key column is present", {
  lookup <- tibble::tibble(
    raw       = "Uni A",
    canonical = "University Alpha",
    new       = FALSE
  )
  pubs <- make_affil_pubs(affiliations = list(c("Uni A"), c("Uni A")))
  path <- write_affil_lookup(lookup)
  on.exit(unlink(path))

  result <- apply_affiliation_lookup(pubs, path, require_reviewed = FALSE)
  expect_equal(result$affiliations[[1L]], "University Alpha")
  expect_equal(result$affiliations[[2L]], "University Alpha")
})

test_that("leaves unmatched affiliations unchanged and issues a warning", {
  lookup <- tibble::tibble(
    raw = "Known Org", canonical = "Known Organisation", new = FALSE
  )
  pubs <- make_affil_pubs(affiliations = list(c("Known Org"), c("Mystery Org")))
  path <- write_affil_lookup(lookup)
  on.exit(unlink(path))

  expect_warning(
    result <- apply_affiliation_lookup(pubs, path, require_reviewed = FALSE),
    regexp = "not in lookup"
  )
  expect_equal(result$affiliations[[2L]], "Mystery Org")
})

test_that("manual_added rows are appended to the matching publication", {
  lookup <- tibble::tibble(
    record_key   = c("eid:001"),
    raw          = c("Dept of Water Res"),
    canonical    = c("California Department of Water Resources"),
    new          = FALSE,
    manual_added = c(TRUE)
  )
  pubs <- make_affil_pubs(
    record_keys  = "eid:001",
    affiliations = list(character(0L))
  )
  path   <- write_affil_lookup(lookup)
  on.exit(unlink(path))

  result <- apply_affiliation_lookup(pubs, path, require_reviewed = FALSE)
  expect_true("California Department of Water Resources" %in% result$affiliations[[1L]])
})

# ── Validation guards ─────────────────────────────────────────────────────────

test_that("stops with informative error when new = TRUE rows exist and require_reviewed = TRUE", {
  lookup <- tibble::tibble(
    raw = "Uni A", canonical = "University Alpha", new = TRUE
  )
  pubs <- make_affil_pubs(affiliations = list(c("Uni A"), c("Uni B")))
  path <- write_affil_lookup(lookup)
  on.exit(unlink(path))

  expect_error(
    apply_affiliation_lookup(pubs, path, require_reviewed = TRUE),
    regexp = "new"
  )
})

test_that("passes when require_reviewed = FALSE even with new = TRUE rows", {
  lookup <- tibble::tibble(
    raw = "Uni A", canonical = "University Alpha", new = TRUE
  )
  pubs <- make_affil_pubs(affiliations = list(c("Uni A"), c("Uni B")))
  path <- write_affil_lookup(lookup)
  on.exit(unlink(path))

  expect_no_error(
    apply_affiliation_lookup(pubs, path, require_reviewed = FALSE)
  )
})

test_that("stops with error when lookup is missing required columns", {
  lookup <- tibble::tibble(canonical = "University Alpha")  # no 'raw'
  pubs   <- make_affil_pubs()
  path   <- write_affil_lookup(lookup)
  on.exit(unlink(path))

  expect_error(
    apply_affiliation_lookup(pubs, path),
    regexp = "raw"
  )
})

# ── Internal helpers ──────────────────────────────────────────────────────────

test_that(".normalize_unknown_canonical converts any case of 'unknown' to 'Unknown'", {
  expect_equal(.normalize_unknown_canonical(c("unknown", "UNKNOWN", "Unknown", "uNkNoWn")),
               c("Unknown", "Unknown", "Unknown", "Unknown"))
})

test_that(".normalize_unknown_canonical leaves non-unknown values unchanged", {
  expect_equal(.normalize_unknown_canonical(c("UC Davis", NA_character_)),
               c("UC Davis", NA_character_))
})

test_that(".coerce_new_flag handles logical input correctly", {
  expect_equal(.coerce_new_flag(c(TRUE, FALSE, NA)), c(TRUE, FALSE, FALSE))
})

test_that(".coerce_new_flag handles character TRUE/FALSE variants", {
  expect_true(.coerce_new_flag("true"))
  expect_true(.coerce_new_flag("T"))
  expect_true(.coerce_new_flag("1"))
  expect_true(.coerce_new_flag("yes"))
  expect_false(.coerce_new_flag("false"))
  expect_false(.coerce_new_flag("0"))
})

test_that(".affiliation_occurrence_key concatenates with CR separator", {
  key <- .affiliation_occurrence_key("eid:001", "Raw Affil String")
  expect_equal(key, "eid:001\rRaw Affil String")
})
