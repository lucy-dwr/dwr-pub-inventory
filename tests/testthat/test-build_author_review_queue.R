test_that("includes affiliation-side candidates in the queue", {
  pubs <- make_harvest_pubs()
  lookup_path <- write_author_lookup_csv()
  result <- build_author_review_queue(
    pubs,
    decisions_path = tempfile(fileext = ".csv"),
    accepted_path  = tempfile(fileext = ".parquet"),
    lookup_path    = lookup_path
  )
  expect_true("doi:10.1/b" %in% result$record_key)
})

test_that("includes funder+affiliation overlap records in the queue", {
  pubs <- make_harvest_pubs()
  lookup_path <- write_author_lookup_csv()
  result <- build_author_review_queue(
    pubs,
    decisions_path = tempfile(fileext = ".csv"),
    accepted_path  = tempfile(fileext = ".parquet"),
    lookup_path    = lookup_path
  )
  expect_true("eid:004" %in% result$record_key)
})

test_that("excludes funder-only records from the queue", {
  pubs <- make_harvest_pubs()
  lookup_path <- write_author_lookup_csv()
  result <- build_author_review_queue(
    pubs,
    decisions_path = tempfile(fileext = ".csv"),
    accepted_path  = tempfile(fileext = ".parquet"),
    lookup_path    = lookup_path
  )
  # eid:001 and eid:003 are query_source = "funder" only
  expect_false("eid:001" %in% result$record_key)
  expect_false("eid:003" %in% result$record_key)
})

test_that("excludes records already in accepted_publications", {
  pubs          <- make_harvest_pubs()
  accepted_path <- write_accepted_parquet("doi:10.1/b")
  on.exit(unlink(accepted_path))

  lookup_path <- write_author_lookup_csv()
  result <- build_author_review_queue(
    pubs,
    decisions_path = tempfile(fileext = ".csv"),
    accepted_path  = accepted_path,
    lookup_path    = lookup_path
  )
  expect_false("doi:10.1/b" %in% result$record_key)
})

test_that("excludes already-reviewed records", {
  pubs <- make_harvest_pubs()
  decisions <- tibble::tibble(
    record_key = "doi:10.1/b", doi = "10.1/b", decision = "drop"
  )
  decisions_path <- write_decisions_csv(decisions)
  on.exit(unlink(decisions_path))

  lookup_path <- write_author_lookup_csv()
  result <- build_author_review_queue(
    pubs,
    decisions_path = decisions_path,
    accepted_path  = tempfile(fileext = ".parquet"),
    lookup_path    = lookup_path
  )
  expect_false("doi:10.1/b" %in% result$record_key)
})

test_that("queue is sorted by descending caff_score", {
  pubs        <- make_harvest_pubs()
  lookup_path <- write_author_lookup_csv()
  result      <- build_author_review_queue(
    pubs,
    decisions_path = tempfile(fileext = ".csv"),
    accepted_path  = tempfile(fileext = ".parquet"),
    lookup_path    = lookup_path
  )
  if (nrow(result) >= 2L) {
    expect_true(all(diff(result$caff_score) <= 0L))
  }
  succeed()
})
