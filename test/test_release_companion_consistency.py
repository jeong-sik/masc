"""Release executable lists agree across every hand-maintained copy.

task-3500 and #45119.  A release executable is named in many files that each
keep their own literal list, and the release pipeline is the first reader of
most of them (release-build.yml is workflow_call-only, so a PR's CI never runs
it).  Two omissions reached a release this way:

  * #50360 added ``masc-antigravity-path-hook`` to the packager while the
    installer-receipt parser still accepted four names; the v0.70.0 RC run
    42689442386 failed installation on all four platforms (#50773, #50782).
  * #45099 installed the browser Add-on programs from a local build only;
    the release built, published and installed neither, so a release
    installation could not run the browser Add-on (#45119).

This suite reads every copy from its file and requires them to agree, so the
next added or removed executable fails here, in the pull-request gate.  The
reference list is the packager's ``NAMES``: every release-named executable it
stages and republishes as ``<name>-<platform>``.

  1. scripts/package-macos-runtime.py ``NAMES`` (reference)
  2. scripts/build-linux-release.sh ``release_binaries`` - Linux build targets
  3. .github/workflows/release-build.yml - the macOS build targets, the
     ``Package binary`` copies and chmods, the glibc floor list, the
     ``--companion`` arguments and the advertised-asset list
  4. scripts/install.sh - the uninstall list and the companions it installs
  5. scripts/install-smoke.sh - the executables loop and ``ASSETS``
  6. scripts/release-dashboard-bundle.py ``COMPANIONS``
  7. scripts/ci/prepare-release-publication.py ``validate_distribution``
  8. lib/installed_dashboard.ml - the closed ``parse_companions`` allowlist
  9. lane-addon-native.yml and linux-x64-probe.yml - the probe runs that feed
     the same packager its ``NAMES``

Agreement alone missed #45119: every copy lacked the browser Add-on programs
at once.  So the reference must also hold what the product looks for beside
masc or on PATH at run time: each ``Native_addon_program`` name
(lib/lane_addon/native_addon_program.ml) and the worker command of each
browser package masc carries (addons/browser/<source>/lane.toml).

The primary ``masc`` binary ships as ``binary_asset``, so every companion list
is the reference minus ``masc``.  ``masc-check-runtime-deployment-preflight``
is a shell script copied from scripts/, so the build and glibc lists are the
reference minus that script.
"""
import argparse
import ast
import re
import sys
import tomllib
import unittest
from pathlib import Path

PRIMARY = 'masc'
MATRIX_SUFFIX = '${{ matrix.arch }}'
PROBE_SUFFIX = 'macos-arm64'

PACKAGER_NAMES = []
SMOKE_EXECUTABLES = []
SMOKE_ASSETS = []
GATE_PLATFORMS = []
GATE_EXPECTED = set()
PARSER_ALLOWLIST = set()
LINUX_BUILD_TARGETS = []
MACOS_BUILD_TARGETS = []
PACKAGED = []
PACKAGED_CHMOD = []
GLIBC_CHECKED = []
WORKFLOW_COMPANIONS = []
ADVERTISED = []
INSTALLER_UNINSTALL = []
INSTALLER_COMPANIONS = []
BUNDLE_COMPANIONS = set()
PROBES = {}
NATIVE_PROGRAMS = []
BROWSER_WORKERS = {}


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


def read_linux_build_targets(path):
    """scripts/build-linux-release.sh `release_binaries=( ... )` Dune targets."""
    text = path.read_text()
    match = re.search(r'^release_binaries=\(\n(.*?)^\)', text, re.S | re.M)
    if match is None:
        raise AssertionError(f'{path}: no `release_binaries=( ... )` block found')
    return _checked(path, 'release_binaries', match.group(1).split())


def step_script(path, text, name):
    """The `run: |` body of the one workflow step named `name`.

    Shell line continuations are joined, so each command is one line.
    """
    lines = text.splitlines()
    starts = [index for index, line in enumerate(lines)
              if re.fullmatch(r'\s*- name: ' + re.escape(name) + r'\s*', line)]
    if len(starts) != 1:
        raise AssertionError(f'{path}: expected one step named {name!r}, found {len(starts)}')
    step_line = lines[starts[0]]
    step_indent = len(step_line) - len(step_line.lstrip())
    for index in range(starts[0] + 1, len(lines)):
        stripped = lines[index].lstrip()
        indent = len(lines[index]) - len(stripped)
        if stripped and indent <= step_indent:
            break
        if re.fullmatch(r'run: \|\s*', stripped):
            body = []
            for line in lines[index + 1:]:
                inner = line.lstrip()
                if inner and len(line) - len(inner) <= indent:
                    break
                body.append(line)
            return re.sub(r'\\\n\s*', ' ', '\n'.join(body))
    raise AssertionError(f'{path}: step {name!r} has no `run: |` block')


def read_build_targets(path, text, step):
    """Every `bin/<name>.exe` Dune target a build step names."""
    return _checked(path, f'{step!r} build targets',
                    re.findall(r'(?<![\w/])bin/\w+\.exe', step_script(path, text, step)))


def producer(source):
    """The Dune target or checked-in file a copy reads, by its source path."""
    match = re.fullmatch(r'(?:"\$MASC_BIN_DIR"|_build/default/bin)/(\w+\.exe)', source)
    return 'bin/' + match.group(1) if match else source


def read_staged(path, text, step, destination, suffix):
    """(producer, release name) of each `cp SOURCE DEST/<name>-<suffix>` in a step."""
    pattern = re.compile(r'^\s*cp\s+(\S+)\s+"?' + re.escape(destination) + r'/([a-z0-9-]+)-'
                         + re.escape(suffix) + r'"?\s*$', re.M)
    staged = [(producer(source), name)
              for source, name in pattern.findall(step_script(path, text, step))]
    _checked(path, f'{step!r} staged names', [name for _, name in staged])
    return staged


def read_release_workflow(path):
    """.github/workflows/release-build.yml: every executable list of the release job."""
    text = path.read_text()
    macos_targets = read_build_targets(path, text, 'Build (macOS)')
    packaged = read_staged(path, text, 'Package binary', 'dist', MATRIX_SUFFIX)
    dist_name = re.compile(r'dist/([a-z0-9-]+)-' + re.escape(MATRIX_SUFFIX))
    chmod = [name
             for line in step_script(path, text, 'Package binary').splitlines()
             if line.strip().startswith('chmod +x')
             for name in dist_name.findall(line)]
    glibc = dist_name.findall(step_script(
        path, text, 'Assert shipped Linux binaries meet the glibc floor'))
    companions = []
    for name, asset in re.findall(
            r'--companion\s+(\S+)\s+"dist/([a-z0-9-]+)-' + re.escape(MATRIX_SUFFIX) + '"',
            step_script(path, text, 'Package binary-matched dashboard distribution')):
        if name != asset:
            raise AssertionError(f'{path}: --companion {name} packages the asset of {asset}')
        companions.append(name)
    advertised = re.findall(r'"([a-z0-9-]+)-\$arch"',
                            step_script(path, text, 'Verify advertised release assets'))
    return (macos_targets, packaged,
            _checked(path, 'Package binary chmod', chmod),
            _checked(path, 'glibc floor list', glibc),
            _checked(path, '--companion arguments', companions),
            _checked(path, 'advertised release assets', advertised))


def read_installer(path):
    """scripts/install.sh: the uninstall list and every installed companion."""
    text = path.read_text()
    uninstall = re.search(r'^uninstall_masc\(\) \{.*?^  for name in ([^;]+); do', text, re.S | re.M)
    if uninstall is None:
        raise AssertionError(f'{path}: no `for name in ...; do` loop in uninstall_masc()')
    assets = dict(re.findall(r'^([A-Z_]+)="([a-z0-9-]+)-\$PLATFORM_SUFFIX"$', text, re.M))
    destinations = dict(re.findall(r'^([A-Z_]+)="\$PREFIX/([a-z0-9-]+)"$', text, re.M))
    companions = []
    for asset_variable, destination_variable in re.findall(
            r'^install_release_companion "\$([A-Z_]+)" "\$([A-Z_]+)"$', text, re.M):
        if asset_variable not in assets or destination_variable not in destinations:
            raise AssertionError(f'{path}: install_release_companion names an undefined '
                                 f'{asset_variable} or {destination_variable}')
        if assets[asset_variable] != destinations[destination_variable]:
            raise AssertionError(f'{path}: companion asset {assets[asset_variable]} is installed '
                                 f'as {destinations[destination_variable]}')
        companions.append(destinations[destination_variable])
    return (_checked(path, 'uninstall list', uninstall.group(1).split()),
            _checked(path, 'installed companions', companions))


def read_bundle_companions(path):
    """scripts/release-dashboard-bundle.py `COMPANIONS = {...}`."""
    text = path.read_text()
    match = re.search(r'^COMPANIONS\s*=\s*\{([^}]*)\}', text, re.M)
    if match is None:
        raise AssertionError(f'{path}: no `COMPANIONS = {{...}}` set found')
    return _checked(path, 'COMPANIONS', sorted(ast.literal_eval('{' + match.group(1) + '}')))


def read_native_programs(path):
    """lib/lane_addon/native_addon_program.ml `let name = function` cases."""
    text = path.read_text()
    match = re.search(r'^let name = function\n((?:[ \t]*\|.*\n)+)', text, re.M)
    if match is None:
        raise AssertionError(f'{path}: no `let name = function` cases found')
    return _checked(path, 'Native_addon_program names',
                    re.findall(r'\|\s*\w+\s*->\s*"([^"]+)"', match.group(1)))


def read_browser_workers(directory):
    """The command each carried browser package (addons/browser/<source>/lane.toml) runs.

    A bare command is looked up on PATH; one with a slash runs from the package.
    """
    manifests = sorted(directory.glob('*/lane.toml'))
    if not manifests:
        raise AssertionError(f'{directory}: no browser package manifest */lane.toml found')
    workers = {}
    for manifest in manifests:
        command = tomllib.loads(manifest.read_text()).get('command')
        if not isinstance(command, list) or not command or not isinstance(command[0], str):
            raise AssertionError(f'{manifest}: command is not a non-empty list: {command!r}')
        if '/' not in command[0]:
            workers[manifest.parent.name] = command[0]
    return workers


def read_probe(path, build_step, package_step, destination):
    text = path.read_text()
    return (read_build_targets(path, text, build_step),
            read_staged(path, text, package_step, destination, PROBE_SUFFIX))


class CompanionListConsistency(unittest.TestCase):
    maxDiff = None

    def assertSameNames(self, expected, actual, where,
                        reference='package-macos-runtime.py NAMES'):
        self.assertEqual(
            {'missing': sorted(set(expected) - set(actual)),
             'unexpected': sorted(set(actual) - set(expected))},
            {'missing': [], 'unexpected': []},
            f'{where} differs from {reference}')

    def companions(self):
        if PRIMARY not in PACKAGER_NAMES:
            self.fail(f"package-macos-runtime.py NAMES lost the primary {PRIMARY!r} binary; "
                      'the companions computation assumes it ships as binary_asset')
        return set(PACKAGER_NAMES) - {PRIMARY}

    def built(self):
        return {name for source, name in PACKAGED if source.startswith('bin/')}

    def test_smoke_checks_every_packaged_binary(self):
        self.assertSameNames(PACKAGER_NAMES, SMOKE_EXECUTABLES,
                             'install-smoke.sh executables loop')

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
        self.assertSameNames(self.companions(), PARSER_ALLOWLIST,
                             'installed_dashboard.ml parse_companions allowlist + masc')

    def test_release_job_packages_every_packager_name(self):
        self.assertSameNames(PACKAGER_NAMES, [name for _, name in PACKAGED],
                             'release-build.yml Package binary copies')
        self.assertSameNames(PACKAGER_NAMES, PACKAGED_CHMOD,
                             'release-build.yml Package binary chmod')

    def test_both_release_builds_build_what_is_packaged(self):
        packaged_targets = [source for source, _ in PACKAGED if source.startswith('bin/')]
        reference = 'the Dune targets release-build.yml Package binary copies'
        self.assertSameNames(packaged_targets, LINUX_BUILD_TARGETS,
                             'build-linux-release.sh release_binaries', reference)
        self.assertSameNames(packaged_targets, MACOS_BUILD_TARGETS,
                             'release-build.yml Build (macOS) targets', reference)

    def test_glibc_floor_checks_every_built_binary(self):
        self.assertSameNames(self.built(), GLIBC_CHECKED, 'release-build.yml glibc floor list',
                             'the built binaries release-build.yml packages')

    def test_release_job_bundles_and_advertises_every_companion(self):
        self.assertSameNames(self.companions(), WORKFLOW_COMPANIONS,
                             'release-build.yml --companion arguments + masc')
        self.assertSameNames(PACKAGER_NAMES, ADVERTISED,
                             'release-build.yml advertised release assets')

    def test_installer_installs_and_uninstalls_every_companion(self):
        self.assertSameNames(self.companions(), INSTALLER_COMPANIONS,
                             'install.sh install_release_companion calls + masc')
        self.assertSameNames(PACKAGER_NAMES, INSTALLER_UNINSTALL, 'install.sh uninstall list')

    def test_bundle_helper_accepts_every_companion(self):
        self.assertSameNames(self.companions(), BUNDLE_COMPANIONS,
                             'release-dashboard-bundle.py COMPANIONS + masc')

    def test_release_ships_every_program_the_browser_addon_runs(self):
        required = [('Native_addon_program', name) for name in NATIVE_PROGRAMS]
        required += [(f'addons/browser/{source}/lane.toml command', worker)
                     for source, worker in BROWSER_WORKERS.items()]
        companions = self.companions()
        unshipped = sorted(f'{where}: {name}' for where, name in required
                           if name not in companions)
        self.assertEqual(
            [],
            unshipped,
            'a release installation lacks programs the browser Add-on runs; add them to '
            'package-macos-runtime.py NAMES and every list this suite reads')

    def test_probe_runs_stage_every_packager_name_they_build(self):
        for probe, (targets, staged) in PROBES.items():
            with self.subTest(probe=probe):
                self.assertSameNames(PACKAGER_NAMES, [name for _, name in staged],
                                     f'{probe} packager inputs')
                unbuilt = sorted(source for source, _ in staged
                                 if source.startswith('bin/') and source not in targets)
                self.assertEqual([], unbuilt, f'{probe} copies Dune targets it never builds')


def main():
    parser = argparse.ArgumentParser(
        description='Assert every release executable list agrees (task-3500, #45119).')
    parser.add_argument('--packager', type=Path, required=True,
                        help='scripts/package-macos-runtime.py')
    parser.add_argument('--smoke', type=Path, required=True,
                        help='scripts/install-smoke.sh')
    parser.add_argument('--gate', type=Path, required=True,
                        help='scripts/ci/prepare-release-publication.py')
    parser.add_argument('--parser', type=Path, required=True,
                        help='lib/installed_dashboard.ml')
    parser.add_argument('--linux-build', type=Path, required=True,
                        help='scripts/build-linux-release.sh')
    parser.add_argument('--release-workflow', type=Path, required=True,
                        help='.github/workflows/release-build.yml')
    parser.add_argument('--installer', type=Path, required=True,
                        help='scripts/install.sh')
    parser.add_argument('--bundle', type=Path, required=True,
                        help='scripts/release-dashboard-bundle.py')
    parser.add_argument('--lane-addon-probe', type=Path, required=True,
                        help='.github/workflows/lane-addon-native.yml')
    parser.add_argument('--runtime-probe', type=Path, required=True,
                        help='.github/workflows/linux-x64-probe.yml')
    parser.add_argument('--native-programs', type=Path, required=True,
                        help='lib/lane_addon/native_addon_program.ml')
    parser.add_argument('--browser-packages', type=Path, required=True,
                        help='addons/browser')
    args = parser.parse_args()

    global PACKAGER_NAMES, SMOKE_EXECUTABLES, SMOKE_ASSETS, GATE_PLATFORMS
    global GATE_EXPECTED, PARSER_ALLOWLIST, LINUX_BUILD_TARGETS, MACOS_BUILD_TARGETS
    global PACKAGED, PACKAGED_CHMOD, GLIBC_CHECKED, WORKFLOW_COMPANIONS, ADVERTISED
    global INSTALLER_UNINSTALL, INSTALLER_COMPANIONS, BUNDLE_COMPANIONS, PROBES
    global NATIVE_PROGRAMS, BROWSER_WORKERS
    PACKAGER_NAMES = read_packager_names(args.packager)
    SMOKE_EXECUTABLES = read_smoke_executables(args.smoke)
    GATE_PLATFORMS, GATE_EXPECTED = read_gate_expectations(args.gate)
    SMOKE_ASSETS = [template.replace('$ARCH', arch)
                    for template in read_smoke_asset_templates(args.smoke)
                    for arch in GATE_PLATFORMS]
    PARSER_ALLOWLIST = set(read_parser_allowlist(args.parser))
    LINUX_BUILD_TARGETS = read_linux_build_targets(args.linux_build)
    (MACOS_BUILD_TARGETS, PACKAGED, PACKAGED_CHMOD, GLIBC_CHECKED, WORKFLOW_COMPANIONS,
     ADVERTISED) = read_release_workflow(args.release_workflow)
    INSTALLER_UNINSTALL, INSTALLER_COMPANIONS = read_installer(args.installer)
    BUNDLE_COMPANIONS = set(read_bundle_companions(args.bundle))
    PROBES = {
        'lane-addon-native.yml': read_probe(
            args.lane_addon_probe, 'Build and test native integration',
            'Package using the release runtime bundler', 'dist'),
        'linux-x64-probe.yml': read_probe(
            args.runtime_probe, 'Build runtime companions',
            'Bundle relocatable runtime with release filenames', '$PROBE_OUT'),
    }
    NATIVE_PROGRAMS = read_native_programs(args.native_programs)
    BROWSER_WORKERS = read_browser_workers(args.browser_packages)

    suite = unittest.TestLoader().loadTestsFromTestCase(CompanionListConsistency)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)


if __name__ == '__main__':
    main()
