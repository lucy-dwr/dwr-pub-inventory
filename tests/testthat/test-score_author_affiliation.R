make_caff_pub <- function(title = "Hydrology study",
                          abstract = "Water flow analysis",
                          year = "2023",
                          authors = list(c("Smith, John A.")),
                          affiliations = list(c("California Department of Water Resources, Sacramento, CA"))) {
  tibble::tibble(
    title        = title,
    abstract     = abstract,
    year         = year,
    authors      = authors,
    affiliations = affiliations
  )
}

test_that("adds 5 points when no author is found in the HR lookup", {
  # Lookup contains a different person — no match for "Unknown, Author X."
  lookup_path <- write_author_lookup_csv(tibble::tibble(
    division = "D", year = "2023", name = "JANE B DOE"
  ))
  pubs <- make_caff_pub(
    authors      = list(c("Unknown, Author X.")),
    affiliations = list(c("California Department of Water Resources, Sacramento, CA"))
  )
  result <- score_author_affiliation(pubs, lookup_path)
  # 5 (not in lookup) + 0 (standard DWR string) + 0 (no unrelated domain) + 0 (CA present) = 5
  expect_equal(result$caff_score, 5L)
})

test_that("adds 0 points from signal 1 when author IS in the HR lookup", {
  lookup_path <- write_author_lookup_csv(tibble::tibble(
    division = "D", year = "2023", name = "JOHN A SMITH"
  ))
  pubs <- make_caff_pub(authors = list(c("Smith, John A.")))
  result <- score_author_affiliation(pubs, lookup_path)
  # 0 (in lookup) + 0 (standard DWR) + 0 (no unrelated domain) + 0 (CA present) = 0
  expect_equal(result$caff_score, 0L)
})

test_that("adds 3 points for a non-standard capitalisation of the DWR affiliation string", {
  # "california department of water resources" (all lowercase) matches the pattern
  # case-insensitively but fails the fixed case-sensitive check → signal 2 fires
  lookup_path <- write_author_lookup_csv(tibble::tibble(
    division = "D", year = "2023", name = "JOHN A SMITH"
  ))
  standard_pub <- make_caff_pub(
    authors      = list(c("Smith, John A.")),
    affiliations = list(c("California Department of Water Resources, Sacramento"))
  )
  variant_pub <- make_caff_pub(
    authors      = list(c("Smith, John A.")),
    affiliations = list(c("california department of water resources, sacramento"))
  )
  delta <- score_author_affiliation(variant_pub, lookup_path)$caff_score -
           score_author_affiliation(standard_pub, lookup_path)$caff_score
  expect_equal(delta, 3L)
})

test_that("adds 2 points for unrelated domain keywords in title/abstract", {
  lookup_path <- write_author_lookup_csv(tibble::tibble(
    division = "D", year = "2023", name = "JOHN A SMITH"
  ))
  no_domain <- make_caff_pub(authors = list(c("Smith, John A.")))
  domain_pub <- make_caff_pub(
    title   = "Cancer immunotherapy clinical trials",
    authors = list(c("Smith, John A.")),
    affiliations = list(c("California Department of Water Resources, Sacramento, CA"))
  )
  delta <- score_author_affiliation(domain_pub, lookup_path)$caff_score -
           score_author_affiliation(no_domain, lookup_path)$caff_score
  expect_equal(delta, 2L)
})

test_that("adds 2 points when there is no California geographic mention", {
  lookup_path <- write_author_lookup_csv(tibble::tibble(
    division = "D", year = "2023", name = "JOHN A SMITH"
  ))
  with_ca <- make_caff_pub(
    title        = "Water resources in California",
    authors      = list(c("Smith, John A.")),
    affiliations = list(c("University of Oregon, Eugene, OR"))
  )
  no_ca <- make_caff_pub(
    title        = "Water resources in Oregon",
    authors      = list(c("Smith, John A.")),
    affiliations = list(c("University of Oregon, Eugene, OR"))
  )
  delta <- score_author_affiliation(no_ca, lookup_path)$caff_score -
           score_author_affiliation(with_ca, lookup_path)$caff_score
  expect_equal(delta, 2L)
})

test_that("achieves high combined score when multiple signals fire", {
  # Signals: unknown author (+5), cancer domain (+2), no CA mention (+2) = 9
  lookup_path <- write_author_lookup_csv(tibble::tibble(
    division = "D", year = "2000", name = "NOBODY HERE"
  ))
  pubs <- make_caff_pub(
    title        = "Cancer immunotherapy clinical trials",
    abstract     = "Tumor response to pharmaceutical treatment",
    year         = "2023",
    authors      = list(c("Smith, John A.")),
    affiliations = list(c("University of Oregon, Eugene, OR"))
  )
  expect_equal(score_author_affiliation(pubs, lookup_path)$caff_score, 9L)
})

test_that("runs without error when lookup file does not exist (signal 1 skipped)", {
  pubs <- make_caff_pub()
  expect_no_error(
    score_author_affiliation(pubs, lookup_path = tempfile(fileext = ".csv"))
  )
})

test_that("caff_score column is integer type", {
  lookup_path <- write_author_lookup_csv()
  result <- score_author_affiliation(make_caff_pub(), lookup_path)
  expect_type(result$caff_score, "integer")
})
