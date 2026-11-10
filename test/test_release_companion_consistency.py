"""Release companion list consistency across the four hand-maintained copies.

task-3500.  The v0.70.0 RC run 42689442386 failed installation on all four
platforms because #50360 added ``masc-antigravity-path-hook`` to the packager
``NAMES`` while the installer-receipt parser allowlist still accepted four
names, and no test asserted that the copies agree: the release pipeline itself
was the first reader of the mismatch (release-build.yml is workflow_call-only,
so #50360's PR CI never ran the release checks, and step 34 of the RC run died
on ``installed_release`` ``invalid_receipt``).  #50773 repaired the parser and
#50782 repaired the publication gate; this suite keeps the four copies from
drifting apart again:

  1. scripts/package-macos-runtime.py ``NAMES`` - every binary the packager
     stages and republishes as ``<name>-<platform>``
  2. scripts/install-smoke.sh - the post-install executables loop and the
     literal ``ASSETS`` required per platform
  3. scripts/ci/prepare-release-publication.py - ``PLATFORMS`` and the
     ``validate_distribution`` expected asset set
  4. lib/installed_dashboard.ml - the closed ``parse_companions`` allowlist

Assertions:

  * every packaged binary is checked by the install smoke executables loop;
  * every smoke-checked executable and every literal smoke ``ASSETS`` entry
    appears in the publication gate's expected set for every release platform;
  * the receipt companions - the packaged binaries minus the primary ``masc``
    binary, which ships as ``binary_asset`` and not as a companion - equal the
    parser allowlist in both directions, so a name can neither go missing
    (``Invalid_receipt`` again) nor linger without shipping.
"""
import argparse
import ast
import re
import sys
import unittest
from pathlib import Path

PACKAGER_NAMES = []
SMOKE_EXECUTABLES = []
SMOKE_ASSETS = []
GATE_PLATFORMS = []
GATE_EXPECTED = set()
PARSER_ALLOWLIST = []


def _checked(path, label, names):
    if not names or any(not isinstance(name, str) or not name for name in names):
        raise AssertionError(f'{path}: {label} did not parse into non-empty strings: {names!r}')
    if len(set(names)) != len(names):
        raise AssertionError(f'{path}: {label} has duplicates: {names!r}')
    return list(names)


def read_packager_names(path):
    """scripts/package-macos-runtime.py `NAMES = (...)` tuple."""
    text = path.read_text()
    match = re.search(r'^NAMES\s*=\s*\(([^)]*)\)', text, re.M)
    if match is None:
        raise AssertionError(f'{path}: no `NAMES = (...)` tuple found')
    return _checked(path, 'NAMES', list(ast.literal_eval('(' + match.group(1) + ')')))


def read_smoke_executables(path):
    """scripts/install-smoke.sh post-install `for a in ...; do` loop."""
    text = path.read_text()
    for match in re.finditer(r'^for a in ([^;]+); do', text, re.M):
        if '$' not in match.group(1):
            return _checked(path, 'for a in executables', match.group(1).split())
    raise AssertionError(f'{path}: no literal `for a in ...; do` executable loop found')


def read_smoke_asset_templates(path):
    """scripts/install-smoke.sh literal `ASSETS=( ... )` entries ($ARCH kept)."""
    text = path.read_text()
    match = re.search(r'^ASSETS=\(\n(.*?)^\)', text, re.S | re.M)
    if match is None:
        raise AssertionError(f'{path}: no literal `ASSETS=( ... )` block found')
    templates = []
    for raw in match.group(1).splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        templates.append(line.strip('"').strip("'"))
    return _checked(path, 'ASSETS', templates)


def read_gate_expectations(path):
    """scripts/ci/prepare-release-publication.py PLATFORMS + expected assets."""
    text = path.read_text()
    platforms_match = re.search(r'^PLATFORMS\s*=\s*\(([^)]*)\)', text, re.M)
    if platforms_match is None:
        raise AssertionError(f'{path}: no `PLATFORMS = (...)` tuple found')
    platforms = list(ast.literal_eval('(' + platforms_match.group(1) + ')'))
    _checked(path, 'PLATFORMS', platforms)
    body_match = re.search(r'^def validate_distribution.*?(?=^def |\Z)', text, re.S | re.M)
    if body_match is None:
        raise AssertionError(f'{path}: no validate_distribution() function found')
    body = body_match.group(0)
    static_match = re.search(r'expected\s*=\s*\{([^}]*)\}', body)
    if static_match is None:
        raise AssertionError(f'{path}: no `expected = {{...}}` set inside validate_distribution')
    expected = set(ast.literal_eval('{' + static_match.group(1) + '}'))
    update_blocks = re.findall(r'expected\.update\(\{(.*?)\}\)', body, re.S)
    if not update_blocks:
        raise AssertionError(f'{path}: no `expected.update({{...}})` in validate_distribution')
    for block in update_blocks:
        for template in re.findall(r"'([^']+)'", block):
            for arch in platforms:
                expected.add(template.replace('{arch}', arch))
    return platforms, expected


def read_parser_allowlist(path):
    """lib/installed_dashboard.ml closed parse_companions allowlist."""
    text = path.read_text()
    match = re.search(r'List\.mem name \[([^\]]*)\]', text)
    if match is None:
        raise AssertionError(f'{path}: no parse_companions allowlist found')
    return _checked(path, 'parse_companions allowlist', re.findall(r'"([^"]+)"', match.group(1)))


class CompanionListConsistency(unittest.TestCase):
    maxDiff = None

    def test_smoke_checks_every_packaged_binary(self):
        missing = sorted(set(PACKAGER_NAMES) - set(SMOKE_EXECUTABLES))
        self.assertEqual(
            [],
            missing,
            'install-smoke.sh never checks binaries packaged by '
            f'package-macos-runtime.py: {missing}')

    def test_gate_expects_every_smoke_executable_on_every_platform(self):
        missing = [f'{name}-{arch}'
                   for name in SMOKE_EXECUTABLES
                   for arch in GATE_PLATFORMS
                   if f'{name}-{arch}' not in GATE_EXPECTED]
        self.assertEqual(
            [],
            missing,
            'prepare-release-publication.py validate_distribution misses '
            f'smoke-checked executables: {missing}')

    def test_gate_expects_every_smoke_asset(self):
        missing = sorted(set(SMOKE_ASSETS) - GATE_EXPECTED)
        self.assertEqual(
            [],
            missing,
            'prepare-release-publication.py validate_distribution misses '
            f'install-smoke.sh ASSETS entries: {missing}')

    def test_parser_allowlist_equals_receipt_companions(self):
        if 'masc' not in PACKAGER_NAMES:
            self.fail(
                "package-macos-runtime.py NAMES lost the primary 'masc' binary; "
                'the companions computation assumes it ships as binary_asset')
        companions = set(PACKAGER_NAMES) - {'masc'}
        rejected = sorted(companions - PARSER_ALLOWLIST)
        unexpected = sorted(PARSER_ALLOWLIST - companions)
        self.assertEqual(
            [],
            rejected,
            'installed_dashboard.ml parse_companions would reject shipped '
            f'companions with Invalid_receipt: {rejected}')
        self.assertEqual(
            [],
            unexpected,
            'installed_dashboard.ml parse_companions accepts names the packager '
            f'never ships: {unexpected}')


def main():
    parser = argparse.ArgumentParser(
        description='Assert the four release companion lists agree (task-3500).')
    parser.add_argument('--packager', type=Path, required=True,
                        help='scripts/package-macos-runtime.py')
    parser.add_argument('--smoke', type=Path, required=True,
                        help='scripts/install-smoke.sh')
    parser.add_argument('--gate', type=Path, required=True,
                        help='scripts/ci/prepare-release-publication.py')
    parser.add_argument('--parser', type=Path, required=True,
                        help='lib/installed_dashboard.ml')
    args = parser.parse_args()

    global PACKAGER_NAMES, SMOKE_EXECUTABLES, SMOKE_ASSETS, GATE_PLATFORMS
    global GATE_EXPECTED, PARSER_ALLOWLIST
    PACKAGER_NAMES = read_packager_names(args.packager)
    SMOKE_EXECUTABLES = read_smoke_executables(args.smoke)
    GATE_PLATFORMS, GATE_EXPECTED = read_gate_expectations(args.gate)
    SMOKE_ASSETS = [template.replace('$ARCH', arch)
                    for template in read_smoke_asset_templates(args.smoke)
                    for arch in GATE_PLATFORMS]
    PARSER_ALLOWLIST = set(read_parser_allowlist(args.parser))

    suite = unittest.TestLoader().loadTestsFromTestCase(CompanionListConsistency)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)


if __name__ == '__main__':
    main()
