from pathlib import Path
import re
cases = {
    "fm-spawn-dispatch-profile": [
        "test_droid_threads_custom_model_and_dynamic_effort_through_settings",
        "test_droid_observes_default_model_without_pinning_it",
        "test_droid_runtime_model_reconciliation",
        "test_droid_trust_gate",
        "test_droid_refuses_backends_without_viewport_capture",
    ],
    "fm-control-relaunch": [
        "test_same_droid_relaunch_preserves_explicit_dynamic_effort",
        "test_droid_relaunch_follows_requested_selection",
    ],
}
for name, selectors in cases.items():
    src = Path("tests/" + name + ".test.sh").read_text()
    src = "\n".join(line for line in src.splitlines()
        if not re.fullmatch(r"test_[a-zA-Z0-9_]+", line)
        and not line.startswith('echo "# all '))
    Path("tests/.phase-" + name + ".test.sh").write_text(
        src + "\n" + "\n".join(selectors) + "\n")
