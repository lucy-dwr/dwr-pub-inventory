test_that("only funder-side records appear in the queue", {
  pubs   <- make_harvest_pubs()
  result <- build_funder_review_queue(
    pubs,
    decisions_path = tempfile(fileext = ".csv"),
    accepted_path  = tempfile(fileext = ".parquet")
  )
  # doi:10.1/b is affiliation-only — must not appear
  expect_false("doi:10.1/b" %in% result$record_key)
  # eid:001, eid:003, eid:004 have "funder" in query_source
  expect_true("eid:001" %in% result$record_key)
  expect_true("eid:003" %in% result$record_key)
  expect_true("eid:004" %in% result$record_key)
})

test_that("excludes records already present in accepted_publications", {
  pubs          <- make_harvest_pubs()
  accepted_path <- write_accepted_parquet(c("eid:001"))
  on.exit(unlink(accepted_path))

  result <- build_funder_review_queue(
    pubs,
    decisions_path = tempfile(fileext = ".csv"),
    accepted_path  = accepted_path
  )
  expect_false("eid:001" %in% result$record_key)
})

test_that("excludes records with any prior review decision", {
  pubs <- make_harvest_pubs()
  decisions <- tibble::tibble(
    record_key = "eid:001", doi = "10.1/a", decision = "keep"
  )
  decisions_path <- write_decisions_csv(decisions)
  on.exit(unlink(decisions_path))

  result <- build_funder_review_queue(
    pubs,
    decisions_path = decisions_path,
    accepted_path  = tempfile(fileext = ".parquet")
  )
  expect_false("eid:001" %in% result$record_key)
})

test_that("excludes 'unsure' decisions by default", {
  pubs <- make_harvest_pubs()
  decisions <- tibble::tibble(
    record_key = "eid:001", doi = "10.1/a", decision = "unsure"
  )
  decisions_path <- write_decisions_csv(decisions)
  on.exit(unlink(decisions_path))

  result <- build_funder_review_queue(
    pubs,
    decisions_path = decisions_path,
    accepted_path  = tempfile(fileext = ".parquet")
  )
  expect_false("eid:001" %in% result$record_key)
})

test_that("re-queues 'unsure' records when include_unsure = TRUE", {
  pubs <- make_harvest_pubs()
  decisions <- tibble::tibble(
    record_key = "eid:001", doi = "10.1/a", decision = "unsure"
  )
  decisions_path <- write_decisions_csv(decisions)
  on.exit(unlink(decisions_path))

  result <- build_funder_review_queue(
    pubs,
    decisions_path = decisions_path,
    accepted_path  = tempfile(fileext = ".parquet"),
    include_unsure = TRUE
  )
  expect_true("eid:001" %in% result$record_key)
})

test_that("queue is sorted by descending cdwr_score", {
  pubs   <- make_harvest_pubs()
  result <- build_funder_review_queue(
    pubs,
    decisions_path = tempfile(fileext = ".csv"),
    accepted_path  = tempfile(fileext = ".parquet")
  )
  expect_true(nrow(result) >= 2L)
  expect_true(all(diff(result$cdwr_score) <= 0L))
})

test_that("returns all funder candidates when no decisions or accepted file exists", {
  pubs   <- make_harvest_pubs()
  result <- build_funder_review_queue(
    pubs,
    decisions_path = tempfile(fileext = ".csv"),
    accepted_path  = tempfile(fileext = ".parquet")
  )
  funder_count <- sum(grepl("funder", pubs$query_source, fixed = TRUE))
  expect_equal(nrow(result), funder_count)
})
