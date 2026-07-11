#!/usr/bin/env bash
set -euo pipefail

mode="${UPGRADE_STUB_MODE:-ok}"
if [ -n "${UPGRADE_STUB_LOG:-}" ]; then
  printf '%s\t%s\n' "$PWD" "$*" >> "$UPGRADE_STUB_LOG"
fi

if [ "$mode" = stderr ]; then
  echo "unexpected adapter diagnostic" >&2
fi

workspace_schema=workbench/v1
workspace_source=implicit
if [ "$(cat .workbench/schema 2>/dev/null || true)" = "workbench/v2" ]; then
  workspace_schema=workbench/v2
  workspace_source=marker
fi

case "$*" in
  "contract show --format json")
    root="$PWD"
    [ "$mode" != bad-root ] || root="$PWD/other"
    if [ "$mode" = duplicate-json ]; then
      printf '{"contract_version":"workbench-contract/v1","contract_version":"workbench-contract/v1"}\n'
      exit 0
    fi
    extra=""
    [ "$mode" != extra-field ] || extra=',"future_field":{"accepted":true}'
    bootstrap_supported=',"bootstrap_authority_approval_contracts":["workbench-bootstrap-authority-approval/v1"]'
    [ "$mode" != missing-bootstrap-contract ] || bootstrap_supported=''
    bootstrap_capability=',"workspace.legacy-inventory-bootstrap/v1"'
    [ "$mode" != missing-bootstrap-capability ] || bootstrap_capability=''
    printf '{"contract_version":"workbench-contract/v1","engine":{"name":"workbench","version":"0.2.0"},"workspace":{"root":"%s","schema":"%s","source":"%s"},"supported":{"workspace_schemas":{"read":["workbench/v1","workbench/v2"],"write":["workbench/v2"]},"legacy_inventory_contracts":["workbench-legacy-inventory/v1"]%s},"capabilities":["workspace.schema/v1","workspace.doctor/v1","workspace.legacy-inventory/v1"%s]%s}\n' \
      "$root" "$workspace_schema" "$workspace_source" "$bootstrap_supported" \
      "$bootstrap_capability" "$extra"
    ;;
  "doctor --format json")
    if [ "$mode" = doctor-bad-exit ]; then
      printf '{"contract_version":"workbench-doctor/v1","ready":false,"writer_coordination":{"blocker":{"code":"writer-lock-unavailable","ref":"refs/heads/workbench-coordination/writer-claims"}}}\n'
      exit 2
    fi
    if [ "$workspace_schema" = workbench/v2 ] \
      && [ "$mode" != doctor-not-ready ] && [ "$mode" != staged-v2 ]; then
      ready=true
      status=0
    else
      ready=false
      status=1
    fi
    doctor_extra=''
    [ "$mode" != doctor-extra ] || doctor_extra=',"future":true'
    if [ "$ready" = true ]; then
      printf '{"contract_version":"workbench-doctor/v1","ready":true,"writer_coordination":{"authority_identity":"github:example/workbench","origin_url":"https://github.com/example/workbench.git","default_ref":"refs/heads/main","default_ref_revision":"1111111111111111111111111111111111111111","default_ref_protected":true,"descriptor_digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","ref":"refs/heads/workbench-coordination/writer-claims","revision":null,"readable":true,"legacy_inventory_readable":true,"push_permission":"allowed","permission_source":"github:repository/example/workbench","push_ready":true,"blocker":null%s}}\n' "$doctor_extra"
    else
      printf '{"contract_version":"workbench-doctor/v1","ready":false,"writer_coordination":{"authority_identity":null,"origin_url":null,"default_ref":null,"default_ref_revision":null,"default_ref_protected":false,"descriptor_digest":null,"ref":"refs/heads/workbench-coordination/writer-claims","revision":null,"readable":false,"legacy_inventory_readable":false,"push_permission":"unknown","permission_source":null,"push_ready":false,"blocker":{"code":"writer-lock-unavailable","ref":"refs/heads/workbench-coordination/writer-claims"}%s}}\n' "$doctor_extra"
    fi
    exit "$status"
    ;;
  "legacy-inventory show --format json"|legacy-inventory\ bootstrap-show\ --authority-approval-file\ *\ --format\ json)
    if [ "${2:-}" = bootstrap-show ]; then
      [ "$workspace_schema" = workbench/v1 ] || [ "$mode" = staged-v2 ] || exit 92
      [ "${4:-}" = "${UPGRADE_STUB_APPROVAL_FILE:-}" ] || exit 92
      [ -f "${4:-}" ] || exit 92
    else
      [ "$workspace_schema" = workbench/v2 ] || exit 92
    fi
    complete=true
    blockers='[]'
    pagination_complete=true
    failure=null
    status=0
    if [ "$mode" = inventory-incomplete ]; then
      complete=false
      blockers='[{"code":"legacy-writer-source-unavailable","ref":"workbench:home/workbench"}]'
      pagination_complete=false
      failure='{"code":"pagination-incomplete","ref":"workbench:home/workbench","cursor":"cursor-2"}'
      status=1
    fi
    printf '{"contract_version":"workbench-legacy-inventory/v1","source_revision":"1111111111111111111111111111111111111111","authority":{"authority_identity":"github:example/workbench","default_ref":"refs/heads/main","default_revision":"1111111111111111111111111111111111111111","descriptor_digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","bootstrap_revision":"0000000000000000000000000000000000000000"},"home_set":{"contract_version":"workbench-legacy-home-set/v1","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","source_revision":"1111111111111111111111111111111111111111"},"homes":[{"home":"workbench","origin_url":"https://github.com/example/workbench.git","membership":"current","pagination":{"complete":%s,"pages_fetched":1,"end_cursor":null,"failure":%s},"claims":[{"claim_id":"task__workbench__40-cleaned","task_claim_id":"task__workbench__40-cleaned","task_contract":"workbench-task/v1","issue":40,"home":"workbench","parent":null,"branch":"task/40-cleaned","lifecycle_digest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","lifecycle_state":"task-cleaned","classification":"cleaned-v1","submission":null,"source_revision":null,"pr_head_revision":null,"ancestry_complete":false,"repos":[]},{"claim_id":"task__workbench__55-legacy","task_claim_id":"task__workbench__55-legacy","task_contract":"workbench-task/v1","issue":55,"home":"workbench","parent":null,"branch":"task/55-legacy","lifecycle_digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","lifecycle_state":"task-claimed","classification":"active-v1","submission":null,"source_revision":"2222222222222222222222222222222222222222","pr_head_revision":null,"ancestry_complete":true,"repos":[]}]}],"active_claims":[],"origin_replacements":[{"home":"workbench","previous_origin_url":"https://github.com/example/workbench.git","current_origin_url":"https://github.com/example/workbench.git","status":"unchanged"}],"complete":%s,"blockers":%s}\n' \
      "$pagination_complete" "$failure" "$complete" "$blockers"
    exit "$status"
    ;;
  *) exit 92 ;;
esac
