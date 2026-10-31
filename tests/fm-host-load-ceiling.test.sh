#!/usr/bin/env bash
# Behavior tests for the spawn load ceiling: a machine that declares a
# one-minute load-average ceiling never gets a fresh worker launched while the
# machine's load is above it (bin/fm-host-load-lib.sh owns the contract;
# bin/fm-spawn.sh runs the check).
#
# Every case drives the real bin/fm-spawn.sh against a real project clone with
# an origin, fake tmux and treehouse binaries that log every call, and a real
# markdown backlog when tasks-axi is installed, with the load read from the
# lib's FM_TEST_HOST_LOAD_1M seam so no case depends on how loaded this machine
# is. A deferral is judged by what it left behind - no task record, no rendered
# launch brief, no endpoint, no worktree allocation, and a backlog item still
# queued - never by wording alone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-host-load-ceiling)
DEFER_EXIT=75
HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

# --- fixture ----------------------------------------------------------------

write_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Run the project's suite for $2 under a busy machine.

## Firstmate spec
Exercise the spawn load ceiling.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
}

# A Firstmate home with its own backlog (when tasks-axi is installed) and a
# brief for every named task.
make_home() {  # <home> [task-id...]
  local home=$1 id
  shift
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' codex > "$home/config/crew-harness"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
      > "$home/data/backlog.md"
    cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
  fi
  for id in "$@"; do
    write_brief "$home" "$id"
    add_item "$home" "$id"
  done
}

# A case: one home, a project clone with an origin, fake tmux/treehouse that
# record every call, and the seam load file every spawn reads.
make_case() {  # <name> [task-id...]
  local name=$1 case_dir fakebin
  shift
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/calls.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
window_file="$FM_FAKE_CALL_LOG.window"
case "$*" in
  *"#{pane_current_path}"*)
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  list-windows) [ ! -s "$window_file" ] || cat "$window_file" ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    grep -Fqx -- "$name" "$window_file" 2>/dev/null || printf '%s\n' "$name" >> "$window_file"
    ;;
  kill-window)
    target=
    previous=
    for arg in "$@"; do
      [ "$previous" = -t ] && target=$arg
      previous=$arg
    done
    target=${target##*:}
    target=${target#=}
    grep -Fvx -- "$target" "$window_file" 2>/dev/null > "$window_file.tmp" || true
    mv "$window_file.tmp" "$window_file"
    ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  make_home "$case_dir/home" "$@"
  printf '%s\n' "$case_dir"
}

add_item() {  # <home> <id>
  [ "$HAVE_TASKS_AXI" = 1 ] || return 0
  tasks-axi add "$2" "item for $2" --kind ship --file "$1/data/backlog.md" >/dev/null
}

row_state() {  # <home> <id>
  tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

# The machine's observed one-minute load, through the lib's test seam.
set_load() {  # <load>
  printf '%s\n' "$1" > "$LOAD_FILE"
}

declare_ceiling() {  # <home> <line>...
  local home=$1
  shift
  printf '%s\n' "$@" > "$home/config/spawn-load-ceiling"
}

run_spawn() {  # <case-dir> <home> <pane-path> <args...>
  local case_dir=$1 home=$2 pane=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_TEST_HOST_LOAD_1M="$LOAD_FILE" \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

spawn_ship() {  # <case-dir> <id> <pane-path> [extra-arg...]
  local case_dir=$1 id=$2 pane=$3
  shift 3
  run_spawn "$case_dir" "$case_dir/home" "$pane" "$id" "$case_dir/project" \
    --mode no-mistakes --yolo off "$@"
}

# Everything a deferred spawn must not have created for <id>; <worktrees-before>
# is worktree_list taken before the spawn.
assert_nothing_created() {  # <case-dir> <home> <id> <calls-before> <worktrees-before>
  local case_dir=$1 home=$2 id=$3 before=$4 worktrees=$5 after
  assert_absent "$home/state/$id.meta" "a deferred spawn published a task record for $id"
  assert_absent "$home/data/$id/launch-brief.md" "a deferred spawn rendered a launch brief for $id"
  after=$(call_count "$case_dir")
  [ "$after" -eq "$before" ] ||
    fail "a deferred spawn touched the terminal or worktree pool for $id: $(tail -n +"$((before + 1))" "$case_dir/calls.log")"
  assert_equals "$worktrees" "$(worktree_list "$case_dir")" "a deferred spawn left a git worktree for $id"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    [ "$(row_state "$home" "$id")" = queued ] ||
      fail "a deferred spawn moved $id's backlog item: $(row_state "$home" "$id")"
  fi
}

call_count() { wc -l < "$1/calls.log" | tr -d ' '; }

worktree_list() { git -C "$1/project" worktree list --porcelain; }

# One isolated worktree per spawn, so every admitted launch has its own copy.
new_worktree() {  # <case-dir> <name>
  git -C "$1/project" worktree add --quiet -b "wt-$2" "$1/wt-$2"
  printf '%s\n' "$1/wt-$2"
}

# --- cases ------------------------------------------------------------------

# The reported incident's shape before any declaration: the machine is already
# heavily loaded, and nothing defers a further launch. Absent a ceiling that
# stays true, so today's dispatch is unchanged.
test_unset_ceiling_keeps_dispatch_unchanged() {
  local case_dir home out rc=0
  case_dir=$(make_case unset task-c)
  home="$case_dir/home"
  # make_case runs in a command substitution, so its own assignments die with
  # that subshell; the seam path comes back through the case directory instead.
  LOAD_FILE="$case_dir/load"
  set_load 40
  out=$(spawn_ship "$case_dir" task-c "$(new_worktree "$case_dir" task-c)") || rc=$?
  expect_code 0 "$rc" "a spawn on a machine with no declared ceiling was refused: $out"
  assert_contains "$out" "spawned task-c" "a spawn with no declared ceiling did not launch the worker"
  assert_not_contains "$out" "deferred:" "a spawn with no declared ceiling reported a deferral"
  pass "a machine with no declared load ceiling keeps today's unguarded dispatch"
}

test_load_under_the_ceiling_admits_the_worker() {
  local case_dir home out rc=0
  case_dir=$(make_case under task-c)
  home="$case_dir/home"
  # make_case runs in a command substitution, so its own assignments die with
  # that subshell; the seam path comes back through the case directory instead.
  LOAD_FILE="$case_dir/load"
  declare_ceiling "$home" "# 8 cores; several suites at once stalled validation" "8"
  set_load 4.20
  out=$(spawn_ship "$case_dir" task-c "$(new_worktree "$case_dir" task-c)") || rc=$?
  expect_code 0 "$rc" "a spawn under the load ceiling was refused: $out"
  assert_contains "$out" "spawned task-c" "a spawn under the load ceiling did not launch"
  assert_not_contains "$out" "deferred:" "a spawn under the load ceiling reported a deferral"
  pass "a spawn under the load ceiling is admitted, comments beside the ceiling included"
}

# Strictly above defers, so a spawn at exactly the ceiling is still admitted.
test_load_at_the_ceiling_admits_the_worker() {
  local case_dir home out rc=0
  case_dir=$(make_case at task-c)
  home="$case_dir/home"
  # make_case runs in a command substitution, so its own assignments die with
  # that subshell; the seam path comes back through the case directory instead.
  LOAD_FILE="$case_dir/load"
  declare_ceiling "$home" "8"
  set_load 8.00
  out=$(spawn_ship "$case_dir" task-c "$(new_worktree "$case_dir" task-c)") || rc=$?
  expect_code 0 "$rc" "a spawn at exactly the load ceiling was refused: $out"
  assert_contains "$out" "spawned task-c" "a spawn at exactly the load ceiling did not launch"
  pass "a spawn at exactly the load ceiling is admitted"
}

test_load_over_the_ceiling_defers_without_leaving_anything_behind() {
  local case_dir home out rc=0 before worktrees
  case_dir=$(make_case over task-c)
  home="$case_dir/home"
  # make_case runs in a command substitution, so its own assignments die with
  # that subshell; the seam path comes back through the case directory instead.
  LOAD_FILE="$case_dir/load"
  declare_ceiling "$home" "8"
  set_load 12.5
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a spawn above the load ceiling was not deferred: $out"
  assert_contains "$out" "deferred: the machine's one-minute load average is 12.5, above the spawn load ceiling of 8 ($home/config/spawn-load-ceiling)" \
    "the deferral did not name the observed load, the ceiling, and its declaration"
  assert_contains "$out" "task task-c was not launched and its backlog item stays queued - dispatch it again once the machine's load average falls to or below the ceiling, or launch under load with --allow-over-load" \
    "the deferral did not name the resume condition"
  assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  pass "a spawn above the load ceiling is deferred before any record, brief, endpoint, worktree, or backlog move exists"
}

test_allow_over_load_launches_a_captain_ordered_spawn_under_load() {
  local case_dir home out rc=0
  case_dir=$(make_case bypass task-c)
  home="$case_dir/home"
  # make_case runs in a command substitution, so its own assignments die with
  # that subshell; the seam path comes back through the case directory instead.
  LOAD_FILE="$case_dir/load"
  declare_ceiling "$home" "8"
  set_load 12.5
  out=$(spawn_ship "$case_dir" task-c "$(new_worktree "$case_dir" task-c)" --allow-over-load) || rc=$?
  expect_code 0 "$rc" "a captain-ordered spawn under load was refused: $out"
  assert_contains "$out" "spawned task-c" "a captain-ordered spawn under load did not launch"
  assert_not_contains "$out" "deferred:" "a captain-ordered spawn under load reported a deferral"
  pass "--allow-over-load launches a captain-ordered spawn above the load ceiling"
}

test_malformed_ceiling_refuses_every_spawn() {
  local case_dir home out rc=0
  case_dir=$(make_case malformed task-c)
  home="$case_dir/home"
  # make_case runs in a command substitution, so its own assignments die with
  # that subshell; the seam path comes back through the case directory instead.
  LOAD_FILE="$case_dir/load"
  set_load 4.20
  declare_ceiling "$home" "eight"
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code 1 "$rc" "a malformed load ceiling did not refuse the spawn: $out"
  assert_contains "$out" "the spawn load ceiling declaration is unreadable ($home/config/spawn-load-ceiling holds eight, which is not a positive number)" \
    "a malformed load ceiling was not named in the refusal"
  assert_absent "$home/state/task-c.meta" "a malformed ceiling's spawn published a task record"
  declare_ceiling "$home" "0"
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code 1 "$rc" "a zero load ceiling did not refuse the spawn: $out"
  assert_contains "$out" "which is not a positive number" "a zero load ceiling was not named in the refusal"
  pass "a malformed or zero load ceiling refuses every fresh spawn rather than guessing the limit"
}

test_unreadable_load_source_refuses_a_configured_ceiling() {
  local case_dir home out rc=0
  case_dir=$(make_case nosource task-c)
  home="$case_dir/home"
  # make_case runs in a command substitution, so its own assignments die with
  # that subshell; the seam path comes back through the case directory instead.
  LOAD_FILE="$case_dir/load"
  declare_ceiling "$home" "8"
  rm -f "$LOAD_FILE"
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code 1 "$rc" "a spawn whose load source cannot be read was not refused: $out"
  assert_contains "$out" "the machine's one-minute load average cannot be read" \
    "an unreadable load source was not named in the refusal"
  assert_absent "$home/state/task-c.meta" "an unreadable load source's spawn published a task record"
  # With no ceiling configured the guard is off, so the same unreadable source
  # changes nothing.
  rm -f "$home/config/spawn-load-ceiling"
  rc=0
  out=$(spawn_ship "$case_dir" task-c "$(new_worktree "$case_dir" task-c)") || rc=$?
  expect_code 0 "$rc" "a spawn with no ceiling and an unreadable load source was refused: $out"
  assert_contains "$out" "spawned task-c" "a spawn with no ceiling and an unreadable load source did not launch"
  pass "an unreadable load source refuses only a spawn whose configured ceiling it cannot check"
}

test_allow_over_load_is_refused_where_the_guard_never_runs() {
  local case_dir home out rc=0
  case_dir=$(make_case misuse task-c)
  home="$case_dir/home"
  # make_case runs in a command substitution, so its own assignments die with
  # that subshell; the seam path comes back through the case directory instead.
  LOAD_FILE="$case_dir/load"
  declare_ceiling "$home" "8"
  set_load 12.5
  out=$(run_spawn "$case_dir" "$home" "$case_dir/unused" task-c "$case_dir/project" --secondmate --allow-over-load) || rc=$?
  expect_code 1 "$rc" "a --secondmate spawn with --allow-over-load was not refused: $out"
  assert_contains "$out" "--allow-over-load applies only to a fresh ship or scout spawn" \
    "the --secondmate misuse was not named in the refusal"
  out=$(run_spawn "$case_dir" "$home" "$case_dir/unused" task-c "$case_dir/project" --relaunch --allow-over-load) || rc=$?
  expect_code 1 "$rc" "a --relaunch with --allow-over-load was not refused: $out"
  assert_contains "$out" "--allow-over-load applies only to a fresh ship or scout spawn" \
    "the --relaunch misuse was not named in the refusal"
  pass "--allow-over-load is refused where the load guard could never run"
}

# --- main -------------------------------------------------------------------

test_unset_ceiling_keeps_dispatch_unchanged
test_load_under_the_ceiling_admits_the_worker
test_load_at_the_ceiling_admits_the_worker
test_load_over_the_ceiling_defers_without_leaving_anything_behind
test_allow_over_load_launches_a_captain_ordered_spawn_under_load
test_malformed_ceiling_refuses_every_spawn
test_unreadable_load_source_refuses_a_configured_ceiling
test_allow_over_load_is_refused_where_the_guard_never_runs
