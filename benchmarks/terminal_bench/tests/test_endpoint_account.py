"""Keeper commands run as the task image's user, as harbor's own agents do.

The endpoint logs in as root and runs masc-exec-shim by name; that name is a
wrapper which drops to PID 1's uid and gid through setpriv before the release
binary starts. setpriv is Linux-only, so the wrapper runs here against a stand-in
setpriv that records its options and then runs the command it was given, kept
off PATH as fedora keeps the real one in /usr/sbin.
"""
import subprocess
import sys
from pathlib import Path

BENCH = Path(__file__).resolve().parents[1]
HELPER = BENCH / "driver" / "endpoint_account.sh"

sys.path.insert(0, str(BENCH / "configs"))

import render_configs  # noqa: E402


def wrapper_text(binary, setpriv, uid, gid, entry):
    return subprocess.run(
        ["bash", "-c", 'source "$1" && bench_shim_wrapper_text "$2" "$3" "$4" "$5" "$6" "$7"',
         "_", str(HELPER), str(binary), str(setpriv), "/usr/bin/env", str(uid), str(gid), entry],
        capture_output=True, text=True, check=True).stdout


def run_wrapper(tmp_path, entry, *args):
    shim = tmp_path / "release-shim"
    shim.write_text('#!/bin/sh\nprintf "HOME=%s USER=%s ARGS=%s\\n" "$HOME" "$USER" "$*"\n')
    shim.chmod(0o755)
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    setpriv = bin_dir / "setpriv"
    record = tmp_path / "setpriv-options"
    setpriv.write_text(
        '#!/bin/sh\n'
        f'while [ "${{1#--}}" != "$1" ]; do printf "%s\\n" "$1" >> "{record}"; shift; done\n'
        'exec "$@"\n')
    setpriv.chmod(0o755)
    wrapper = tmp_path / "masc-exec-shim"
    wrapper.write_text(wrapper_text(shim, setpriv, 1000, 1001, entry))
    wrapper.chmod(0o755)
    # An sshd session's PATH, without the directory setpriv is in: the wrapper
    # names it by absolute path.
    env = {"PATH": "/usr/bin:/bin", "HOME": "/root", "USER": "root"}
    output = subprocess.run([str(wrapper), *args], capture_output=True, text=True,
                            check=True, env=env).stdout
    return output.strip(), record.read_text().splitlines()


def test_an_account_with_a_passwd_entry_keeps_its_name_home_and_groups(tmp_path):
    output, options = run_wrapper(
        tmp_path, "agent:x:1000:1001:Agent:/home/agent:/bin/bash", "--probe")
    assert options == ["--reuid=1000", "--regid=1001", "--init-groups"]
    assert output == "HOME=/home/agent USER=agent ARGS=--probe"


def test_an_account_without_one_gets_docker_s_home_and_groups_and_its_uid_as_user(tmp_path):
    # docker exec gives such an account HOME=/ and no supplementary groups, and
    # no USER; the shim always gives a payload USER, so it is the uid here.
    output, options = run_wrapper(tmp_path, "", "a", "b c")
    assert options == ["--reuid=1000", "--regid=1001", "--clear-groups"]
    assert output == "HOME=/ USER=1000 ARGS=a b c"


def test_a_home_with_quotes_and_spaces_reaches_the_shim_whole(tmp_path):
    output, _ = run_wrapper(tmp_path, "o:x:1000:1001::/home/o'brien dir:/bin/sh")
    assert output == "HOME=/home/o'brien dir USER=o ARGS="


def test_the_rendered_endpoint_uses_the_directory_the_bootstrap_prepares():
    listed = subprocess.run(
        ["bash", "-c", 'source "$1" && printf "%s" "$BENCH_REMOTE_ROOT"', "_", str(HELPER)],
        capture_output=True, text=True, check=True).stdout
    assert listed == render_configs.REMOTE_ROOT
    out = render_configs.render_arm("b", runtime_id="anthropic.claude-fable-5", effort="high")
    runtime_toml = (out / "runtime.toml").read_text()
    assert f'remote_root = "{render_configs.REMOTE_ROOT}"' in runtime_toml
