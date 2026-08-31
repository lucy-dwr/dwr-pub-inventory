# Publishing the dashboards to Posit Connect

This guide explains how to publish the two dashboard applications from Posit
Workbench to Posit Connect:

- **Internal:** `dashboard_app_internal_publish.R` — for DWR staff; includes
  division information and the Ask the data chat assistant.
- **External:** `dashboard_app_external_publish.R` — public-facing; excludes
  division information and the chat assistant.

**Publish from the repository root.** Do not select either file in `shiny/` as 
the application entry point.

## Why the root-level publish files are needed

The dashboards use paths relative to the repository root (for example,
`data/generated/dwr_publications.parquet` and `R/dashboard_download.R`). The
root-level files must source and return the actual Shiny app objects:

```r
# dashboard_app_external_publish.R
source("shiny/dashboard_app_external.R", local = TRUE)$value
```

```r
# dashboard_app_internal_publish.R
source("shiny/dashboard_app_internal.R", local = TRUE)$value
```

The `$value` is important: `source()` otherwise returns a list, not the
`shiny.appobj` that Posit Connect expects. Using these wrappers makes Connect
start the app with the repository root as its working directory and lets the
app find its data, helper code, and assets.

## Before publishing

1. Open the R project in Posit Workbench from the repository root.
2. Confirm each root-level `*_publish.R` wrapper uses the form above. A wrapper
   containing only `source("shiny/<app>.R")` will fail validation with an
   error that the file did not return a `shiny.appobj` object.
3. Update the dashboard data, if needed, and confirm these files exist and are
   current:

   - `data/generated/dwr_publications.parquet`
   - `data/lookups/institution_geo_lookup.csv`
   - `data/refresh_log.csv`
   - `taxonomy/dwr_disciplines_taxonomy.csv`
   
4. Restore the project packages if necessary:

   ```r
   renv::restore()
   ```

5. Test the appropriate dashboard from the repository root:

   ```r
   shiny::runApp("shiny/dashboard_app_external.R")
   shiny::runApp("shiny/dashboard_app_internal.R")
   ```

6. Test the publishing wrapper from the repository root before using it as the
   Connect entry point:

   ```r
   shiny::runApp("dashboard_app_external_publish.R")
   shiny::runApp("dashboard_app_internal_publish.R")
   ```

   Run one command at a time and stop the local app before testing the other.
   The wrapper should start the same dashboard without the error that it did
   not return a `shiny.appobj` object. Confirm that the DWR logo appears in
   the upper-left header; this verifies that the bundled `shiny/www/` asset is
   available from the root-level entry point.

For the internal dashboard, the local session also needs `PUBCLASSIFY_LLM_KEY`
when testing the chat assistant.

## Access model

**The internal dashboard is published as a public Posit Connect app because**
**access is enforced by Cloudflare, not by Posit Connect accounts.** Work with
DTS to configure the Cloudflare-protected route to require the approved DWR
identity space before a user can reach the internal dashboard. Do not describe
or configure the internal app as staff-only through Posit Connect user or group
permissions.

Ensure users cannot reach the Connect origin URL through a route that bypasses
the Cloudflare identity check. The external dashboard is public without this
Cloudflare access restriction.

## Deployment settings checklist

Record the following settings for each deployment when it is created or
updated. Add the final URLs here once they are assigned.

| Setting | Internal dashboard | External dashboard |
|---|---|---|
| Posit Connect title | DWR peer-reviewed publication inventory (internal) | DWR peer-reviewed publication inventory (external) |
| Connect content type | Shiny (`r-shiny`) | Shiny (`r-shiny`) |
| Posit Connect access | Public; do not rely on Connect accounts or groups | Public |
| User-facing URL | Cloudflare-protected Connect URL: `https://data-tools.water.ca.gov/pub-inventory-internal` | Public Connect URL: `https://data-tools.water.ca.gov/pub-inventory` |
| Connect route | Apply the Cloudflare Access policy to this app's Connect path | No Cloudflare Access policy |
| Required environment variable | `PUBCLASSIFY_LLM_KEY` | None |

These URL patterns assume that `data-tools.water.ca.gov` is the
Cloudflare-proxied hostname for Posit Connect. Use the Connect-assigned path
for each app; do not invent or change the path outside Connect. For the
internal dashboard, configure Cloudflare Access to require the approved DWR
identity space for that specific Connect path. Allow WebSocket traffic and
bypass edge caching for the Shiny application route; a Shiny session is
dynamic and must not be served from a shared cache. Test the Cloudflare URL in
a browser session that is not already authenticated, as well as in an approved
DWR identity session for a user who does not otherwise have access to Connect.
Ensure that the Connect host is not exposed through an unproxied DNS record or
another route that bypasses this policy.

## Publish with the Posit Publisher pane

For each dashboard, open its root-level `*_publish.R` file in Posit Workbench
and use the **Publish** button/Publisher pane to create or update the matching
Posit Connect content item. Confirm that the selected entry point is the
root-level wrapper, set an appropriate title and visibility, then publish.

After the first bundle, Posit Publisher writes two kinds of local metadata:

- A publishing manifest under `.posit/publish/`. This is the TOML file that
  records the entry point, runtime, title, and `files` list for the bundle.
- A deployment record under `.posit/publish/deployments/`. This connects the
  local publishing configuration to the existing Posit Connect content item.

Keep this metadata in the repository for future publishing. It is fine to commit
to Git. This metadata lets the publisher update the same Connect item instead of
treating a later publish as a new deployment. However, it is deployment metadata,
not application code: do not add it to the app's `files` list by hand. 

## Check the generated TOML file list

This is the critical publishing check. Posit Publisher determines the bundle
from the generated TOML `files` list; Connect cannot read a file that is absent
from that list, even if it is present in the Git repository.

Review the TOML after creating or updating a bundle. It must include the
wrapper, the app script, every local file read or sourced by that app, the
assets, and `renv.lock`. Re-publish after changing application dependencies or
data inputs, and verify that the regenerated list still contains them.

### External dashboard required files

```toml
files = [
  "/dashboard_app_external_publish.R",
  "/shiny/dashboard_app_external.R",
  "/shiny/www/dwr-logo-new.png",
  "/shiny/content/about.md",
  "/shiny/content/classification.md",
  "/R/dashboard_download.R",
  "/data/generated/dwr_publications.parquet",
  "/data/lookups/institution_geo_lookup.csv",
  "/data/refresh_log.csv",
  "/taxonomy/dwr_disciplines_taxonomy.csv",
  "/renv.lock",
]
```

### Internal dashboard required files

```toml
files = [
  "/dashboard_app_internal_publish.R",
  "/shiny/dashboard_app_internal.R",
  "/shiny/www/dwr-logo-new.png",
  "/shiny/content/about.md",
  "/shiny/content/classification.md",
  "/R/dashboard_download.R",
  "/R/dashboard_chat_tools.R",
  "/R/load_pipeline_config.R",
  "/config/pipeline.yml",
  "/prompts/chat_system_prompt.txt",
  "/data/generated/dwr_publications.parquet",
  "/data/lookups/institution_geo_lookup.csv",
  "/data/refresh_log.csv",
  "/taxonomy/dwr_disciplines_taxonomy.csv",
  "/renv.lock",
]
```

The Publisher-generated manifest also includes its own path and deployment
record in some workflows. Preserve those entries when Publisher adds them. Do
not copy the external list to the internal app: the latter requires the chat
files, configuration, and prompt shown above.

For this project, the Publisher manifest should use R 4.6.0. The current
`renv.lock` and local development R both specify 4.6.0, and Posit Publisher
uses `renv.lock` to determine the R information for a deployment. Confirm that
R 4.6.0 is available on the Connect server. Do not change the manifest to
4.6.1+ unless the project is intentionally upgraded and `renv.lock` is updated
and tested with that version. The manifest block is:

```toml
type = "r-shiny"
validate = true
product_type = "connect"

[r]
version = "4.6.0"
package_file = "renv.lock"
package_manager = "renv"
```

## Internal dashboard secret

The internal dashboard calls `Sys.getenv("PUBCLASSIFY_LLM_KEY")` at startup.
Set `PUBCLASSIFY_LLM_KEY` as an environment variable for the internal Connect
content item (or through the approved Connect environment variable management
process) before testing the deployed app. **Never put the key in**
**`config/pipeline.yml`, the TOML manifest, or the repository or commit it to**
Git.**

The external dashboard does not require this key.

## Verify the deployment

After each publish:

1. Open the Connect URL in an appropriate browser session.
2. Confirm the app starts without a missing-file or package error.
3. Check the dashboard, Institution Map, Publishing Network, Science Fields,
   About, CSV download features, and the DWR logo in the upper-left header.
4. For the internal app, confirm division filtering and run a simple Ask the
   data prompt to verify the LLM environment variable and endpoint access.
5. Confirm the access model: the internal dashboard is publicly published in
   Connect but requires the approved DWR identity through Cloudflare; the
   external dashboard is publicly available without that Cloudflare restriction.

If Connect reports a missing file, compare the error path with the generated
TOML `files` array, add the missing project file through the Publisher bundle
selection, then publish a new version. Do not solve root directory failures by
changing the application paths; keep the root-level publishing wrapper as the
entry point.
