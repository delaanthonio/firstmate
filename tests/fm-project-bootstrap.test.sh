#!/usr/bin/env bash
# Dependency detection, override, receipts, locking, and real spawn refusal.
# Managers and terminal delivery are fixtures; Git worktrees and the bootstrap
# executable are real, and no package downloads or model calls are made.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-bootstrap)
BOOTSTRAP="$ROOT/bin/fm-project-bootstrap.sh"

make_case() {
  local name=$1 tool
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJECT_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  LOG="$CASE_DIR/bootstrap.log"
  fm_test_spawn_home "$HOME_DIR" codex
  fm_git_worktree "$PROJECT_DIR" "$WT_DIR" "bootstrap-$name"
  FAKEBIN=$(make_spawn_fakebin "$CASE_DIR/tools")
  fm_test_fake_sleep_noop "$FAKEBIN"
  for tool in mise uv npm cargo bundle; do
    cat >"$FAKEBIN/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s %s cwd=%s\n' "${0##*/}" "$*" "$PWD" >> "$FM_BOOTSTRAP_LOG"
if [ "${FM_BOOTSTRAP_FAIL:-}" = "${0##*/}" ]; then
  echo 'fixture dependency error' >&2
  exit 42
fi
SH
    chmod +x "$FAKEBIN/$tool"
  done
}

run_bootstrap() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_BOOTSTRAP_LOG="$LOG" PATH="$FAKEBIN:$PATH" \
    bash "$BOOTSTRAP" "$PROJECT_DIR" "$WT_DIR" "$@"
}

test_detected_managers_and_worktree_cwd() {
  local marker tool expected out
  for marker in uv.lock mise.toml .mise.toml package-lock.json Cargo.lock Gemfile.lock; do
    make_case "detect-${marker//./-}"
    : >"$WT_DIR/$marker"
    case "$marker" in
      uv.lock) tool='uv sync' ;;
      mise.toml | .mise.toml) tool='mise install' ;;
      package-lock.json) tool='npm ci' ;;
      Cargo.lock) tool='cargo fetch' ;;
      Gemfile.lock) tool='bundle install' ;;
    esac
    out=$(run_bootstrap --fresh 2>&1) || fail "$out"
    expected="$tool cwd=$(cd "$WT_DIR" && pwd -P)"
    [ "$(cat "$LOG")" = "$expected" ] || fail "wrong detection for $marker: $(cat "$LOG")"
    [ ! -e "$PROJECT_DIR/$marker" ] || fail 'bootstrap ran in primary checkout'
  done
  make_case multiple
  touch "$WT_DIR/mise.toml" "$WT_DIR/.mise.toml" "$WT_DIR/uv.lock" "$WT_DIR/package-lock.json"
  run_bootstrap --fresh >/dev/null 2>&1
  [ "$(sed -n '1s/ cwd=.*//p' "$LOG")" = 'mise install' ] || fail 'mise did not run first'
  [ "$(wc -l <"$LOG" | tr -d ' ')" = 3 ] || fail 'matching managers were skipped or duplicated'
  pass 'all lockfile detections run in the worker copy, with mise first'
}

test_override_and_receipt_invalidation() {
  local out
  make_case override
  touch "$WT_DIR/uv.lock" "$WT_DIR/package-lock.json"
  mkdir -p "$WT_DIR/packages/api"
  printf 'base\n' >"$WT_DIR/packages/api/pyproject.toml"
  cat >"$HOME_DIR/config/project-bootstrap.json" <<'JSON'
{"project":{"command":"uv sync --all-groups","markers":["packages/api/pyproject.toml"]}}
JSON
  run_bootstrap --fresh >/dev/null 2>&1
  assert_grep 'uv sync --all-groups' "$LOG" 'override did not replace defaults'
  [ "$(wc -l <"$LOG" | tr -d ' ')" = 1 ] || fail 'detected commands ran with override'
  out=$(run_bootstrap 2>&1)
  assert_contains "$out" 'dependencies unchanged' 'unchanged relaunch repeated sync'
  printf 'changed\n' >>"$WT_DIR/uv.lock"
  run_bootstrap >/dev/null 2>&1
  printf 'changed\n' >>"$WT_DIR/packages/api/pyproject.toml"
  run_bootstrap >/dev/null 2>&1
  rm "$WT_DIR/packages/api/pyproject.toml"
  run_bootstrap >/dev/null 2>&1
  printf 'restored\n' >"$WT_DIR/packages/api/pyproject.toml"
  run_bootstrap >/dev/null 2>&1
  printf '{"project":{"command":"uv sync --all-extras"}}\n' >"$HOME_DIR/config/project-bootstrap.json"
  run_bootstrap >/dev/null 2>&1
  run_bootstrap --fresh >/dev/null 2>&1
  [ "$(wc -l <"$LOG" | tr -d ' ')" = 7 ] || fail 'marker, command, or freshness did not invalidate success'
  pass 'pinned command replaces detection and receipts track changed, added, and removed inputs'
}

test_registered_symlink_name_selects_override() {
  local out
  make_case registered-name
  ln -s "$PROJECT_DIR" "$CASE_DIR/registered project"
  PROJECT_DIR="$CASE_DIR/registered project"
  printf '{"registered project":{"command":"uv sync --all-groups"}}\n' >"$HOME_DIR/config/project-bootstrap.json"
  out=$(run_bootstrap --fresh 2>&1) || fail "$out"
  assert_grep 'uv sync --all-groups' "$LOG" 'logical clone name did not select override'
  pass 'registered names with spaces and symlinked clones select their own override'
}

test_failure_invalidates_success() {
  local out code=0
  make_case retry
  touch "$WT_DIR/uv.lock"
  run_bootstrap --fresh >/dev/null 2>&1
  out=$(FM_BOOTSTRAP_FAIL=uv run_bootstrap --fresh 2>&1) || code=$?
  expect_code 42 "$code" 'bootstrap should preserve dependency exit status'
  assert_contains "$out" 'fixture dependency error' 'dependency diagnostics were lost'
  run_bootstrap >/dev/null 2>&1
  [ "$(wc -l <"$LOG" | tr -d ' ')" = 3 ] || fail 'a failed sync left a reusable success receipt'
  pass 'a failed sync keeps diagnostics and cannot reuse an older success'
}

test_invalid_config_and_no_detection() {
  local invalid out code
  make_case invalid
  for invalid in '{' '{"project":{"command":""}}' \
    '{"project":{"command":"true","markers":["../escape"]}}' \
    '{"project":{"command":"true","unknown":1}}'; do
    printf '%s\n' "$invalid" >"$HOME_DIR/config/project-bootstrap.json"
    code=0
    out=$(run_bootstrap --fresh 2>&1) || code=$?
    [ "$code" -ne 0 ] || fail "accepted invalid config: $invalid"
    assert_contains "$out" 'invalid dependency bootstrap configuration' 'configuration refusal was unclear'
  done
  rm "$HOME_DIR/config/project-bootstrap.json"
  run_bootstrap --fresh >/dev/null 2>&1
  assert_absent "$LOG" 'project without recognized dependencies ran a command'
  pass 'invalid configuration refuses, while a project without markers needs no bootstrap'
}

test_spawn_refuses_before_launch_and_backlog_transition() {
  local id=bootstrap-refusal out code=0 automatic=0 before
  make_case spawn-refusal
  touch "$PROJECT_DIR/uv.lock"
  git -C "$PROJECT_DIR" add uv.lock
  git -C "$PROJECT_DIR" commit -qm 'declare dependencies'
  git -C "$PROJECT_DIR" push -q origin main
  fm_test_spawn_brief "$HOME_DIR" "$id"
  if command -v tasks-axi >/dev/null 2>&1; then
    automatic=1
    # Keep a shimmed tasks-axi runnable under the spawn fixture's empty HOME.
    # All invocations still select this fixture's markdown backlog explicitly.
    printf '#!/usr/bin/env bash\nHOME=%q TASKS_AXI_BACKEND=markdown exec %q "$@"\n' \
      "$HOME" "$(command -v tasks-axi)" >"$FAKEBIN/tasks-axi"
    chmod +x "$FAKEBIN/tasks-axi"
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' >"$HOME_DIR/data/backlog.md"
    printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' >"$HOME_DIR/.tasks.toml"
    tasks-axi add "$id" 'bootstrap refusal' --kind ship --file "$HOME_DIR/data/backlog.md" >/dev/null
  else
    printf 'manual\n' >"$HOME_DIR/config/backlog-backend"
    printf '%s\n' "- [ ] $id queued" >"$HOME_DIR/data/backlog.md"
  fi
  before=$(cat "$HOME_DIR/data/backlog.md")
  out=$(FM_BOOTSTRAP_FAIL=uv FM_BOOTSTRAP_LOG="$LOG" FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" \
    "$id" "$PROJECT_DIR" --mode no-mistakes --yolo off) || code=$?
  [ "$code" -ne 0 ] || fail "spawn launched despite failed sync: $out"
  assert_contains "$out" 'fixture dependency error' 'spawn swallowed the dependency diagnostics'
  assert_contains "$out" "dependency bootstrap refused spawn of $id" 'spawn did not explain refusal'
  assert_absent "$HOME_DIR/state/$id.meta" 'failed bootstrap published metadata'
  assert_absent "$CASE_DIR/launch.log" 'worker launch reached the terminal'
  [ "$(cat "$HOME_DIR/data/backlog.md")" = "$before" ] || fail 'failed bootstrap changed backlog'
  if [ "$automatic" = 1 ]; then
    out=$(tasks-axi show "$id" --file "$HOME_DIR/data/backlog.md")
    assert_contains "$out" 'state: queued' 'refused spawn moved the queued item'
  fi
  pass 'real spawn refuses bootstrap failure before worker delivery or backlog transition'
}

test_spawn_bootstraps_before_successful_launch() {
  local id=bootstrap-success out
  make_case spawn-success
  fm_test_spawn_brief "$HOME_DIR" "$id"
  cat >"$HOME_DIR/config/project-bootstrap.json" <<'JSON'
{"project":{"command":"test ! -s \"$FM_FAKE_LAUNCH_LOG\"; uv sync"}}
JSON
  out=$(FM_BOOTSTRAP_LOG="$LOG" FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" \
    "$id" "$PROJECT_DIR" --scout) || fail "$out"
  assert_grep 'uv sync' "$LOG" 'scout skipped bootstrap'
  assert_present "$CASE_DIR/launch.log" 'successful bootstrap never reached launch'
  assert_present "$HOME_DIR/state/$id.meta" 'successful bootstrap never published task'
  pass 'a scout bootstraps before its launch and then publishes normally'
}

test_concurrent_relaunches_share_success() {
  local first second
  make_case concurrent
  printf '{"project":{"command":"uv sync; /bin/sleep 0.2"}}\n' >"$HOME_DIR/config/project-bootstrap.json"
  run_bootstrap >"$CASE_DIR/first.out" 2>&1 &
  first=$!
  fm_test_track_child "$first"
  run_bootstrap >"$CASE_DIR/second.out" 2>&1 &
  second=$!
  fm_test_track_child "$second"
  wait "$first" || fail "$(cat "$CASE_DIR/first.out")"
  wait "$second" || fail "$(cat "$CASE_DIR/second.out")"
  [ "$(wc -l <"$LOG" | tr -d ' ')" = 1 ] || fail 'concurrent bootstraps ran the same sync twice'
  pass 'concurrent unchanged relaunches serialize and reuse success'
}

test_override_inherits_into_secondmate_config() {
  make_case inheritance
  mkdir -p "$CASE_DIR/secondmate/config"
  printf '{"project":{"command":"uv sync --all-groups"}}\n' >"$HOME_DIR/config/project-bootstrap.json"
  bash -c '. "$1"; propagate_inheritable_config "$2" "$3"' _ \
    "$ROOT/bin/fm-config-inherit-lib.sh" "$HOME_DIR/config" "$CASE_DIR/secondmate/config"
  cmp -s "$HOME_DIR/config/project-bootstrap.json" "$CASE_DIR/secondmate/config/project-bootstrap.json" ||
    fail 'secondmate did not inherit bootstrap configuration'
  pass 'secondmate workers inherit the project bootstrap override'
}

test_detected_managers_and_worktree_cwd
test_override_and_receipt_invalidation
test_registered_symlink_name_selects_override
test_failure_invalidates_success
test_invalid_config_and_no_detection
test_spawn_refuses_before_launch_and_backlog_transition
test_spawn_bootstraps_before_successful_launch
test_concurrent_relaunches_share_success
test_override_inherits_into_secondmate_config
echo '# all fm-project-bootstrap tests passed'
