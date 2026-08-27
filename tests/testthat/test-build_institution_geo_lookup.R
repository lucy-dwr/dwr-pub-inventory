test_that("replaces request-failed rows when geocoding is retried", {
  existing <- data.frame(
    canonical = c("Known University", "Retry Institute"),
    country = c("United States", NA_character_),
    state = c("California", NA_character_),
    status = c("resolved", "request_failed"),
    error = c(NA_character_, "HTTP 404"),
    resolved = c(TRUE, FALSE),
    stringsAsFactors = FALSE
  )
  retried <- data.frame(
    canonical = "Retry Institute",
    country = "Canada",
    state = NA_character_,
    status = "resolved",
    error = NA_character_,
    resolved = TRUE,
    stringsAsFactors = FALSE
  )

  result <- .geo_merge(existing, retried)

  expect_equal(nrow(result), 2L)
  expect_equal(result$status[result$canonical == "Retry Institute"], "resolved")
  expect_equal(result$country[result$canonical == "Retry Institute"], "Canada")
})

test_that("migrates legacy no-country rows to confirmed unknown", {
  path <- tempfile(fileext = ".csv")
  on.exit(unlink(path))
  readr::write_csv(
    data.frame(
      canonical = c("Located Institute", "Ambiguous Institute"),
      country = c("United States", NA_character_),
      state = c("California", NA_character_),
      resolved = c(TRUE, TRUE)
    ),
    path
  )

  result <- .read_existing_geo_lookup(path)

  expect_equal(result$status, c("resolved", "unknown"))
  expect_true(all(result$resolved))
})
