join_author_division <- function(pubs, lookup_path, org_lookup_path,
                                  decisions_path = "data/author_division_decisions.csv") {
  if (!file.exists(decisions_path)) {
    return(dplyr::mutate(pubs, author_division = NA_character_))
  }

  d <- readr::read_csv(
    decisions_path,
    show_col_types = FALSE,
    col_types = readr::cols(.default = readr::col_character())
  )

  # Confirmed DWR authors with a resolved division
  dwr <- d[!is.na(d$decision) & d$decision == "dwr" &
            !is.na(d$division)  & nzchar(d$division), ]

  author_divisions <- vapply(seq_len(nrow(pubs)), function(i) {
    key  <- pubs$record_key[i]
    rows <- dwr[dwr$record_key == key, ]
    if (nrow(rows) == 0L) return(NA_character_)
    divs <- unique(rows$division[!is.na(rows$division) & nzchar(rows$division)])
    if (length(divs) == 0L) return(NA_character_)
    paste(divs, collapse = "; ")
  }, character(1L))

  dplyr::mutate(pubs, author_division = author_divisions)
}
