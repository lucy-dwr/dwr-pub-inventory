test_that("records output-token reservations in a rolling-window ledger", {
  path <- tempfile(fileext = ".csv")
  on.exit(unlink(path))
  config <- list(
    output_tokens_per_minute = 2000,
    safety_fraction = 0.8,
    state_path = path
  )

  expect_no_error(.llm_reserve_output_tokens(600, config))
  expect_no_error(.llm_reserve_output_tokens(600, config))

  ledger <- readr::read_csv(path, show_col_types = FALSE)
  expect_equal(nrow(ledger), 2L)
  expect_equal(sum(ledger$tokens), 1200)
})

test_that("rejects a reservation that cannot fit in the safe budget", {
  config <- list(
    output_tokens_per_minute = 2000,
    safety_fraction = 0.8,
    state_path = tempfile(fileext = ".csv")
  )

  expect_error(.llm_reserve_output_tokens(1601, config), "Invalid LLM rate-limit")
})
