# GCP: operating knowledge (research projects)

## The three credential stores (memorize this)
- `gcloud auth login` — the CLI's own store. For typed commands only.
- `gcloud auth application-default login` — the ADC file, discovered by CODE
  (google-auth, Vertex/Gemini SDKs, BigQuery clients).
- Attached service account — the metadata server IS the ADC on GCP compute.
  Beats both; needs no login, ever.

Combining the first two: `gcloud auth login --update-adc` = one browser trip.
CAVEAT: verify Vertex accepts the resulting ADC once — aiplatform REJECTS
tokens minted for the gcloud-CLI OAuth client (ACCESS_TOKEN_TYPE_UNSUPPORTED)
while accepting proper ADC ones; if it rejects, keep the two logins separate.
Org policy expires sessions every day or two: EXPECT reauth; design everything
to fail loudly on auth errors, never to retry silently.

## Identity rules that cost us days
- A VM with NO attached SA has NO identity: google.auth.default() finds
  nothing; ADC-based code cannot work at all. Check FIRST on any new box:
  `gcloud compute instances describe <vm> --format="value(serviceAccounts)"`.
- Attach at create time (`--service-account=... --scopes=cloud-platform`), or
  on a stopped VM via `set-service-account`. You need
  `iam.serviceAccounts.actAs` on the SA — and SA-level grants DO NOT show in
  `projects get-iam-policy`; test with `serviceAccounts:testIamPermissions`
  before concluding you lack access.
- 403 IAM_PERMISSION_DENIED = plain IAM, fixed by a role grant. "Request is
  prohibited by organization's policy" = VPC-SC perimeter — different owner,
  different fix. Never conflate them in a report.
- A Vertex 404 "model not found or no access" can be the REGION: publisher
  models often serve at `locations/global`, not the VM's home region.

## IAP: how you reach anything (no external IPs in research projects)
- SSH: `gcloud compute ssh --tunnel-through-iap`; auth via metadata SSH keys
  (gcloud generates and pushes one on first use). OS Login policies may apply.
- Port tunnels reach ONLY firewall-permitted ports from the IAP range
  (35.235.240.0/20) — check the `allow-iap-*` rules; a tunnel to a blocked or
  unbound port fails with `4003 failed to connect to backend`.
- Services must bind 0.0.0.0: IAP connects to the NIC, not loopback. A service
  on 127.0.0.1 passes every on-VM curl and still refuses every tunnel.
- The python IAP tunnel (without NumPy) is slow and can drop connections under
  multipart load; prefer colocating chatty services on one box over tunneling
  between boxes. Windows client prints benign per-connection
  WinError 10038 noise — cosmetic; keep that terminal off projectors.

## Capacity & quota
- Quota is not capacity: `ZONE_RESOURCE_POOL_EXHAUSTED` means the zone has no
  GPUs to hand out right now. Playbook: bounded retry (~4 x 90s) keyed to that
  EXACT error signature, then sibling zones; never blind-retry other errors.
- Quotas are per-metric per-region (L4 vs A100-80GB separate; Vertex serving
  quota separate from Compute quota). Read them before planning a layout.

## Shared-VM etiquette (project-scoped IAM = no per-VM privacy)
Ownership is a convention, not a mechanism. Label your VMs (`owner=`,
`purpose=`); read freely; ask before state-changing someone else's VM; deploy
only into your own directory on a borrowed box; restore the prior power state;
whoever powers a VM on owns the bill until it is off. NEVER label a borrowed
VM (that keeps it out of your janitor's reach — deliberately).

## Windows client quirks
gcloud.cmd's batch wrapper mangles arguments containing parentheses, `~`, or
` OR ` — route those through PowerShell `cmd /c gcloud ...`, or filter
client-side instead. Full paths beat PATH: shells inherit a stale PATH after
installs, and every "command not found" this month was that.
