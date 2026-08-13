# SWP leadership meeting figures -----------------------------------------------
#
# Run this file from the repository root:
# source("figures/R/swp_leadership_mtg_figs.R")
#
# Finished figures are written to figures/output/, which is intentionally
# ignored by Git because its contents are generated from this script.

library(arrow)
library(dplyr)
library(ggplot2)

source("figures/R/palette.R")

output_dir <- "figures/output"
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

# Match the dashboard's contribution assignment and stacking order. A paper is
# assigned to the "highest ranked" contribution category that applies to it.
contribution_levels <- c("Funder", "Co-Author", "Lead Author", "Sole Author")

# ── Figure 1: articles over time -----------------------------------------------
publications <- arrow::read_parquet("data/generated/dwr_publications.parquet")
publications <- publications |>
  mutate(
    contribution_type = case_when(
      is_sole_author ~ "Sole Author",
      is_lead_author ~ "Lead Author",
      is_author ~ "Co-Author",
      is_funder ~ "Funder",
      TRUE ~ NA_character_
    )
  )

years_present <- sort(unique(publications$year[!is.na(publications$year)]))
count_grid <- expand.grid(
  year = years_present,
  contribution_type = contribution_levels,
  KEEP.OUT.ATTRS = FALSE,
  stringsAsFactors = FALSE
)

article_counts <- publications |>
  filter(!is.na(year), !is.na(contribution_type)) |>
  count(year, contribution_type, name = "articles") |>
  right_join(count_grid, by = c("year", "contribution_type")) |>
  mutate(
    articles = coalesce(articles, 0L),
    contribution_type = factor(contribution_type, levels = contribution_levels)
  )

annual_totals <- publications |>
  filter(!is.na(year)) |>
  count(year, name = "articles") |>
  mutate(label_y = articles + if_else(year %% 2L == 0L, 4, 1))

x_breaks <- seq(
  ceiling(min(years_present) / 5) * 5,
  floor(max(years_present) / 5) * 5,
  by = 5
)
if (x_breaks[1L] - min(years_present) >= 3L)
  x_breaks <- c(min(years_present), x_breaks)
y_max <- max(annual_totals$label_y) * 1.12

articles_over_time <- ggplot(
  article_counts,
  aes(x = year, y = articles, fill = contribution_type)
) +
  geom_col(width = 0.76, color = "white", linewidth = 0.35) +
  geom_text(
    data = annual_totals,
    aes(x = year, y = label_y, label = articles),
    inherit.aes = FALSE,
    family = "Arial",
    color = dwr_colors[["navy"]],
    fontface = "bold",
    size = 3.3,
    vjust = -0.55
  ) +
  scale_fill_manual(values = dwr_contribution_colors, drop = FALSE) +
  scale_x_continuous(breaks = x_breaks, labels = x_breaks) +
  scale_y_continuous(limits = c(0, y_max), expand = expansion(mult = c(0, 0))) +
  labs(
    title = "Articles over time",
    subtitle = "By DWR contribution type",
    x = NULL,
    y = "Articles",
    fill = NULL
  ) +
  guides(fill = guide_legend(nrow = 1, byrow = TRUE)) +
  theme_minimal(base_family = "Arial", base_size = 18) +
  theme(
    plot.background = element_rect(fill = "white", color = NA),
    panel.background = element_rect(fill = "white", color = NA),
    panel.grid.major.x = element_blank(),
    panel.grid.minor.x = element_blank(),
    panel.grid.major.y = element_line(color = "#dfe5ea", linewidth = 0.35),
    panel.grid.minor.y = element_line(color = "#eef1f5", linewidth = 0.25),
    axis.text = element_text(color = dwr_colors[["navy"]]),
    axis.title.y = element_text(color = dwr_colors[["navy"]], margin = margin(r = 12)),
    plot.title = element_text(color = dwr_colors[["navy"]], face = "bold", size = 26),
    plot.subtitle = element_text(color = dwr_colors[["navy_light"]], size = 15, margin = margin(b = 14)),
    legend.position = "bottom",
    legend.text = element_text(color = dwr_colors[["navy"]], size = 13),
    legend.key.width = grid::unit(1.3, "cm"),
    plot.margin = margin(20, 34, 18, 24)
  )

ggsave(
  filename = file.path(output_dir, "articles-over-time-by-contribution.png"),
  plot = articles_over_time,
  width = 13.333,
  height = 7.5,
  units = "in",
  dpi = 300,
  bg = "white"
)

# ── Figure 2: SWP-associated articles by scientific field ---------------------
# A publication is included when a State Water Project division appears in its
# author or funding division assignment. Fields with fewer than five articles
# are combined so the slide remains readable.
swp_publications <- publications |>
  filter(
    year >= 2020L,
    year <= 2026L,
    coalesce(grepl("(^|;)\\s*SWP", author_division), FALSE) |
      coalesce(grepl("(^|;)\\s*SWP", funding_division), FALSE),
    !is.na(pc_field),
    !is.na(contribution_type)
  )

field_totals <- swp_publications |>
  count(pc_field, name = "articles")

fields_to_show <- field_totals |>
  filter(articles >= 5L) |>
  pull(pc_field)

swp_publications <- swp_publications |>
  mutate(
    scientific_field = if_else(
      pc_field %in% fields_to_show,
      stringr::str_replace_all(stringr::str_to_title(pc_field), "\\bDna\\b", "DNA"),
      "Other scientific fields (4 or fewer articles)"
    )
  )

field_totals <- swp_publications |>
  count(scientific_field, name = "articles") |>
  arrange(articles)

field_counts <- swp_publications |>
  count(scientific_field, contribution_type, name = "articles") |>
  mutate(
    scientific_field = factor(scientific_field, levels = field_totals$scientific_field),
    contribution_type = factor(contribution_type, levels = contribution_levels)
  )

field_totals <- field_totals |>
  mutate(scientific_field = factor(scientific_field, levels = scientific_field))

swp_fields_by_contribution <- ggplot(
  field_counts,
  aes(x = scientific_field, y = articles, fill = contribution_type)
) +
  geom_col(width = 0.72, color = "white", linewidth = 0.35) +
  geom_text(
    data = field_totals,
    aes(x = scientific_field, y = articles, label = articles),
    inherit.aes = FALSE,
    family = "Arial",
    color = dwr_colors[["navy"]],
    fontface = "bold",
    size = 3.5,
    hjust = -0.25
  ) +
  coord_flip(clip = "off") +
  scale_fill_manual(values = dwr_contribution_colors, drop = FALSE) +
  scale_y_continuous(
    limits = c(0, max(field_totals$articles) * 1.1),
    breaks = seq(0, ceiling(max(field_totals$articles) / 10) * 10, by = 10),
    expand = expansion(mult = c(0, 0))
  ) +
  labs(
    title = "SWP-associated articles by scientific field",
    subtitle = "2020–2026 publications; colored by DWR contribution type",
    x = NULL,
    y = "Articles",
    fill = NULL
  ) +
  guides(fill = guide_legend(nrow = 1, byrow = TRUE)) +
  theme_minimal(base_family = "Arial", base_size = 16) +
  theme(
    plot.background = element_rect(fill = "white", color = NA),
    panel.background = element_rect(fill = "white", color = NA),
    panel.grid.major.y = element_blank(),
    panel.grid.minor.y = element_blank(),
    panel.grid.major.x = element_line(color = "#dfe5ea", linewidth = 0.35),
    panel.grid.minor.x = element_line(color = "#eef1f5", linewidth = 0.25),
    axis.text = element_text(color = dwr_colors[["navy"]]),
    axis.text.y = element_text(size = 12),
    axis.title.x = element_text(color = dwr_colors[["navy"]], margin = margin(t = 10)),
    plot.title = element_text(color = dwr_colors[["navy"]], face = "bold", size = 24),
    plot.subtitle = element_text(color = dwr_colors[["navy_light"]], size = 14, margin = margin(b = 12)),
    legend.position = "bottom",
    legend.text = element_text(color = dwr_colors[["navy"]], size = 12),
    legend.key.width = grid::unit(1.2, "cm"),
    plot.margin = margin(20, 44, 18, 16)
  )

ggsave(
  filename = file.path(output_dir, "swp-fields-by-contribution-2020-2026.png"),
  plot = swp_fields_by_contribution,
  width = 13.333,
  height = 7.5,
  units = "in",
  dpi = 300,
  bg = "white"
)

# ── Figure 3: SWP research at a glance ----------------------------------------
# External institutions are unique non-DWR affiliations on SWP-associated
# publications. An institution counts at most once per publication.
swp_headline_publications <- publications |>
  filter(
    year >= 2020L,
    year <= 2026L,
    coalesce(grepl("(^|;)\\s*SWP", author_division), FALSE) |
      coalesce(grepl("(^|;)\\s*SWP", funding_division), FALSE)
  )

partner_affiliations <- lapply(swp_headline_publications$affiliations, function(affiliations) {
  affiliations <- unique(unlist(affiliations))
  affiliations <- affiliations[!is.na(affiliations) & nzchar(trimws(affiliations))]
  affiliations[!grepl(
    "California Department of Water Resources|Department of Water Resources",
    affiliations
  )]
})

partner_counts <- sort(table(unlist(partner_affiliations, use.names = FALSE)), decreasing = TRUE)
partner_counts <- data.frame(
  institution = names(partner_counts),
  articles = as.integer(partner_counts),
  row.names = NULL
)
top_partners <- head(partner_counts, 6L)

headline_cards <- data.frame(
  xmin = c(0, 30.5, 61, 91.5),
  xmax = c(28.5, 59, 89.5, 120),
  metric = c(
    format(nrow(swp_headline_publications), big.mark = ","),
    format(nrow(partner_counts), big.mark = ","),
    paste0(round(mean(swp_headline_publications$contribution_type != "Funder") * 100), "%"),
    format(sum(swp_headline_publications$contribution_type == "Sole Author"), big.mark = ",")
  ),
  label = c(
    "SWP-associated publications",
    "External institutions represented",
    "With SWP authorship",
    "Sole-authored publications"
  ),
  detail = c(
    "2020–2026",
    "Across all included publications",
    paste0(sum(swp_headline_publications$contribution_type != "Funder"), " of ",
           nrow(swp_headline_publications), " publications"),
    "2020–2026"
  )
)

top_partners <- top_partners |>
  mutate(
    y = rev(seq_len(n())),
    bar_end = 80 * articles / max(articles)
  )

swp_research_at_a_glance <- ggplot() +
  geom_rect(
    data = headline_cards,
    aes(xmin = xmin, xmax = xmax, ymin = 70, ymax = 91),
    fill = "#f2f7f9",
    color = "#d8e8d8",
    linewidth = 0.7
  ) +
  geom_text(
    data = headline_cards,
    aes(x = xmin + 3, y = 85, label = metric),
    hjust = 0,
    family = "Arial",
    color = dwr_colors[["navy"]],
    fontface = "bold",
    size = 11
  ) +
  geom_text(
    data = headline_cards,
    aes(x = xmin + 3, y = 77.5, label = label),
    hjust = 0,
    family = "Arial",
    color = dwr_colors[["navy"]],
    size = 4.2
  ) +
  geom_text(
    data = headline_cards,
    aes(x = xmin + 3, y = 73.2, label = detail),
    hjust = 0,
    family = "Arial",
    color = dwr_colors[["gray_text"]],
    size = 3.1
  ) +
  geom_text(
    aes(x = 0, y = 104, label = "SWP research at a glance"),
    hjust = 0,
    vjust = 1,
    family = "Arial",
    color = dwr_colors[["navy"]],
    fontface = "bold",
    size = 10
  ) +
  geom_text(
    aes(x = 0, y = 96.5, label = "2020–2026 State Water Project publication portfolio"),
    hjust = 0,
    vjust = 1,
    family = "Arial",
    color = dwr_colors[["navy_light"]],
    size = 4.8
  ) +
  geom_text(
    aes(x = 0, y = 64, label = "Leading external institutions"),
    hjust = 0,
    family = "Arial",
    color = dwr_colors[["navy"]],
    fontface = "bold",
    size = 5.2
  ) +
  geom_text(
    aes(x = 0, y = 59, label = "Number of SWP-associated publications listing the institution"),
    hjust = 0,
    family = "Arial",
    color = dwr_colors[["gray_text"]],
    size = 3.4
  ) +
  geom_segment(
    data = top_partners,
    aes(x = 35, xend = 35 + bar_end, y = y * 7, yend = y * 7),
    color = dwr_colors[["teal_light"]],
    linewidth = 4.5,
    lineend = "butt"
  ) +
  geom_segment(
    data = top_partners,
    aes(x = 35, xend = 35 + bar_end, y = y * 7, yend = y * 7),
    color = dwr_colors[["teal"]],
    linewidth = 3.1,
    lineend = "butt"
  ) +
  geom_text(
    data = top_partners,
    aes(x = 0, y = y * 7, label = institution),
    hjust = 0,
    family = "Arial",
    color = dwr_colors[["navy"]],
    size = 4
  ) +
  geom_text(
    data = top_partners,
    aes(x = 118, y = y * 7, label = articles),
    hjust = 1,
    family = "Arial",
    color = dwr_colors[["navy"]],
    fontface = "bold",
    size = 4
  ) +
  coord_cartesian(xlim = c(0, 120), ylim = c(0, 107), clip = "off") +
  theme_void(base_family = "Arial") +
  theme(
    plot.background = element_rect(fill = "white", color = NA),
    plot.margin = margin(20, 34, 20, 34)
  )

ggsave(
  filename = file.path(output_dir, "swp-research-at-a-glance-2020-2026.png"),
  plot = swp_research_at_a_glance,
  width = 13.333,
  height = 7.5,
  units = "in",
  dpi = 300,
  bg = "white"
)
