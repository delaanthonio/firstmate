#!/usr/bin/env bash
# Executable registration tests for Droid's tracked primary project settings.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SETTINGS="$ROOT/.factory/settings.json"
TMP_ROOT=$(fm_test_tmproot fm-droid-primary)

[ -f "$SETTINGS" ] || fail "tracked Droid primary settings are missing"

test_registration_inventory() {
  jq -e '
    (.hooks.SessionStart | length) == 1 and
    (.hooks.PreToolUse | length) == 1 and
    (.hooks.Stop | length) == 1 and
    .hooks.PreToolUse[0].matcher == "Execute" and
    any(.hooks.SessionStart[0].hooks[]; .command | contains("fm-sessionstart-run.sh")) and
    any(.hooks.PreToolUse[0].hooks[]; .command | contains("fm-arm-pretool-check.sh")) and
    any(.hooks.Stop[0].hooks[]; .command | contains("fm-turnend-guard.sh"))
  ' "$SETTINGS" >/dev/null \
    || fail "Droid settings do not carry the one SessionStart, Execute PreToolUse, and Stop primary registration"
  pass "Droid primary settings register the three verified hook transports"
}

make_probe_root() {
  local dir=$1 script
  mkdir -p "$dir/bin"
  for script in fm-sessionstart-run.sh fm-arm-pretool-check.sh fm-turnend-guard.sh; do
    cat > "$dir/bin/$script" <<'SH'
#!/usr/bin/env bash
payload=$(cat)
printf '%s\t%s\n' "${0##*/}" "$payload" >> "$DROID_PROBE_LOG"
case "${0##*/}" in
  fm-sessionstart-run.sh) printf '%s\n' DROID_SESSIONSTART_OUTPUT ;;
  fm-arm-pretool-check.sh) printf '%s\n' DROID_PRETOOL_DENY >&2; exit 2 ;;
  fm-turnend-guard.sh) printf '%s\n' DROID_STOP_BLOCK >&2; exit 2 ;;
esac
SH
    chmod +x "$dir/bin/$script"
  done
}

run_registered_hook() {  # <event> <payload> <root> <log>
  local event=$1 payload=$2 root=$3 log=$4 command
  command=$(jq -r --arg event "$event" '.hooks[$event][0].hooks[0].command' "$SETTINGS")
  printf '%s' "$payload" | DROID_PROJECT_DIR="$root" DROID_PROBE_LOG="$log" bash -c "$command"
}

test_commands_anchor_and_preserve_transport() {
  local root="$TMP_ROOT/root" log="$TMP_ROOT/invoked" payload out status
  make_probe_root "$root"

  payload='{"hook_event_name":"SessionStart","source":"startup"}'
  out=$(run_registered_hook SessionStart "$payload" "$root" "$log")
  [ "$out" = DROID_SESSIONSTART_OUTPUT ] \
    || fail "Droid SessionStart registration did not preserve hook stdout"

  payload='{"hook_event_name":"PreToolUse","tool_name":"Execute","tool_input":{"command":"bin/fm-watch-arm.sh &"}}'
  set +e
  out=$(run_registered_hook PreToolUse "$payload" "$root" "$log" 2>&1)
  status=$?
  set -e
  expect_code 2 "$status" "Droid PreToolUse registration must preserve checker exit 2"
  [ "$out" = DROID_PRETOOL_DENY ] \
    || fail "Droid PreToolUse registration did not preserve checker stderr"

  payload='{"hook_event_name":"Stop","stop_hook_active":false}'
  set +e
  out=$(run_registered_hook Stop "$payload" "$root" "$log" 2>&1)
  status=$?
  set -e
  expect_code 2 "$status" "Droid Stop registration must preserve guard exit 2"
  [ "$out" = DROID_STOP_BLOCK ] \
    || fail "Droid Stop registration did not preserve guard stderr"

  grep -Fqx $'fm-sessionstart-run.sh\t{"hook_event_name":"SessionStart","source":"startup"}' "$log" \
    || fail "Droid SessionStart command did not pass the exact payload"
  grep -Fqx $'fm-arm-pretool-check.sh\t{"hook_event_name":"PreToolUse","tool_name":"Execute","tool_input":{"command":"bin/fm-watch-arm.sh &"}}' "$log" \
    || fail "Droid PreToolUse command did not pass the exact payload"
  grep -Fqx $'fm-turnend-guard.sh\t{"hook_event_name":"Stop","stop_hook_active":false}' "$log" \
    || fail "Droid Stop command did not pass the exact payload"
  pass "Droid tracked hook commands anchor through DROID_PROJECT_DIR and preserve stdin, output, and status"
}

test_registration_inventory
test_commands_anchor_and_preserve_transport
