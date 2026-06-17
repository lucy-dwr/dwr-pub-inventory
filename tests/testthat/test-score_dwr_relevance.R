make_score_pub <- function(title = "", abstract = NA_character_,
                           affiliations = list(character(0L)),
                           funders = list(character(0L)),
                           grant_numbers = list(character(0L))) {
  tibble::tibble(
    title         = title,
    abstract      = abstract,
    affiliations  = affiliations,
    funders       = funders,
    grant_numbers = grant_numbers
  )
}

test_that("cdwr_score is 0 for a clear California water resources publication", {
  pubs <- make_score_pub(
    title        = "Groundwater management in California",
    abstract     = "Sacramento River delta water quality monitoring",
    affiliations = list(c("California Department of Water Resources, Sacramento, CA")),
    funders      = list(c("California DWR"))
  )
  expect_equal(score_dwr_relevance(pubs)$cdwr_score, 0L)
})

test_that("adds 4 points when no California geographic mention exists", {
  with_ca <- make_score_pub(
    title        = "River flow in California",
    abstract     = "Groundwater study",
    affiliations = list(c("University of Oregon, Eugene, OR"))
  )
  without_ca <- make_score_pub(
    title        = "River flow in the Pacific Northwest",
    abstract     = "Groundwater study",
    affiliations = list(c("University of Oregon, Eugene, OR"))
  )
  delta <- score_dwr_relevance(without_ca)$cdwr_score -
           score_dwr_relevance(with_ca)$cdwr_score
  expect_equal(delta, 4L)
})

test_that("adds 4 points when no water-related topic is detected", {
  with_water <- make_score_pub(
    title        = "Biodiversity in California coastal wetlands",
    affiliations = list(c("UC Berkeley, Berkeley, CA"))
  )
  without_water <- make_score_pub(
    title        = "Biodiversity in California coastal ecosystems",
    affiliations = list(c("UC Berkeley, Berkeley, CA"))
  )
  delta <- score_dwr_relevance(without_water)$cdwr_score -
           score_dwr_relevance(with_water)$cdwr_score
  expect_equal(delta, 4L)
})

test_that("adds 3 points when non-water domain keywords are present", {
  no_domain <- make_score_pub(
    title        = "Soil nitrogen in the Pacific Northwest",
    affiliations = list(c("University of Washington, Seattle, WA"))
  )
  with_domain <- make_score_pub(
    title        = "Cancer drug resistance in oncology patients",
    affiliations = list(c("University of Washington, Seattle, WA"))
  )
  delta <- score_dwr_relevance(with_domain)$cdwr_score -
           score_dwr_relevance(no_domain)$cdwr_score
  expect_equal(delta, 3L)
})

test_that("adds 2 points when no US institution is detected in affiliations", {
  us_affil <- make_score_pub(
    title        = "Soil carbon sequestration",
    affiliations = list(c("University of Colorado, Boulder, Colorado"))
  )
  non_us_affil <- make_score_pub(
    title        = "Soil carbon sequestration",
    affiliations = list(c("Sorbonne Université, Paris, France"))
  )
  delta <- score_dwr_relevance(non_us_affil)$cdwr_score -
           score_dwr_relevance(us_affil)$cdwr_score
  expect_equal(delta, 2L)
})

test_that("reaches score of 13 when all four penalties fire", {
  # No CA, no water, non-water domain (quantum computing), non-US affiliation
  pubs <- make_score_pub(
    title        = "Quantum computing algorithms for drug discovery",
    abstract     = "Qubit decoherence and pharmaceutical protein folding",
    affiliations = list(c("École Polytechnique, Palaiseau, France"))
  )
  expect_equal(score_dwr_relevance(pubs)$cdwr_score, 13L)
})

test_that("cdwr_score column is integer type", {
  result <- score_dwr_relevance(make_pubs())
  expect_type(result$cdwr_score, "integer")
})
