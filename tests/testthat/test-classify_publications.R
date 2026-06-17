source(file.path(.proj_root, "R", "classify_publications.R"))

# ── env_or_null() ─────────────────────────────────────────────────────────────

test_that("env_or_null returns the value when the variable is set", {
  withr::with_envvar(c(TEST_VAR = "hello"), {
    expect_equal(env_or_null("TEST_VAR"), "hello")
  })
})

test_that("env_or_null returns NULL when the variable is unset", {
  withr::with_envvar(c(TEST_VAR = NA), {
    expect_null(env_or_null("TEST_VAR"))
  })
})

test_that("env_or_null returns NULL when the variable is empty string", {
  withr::with_envvar(c(TEST_VAR = ""), {
    expect_null(env_or_null("TEST_VAR"))
  })
})

# ── %||% ─────────────────────────────────────────────────────────────────────

test_that("%||% returns right when left is NULL", {
  expect_equal(NULL %||% "default", "default")
})

test_that("%||% returns left when left is non-NULL", {
  expect_equal("value" %||% "default", "value")
})

test_that("%||% returns NULL when both sides are NULL", {
  expect_null(NULL %||% NULL)
})
