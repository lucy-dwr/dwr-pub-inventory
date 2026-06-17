make_accepted_pubs <- function(record_keys = c("eid:001", "doi:10.1/a")) {
  tibble::tibble(
    record_key = record_keys,
    title      = paste("Title", seq_along(record_keys)),
    doi        = paste0("10.1/", seq_along(record_keys)),
    year       = "2023"
  )
}

test_that("creates a new parquet file with correct row count on first run", {
  path <- tempfile(fileext = ".parquet")
  on.exit(unlink(path))

  append_accepted_publications(make_accepted_pubs(), "2026-06-01", accepted_path = path)

  expect_true(file.exists(path))
  result <- arrow::read_parquet(path)
  expect_equal(nrow(result), 2L)
})

test_that("adds provenance columns on first run", {
  path <- tempfile(fileext = ".parquet")
  on.exit(unlink(path))

  append_accepted_publications(make_accepted_pubs(), "2026-06-01", accepted_path = path)
  result <- arrow::read_parquet(path)

  expect_true("accepted_at"           %in% names(result))
  expect_true("accepted_refresh_id"   %in% names(result))
  expect_true("record_status"         %in% names(result))
  expect_true("first_seen_at"         %in% names(result))
  expect_true("last_seen_at"          %in% names(result))
  expect_equal(result$record_status[[1L]], "active")
})

test_that("is idempotent: re-running with same records does not grow the table", {
  path <- tempfile(fileext = ".parquet")
  on.exit(unlink(path))

  pubs <- make_accepted_pubs()
  append_accepted_publications(pubs, "2026-06-01", accepted_path = path)
  append_accepted_publications(pubs, "2026-06-02", accepted_path = path)

  result <- arrow::read_parquet(path)
  expect_equal(nrow(result), 2L)
})

test_that("appends only genuinely new records on subsequent runs", {
  path <- tempfile(fileext = ".parquet")
  on.exit(unlink(path))

  pubs_first  <- make_accepted_pubs(c("eid:001", "doi:10.1/a"))
  pubs_second <- make_accepted_pubs(c("eid:001", "eid:002"))  # eid:001 already exists

  append_accepted_publications(pubs_first,  "2026-06-01", accepted_path = path)
  append_accepted_publications(pubs_second, "2026-06-02", accepted_path = path)

  result <- arrow::read_parquet(path)
  expect_equal(nrow(result), 3L)  # eid:001, doi:10.1/a, eid:002
})

test_that("column sets are aligned when new records have extra columns", {
  path <- tempfile(fileext = ".parquet")
  on.exit(unlink(path))

  pubs_first  <- make_accepted_pubs("eid:001")
  pubs_second <- dplyr::mutate(make_accepted_pubs("eid:002"), extra_col = "new")

  append_accepted_publications(pubs_first,  "2026-06-01", accepted_path = path)
  expect_no_error(
    append_accepted_publications(pubs_second, "2026-06-02", accepted_path = path)
  )
  result <- arrow::read_parquet(path)
  expect_equal(nrow(result), 2L)
  expect_true("extra_col" %in% names(result))
})

test_that("returns the accepted_path file path", {
  path <- tempfile(fileext = ".parquet")
  on.exit(unlink(path))

  returned <- append_accepted_publications(make_accepted_pubs(), "2026-06-01", accepted_path = path)
  expect_equal(returned, path)
})

test_that("empty pubs tibble creates a file with only provenance columns", {
  path <- tempfile(fileext = ".parquet")
  on.exit(unlink(path))

  empty_pubs <- make_accepted_pubs()[0L, ]  # zero rows, same schema
  append_accepted_publications(empty_pubs, "2026-06-01", accepted_path = path)

  result <- arrow::read_parquet(path)
  expect_equal(nrow(result), 0L)
  expect_true("record_status" %in% names(result))
})
