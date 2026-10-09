# ACCESS-REPORT — what this repository's pods could and could not reach, by date

## 2026-10-08T12:51Z — bootstrap-repo.sh in session maestro-gke-test-0lpw (pod maestro-maestro-gke-test-0lpw-0), as ivanm-toptal

| check | result | detail |
|---|---|---|
| gh | ok | ivanm-toptal |
| gcloud account | info | maestro-session-p1@toptal-maestro.iam.gserviceaccount.com |
| compute | skipped | no GCP project recorded yet |

## 2026-10-09 — T-1 (worker/docs-index) Phase 0 close-out, as ivanm-toptal

| check | result | detail |
|---|---|---|
| gh | ok | `gh auth status` exit 0, ivanm-toptal; warns token lacks `read:org` (not needed by T-1) |
| compute | ok | `gcloud compute instances list --project toptal-ai-research-staging --limit 3` exit 0, 3 rows |
| janitor | ok | `--report-only` exit 0: no maestro-gke-test instances in toptal-ai-research-staging |

All three passed; T-1 started no machine and spent nothing.
