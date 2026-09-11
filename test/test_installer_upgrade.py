"""Exercise installer config effects without a compiler or network."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

INSTALLER = (Path(__file__).resolve().parents[1] / 'scripts/install.sh').read_text()


def section(start, end):
    return INSTALLER.split(start, 1)[1].split(end, 1)[0]


class UpgradeConfigTest(unittest.TestCase):
    def exercise(self, reset=False, missing_overlay=False):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            config = base / '.masc/config'
            config.mkdir(parents=True)
            runtime = config / 'runtime.toml'
            runtime.write_text('[runtime]\ndefault = "operator-choice"\n')
            overlay = config / 'agent-core-models-overlay.toml'
            if not missing_overlay:
                overlay.write_text('custom overlay\n')
            keeper = config / 'keepers/custom.toml'
            keeper.parent.mkdir()
            keeper.write_text('custom instructions\n')
            skill = base / '.masc/skills/custom/SKILL.md'
            skill.parent.mkdir(parents=True)
            skill.write_text('operator skill\n')
            binary = base / 'masc'
            binary.write_text('''#!/usr/bin/env bash
# Stands in for `masc init`, reading its flags the way the binary does:
# --base-path <dir>, --force, and --skills-only (an upgrade seeds Skills
# alone and leaves the config tree as it is). The subcommand and the base
# path are asserted rather than read by position: the upgrade path inserts
# --skills-only ahead of --base-path, and a positional read turned the flag
# itself into a path. optional.toml stands for a config file the operator
# deleted -- an ordinary upgrade must not put it back.
set -eu
test "$1" = init
shift
seed_base=""
skills_only=0
force_seed=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --base-path) seed_base="$2"; shift 2 ;;
    --skills-only) skills_only=1; shift ;;
    --force) force_seed=1; shift ;;
    # The installer's seed asks for this; `masc init` does not record a
    # default workspace without it. Accepted and ignored: what this fake
    # stands in for is the config seed, not the record.
    --record-default) shift ;;
    *) echo "unexpected init argument: $1" >&2; exit 2 ;;
  esac
done
test -n "$seed_base"
cfg="$seed_base/.masc/config"
if [ "$skills_only" -eq 0 ]; then
  for name in runtime.toml agent-core-models-overlay.toml optional.toml; do
    if [ ! -e "$cfg/$name" ] || [ "$force_seed" -eq 1 ]; then
      echo seeded > "$cfg/$name"
    fi
  done
fi
skill_root="$seed_base/.masc/skills"
if [ ! -e "$skill_root/browser-lanes" ]; then
  mkdir -p "$skill_root/browser-lanes"
  echo builtin > "$skill_root/browser-lanes/SKILL.md"
fi
echo initialized
''')
            binary.chmod(0o755)
            script = '''set -euo pipefail
FORCE=1
RESET_CONFIG="$TEST_RESET"
SEED_CONFIG=1
DRY_RUN=0
DRY_RUN_WITHOUT_PYTHON=0
CONFIG_PREEXISTING=0
WIZARD=auto
WIZARD_PROVIDER=""
WIZARD_SANDBOX=""
REPO=fixture/repo
VERSION=v0.0.0
MASC_INSTALL_CONFIG_FETCH_TIMEOUT_S=1
MASC_INSTALL_CURL_RETRIES=0
PARTIAL_FILES=()
log() { :; }
die() { echo "$*" >&2; exit 1; }
run_wizard() { touch "$BASE_PATH/wizard-ran"; }
verify_checksum() { :; }
curl() {
  local output=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then output="$2"; shift 2; else shift; fi
  done
  case "$output" in
    *.partial) echo 'reset instructions' > "$output" ;;
    *) echo 'keepers/custom.toml' > "$output" ;;
  esac
}
'''
            script += 'maybe_run_wizard() {' + section('maybe_run_wizard() {', '\nis_tty()')
            script += section('# --- 4. seed minimum config', '# --- 4c. keeper team preset').split('\n', 1)[1]
            script += 'seed_team() {' + section('seed_team() {', '\nif [ -n "$TEAM" ]; then')
            script += '\nseed_team classic\ntest "$(command -v masc)" = "$DEST"\n'
            env = dict(os.environ, BASE_PATH=str(base), PREFIX=str(base), DEST=str(binary), TEST_RESET=str(int(reset)))
            result = subprocess.run(['bash', '-c', script], env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(runtime.read_text(), 'seeded\n' if reset else '[runtime]\ndefault = "operator-choice"\n')
            self.assertEqual(keeper.read_text(), 'reset instructions\n' if reset else 'custom instructions\n')
            self.assertEqual((base / 'wizard-ran').exists(), reset)
            self.assertTrue(overlay.exists())
            self.assertEqual((config / 'optional.toml').exists(), reset or missing_overlay,
                             'ordinary upgrade must preserve removed optional config')
            self.assertEqual(skill.read_text(), 'operator skill\n')
            self.assertEqual((base / '.masc/skills/browser-lanes/SKILL.md').read_text(), 'builtin\n')

    def test_force_upgrade_preserves_custom_config_and_team(self):
        self.exercise()

    def test_force_upgrade_repairs_missing_overlay_without_resetting_default(self):
        self.exercise(missing_overlay=True)

    def test_explicit_reset_replaces_config_and_team_and_runs_wizard(self):
        self.exercise(reset=True)


if __name__ == '__main__':
    unittest.main()
