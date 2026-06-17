# Helpers — flat affiliations vectors (post-add_record_keys structure)

make_flagging_pubs <- function() {
  tibble::tibble(
    query_source = c("funder", "affiliation", "funder; affiliation", "funder"),
    affiliations = list(
      # pub 1: DWR is the only affiliation — is_lead AND is_sole
      c("California Department of Water Resources, Sacramento, CA"),
      # pub 2: no DWR affiliation at all
      c("University of London, UK", "Peking University, China"),
      # pub 3: DWR leads but not sole (mixed authorship)
      c("California Department of Water Resources", "MIT, Cambridge, MA"),
      # pub 4: all affiliations are DWR — sole author scenario
      c("California Department of Water Resources", "California Department of Water Resources")
    )
  )
}

test_that("is_funder is TRUE when query_source contains 'funder'", {
  result <- flag_dwr_contributions(make_flagging_pubs())
  expect_equal(result$is_funder, c(TRUE, FALSE, TRUE, TRUE))
})

test_that("is_author is TRUE when query_source contains 'affiliation'", {
  result <- flag_dwr_contributions(make_flagging_pubs())
  # pub 2: affiliation-only query; pub 3: funder; affiliation overlap
  expect_true(result$is_author[[2L]])
  expect_true(result$is_author[[3L]])
})

test_that("is_author is TRUE via DWR affiliation even with funder-only query_source", {
  pubs <- tibble::tibble(
    query_source = "funder",
    affiliations = list(c("California Department of Water Resources, Sacramento"))
  )
  result <- flag_dwr_contributions(pubs)
  expect_true(result$is_author)
})

test_that("is_lead_author is TRUE when first affiliation string contains DWR", {
  result <- flag_dwr_contributions(make_flagging_pubs())
  expect_equal(result$is_lead_author, c(TRUE, FALSE, TRUE, TRUE))
})

test_that("is_sole_author is TRUE only when all affiliations contain DWR", {
  result <- flag_dwr_contributions(make_flagging_pubs())
  # pub 3 has MIT → not sole; pub 4 has only DWR entries → sole
  expect_equal(result$is_sole_author, c(TRUE, FALSE, FALSE, TRUE))
})

test_that("empty affiliations produce FALSE for both lead and sole", {
  pubs <- tibble::tibble(
    query_source = "funder",
    affiliations = list(character(0L))
  )
  result <- flag_dwr_contributions(pubs)
  expect_false(result$is_lead_author)
  expect_false(result$is_sole_author)
})

test_that("DWR pattern match is case-insensitive", {
  pubs <- tibble::tibble(
    query_source = "funder",
    affiliations = list(c("california department of water resources, sacramento"))
  )
  result <- flag_dwr_contributions(pubs)
  expect_true(result$is_lead_author)
})
