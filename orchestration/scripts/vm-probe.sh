#!/usr/bin/env bash
# vm-probe.sh — prove, from inside the pod, that gcloud acts as you in your GCP project: create the
# smallest machine with our labels, stop it, delete it, and show that nothing is left. One command to
# type in the web terminal; every value comes from the pod's own files:
#   ORCH_GCP_PROJECT, ORCH_VM_PREFIX, ORCH_PROJECT   orchestration/local.env (through orch-env.sh)
#   the zone                                          .devcontainer/devcontainer.json customizations.maestro-k8s.gcpZone, default us-east1-b
#   the owner label                                   gh api user (the GitHub login), lowercased
# Flags: --zone <z> --project <gcp-project> --subnet <name> --dry-run (print the commands, run nothing). With --project,
# a probe that succeeds RECORDS the project as ORCH_GCP_PROJECT in orchestration/local.env when none is recorded yet:
# the moment a programme first needs machines is the moment its default project is chosen, not pod creation.
# The machine is created the way the organisation's policies demand of every machine in a research project
# (docs/GCP.md): no external IP (constraints/compute.vmExternalIpAccess allows named exceptions only) and a
# Shielded VM (constraints/compute.requireShieldedVm). A probe that asked for neither was refused on 8 October 2026.
# It attaches no service account: the machine does nothing, and attaching the project's default one needs
# iam.serviceAccountUser on that account, which is a question for machines that have work to do, not for the probe.
# --subnet is for a project without a `default` network; the refusal names it.
# Kit-only (docs/TUTORIAL.md stage 5.1); not part of the research repository's launchers.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
W=${WORKSPACE:-/workspace}; [ -d "$W" ] || W=$(cd "$HERE/../.." && pwd)
# shellcheck source=/dev/null
. "$HERE/orch-env.sh"; orch_env_load "$W"
ZONE=""; DRY=0; GIVEN=""; SUBNET=""
while [ $# -gt 0 ]; do case "$1" in --zone) ZONE=$2; shift 2;; --project) ORCH_GCP_PROJECT=$2; GIVEN=$2; shift 2;; --subnet) SUBNET=$2; shift 2;; --dry-run) DRY=1; shift;; -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0;; *) echo "vm-probe: unknown flag $1"; exit 2;; esac; done
if [ -z "${ORCH_GCP_PROJECT:-}" ]; then echo "vm-probe: no GCP project recorded yet for this programme; name one: bash orchestration/scripts/vm-probe.sh --project <gcp-project>  (a successful probe records it in orchestration/local.env)"; exit 2; fi
if ! orch_require ORCH_VM_PREFIX ORCH_PROJECT; then exit 2; fi
if [ -z "$ZONE" ] && [ -f "$W/.devcontainer/devcontainer.json" ]; then
  ZONE=$(python3 - "$W/.devcontainer/devcontainer.json" <<'PY'
import json, re, sys
raw = re.sub(r"^\s*//.*$", "", open(sys.argv[1], encoding="utf-8").read(), flags=re.M)
try: print(((json.loads(raw).get("customizations") or {}).get("maestro-k8s") or {}).get("gcpZone") or "")
except Exception: print("")
PY
)
fi
ZONE=${ZONE:-us-east1-b}
OWNER=$(gh api user -q .login 2>/dev/null || echo "${USER:-unknown}"); OWNER=$(printf '%s' "$OWNER" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_\n-' '-')
NAME="${ORCH_VM_PREFIX}probe"
P=(--project "$ORCH_GCP_PROJECT" --zone "$ZONE" --quiet)
NET=(); [ -n "$SUBNET" ] && NET=(--subnet "$SUBNET")
echo "vm-probe: project $ORCH_GCP_PROJECT · zone $ZONE · machine $NAME (e2-micro, no external IP, Shielded VM, no service account${SUBNET:+, subnet $SUBNET}) · labels purpose=$ORCH_PROJECT,owner=$OWNER"
run() { echo "+ gcloud $*"; [ "$DRY" = 1 ] && return 0; out=$(gcloud "$@" 2>&1); rc=$?; [ $rc -ne 0 ] && printf '%s\n' "$out" | tail -3; return $rc; }
if ! run compute instances create "$NAME" "${P[@]}" --machine-type=e2-micro --no-address --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring --no-service-account --no-scopes ${NET[@]+"${NET[@]}"} --labels="purpose=$ORCH_PROJECT,owner=$OWNER"; then
  case "$out" in
    *"Constraint constraints/"*) echo "vm-probe: CREATE refused by an organisation policy, the constraint named above. The probe already asks for what every research project demands, no external IP and a Shielded VM; a constraint beyond those is the project owner's to explain or exempt — not a role on your account, not the pod.";;
    *"networks/default"*) echo "vm-probe: CREATE refused: $ORCH_GCP_PROJECT has no 'default' network. Name a subnet of the zone's region: bash orchestration/scripts/vm-probe.sh --project $ORCH_GCP_PROJECT --subnet <name>  (gcloud compute networks subnets list --project $ORCH_GCP_PROJECT)";;
    *ermission*|*PERMISSION_DENIED*) echo "vm-probe: CREATE refused for a missing role on YOUR account in $ORCH_GCP_PROJECT (roles/compute.instanceAdmin.v1; docs/TUTORIAL.md stage 1.4) — not the pod.";;
    *"not found"*|*"Failed to find"*) echo "vm-probe: CREATE refused: project $ORCH_GCP_PROJECT or zone $ZONE does not exist, or your account does not reach it (a project you cannot see reads as not found).";;
    *) echo "vm-probe: CREATE refused; gcloud's reason is above.";;
  esac; exit 1; fi
if ! run compute instances stop "$NAME" "${P[@]}"; then echo "vm-probe: STOP failed; delete the machine yourself: gcloud compute instances delete $NAME --project $ORCH_GCP_PROJECT --zone $ZONE"; exit 1; fi
if ! run compute instances delete "$NAME" "${P[@]}"; then echo "vm-probe: DELETE failed; the machine $NAME is still there — delete it yourself with the command above."; exit 1; fi
[ "$DRY" = 1 ] && { echo "vm-probe: dry run, nothing created."; exit 0; }
left=$(gcloud compute instances list --project "$ORCH_GCP_PROJECT" --filter="name=$NAME" --format='value(name)' 2>/dev/null)
if [ -z "$left" ]; then echo "VM lifecycle: create, stop, delete all worked — nothing left behind."
  if [ -n "$GIVEN" ] && ! grep -q "^ORCH_GCP_PROJECT=" "$W/orchestration/local.env" 2>/dev/null; then printf 'ORCH_GCP_PROJECT=%s\n' "$GIVEN" >> "$W/orchestration/local.env"; echo "vm-probe: recorded ORCH_GCP_PROJECT=$GIVEN in orchestration/local.env (the default project for this programme's machines; edit it there any time)"; fi
  exit 0
else echo "vm-probe: $NAME still listed after delete; check the console."; exit 1; fi
