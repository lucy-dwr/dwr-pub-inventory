test_that("EID takes priority over DOI and hash", {
  pubs <- tibble::tibble(
    eid = "2-s2.0-001", doi = "10.1000/abc",
    title = "T", year = "2023",
    authors = list(c("Smith, J.")),
    affiliations = list(character(0L)),
    funders = list(character(0L)), grant_numbers = list(character(0L)),
    journal = "J"
  )
  result <- add_record_keys(pubs)
  expect_equal(result$record_key, "eid:2-s2.0-001")
})

test_that("DOI is used and normalised when EID is NA", {
  pubs <- tibble::tibble(
    eid = NA_character_, doi = "  10.1000/ABC  ",
    title = "T", year = "2023",
    authors = list(c("Smith, J.")),
    affiliations = list(character(0L)),
    funders = list(character(0L)), grant_numbers = list(character(0L)),
    journal = "J"
  )
  result <- add_record_keys(pubs)
  expect_equal(result$record_key, "doi:10.1000/abc")
})

test_that("blank EID falls through to DOI", {
  pubs <- tibble::tibble(
    eid = "  ", doi = "10.1000/xyz",
    title = "T", year = "2023",
    authors = list(c("Smith, J.")),
    affiliations = list(character(0L)),
    funders = list(character(0L)), grant_numbers = list(character(0L)),
    journal = "J"
  )
  result <- add_record_keys(pubs)
  expect_equal(result$record_key, "doi:10.1000/xyz")
})

test_that("hash is used when both EID and DOI are NA", {
  pubs <- tibble::tibble(
    eid = NA_character_, doi = NA_character_,
    title = "A study of hydrology", year = "2020",
    authors = list(c("Brown, K.")),
    affiliations = list(character(0L)),
    funders = list(character(0L)), grant_numbers = list(character(0L)),
    journal = "Hydrology"
  )
  result <- add_record_keys(pubs)
  expect_match(result$record_key, "^hash:[0-9a-f]{16}$")
})

test_that("hash is deterministic for identical inputs", {
  pubs <- tibble::tibble(
    eid = NA_character_, doi = NA_character_,
    title = "A study", year = "2021",
    authors = list(c("Doe, Jane A.")),
    affiliations = list(character(0L)),
    funders = list(character(0L)), grant_numbers = list(character(0L)),
    journal = "Science"
  )
  expect_equal(add_record_keys(pubs)$record_key, add_record_keys(pubs)$record_key)
})

test_that("record_key is the first column", {
  result <- add_record_keys(make_pubs())
  expect_equal(names(result)[[1L]], "record_key")
})

test_that("nested list columns are flattened to plain character vectors", {
  pubs <- tibble::tibble(
    eid = NA_character_, doi = "10.1/x",
    title = "T", year = "2020",
    authors = list(c("Smith, J.", "Jones, M.")),
    affiliations = list(list(list("Uni A", "Uni B"), list("Uni C"))),
    funders = list(character(0L)), grant_numbers = list(character(0L)),
    journal = "J"
  )
  result <- add_record_keys(pubs)
  expect_true(is.character(unlist(result$affiliations)))
  expect_false(is.list(result$affiliations[[1L]][[1L]]))
})

test_that("non-key columns are not modified", {
  pubs <- make_pubs()
  result <- add_record_keys(pubs)
  expect_equal(result$title,   pubs$title)
  expect_equal(result$doi,     pubs$doi)
  expect_equal(result$journal, pubs$journal)
})
