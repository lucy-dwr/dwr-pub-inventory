# Review Quality Control Guide

This guide sets the standard for reviewing publication candidates in the DWR
Publication Inventory. Use it for both the funder and author/affiliation review
apps. It is also the living record of review precedents and unusual decisions.

## Purpose and scope

The review apps help organize, prioritize, and process candidate records returned
by Scopus. They do not decide whether a record belongs in the inventory. A
reviewer makes that decision from the evidence available for the record.

Review every record in each queue, regardless of its suspicion score. Scores
help prioritize attention only; they are not confidence estimates, evidence, or
automatic decision rules.

The inventory has two **independent** inclusion routes:

- **Funder route:** the publication received actual DWR financial support
- **Author route:** at least one author worked for DWR when contributing to the
  publication, and contributions were under the auspices of their DWR employment

A publication may qualify through either route or through both.

## Evidence available during review

Reviewers will not usually have access to article full text. Base decisions on
the information ordinarily available in Scopus metadata and the article or DOI
page published by the journal. This may include the title, abstract, authors,
affiliations, funder information, grant information, and any publicly visible
acknowledgments or funding statement.

These sources are incomplete. Scopus and journal pages may omit, shorten, or
normalize funder names, grant and contract numbers, author-affiliation links,
and acknowledgments. Older records can be especially sparse. Missing metadata
is not evidence that DWR was not involved.

Use accessible supporting information where it is directly relevant. Do not
assume that inaccessible acknowledgment or funding text supports or disproves a
record.

## Review decisions

Choose one decision for every record.

| Decision | Use when |
|---|---|
| **Keep** | The available evidence affirmatively confirms the relevant DWR funding or DWR-employment authorship relationship. |
| **Drop** | The available evidence affirmatively shows that the candidate does not meet the route-specific standard. |
| **Unsure** | The available evidence cannot affirmatively confirm the relationship and cannot affirmatively rule it out. |

**Unsure does not mean unlikely.** It means the relationship is not
affirmatively confirmable from the evidence available during review. For
example, select **Unsure** when a likely funding statement or acknowledgment is
behind a paywall and the accessible metadata and article page do not establish
DWR funding. Unsure decisions may always be amended when better evidence becomes
available.

## Funding review standard

Keep a funded candidate only when there is affirmative evidence of actual DWR
financial support. This can include a funding statement or acknowledgment
identifying DWR, or an identifiable DWR grant or contract number.

Do **not** treat a general DWR contribution as funding. By itself, the following
does not meet the funding standard:

- DWR-provided data, models, facilities, samples, or study access
- Technical advice, review, collaboration, or other non-financial assistance
- DWR being discussed, cited, or named as a stakeholder
- A DWR-affiliated author without evidence of DWR funding

Multiple funders are not a concern. Keep the record through the funder route if
any funding source affirmatively identifies DWR, even when other organizations
also funded the work.

The Scopus publication year—typically the print-publication year—is the review
year. Funding does not need to have occurred in that same calendar year.

## Author and affiliation review standard

Keep an author candidate when at least one author is affirmatively shown to have
worked for DWR, and the publication was associated with that person's DWR
employment or performed under those auspices.

If the record lists multiple affiliations, a single DWR affiliation is enough to
qualify the record through the author route.

A former DWR employee who reports a different affiliation does not qualify
merely because of their former DWR employment.

Use human judgment for initials, name changes, shared names, alternate spellings,
and inconsistent affiliation text. The app's author matching and division
suggestions are aids; they do not resolve identity ambiguity on their own.
In particular, common names and abbreviated Scopus names can create false
automatic matches to the DWR HR-derived staff lookup. A DWR badge or suggested
division is not by itself confirmation that the publication's author is the DWR
employee. Confirm the identity from the available author and affiliation context
before keeping the record.

## Suspicion scores

Suspicion scores sort likely false positives toward the front of the review
queue. Every record must still receive the same review and evidence standard.
Higher scores mean “inspect more closely,” not “probably wrong.”

### Funder-review score (`cdwr_score`, 0–13)

The score adds points when the available record has these signals:

| Signal | Points |
|---|---:|
| No California geographic reference across available text | +4 |
| No water-related topic in title or abstract | +4 |
| Keywords suggest a non-water field, such as medicine or physics | +3 |
| No U.S. institution detected in author affiliations | +2 |

### Author-review score (`caff_score`, 0–12)

The score adds points when the available record has these signals:

| Signal | Points |
|---|---:|
| No author/year match in the HR-derived DWR staff lookup | +5 |
| DWR affiliation is a nonstandard text variant | +3 |
| Keywords suggest an unrelated field | +2 |
| No California geographic reference | +2 |

Both apps label scores as low, medium, or high suspicion. These labels do not
change the decision rules. For example, a DWR-funded publication can have no
water-related words in its title or abstract, and a current DWR author can be
absent from the staff lookup because of a name change or data gap. Conversely,
an apparent staff-lookup match can be a false match when different people share
a name or initials.

## Practical review workflow

1. Launch the relevant review application and navigate to a record that needs
   review.
2. Read the Scopus metadata in the application and the information available on
   the journal article or DOI page.
3. Identify which review route is under consideration: funding, authorship, or
   both.
4. Apply the relevant affirmative confirmation standard above.
5. Select **Keep**, **Drop**, or **Unsure**. Do not use topical relevance,
   suspicion score, or missing metadata as a substitute for evidence.
6. For unusual, uncertain, or changed decisions, add a concise entry to the
   precedent log below. Include the evidence reviewed and the reason for the
   decision. Use the app's review-notes field as well when it is useful.

## Affiliation canonicalization review walkthrough

The affiliation canonicalization app standardizes the institution names that
appear in the inventory. This is separate from deciding whether a publication
is DWR-funded or DWR-authored. Review the organization named in an affiliation
string; do not infer funding, employment status, or a DWR division here.

### Before starting

Build the current lookup, then launch the app from the repository root:

```r
targets::tar_make(affiliation_lookup_file)
shiny::runApp("shiny/affiliation_review_app.R")
```

The app opens on articles that have both a new/unreviewed affiliation and an
`Unknown` canonical institution. These filters focus the work; they do not mean
that an affiliation is wrong solely because it is new or unknown.

### Review one article at a time

The app groups every raw affiliation for a publication together. Start with the
article title, authors, year, and DOI in the left panel. Open the DOI when its
journal page is needed to understand an ambiguous affiliation or find an
affiliation missing from the metadata.

In the **Article Affiliations** tab:

1. Read all raw affiliation strings for the current article before saving it.
   A single article may legitimately have several institutions.
2. Select an affiliation row to display its full raw text in **Selected Raw
   Affiliation**. The field and buttons in the left panel affect only that row.
3. Check whether the proposed canonical value identifies the actual institution
   in the raw text. A department, laboratory, campus address, city, or country
   is not normally the canonical institution unless it is part of the
   institution's established name.
4. Use the exact established canonical name when one exists. In the
   **Canonical Institutions** tab, select a known name to copy it to the
   selected row. You may also type or directly edit the canonical value when a
   new canonical name is necessary.
5. Add a short review note when the decision is non-obvious—for example, a
   renamed institution, an ambiguous acronym, or why `Unknown` was necessary.
6. Use **Apply to selected row** after typing a value. Edits made directly in
   the table are also retained in the article's draft.

Choosing a name in **Canonical Institutions** applies that name to the selected
row in the draft; it is not written to the lookup file until the article is
saved.

### When to use `Unknown`

Use **Mark selected Unknown** only when the institution cannot be reliably
identified from the raw affiliation and accessible article metadata. Do not
guess based on an acronym, a city, a collaborator, or a superficially similar
institution. `Unknown` is preferable to a plausible but incorrect
canonicalization and can be corrected later.

If the journal page shows an affiliation that is missing from the displayed
article rows, use **Add Missing Affiliation**. Enter the raw affiliation as it
appears in the article and supply its canonical institution when it can be
confirmed. This creates a manually added row for the current article.

### Save, skip, and verify

Use the navigation buttons deliberately:

| Control | Effect |
|---|---|
| **Save Article + Next** | Saves all affiliation rows for the current article, marks them reviewed, and moves to another visible article. |
| **Save Article** | Saves all affiliation rows for the current article and remains on it. |
| **Skip** / **Back** | Moves between visible articles without saving the current draft. |

Saving is article-level: it saves every affiliation row shown for that article,
not only the selected row. Blank canonical values are saved as `Unknown`. Before
saving, confirm that every row has the intended canonical value and that no
distinct institutions were accidentally merged. After saving, the article may
disappear from the default queue because it is no longer new; this is expected.

For a correction to a previously reviewed affiliation, clear the relevant
filters or use **Search articles**, reopen the article, revise the appropriate
row, and save the article again.

### Canonicalization rules of thumb

- Reuse an existing canonical name for the same institution whenever possible;
  do not create spelling, punctuation, acronym, department, or campus-address
  variants of an established value.
- Preserve distinct institutions. A university, a separate government agency,
  and an affiliated research institute should not be collapsed merely because
  they share a location or collaborate frequently.
- Use the organization that the affiliation actually names, rather than the
  university system, parent organization, or funder you expect it to be.
- Record unusual rules in the precedent log below so later reviewers make the
  same choice.

## Funding and author divisions

`funding_division` and `author_division` describe different relationships.
`funding_division` is the DWR division associated with confirmed DWR funding;
`author_division` is the division associated with confirmed DWR author(s).
Neither implies the other, and a publication can have one, both, or neither.

After a funder-route record is kept, its funding division is assigned separately
using the appropriate internal information. Do not delay or change the keep/drop/
unsure decision solely because the division is not yet known.

## Quick decision check

```text
Can the available evidence affirmatively confirm the route-specific DWR relationship?
  Yes → Keep
  No  → Can it affirmatively rule out that relationship?
           Yes → Drop
           No  → Unsure
```

## Precedent and decision log

Add rows here when a case establishes a useful rule, involves unusual evidence,
is marked unsure for a non-obvious reason, or reverses an earlier decision. Keep
entries concise and avoid including restricted information. New cases should be
reviewed against prior entries for consistency.

| Date | Route | Record identifier / short description | Decision | Evidence reviewed | Rationale or precedent | Reviewer |
|---|---|---|---|---|---|---|
|  |  |  |  |  |  |  |
