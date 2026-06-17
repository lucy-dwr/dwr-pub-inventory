test_that("drops records whose record_key is marked 'drop'", {
  pubs <- tibble::tibble(
    record_key = c("eid:A", "eid:B", "eid:C"),
    doi        = c("10.1/a", "10.1/b", "10.1/c")
  )
  decisions <- tibble::tibble(
    record_key = c("eid:A", "eid:B"),
    doi        = c("10.1/a", "10.1/b"),
    decision   = c("drop", "keep")
  )
  path <- write_decisions_csv(decisions)
  on.exit(unlink(path))

  result <- apply_review_decisions(pubs, path)
  expect_false("eid:A" %in% result$record_key)
  expect_true("eid:B"  %in% result$record_key)
  expect_true("eid:C"  %in% result$record_key)
})

test_that("retains records marked 'keep', 'unsure', or unreviewed", {
  pubs <- tibble::tibble(
    record_key = c("eid:A", "eid:B", "eid:C"),
    doi        = c("10.1/a", "10.1/b", "10.1/c")
  )
  decisions <- tibble::tibble(
    record_key = c("eid:A", "eid:B"),
    doi        = c("10.1/a", "10.1/b"),
    decision   = c("keep", "unsure")
  )
  path <- write_decisions_csv(decisions)
  on.exit(unlink(path))

  result <- apply_review_decisions(pubs, path)
  expect_equal(nrow(result), 3L)
})

test_that("falls back to DOI matching when record_key column is absent", {
  pubs <- tibble::tibble(doi = c("10.1/a", "10.1/b", "10.1/c"))
  decisions <- tibble::tibble(doi = c("10.1/a"), decision = c("drop"))
  path <- write_decisions_csv(decisions)
  on.exit(unlink(path))

  result <- apply_review_decisions(pubs, path)
  expect_false("10.1/a" %in% result$doi)
  expect_true("10.1/b"  %in% result$doi)
})

test_that("returns pubs unchanged when decisions file does not exist", {
  pubs <- make_pubs()
  result <- apply_review_decisions(pubs, tempfile(fileext = ".csv"))
  expect_equal(nrow(result), nrow(pubs))
})

test_that("ignores rows where decision is NA", {
  pubs <- tibble::tibble(
    record_key = c("eid:A", "eid:B"),
    doi        = c("10.1/a", "10.1/b")
  )
  decisions <- tibble::tibble(
    record_key = c("eid:A"),
    doi        = c("10.1/a"),
    decision   = NA_character_
  )
  path <- write_decisions_csv(decisions)
  on.exit(unlink(path))

  result <- apply_review_decisions(pubs, path)
  expect_equal(nrow(result), 2L)
})

test_that("handles an empty decisions file gracefully", {
  pubs <- make_pubs()
  empty_decisions <- tibble::tibble(
    record_key = character(), doi = character(), decision = character()
  )
  path <- write_decisions_csv(empty_decisions)
  on.exit(unlink(path))

  result <- apply_review_decisions(pubs, path)
  expect_equal(nrow(result), nrow(pubs))
})
