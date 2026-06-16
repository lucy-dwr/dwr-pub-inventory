# Shared helpers for matching Scopus author names against the DWR HR lookup.
# Used by score_author_affiliation(), join_author_division(), and
# shiny/author_review_app.R (which sources this file explicitly).

# Convert a Scopus author name to "FIRST [M] LAST" uppercase.
#
# Handles two formats:
#   "Last, First M."  — comma present, standard Scopus API format
#   "Last I."         — no comma; trailing tokens are 1-2 letter initials
#     e.g. "Riordan D." → "D RIORDAN", "Biales A.D." → "A D BIALES"
normalize_scopus_name <- function(name) {
  if (is.na(name) || !nzchar(trimws(name))) return(NA_character_)
  name <- trimws(name)

  clean <- function(x) {
    x <- gsub("\\.", " ", x)
    x <- gsub("[^A-Za-z ]", "", x)
    toupper(trimws(gsub("\\s+", " ", x)))
  }

  comma_pos <- regexpr(",", name, fixed = TRUE)[[1L]]
  if (comma_pos >= 1L) {
    last_raw  <- substr(name, 1L, comma_pos - 1L)
    given_raw <- substr(name, comma_pos + 1L, nchar(name))
    return(paste(clean(given_raw), clean(last_raw)))
  }

  # No comma: check whether all tokens after the first look like initials
  # (1-2 letters, possibly dotted) — if so, treat as "Last I." format.
  tokens <- strsplit(trimws(name), "\\s+")[[1L]]
  if (length(tokens) >= 2L) {
    is_initial <- function(tok) {
      tok_clean <- gsub("\\.", "", tok)
      nchar(tok_clean) <= 2L && grepl("^[A-Za-z]+$", tok_clean)
    }
    if (all(vapply(tokens[-1L], is_initial, logical(1L)))) {
      last_raw  <- tokens[1L]
      given_raw <- paste(tokens[-1L], collapse = " ")
      return(paste(clean(given_raw), clean(last_raw)))
    }
  }

  clean(name)
}

# First character of the first whitespace-separated token of a normalized name.
.name_first_initial <- function(norm) {
  if (is.na(norm) || !nzchar(norm)) return(NA_character_)
  substr(trimws(norm), 1L, 1L)
}

# Last whitespace-separated token of a normalized name.
.name_last_token <- function(norm) {
  if (is.na(norm) || !nzchar(norm)) return(NA_character_)
  parts <- strsplit(trimws(norm), "\\s+")[[1L]]
  parts[length(parts)]
}

#' Prepare the author division lookup for name matching.
#'
#' Reads `data/author_division_lookup.csv` and adds normalized name fields
#' used by `author_in_lookup()` and `find_author_divisions()`.
#'
#' @param lookup_path Path to the lookup CSV (columns: division, year, name).
#' @return Data frame with original columns plus norm_name, first_initial,
#'   last_name.
prepare_lookup <- function(lookup_path) {
  lookup <- readr::read_csv(
    lookup_path,
    show_col_types = FALSE,
    col_types = readr::cols(.default = readr::col_character())
  )
  # Lookup names are already "FIRST [MIDDLE] LAST" uppercase from the HR export.
  lookup$norm_name <- vapply(lookup$name, function(n) {
    n <- toupper(trimws(n))
    n <- gsub("[^A-Za-z ]", "", n)
    trimws(gsub("\\s+", " ", n))
  }, character(1L))
  lookup$first_initial <- substr(lookup$norm_name, 1L, 1L)
  lookup$last_name <- vapply(
    strsplit(lookup$norm_name, "\\s+"),
    function(x) x[length(x)],
    character(1L)
  )
  lookup
}

#' Check whether a Scopus author name matches any HR lookup entry for a year.
#'
#' Uses a two-tier strategy:
#' 1. Exact last name + exact first initial (handles middle initials by ignoring them).
#' 2. Jaro-Winkler similarity >= 0.92 on the full normalized name (typos / variants).
#'
#' Nicknames where the first initial differs (e.g. Bob vs Robert) are a known
#' gap and will return FALSE.
#'
#' @param scopus_name Author name in Scopus format ("Last, First M.").
#' @param year        Publication year (numeric or character).
#' @param lookup      Pre-processed lookup from `prepare_lookup()`.
#' @return Logical scalar.
author_in_lookup <- function(scopus_name, year, lookup) {
  if (is.na(scopus_name) || !is.data.frame(lookup) || nrow(lookup) == 0L) return(FALSE)
  norm <- normalize_scopus_name(scopus_name)
  if (is.na(norm) || !nzchar(norm)) return(FALSE)

  init <- .name_first_initial(norm)
  last <- .name_last_token(norm)
  years <- as.character(c(as.integer(year) - 1L, as.integer(year), as.integer(year) + 1L))
  candidates <- lookup[lookup$year %in% years, , drop = FALSE]
  if (nrow(candidates) == 0L) return(FALSE)

  # Tier 1
  if (any(candidates$last_name == last & candidates$first_initial == init, na.rm = TRUE))
    return(TRUE)

  # Tier 2
  if (requireNamespace("stringdist", quietly = TRUE)) {
    sims <- stringdist::stringsim(norm, candidates$norm_name, method = "jw")
    if (any(sims >= 0.92, na.rm = TRUE)) return(TRUE)
  }

  FALSE
}

#' Resolve a confirmed DWR author to a single division using priority rules.
#'
#' Applies rules in order:
#'   1 - unique division match in publication year
#'   2 - unique division match in prior year
#'   3 - unique division match in following year
#'   4 - multiple distinct divisions found (needs manual selection)
#'   5 - no match at all (needs manual selection from full vocabulary)
#'
#' @param scopus_name Author name in Scopus format.
#' @param year        Publication year (numeric or character).
#' @param lookup      Pre-processed lookup from `prepare_lookup()` with org
#'   canonicalization already applied.
#' @return Named list: `rule` (integer 1–5), `division` (character, NA if
#'   unresolved), `candidates` (character vector of distinct divisions found).
resolve_author_division <- function(scopus_name, year, lookup) {
  no_match  <- list(rule = 5L, division = NA_character_, candidates = character())
  ambiguous <- function(divs) list(rule = 4L, division = NA_character_, candidates = divs)

  if (is.na(scopus_name) || !is.data.frame(lookup) || nrow(lookup) == 0L) return(no_match)
  norm <- normalize_scopus_name(scopus_name)
  if (is.na(norm) || !nzchar(norm)) return(no_match)

  init <- .name_first_initial(norm)
  last <- .name_last_token(norm)

  match_single_year <- function(yr) {
    cands <- lookup[lookup$year == as.character(yr), , drop = FALSE]
    if (nrow(cands) == 0L) return(character())
    t1 <- cands[cands$last_name == last & cands$first_initial == init, ]
    if (nrow(t1) > 0L) return(unique(t1$division[!is.na(t1$division)]))
    if (requireNamespace("stringdist", quietly = TRUE)) {
      sims <- stringdist::stringsim(norm, cands$norm_name, method = "jw")
      t2 <- cands[!is.na(sims) & sims >= 0.92, ]
      if (nrow(t2) > 0L) return(unique(t2$division[!is.na(t2$division)]))
    }
    character()
  }

  pub_yr     <- as.integer(year)
  year_order <- c(pub_yr, pub_yr - 1L, pub_yr + 1L)
  all_divs   <- character()

  for (rule_num in seq_along(year_order)) {
    divs     <- match_single_year(year_order[rule_num])
    all_divs <- unique(c(all_divs, divs))
    if (length(divs) == 1L)
      return(list(rule = rule_num, division = divs[1L], candidates = divs))
  }

  if (length(all_divs) > 0L) ambiguous(all_divs) else no_match
}

#' Return matched lookup rows for a Scopus author name and year.
#'
#' Applies the same two-tier matching as `author_in_lookup()` but returns
#' all matched rows (not just TRUE/FALSE), so division names can be extracted.
#'
#' @param scopus_name Author name in Scopus format.
#' @param year        Publication year (numeric or character).
#' @param lookup      Pre-processed lookup from `prepare_lookup()`.
#' @return Zero-or-more-row data frame with at least a `division` column.
find_author_divisions <- function(scopus_name, year, lookup) {
  empty <- data.frame(division = character(), norm_name = character(),
                      stringsAsFactors = FALSE)
  if (is.na(scopus_name) || !is.data.frame(lookup) || nrow(lookup) == 0L) return(empty)
  norm <- normalize_scopus_name(scopus_name)
  if (is.na(norm) || !nzchar(norm)) return(empty)

  init <- .name_first_initial(norm)
  last <- .name_last_token(norm)
  years <- as.character(c(as.integer(year) - 1L, as.integer(year), as.integer(year) + 1L))
  candidates <- lookup[lookup$year %in% years, , drop = FALSE]
  if (nrow(candidates) == 0L) return(empty)

  # Tier 1
  tier1 <- candidates[candidates$last_name == last & candidates$first_initial == init,
                      , drop = FALSE]
  if (nrow(tier1) > 0L) return(tier1[, c("division", "norm_name"), drop = FALSE])

  # Tier 2
  if (requireNamespace("stringdist", quietly = TRUE)) {
    sims <- stringdist::stringsim(norm, candidates$norm_name, method = "jw")
    tier2 <- candidates[!is.na(sims) & sims >= 0.92, , drop = FALSE]
    if (nrow(tier2) > 0L) return(tier2[, c("division", "norm_name"), drop = FALSE])
  }

  empty
}
