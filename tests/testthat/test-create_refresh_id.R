# ── create_refresh_id() ───────────────────────────────────────────────────────

test_that("returns config value when refresh id is set", {
  cfg <- list(refresh = list(id = "2026-06-01"))
  expect_equal(create_refresh_id(cfg), "2026-06-01")
})

test_that("returns today's date when config id is empty string", {
  cfg <- list(refresh = list(id = ""))
  expect_equal(create_refresh_id(cfg), format(Sys.Date(), "%Y-%m-%d"))
})

test_that("returns today's date when config id is whitespace only", {
  cfg <- list(refresh = list(id = "   "))
  expect_equal(create_refresh_id(cfg), format(Sys.Date(), "%Y-%m-%d"))
})

test_that("returns today's date when config is NULL", {
  expect_equal(create_refresh_id(NULL), format(Sys.Date(), "%Y-%m-%d"))
})

# ── init_refresh_log() ────────────────────────────────────────────────────────

test_that("creates a new log file with correct columns and one data row", {
  log_path <- tempfile(fileext = ".csv")
  on.exit(unlink(log_path))

  init_refresh_log("2026-06-01", log_path = log_path)

  expect_true(file.exists(log_path))
  log <- readr::read_csv(log_path, col_types = readr::cols(.default = readr::col_character()),
                         show_col_types = FALSE)
  expect_true("refresh_id" %in% names(log))
  expect_true("started_at" %in% names(log))
  expect_equal(nrow(log), 1L)
  expect_equal(log$refresh_id[[1L]], "2026-06-01")
})

test_that("appends a new row to an existing log", {
  log_path <- tempfile(fileext = ".csv")
  on.exit(unlink(log_path))

  init_refresh_log("2026-05-01", log_path = log_path)
  init_refresh_log("2026-06-01", log_path = log_path)

  log <- readr::read_csv(log_path, col_types = readr::cols(.default = readr::col_character()),
                         show_col_types = FALSE)
  expect_equal(nrow(log), 2L)
})

test_that("is a no-op when refresh_id already exists in log", {
  log_path <- tempfile(fileext = ".csv")
  on.exit(unlink(log_path))

  init_refresh_log("2026-06-01", log_path = log_path)
  init_refresh_log("2026-06-01", log_path = log_path)  # duplicate

  log <- readr::read_csv(log_path, col_types = readr::cols(.default = readr::col_character()),
                         show_col_types = FALSE)
  expect_equal(nrow(dplyr::filter(log, refresh_id == "2026-06-01")), 1L)
})

test_that("started_at is populated on the new row", {
  log_path <- tempfile(fileext = ".csv")
  on.exit(unlink(log_path))

  init_refresh_log("2026-06-01", log_path = log_path)
  log <- readr::read_csv(log_path, col_types = readr::cols(.default = readr::col_character()),
                         show_col_types = FALSE)
  expect_false(is.na(log$started_at[[1L]]))
})

# ── complete_refresh_log() ────────────────────────────────────────────────────

test_that("writes count fields and completed_at to the matching row", {
  log_path <- tempfile(fileext = ".csv")
  on.exit(unlink(log_path))

  init_refresh_log("2026-06-01", log_path = log_path)
  complete_refresh_log("2026-06-01", log_path = log_path, n_accepted = 42L)

  log <- readr::read_csv(log_path, col_types = readr::cols(.default = readr::col_character()),
                         show_col_types = FALSE)
  row <- dplyr::filter(log, refresh_id == "2026-06-01")
  expect_equal(row$n_accepted[[1L]], "42")
  expect_false(is.na(row$completed_at[[1L]]))
})

test_that("warns when refresh_id is not found in log", {
  log_path <- tempfile(fileext = ".csv")
  on.exit(unlink(log_path))

  init_refresh_log("2026-06-01", log_path = log_path)
  expect_warning(
    complete_refresh_log("9999-99-99", log_path = log_path),
    regexp = "not found"
  )
})

test_that("warns and returns NULL invisibly when log file does not exist", {
  expect_warning(
    result <- complete_refresh_log("2026-06-01", log_path = tempfile(fileext = ".csv")),
    regexp = "no log"
  )
  expect_null(result)
})
