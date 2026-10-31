import pathlib
source = pathlib.Path('/Users/dela/.no-mistakes/evidence/01M69T3KBCD1G1QNNJGT8JFA3T/live-timeout-scenarios.py').read_text()
exec(source.split('assert not FIXTURES.exists()')[0])
print('\nDRIVER CORRECTION: the explicit bound is max(ordinary=1, allowance=2), so the expected diagnostic is 2s. Initial failure was in the driver assertion, after the product correctly timed out at 2s. Re-driving with the corrected assertion.', flush=True)
assert not FIXTURES.exists()
FIXTURES.mkdir()
try:
    run_case('explicit-bound', 1, 2, 4)
finally:
    shutil.rmtree(FIXTURES)
