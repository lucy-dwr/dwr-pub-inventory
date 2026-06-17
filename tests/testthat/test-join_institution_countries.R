write_geo_lookup <- function(df, dir = tempdir()) {
  path <- tempfile(tmpdir = dir, fileext = ".csv")
  readr::write_csv(df, path)
  path
}

test_that("adds an affiliation_countries list column", {
  geo <- tibble::tibble(canonical = "UC Davis", country = "United States", state = "California")
  pubs <- tibble::tibble(affiliations = list(c("UC Davis")))
  path <- write_geo_lookup(geo)
  on.exit(unlink(path))

  result <- join_institution_countries(pubs, path)
  expect_true("affiliation_countries" %in% names(result))
  expect_type(result$affiliation_countries, "list")
})

test_that("maps canonical institution names to their countries", {
  geo <- tibble::tibble(
    canonical = c("UC Davis",       "Sorbonne Université"),
    country   = c("United States",  "France"),
    state     = c("California",     NA_character_)
  )
  pubs <- tibble::tibble(affiliations = list(c("UC Davis", "Sorbonne Université")))
  path <- write_geo_lookup(geo)
  on.exit(unlink(path))

  result <- join_institution_countries(pubs, path)
  expect_setequal(result$affiliation_countries[[1L]], c("United States", "France"))
})

test_that("produces an empty character vector for publications with no matched affiliations", {
  geo  <- tibble::tibble(canonical = "UC Davis", country = "United States", state = "California")
  pubs <- tibble::tibble(affiliations = list(c("Unknown University")))
  path <- write_geo_lookup(geo)
  on.exit(unlink(path))

  result <- join_institution_countries(pubs, path)
  expect_equal(result$affiliation_countries[[1L]], character(0L))
})

test_that("deduplicates countries when multiple affiliations resolve to the same country", {
  geo <- tibble::tibble(
    canonical = c("UC Davis", "Stanford University"),
    country   = c("United States", "United States"),
    state     = c("California", "California")
  )
  pubs <- tibble::tibble(affiliations = list(c("UC Davis", "Stanford University")))
  path <- write_geo_lookup(geo)
  on.exit(unlink(path))

  result <- join_institution_countries(pubs, path)
  expect_equal(result$affiliation_countries[[1L]], "United States")
})

test_that("stops with an informative error when required columns are missing from geo lookup", {
  bad_geo <- tibble::tibble(institution = "UC Davis", nation = "USA")  # wrong column names
  pubs    <- tibble::tibble(affiliations = list(c("UC Davis")))
  path    <- write_geo_lookup(bad_geo)
  on.exit(unlink(path))

  expect_error(
    join_institution_countries(pubs, path),
    regexp = "canonical"
  )
})

test_that("omits NA country values from the result vector", {
  geo <- tibble::tibble(
    canonical = c("UC Davis", "Unknown Corp"),
    country   = c("United States", NA_character_),
    state     = c("California", NA_character_)
  )
  pubs <- tibble::tibble(affiliations = list(c("UC Davis", "Unknown Corp")))
  path <- write_geo_lookup(geo)
  on.exit(unlink(path))

  result <- join_institution_countries(pubs, path)
  expect_false(any(is.na(result$affiliation_countries[[1L]])))
  expect_equal(result$affiliation_countries[[1L]], "United States")
})
