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
    def exercise(self, reset=False, missing_overlay=False, init_failure="", later_failure=False):
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
config_only=0
force_seed=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --base-path) seed_base="$2"; shift 2 ;;
    --skills-only) skills_only=1; shift ;;
    --config-only) config_only=1; shift ;;
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
if [ "$config_only" -eq 1 ]; then
  if [ "$TEST_INIT_FAILURE" = config ]; then
    echo 'config read failed' >&2
    exit 7
  fi
  exit 0
fi
# The real installer must have ended its bundle rollback transaction first.
test -e "$seed_base/bundle-committed"
skill_root="$seed_base/.masc/skills"
if [ ! -e "$skill_root/browser-lanes" ]; then
  mkdir -p "$skill_root/browser-lanes"
  echo builtin > "$skill_root/browser-lanes/SKILL.md"
fi
echo 'preserved operator-edited browser-lanes' >&2
echo 'recovery: masc skills-refresh browser-lanes' >&2
if [ "$TEST_INIT_FAILURE" = skills ]; then
  echo 'receipt read failed' >&2
  exit 7
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
log() { printf '%s\\n' "$*"; }
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
            script += '\nif [ "$TEST_LATER_FAILURE" = 1 ]; then exit 9; fi\n'
            # Execute the actual commit-to-refresh sequence. The fake binary
            # refuses package publication until this helper commits the bundle.
            script += 'BUNDLE_HELPER=fixture\npython3() { touch "$BASE_PATH/bundle-committed"; }\n'
            commit = 'python3 "$BUNDLE_HELPER" commit --prefix "$PREFIX"'
            script += commit + section(commit, '\nconfigure_shell_path') + '\n'
            self.assertLess(INSTALLER.index('# --- 4. seed minimum config'), INSTALLER.index(commit))
            env = dict(os.environ, BASE_PATH=str(base), PREFIX=str(base), DEST=str(binary), TEST_RESET=str(int(reset)),
                       TEST_INIT_FAILURE=init_failure, TEST_LATER_FAILURE=str(int(later_failure)))
            result = subprocess.run(['bash', '-c', script], env=env, text=True, capture_output=True)
            diagnostics = result.stdout + result.stderr
            if later_failure or init_failure == 'config':
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((base / 'bundle-committed').exists())
                self.assertFalse((base / '.masc/skills/browser-lanes').exists())
                self.assertEqual(skill.read_text(), 'operator skill\n')
                if init_failure == 'config':
                    self.assertIn('config read failed', diagnostics)
                return
            self.assertTrue((base / 'bundle-committed').exists())
            self.assertIn('preserved operator-edited browser-lanes', diagnostics)
            self.assertIn('recovery: masc skills-refresh browser-lanes', diagnostics)
            if init_failure:
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('receipt read failed', diagnostics)
                self.assertNotIn('initialized', diagnostics)
                return
            self.assertIn('initialized', diagnostics)
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

    def test_skill_seed_failure_preserves_full_diagnostics_and_fails_install(self):
        self.exercise(init_failure="skills")

    def test_config_seed_failure_preserves_full_diagnostics_and_fails_install(self):
        self.exercise(missing_overlay=True, init_failure="config")

    def test_later_failure_does_not_publish_skills_before_commit(self):
        self.exercise(later_failure=True)
        self.exercise(missing_overlay=True, later_failure=True)
        self.exercise(reset=True, later_failure=True)

    def test_explicit_reset_replaces_config_and_team_and_runs_wizard(self):
        self.exercise(reset=True)


if __name__ == '__main__':
    unittest.main()
