# ── normalize_scopus_name() ───────────────────────────────────────────────────

test_that("converts 'Last, First M.' format to 'FIRST M LAST'", {
  expect_equal(normalize_scopus_name("Smith, John A."), "JOHN A SMITH")
})

test_that("handles multi-word given names in comma format", {
  expect_equal(normalize_scopus_name("Van Der Berg, Anna Marie"), "ANNA MARIE VAN DER BERG")
})

test_that("converts 'Last I.' (no comma, trailing initials) to 'I LAST'", {
  expect_equal(normalize_scopus_name("Riordan D."), "D RIORDAN")
})

test_that("converts 'Last A.D.' (no comma, multi-initial) to 'A D LAST'", {
  expect_equal(normalize_scopus_name("Biales A.D."), "A D BIALES")
})

test_that("returns NA for NA input", {
  expect_equal(normalize_scopus_name(NA_character_), NA_character_)
})

test_that("returns NA for empty or whitespace-only input", {
  expect_equal(normalize_scopus_name(""), NA_character_)
  expect_equal(normalize_scopus_name("   "), NA_character_)
})

# ── author_in_lookup() ────────────────────────────────────────────────────────

test_that("returns TRUE on exact last-name and first-initial match in publication year", {
  lookup <- prepare_lookup(write_author_lookup_csv(tibble::tibble(
    division = "D", year = "2023", name = "JOHN A SMITH"
  )))
  expect_true(author_in_lookup("Smith, John A.", "2023", lookup))
})

test_that("returns TRUE when author is found in the adjacent year", {
  lookup <- prepare_lookup(write_author_lookup_csv(tibble::tibble(
    division = "D", year = "2022", name = "JOHN A SMITH"
  )))
  expect_true(author_in_lookup("Smith, John A.", "2023", lookup))  # year-1 match
})

test_that("returns FALSE when author is not in lookup", {
  lookup <- prepare_lookup(write_author_lookup_csv(tibble::tibble(
    division = "D", year = "2023", name = "JANE B DOE"
  )))
  expect_false(author_in_lookup("Smith, John A.", "2023", lookup))
})

test_that("returns FALSE for NA author name without error", {
  lookup <- prepare_lookup(write_author_lookup_csv())
  expect_false(author_in_lookup(NA_character_, "2023", lookup))
})

test_that("returns FALSE for an empty lookup data frame", {
  empty_lookup <- data.frame(
    division = character(), year = character(), name = character(),
    norm_name = character(), first_initial = character(), last_name = character(),
    stringsAsFactors = FALSE
  )
  expect_false(author_in_lookup("Smith, John A.", "2023", empty_lookup))
})

# ── resolve_author_division() ─────────────────────────────────────────────────

test_that("rule 1: resolves a unique division match in the publication year", {
  lookup <- prepare_lookup(write_author_lookup_csv(tibble::tibble(
    division = "Division of Planning", year = "2023", name = "JOHN A SMITH"
  )))
  result <- resolve_author_division("Smith, John A.", "2023", lookup)
  expect_equal(result$rule, 1L)
  expect_equal(result$division, "Division of Planning")
})

test_that("rule 2: falls back to prior year when no exact-year match", {
  lookup <- prepare_lookup(write_author_lookup_csv(tibble::tibble(
    division = "Division of Planning", year = "2022", name = "JOHN A SMITH"
  )))
  result <- resolve_author_division("Smith, John A.", "2023", lookup)
  expect_equal(result$rule, 2L)
})

test_that("rule 4: flags ambiguous result when multiple divisions are found", {
  lookup <- prepare_lookup(write_author_lookup_csv(tibble::tibble(
    division = c("Division A", "Division B"),
    year     = c("2023",       "2023"),
    name     = c("JOHN A SMITH", "JOHN A SMITH")
  )))
  result <- resolve_author_division("Smith, John A.", "2023", lookup)
  expect_equal(result$rule, 4L)
  expect_true(is.na(result$division))
  expect_length(result$candidates, 2L)
})

test_that("rule 5: returns no-match when author is not in lookup at all", {
  lookup <- prepare_lookup(write_author_lookup_csv(tibble::tibble(
    division = "D", year = "2023", name = "JANE B DOE"
  )))
  result <- resolve_author_division("Smith, John A.", "2023", lookup)
  expect_equal(result$rule, 5L)
})
