#!/usr/bin/env bash
# Dependency detection, override, receipts, locking, and real spawn refusal.
# Managers and terminal delivery are fixtures; Git worktrees and the bootstrap
# executable are real, and no package downloads or model calls are made.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_git_identity

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
if [ "${0##*/}" = mise ] && [ "${1:-}" = exec ]; then
  printf 'mise exec cwd=%s\n' "$PWD" >> "$FM_BOOTSTRAP_LOG"
  shift 2
  FM_BOOTSTRAP_MISE_ACTIVE=1 exec "$@"
fi
printf '%s %s cwd=%s\n' "${0##*/}" "$*" "$PWD" >> "$FM_BOOTSTRAP_LOG"
if [ "${0##*/}" != mise ] && [ "${FM_BOOTSTRAP_EXPECT_MISE:-}" = 1 ] && [ "${FM_BOOTSTRAP_MISE_ACTIVE:-}" != 1 ]; then
  echo 'dependency manager used supervisor toolchain' >&2
  exit 43
fi
if [ "${FM_BOOTSTRAP_FAIL:-}" = "${0##*/}" ]; then
  echo 'fixture dependency error' >&2
  exit 42
fi
[ -z "${FM_BOOTSTRAP_DELAY:-}" ] || /bin/sleep "$FM_BOOTSTRAP_DELAY"
case "${0##*/}" in
  uv) mkdir -p .venv ;;
  npm) mkdir -p node_modules ;;
esac
SH
    chmod +x "$FAKEBIN/$tool"
  done
}

run_bootstrap() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_BOOTSTRAP_LOG="$LOG" PATH="$FAKEBIN:$PATH" \
    bash "$BOOTSTRAP" "$PROJECT_DIR" "$WT_DIR"
}

test_detected_managers_and_worktree_cwd() {
  local marker tool expected out
  for marker in uv.lock mise.toml .mise.toml package-lock.json Cargo.lock Gemfile.lock; do
    make_case "detect-${marker//./-}"
    : >"$WT_DIR/$marker"
    case "$marker" in
      uv.lock) tool='uv sync'; touch "$WT_DIR/pyproject.toml" ;;
      mise.toml | .mise.toml) tool='mise install' ;;
      package-lock.json) tool='npm ci'; touch "$WT_DIR/package.json" ;;
      Cargo.lock) tool='cargo fetch'; touch "$WT_DIR/Cargo.toml" ;;
      Gemfile.lock) tool='bundle install'; touch "$WT_DIR/Gemfile" ;;
    esac
    out=$(run_bootstrap 2>&1) || fail "$out"
    expected="$tool cwd=$(cd "$WT_DIR" && pwd -P)"
    [ "$(cat "$LOG")" = "$expected" ] || fail "wrong detection for $marker: $(cat "$LOG")"
    [ ! -e "$PROJECT_DIR/$marker" ] || fail 'bootstrap ran in primary checkout'
  done
  for marker in mise.toml .mise.toml; do
    make_case "multiple-${marker//./-}"
    touch "$WT_DIR/$marker" "$WT_DIR/uv.lock" "$WT_DIR/package-lock.json" "$WT_DIR/Cargo.lock" "$WT_DIR/Gemfile.lock"
    out=$(FM_BOOTSTRAP_EXPECT_MISE=1 run_bootstrap 2>&1) || fail "$out"
    [ "$(sed -n '1s/ cwd=.*//p' "$LOG")" = 'mise install' ] || fail 'mise did not run first'
    assert_grep 'mise exec cwd=' "$LOG" 'mise environment was not entered'
    [ "$(wc -l <"$LOG" | tr -d ' ')" = 6 ] || fail 'matching managers were skipped or duplicated'
  done
  pass 'all detected managers run in the worker copy and use either mise configuration'
}

test_receipt_output_and_input_invalidation() {
  local out output
  make_case receipts
  touch "$WT_DIR/uv.lock" "$WT_DIR/package-lock.json"
  run_bootstrap >/dev/null 2>&1
  out=$(run_bootstrap 2>&1)
  assert_contains "$out" 'dependencies unchanged' 'unchanged relaunch repeated sync'
  for output in .venv node_modules; do
    rm -rf "${WT_DIR:?}/${output:?}"
    run_bootstrap >/dev/null 2>&1
    assert_present "$WT_DIR/$output" 'missing dependency output did not force sync'
  done
  printf 'changed\n' >>"$WT_DIR/uv.lock"
  run_bootstrap >/dev/null 2>&1
  printf '{}\n' >"$WT_DIR/package.json"
  run_bootstrap >/dev/null 2>&1
  rm "$WT_DIR/package.json"
  run_bootstrap >/dev/null 2>&1
  [ "$(wc -l <"$LOG" | tr -d ' ')" = 12 ] || fail 'output deletion or input change did not invalidate success'
  pass 'receipts require every output directory and unchanged, added, and removed inputs'
}

test_commands_without_known_local_outputs_rerun() {
  local marker
  for marker in Cargo.lock Gemfile.lock mise.toml; do
    make_case "uncached-${marker//./-}"
    touch "$WT_DIR/$marker"
    run_bootstrap >/dev/null 2>&1
    run_bootstrap >/dev/null 2>&1
    [ "$(wc -l <"$LOG" | tr -d ' ')" = 2 ] || fail "$marker reused an unverifiable output"
  done
  make_case override
  touch "$WT_DIR/pnpm-lock.yaml" "$WT_DIR/package.json"
  printf '{"project":{"command":"uv sync --all-groups"}}\n' >"$HOME_DIR/config/project-bootstrap.json"
  run_bootstrap >/dev/null 2>&1
  run_bootstrap >/dev/null 2>&1
  assert_grep 'uv sync --all-groups' "$LOG" 'override did not replace defaults'
  [ "$(wc -l <"$LOG" | tr -d ' ')" = 2 ] || fail 'custom bootstrap reused an unverifiable output'
  pass 'global-output managers, toolchain-only projects, and overrides rerun on relaunch'
}

test_registered_symlink_name_selects_override() {
  local out
  make_case registered-name
  ln -s "$PROJECT_DIR" "$CASE_DIR/registered project"
  PROJECT_DIR="$CASE_DIR/registered project"
  printf '{"registered project":{"command":"uv sync --all-groups"}}\n' >"$HOME_DIR/config/project-bootstrap.json"
  out=$(run_bootstrap 2>&1) || fail "$out"
  assert_grep 'uv sync --all-groups' "$LOG" 'logical clone name did not select override'
  pass 'registered names with spaces and symlinked clones select their own override'
}

test_failure_invalidates_success() {
  local out code=0
  make_case retry
  touch "$WT_DIR/uv.lock"
  run_bootstrap >/dev/null 2>&1
  rm -rf "$WT_DIR/.venv"
  out=$(FM_BOOTSTRAP_FAIL=uv run_bootstrap 2>&1) || code=$?
  expect_code 42 "$code" 'bootstrap should preserve dependency exit status'
  assert_contains "$out" 'fixture dependency error' 'dependency diagnostics were lost'
  mkdir -p "$WT_DIR/.venv"
  run_bootstrap >/dev/null 2>&1
  [ "$(wc -l <"$LOG" | tr -d ' ')" = 3 ] || fail 'a failed sync left a reusable success receipt'
  pass 'a failed sync keeps diagnostics and cannot reuse an older success'
}

test_invalid_config_and_no_detection() {
  local invalid out code manifest mixed
  make_case invalid
  for invalid in '{' '{"project":{"command":""}}' \
    '{"project":{"command":"true","markers":["input"]}}' \
    '{"project":{"command":"true","unknown":1}}'; do
    printf '%s\n' "$invalid" >"$HOME_DIR/config/project-bootstrap.json"
    code=0
    out=$(run_bootstrap 2>&1) || code=$?
    [ "$code" -ne 0 ] || fail "accepted invalid config: $invalid"
    assert_contains "$out" 'invalid dependency bootstrap configuration' 'configuration refusal was unclear'
  done
  rm "$HOME_DIR/config/project-bootstrap.json"
  run_bootstrap >/dev/null 2>&1
  assert_absent "$LOG" 'dependency-free project ran a command'
  for mixed in no yes; do
    for manifest in pyproject.toml package.json Cargo.toml Gemfile pnpm-lock.yaml yarn.lock \
      bun.lock bun.lockb npm-shrinkwrap.json requirements.txt requirements-dev.txt \
      Pipfile Pipfile.lock poetry.lock setup.py setup.cfg go.mod go.sum composer.json composer.lock; do
      make_case "unresolved-$mixed-${manifest//./-}"
      touch "$WT_DIR/$manifest"
      [ "$manifest" != pnpm-lock.yaml ] || touch "$WT_DIR/package.json" "$WT_DIR/package-lock.json"
      [ "$mixed" = no ] || touch "$WT_DIR/mise.toml"
      code=0
      out=$(run_bootstrap 2>&1) || code=$?
      [ "$code" -ne 0 ] || fail "unresolved $manifest launched (mise=$mixed)"
      assert_contains "$out" "$manifest" 'refusal did not name the manifest'
      assert_contains "$out" 'project-bootstrap.json' 'refusal did not name the configuration remedy'
      assert_absent "$LOG" 'unresolved dependencies started a partial bootstrap'
    done
  done
  pass 'only dependency-free projects no-op; unresolved families refuse even with other detected commands'
}

test_nested_layouts_require_override() {
  local mode layout manifest out code
  for mode in empty cached; do
    make_case "nested-$mode"
    if [ "$mode" = cached ]; then
      touch "$WT_DIR/uv.lock"
      run_bootstrap >/dev/null 2>&1
    fi
    for layout in frontend 'packages/api service'; do
      mkdir -p "$WT_DIR/$layout"
      for manifest in uv.lock package-lock.json Cargo.lock Gemfile.lock \
        pyproject.toml package.json Cargo.toml Gemfile pnpm-lock.yaml yarn.lock \
        bun.lock bun.lockb npm-shrinkwrap.json requirements.txt requirements-dev.txt \
        Pipfile Pipfile.lock poetry.lock setup.py setup.cfg go.mod go.sum composer.json composer.lock; do
        touch "$WT_DIR/$layout/$manifest"
        code=0
        out=$(run_bootstrap 2>&1) || code=$?
        [ "$code" -ne 0 ] || fail "nested $layout/$manifest bypassed bootstrap (mode=$mode)"
        assert_contains "$out" "$layout/$manifest" 'refusal did not identify the nested layout'
        assert_contains "$out" 'project-bootstrap.json' 'nested refusal omitted the override remedy'
        rm "$WT_DIR/$layout/$manifest"
      done
    done
    if [ "$mode" = empty ]; then
      assert_absent "$LOG" 'nested refusal ran a dependency command'
    else
      out=$(run_bootstrap 2>&1) || fail "$out"
      assert_contains "$out" 'dependencies unchanged' 'removing the unresolved layout broke valid receipt reuse'
      [ "$(wc -l <"$LOG" | tr -d ' ')" = 1 ] || fail 'nested validation ran a partial bootstrap'
    fi
    mkdir -p "$WT_DIR/frontend"
    touch "$WT_DIR/frontend/package.json" "$WT_DIR/frontend/package-lock.json"
    printf '{"project":{"command":"cd frontend; npm ci"}}\n' >"$HOME_DIR/config/project-bootstrap.json"
    out=$(run_bootstrap 2>&1) || fail "$out"
    assert_present "$WT_DIR/frontend/node_modules" 'explicit nested bootstrap did not run in the declared directory'
  done
  pass 'nested layouts require an override before no-op, root bootstrap, or cached receipt reuse'
}

test_scan_scope_exclusions() {
  local layout out
  make_case scan-scope
  for layout in .hidden .venv node_modules vendor lib/.hidden lib/.venv lib/node_modules lib/vendor deep/a/b; do
    mkdir -p "$WT_DIR/$layout"
    touch "$WT_DIR/$layout/package.json"
  done
  ln -s deep/a/b "$WT_DIR/linked-layout"
  out=$(run_bootstrap 2>&1) || fail "$out"
  assert_absent "$LOG" 'excluded directories or deeper layouts triggered bootstrap'
  pass 'layout scanning stops after two directory levels and skips hidden, dependency, and symlink directories'
}

test_setuptools_companions_use_uv() {
  local out
  make_case setuptools
  touch "$WT_DIR/pyproject.toml" "$WT_DIR/uv.lock" "$WT_DIR/setup.py" "$WT_DIR/setup.cfg"
  out=$(run_bootstrap 2>&1) || fail "$out"
  assert_present "$WT_DIR/.venv" 'setuptools companions prevented the resolved uv bootstrap'
  out=$(run_bootstrap 2>&1) || fail "$out"
  assert_contains "$out" 'dependencies unchanged' 'unchanged setuptools layout did not reuse its receipt'
  printf 'changed\n' >>"$WT_DIR/setup.py"
  run_bootstrap >/dev/null 2>&1
  printf 'changed\n' >>"$WT_DIR/setup.cfg"
  run_bootstrap >/dev/null 2>&1
  rm "$WT_DIR/setup.py"
  run_bootstrap >/dev/null 2>&1
  rm "$WT_DIR/setup.cfg"
  run_bootstrap >/dev/null 2>&1
  touch "$WT_DIR/setup.py"
  run_bootstrap >/dev/null 2>&1
  touch "$WT_DIR/setup.cfg"
  run_bootstrap >/dev/null 2>&1
  [ "$(wc -l <"$LOG" | tr -d ' ')" = 7 ] || fail 'setuptools changes, removals, or additions did not invalidate the receipt'
  pass 'uv bootstraps setuptools companion files and fingerprints both representations'
}

test_spawn_refuses_before_launch_and_backlog_transition() {
  local id out code automatic before scenario
  for scenario in command unresolved nested; do
    id="bootstrap-refusal-$scenario"
    code=0
    automatic=0
    make_case "spawn-refusal-$scenario"
    if [ "$scenario" = command ]; then
      touch "$PROJECT_DIR/uv.lock"
    elif [ "$scenario" = unresolved ]; then
      touch "$PROJECT_DIR/package.json" "$PROJECT_DIR/pnpm-lock.yaml"
    else
      mkdir -p "$PROJECT_DIR/frontend"
      touch "$PROJECT_DIR/frontend/package.json" "$PROJECT_DIR/frontend/package-lock.json"
    fi
    git -C "$PROJECT_DIR" add .
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
    if [ "$scenario" = command ]; then
      assert_contains "$out" 'fixture dependency error' 'spawn swallowed the dependency diagnostics'
    else
      assert_contains "$out" 'project-bootstrap.json' 'spawn did not name the missing bootstrap command configuration'
    fi
    assert_contains "$out" "dependency bootstrap refused spawn of $id" 'spawn did not explain refusal'
    assert_absent "$HOME_DIR/state/$id.meta" 'failed bootstrap published metadata'
    assert_absent "$CASE_DIR/launch.log" 'worker launch reached the terminal'
    [ "$(cat "$HOME_DIR/data/backlog.md")" = "$before" ] || fail 'failed bootstrap changed backlog'
    if [ "$automatic" = 1 ]; then
      out=$(tasks-axi show "$id" --file "$HOME_DIR/data/backlog.md")
      assert_contains "$out" 'state: queued' 'refused spawn moved the queued item'
    fi
  done
  pass 'real spawn refuses failed sync and unresolved manifests before worker delivery or backlog transition'
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
  touch "$WT_DIR/uv.lock"
  FM_BOOTSTRAP_DELAY=0.2 run_bootstrap >"$CASE_DIR/first.out" 2>&1 &
  first=$!
  fm_test_track_child "$first"
  FM_BOOTSTRAP_DELAY=0.2 run_bootstrap >"$CASE_DIR/second.out" 2>&1 &
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
test_receipt_output_and_input_invalidation
test_commands_without_known_local_outputs_rerun
test_registered_symlink_name_selects_override
test_failure_invalidates_success
test_invalid_config_and_no_detection
test_nested_layouts_require_override
test_scan_scope_exclusions
test_setuptools_companions_use_uv
test_spawn_refuses_before_launch_and_backlog_transition
test_spawn_bootstraps_before_successful_launch
test_concurrent_relaunches_share_success
test_override_inherits_into_secondmate_config
echo '# all fm-project-bootstrap tests passed'
