# Score publications by their likelihood of NOT being genuinely CA-DWR-funded.
# Higher scores = less likely to be a true CA DWR publication.
#
# Signals and weights:
#   +4  No California geographic mention across all text fields
#   +4  No water-related topic in title or abstract
#   +3  Domain keywords indicate a non-water field (medicine, physics, etc.)
#   +2  No US institution detected in author affiliations
#
# Maximum possible score: 13
#
# Returns `pubs` with an added integer column `cdwr_score`.

score_cdwr_relevance <- function(pubs) {

  ca_pattern <- paste0(
    "california|\\bcdwr\\b|\\bdwr\\b|sacramento|san francisco|bay.?delta|",
    "central valley|san joaquin|los angeles|lake tahoe|mono lake|owens|",
    "sierra nevada|\\bfresno\\b|bay area|\\bnapa\\b|\\bsonoma\\b|\\bmarin\\b|",
    "\\balameda\\b|\\bstockton\\b|\\bklamath\\b|\\btrinity\\b|salton sea"
  )

  water_pattern <- paste0(
    "\\bwater\\b|hydro|\\briver\\b|\\bstream\\b|groundwater|aquifer|",
    "reservoir|drought|flood|irrigation|watershed|runoff|precipitation|",
    "\\bsnow\\b|glacier|\\bdelta\\b|estuary|wetland|salinity|turbidity|",
    "sediment|\\bflow\\b|discharge|\\bdam\\b|\\blevee\\b|canal|aqueduct|",
    "wastewater|stormwater|\\bsalmon\\b|\\bsturgeon\\b|\\bsteelhead\\b|",
    "\\bsmelt\\b|\\blamprey\\b"
  )

  non_water_topic_pattern <- paste0(
    # Oncology / clinical medicine
    "\\bcancer\\b|\\btumou?r\\b|oncolog|leukemia|lymphoma|melanoma|",
    "\\bmetastas|chemotherapy|radiotherapy|immunotherapy|",
    "cardiac|cardiovascular|coronary|arrhythmia|myocardial|",
    "pulmonary|\\blung\\b|\\basthma\\b|chronic obstructive|",
    "\\bstroke\\b|\\bepilepsy\\b|\\bseizure\\b|",
    "alzheimer|parkinson|dementia|\\bneurodegenerative\\b|",
    "psychiatric|\\bdepression\\b|\\banxiety\\b|schizophrenia|autism|",
    "orthopedic|\\bfracture\\b|osteoporosis|",
    "dermatolog|\\bskin disease\\b|\\bwound healing\\b|",
    "ophthalmolog|\\bretina\\b|\\bglaucoma\\b|",
    "obstetric|\\bpregnancy\\b|\\bneonatal\\b|\\bpediatric\\b|",
    "clinical trial|\\bpatient\\b|\\bdiagnosis\\b|\\btherapy\\b|",
    "\\bsurgery\\b|surgical|anesthesia|\\bhospital\\b|\\bnursing\\b|",
    "pharmaceutical|\\bdrug\\b delivery|drug resistance|",
    "\\bvaccine\\b|\\bvirus\\b|\\bbacteria\\b|antibiotic|antimicrobial|",
    "\\bcovid\\b|pandemic|influenza|\\bhiv\\b|\\baids\\b|",
    "\\bebola\\b|malaria|tuberculosis|",
    # Molecular / cell biology
    "\\bRNA\\b|\\bmRNA\\b|\\bCRISPR\\b|gene expression|",
    "transcriptom|proteom|metabolom|epigenetic|",
    "stem cell|\\bapoptosis\\b|cell signaling|cell membrane|",
    # Materials science
    "nanoparticle|nanomaterial|\\bgraphene\\b|",
    "\\bpolymer\\b|\\bcomposite material\\b|\\bceramic\\b|\\balloy\\b|",
    "semiconductor|transistor|photovoltaic|",
    # Physics
    "quantum computing|plasma physics|nuclear fusion|particle physics|",
    "astrophysics|cosmology|dark matter|dark energy|\\bgalaxy\\b|",
    "black hole|neutron star|exoplanet|",
    # Economics / finance
    "stock market|financial market|monetary policy|macroeconomic|",
    "\\binflation\\b|\\bGDP\\b|bond market|hedge fund|cryptocurrency|blockchain",
    # Computer science (terms unlikely in water contexts)
    "cybersecurity|natural language processing|computer vision|",
    "operating system|\\bcompiler\\b|\\bcryptograph"
  )

  # Matches US state names, common high-output universities without state names,
  # federal agencies, and national labs. Absence suggests no US institution listed.
  us_affil_pattern <- paste0(
    # 50 states
    "\\balabama\\b|\\balaska\\b|\\barizona\\b|\\barkansas\\b|\\bcalifornia\\b|",
    "\\bcolorado\\b|\\bconnecticut\\b|\\bdelaware\\b|\\bflorida\\b|\\bgeorgia\\b|",
    "\\bhawaii\\b|\\bidaho\\b|\\billinois\\b|\\bindiana\\b|\\biowa\\b|\\bkansas\\b|",
    "\\bkentucky\\b|\\blouisiana\\b|\\bmaine\\b|\\bmaryland\\b|\\bmassachusetts\\b|",
    "\\bmichigan\\b|\\bminnesota\\b|\\bmississippi\\b|\\bmissouri\\b|\\bmontana\\b|",
    "\\bnebraska\\b|\\bnevada\\b|new hampshire|new jersey|new mexico|new york|",
    "north carolina|north dakota|\\bohio\\b|\\boklahoma\\b|\\boregon\\b|",
    "pennsylvania|rhode island|south carolina|south dakota|\\btennessee\\b|",
    "\\btexas\\b|\\butah\\b|\\bvermont\\b|\\bvirginia\\b|\\bwashington\\b|",
    "west virginia|\\bwisconsin\\b|\\bwyoming\\b|",
    # Major private research universities (no state in name)
    "stanford|harvard|\\bmit\\b|massachusetts institute of technology|",
    "yale university|princeton|columbia university|cornell university|",
    "duke university|johns hopkins|northwestern university|",
    "vanderbilt|rice university|tulane|carnegie mellon|",
    "notre dame|georgetown|emory university|tufts university|",
    "dartmouth|brown university|boston university|northeastern university|",
    "drexel|fordham|lehigh|villanova|wake forest|",
    "rensselaer|rochester institute|syracuse university|",
    "george washington|american university|howard university|",
    "university of chicago|washington university in st|",
    "university of rochester|case western reserve|",
    "brandeis university|rockefeller university|purdue university|",
    "baylor university|university of miami|clarkson university|",
    # Federal agencies and national labs
    "\\bnoaa\\b|\\busgs\\b|\\bnasa\\b|\\bepa\\b|",
    "national oceanic|geological survey|",
    "lawrence berkeley|lawrence livermore|",
    "sandia national|los alamos|pacific northwest national|",
    "argonne national|oak ridge national|",
    "army corps of engineers|bureau of reclamation|",
    # Country markers
    "united states|\\busa\\b|\\bu\\.s\\.a?\\.\\b"
  )

  score_one <- function(i) {
    title      <- tolower(pubs$title[i])
    abstract   <- tolower(pubs$abstract[i])
    affils     <- tolower(paste(unlist(pubs$affiliations[[i]]),  collapse = " "))
    funders    <- tolower(paste(unlist(pubs$funders[[i]]),       collapse = " "))
    grant_nums <- tolower(paste(unlist(pubs$grant_numbers[[i]]), collapse = " "))

    all_text <- paste(title, abstract, affils, funders, grant_nums)

    s <- 0L
    if (!grepl(ca_pattern,              all_text, perl = TRUE)) s <- s + 4L
    if (!grepl(water_pattern,           all_text, perl = TRUE)) s <- s + 4L
    if ( grepl(non_water_topic_pattern, all_text, perl = TRUE)) s <- s + 3L
    if (!grepl(us_affil_pattern,        affils,   perl = TRUE)) s <- s + 2L
    s
  }

  dplyr::mutate(
    pubs,
    cdwr_score = vapply(seq_len(nrow(pubs)), score_one, integer(1L))
  )
}
