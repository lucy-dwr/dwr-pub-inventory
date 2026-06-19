# Known Limitations

This document records known limitations in the publication inventory dataset and
data model. It is intended to help maintainers and downstream users interpret
counts, division assignments, contribution flags, and dashboard views.

## Coverage

### Scopus-dependent discovery

The inventory is built from systematic Scopus searches. Publications that are
not indexed in Scopus, have incomplete Scopus metadata, or do not match the
configured funder and affiliation search terms may be absent even if they are
DWR-related.

### Funding confirmation can be blocked by paywalls

Some potentially DWR-funded records cannot be affirmatively confirmed during
manual review because the funding statement, acknowledgments, or article full
text is behind a paywall. These records may be marked `unsure` in
`data/decisions/funding_review_decisions.csv` when available metadata is
insufficient to verify DWR funding. Therefore, records of these publications are
maintained in this repository but not incorporated in the final accepted inventory
or displayed in the frontend dashboard.

Therefore, this repository produces an undercount. In particular, `unsure` funder
records are not eligible for `data/lookups/funding_division_lookup.csv`, so
division-level funded-publication counts understate records where DWR funding may
exist but could not be verified. The flipside of this, of course, is that the 
quality of the data in the inventory is high; DWR funding has been actively
confirmed for included articles.

### Manual review decisions reflect available evidence

Review decisions are made from Scopus metadata, DOI landing pages, accessible
article pages, and other available evidence at review time. Publisher metadata
can change, article access can change, and older records may have sparse or
inconsistent funding and affiliation text.

## Authorship And Division Data

### DWR author detection depends on affiliation metadata

Author-route records are discovered primarily through Scopus affiliation
metadata. Records may be missed when DWR authors used another affiliation,
Scopus omitted or normalized the affiliation unexpectedly, or the publication
metadata does not include an explicit California Department of Water Resources
affiliation.

### Author divisions are inferred from an HR-derived lookup

DWR author divisions are determined by matching Scopus author names and
publication years to a private HR-derived name/year/division lookup. The matching
logic uses exact last-name plus first-initial matching first, then fuzzy
Jaro-Winkler matching for name variants when available. A layer of manual review
and assignment is performed for instances in which there are multiple potential
matches in the HR-derived list or for which no match was found.

This can introduce inaccuracies. Potential failure modes include shared last
names and first initials, name changes, nicknames with different first initials,
transliteration differences, missing middle names, HR lookup gaps, employee
movement between divisions, and publication dates that do not align cleanly with
the year of the underlying work. Ambiguous or missing matches are routed to
manual division review, but automatically resolved matches may still contain
errors.

### Funding and author divisions are different concepts

`funding_division` identifies the DWR division associated with a DWR funding
relationship when that division has been manually assigned.

`author_division` identifies the division of confirmed DWR author(s) based on
author-level review and division resolution. A publication can have one, both, or
neither division field populated. These fields should not be treated as
interchangeable. While this is not necessarily a limitation, it is important to
understand this concept when analyzing or interpreting the inventory.

## Classification And Enrichment

### Science fields are model-assisted classifications

Science category and field values are assigned by an LLM using the configured
DWR taxonomy, publication title, abstract when available, and related metadata.
These labels are useful for browsing and aggregate reporting, but they are not a
peer-reviewed subject classification. Records with sparse abstracts, broad
interdisciplinary scope, or ambiguous objectives can be misclassified.

### Institution names and geography are normalized

Institution names are canonicalized through lookup tables that are partly
model-assisted and partly manually reviewed. Country and US state enrichment is
also model-assisted. Ambiguous institution names, multi-campus systems,
historical institution names, and incomplete affiliation strings can produce
incorrect or missing geography.

## Data Model

### Publication-level records flatten richer relationships

The dashboard export is one row per publication, with multi-valued fields such as
authors, affiliations, affiliation countries, and author divisions collapsed for
some outputs. This makes the dashboard easier to filter but cannot fully
represent all author-affiliation-division relationships for a publication.


