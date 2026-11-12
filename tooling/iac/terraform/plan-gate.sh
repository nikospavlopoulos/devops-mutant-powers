#!/usr/bin/env bash
# plan-gate.sh — CI gate: fail when a saved Terraform plan deletes, replaces or forgets protected resources.
# Usage:   terraform plan -input=false -out=tfplan && terraform show -json tfplan > plan.json
#          plan-gate.sh plan.json
# Exit:    0 = only allowed changes · 1 = a change needs a human · 2 = unusable input (fail closed)
# Needs:   bash + jq. Reads resource_changes[].change.actions from the JSON plan representation (format 1.x).
set -euo pipefail

# CHANGE: resource types whose delete / replace / forget always stops the pipeline (regex on the type name)
PROTECTED_TYPES_REGEX="${PROTECTED_TYPES_REGEX:-(^|_)(instance|virtual_machine|virtual_machine_scale_set|server|cluster|lb|elb|load_balancer|forwarding_rule|public_ip|eip|address|floating_ip|primary_ip|vpc|network|virtual_network|subnet|subnetwork|disk|managed_disk|ebs_volume|volume|secret|key_vault|kms_key|dns_zone|route53_zone|dns_managed_zone|zone|bucket|storage_account|db_instance|rds_cluster|flexible_server|database)($|_)}"
# CHANGE: action sets that pass unreviewed (each set comma-joined, sets space-separated)
ALLOWED_ACTIONS="${ALLOWED_ACTIONS:-no-op read create update}"
# CHANGE: true lets delete/replace of NON-protected types pass (still printed as REVIEW)
ALLOW_UNPROTECTED_DELETE="${ALLOW_UNPROTECTED_DELETE:-false}"
# CHANGE: true also prints unchanged (no-op) resources
SHOW_NOOP="${SHOW_NOOP:-false}"

die() { echo "plan-gate: $*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq not found"
[ "$#" -eq 1 ] || die "usage: plan-gate.sh <plan.json>"
plan=$1
[ -r "$plan" ] || die "cannot read '$plan'"
case $ALLOW_UNPROTECTED_DELETE in true|false) ;; *) die "ALLOW_UNPROTECTED_DELETE must be true or false" ;; esac

jq -e 'type == "object"' "$plan" >/dev/null 2>&1 || die "'$plan' is not a JSON object (did terraform show -json fail?)"
jq -n --arg r "$PROTECTED_TYPES_REGEX" '"" | test($r)' >/dev/null 2>&1 || die "PROTECTED_TYPES_REGEX is not a valid regex"

meta=$(jq -r '[(.format_version // "?"), (.terraform_version // "?"), ((.errored // false) | tostring),
  ((has("planned_values") or has("resource_changes")) | tostring), ((.resource_drift // []) | length | tostring)] | @tsv' "$plan")
IFS=$'\t' read -r fmt tfver errored isplan drift <<<"$meta"
[ "$isplan" = true ] || die "no planned_values/resource_changes: pass the JSON of a saved PLAN, not of state"
[ "$errored" = false ] || die "plan errored: fix the plan first, there is nothing to gate"
case $fmt in 1.*) ;; *) die "unsupported format_version '$fmt' (gate written for 1.x)" ;; esac

# One TSV row per resource instance: verdict, actions, address, action_reason
rows=$(jq -r --arg ok "$ALLOWED_ACTIONS" --arg prot "$PROTECTED_TYPES_REGEX" '
  ($ok | split(" ") | map(select(length > 0))) as $okset
  | ["no-op", "create", "read", "update", "delete", "forget"] as $known
  | (.resource_changes // [])[]
  | (.change.actions // ["missing"]) as $a
  | ($a | join(",")) as $as
  | (if .mode == "data" then "OK"
     elif ($a | any(. == "delete" or . == "forget")) and ((.type // "") | test($prot)) then "HARD_STOP"
     elif ($okset | any(. == $as)) then "OK"
     elif ($a | all(. as $x | $known | any(. == $x)) | not) then "UNKNOWN"
     elif ((.type // "") | test($prot)) then "HARD_STOP"
     else "REVIEW" end) as $v
  | [$v, $as, (.address // "?"), (.action_reason // "-")] | @tsv' "$plan") ||
  die "cannot evaluate resource_changes in '$plan' (malformed plan JSON)"

ok=0 review=0 hard=0 unknown=0
printf '%-10s %-14s %s\n' VERDICT ACTIONS ADDRESS
while IFS=$'\t' read -r v as addr reason; do
  [ -n "$v" ] || continue
  case $v in
    OK) ok=$((ok + 1)) ;;
    REVIEW) review=$((review + 1)) ;;
    HARD_STOP) hard=$((hard + 1)) ;;
    *) unknown=$((unknown + 1)) ;;
  esac
  if [ "$as" = no-op ] && [ "$SHOW_NOOP" != true ]; then continue; fi
  note=""
  if [ "$reason" != "-" ]; then note="  ($reason)"; fi
  printf '%-10s %-14s %s%s\n' "$v" "$as" "$addr" "$note"
done <<<"$rows"

echo "---"
echo "plan-gate: terraform $tfver, format $fmt: ok=$ok review=$review hard_stop=$hard unknown=$unknown, drifted=$drift"
blocking=$((hard + unknown))
if [ "$ALLOW_UNPROTECTED_DELETE" != true ]; then blocking=$((blocking + review)); fi
if [ "$blocking" -gt 0 ]; then
  echo "RESULT: FAIL - $blocking change(s) need a human. Read the plan; apply only this reviewed plan file from the manual job."
  exit 1
fi
echo "RESULT: PASS"
