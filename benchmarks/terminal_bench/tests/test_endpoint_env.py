"""The image environment the bootstrap hands the shim as env_file= lines.

One line the shim refuses refuses the whole file and so every request, which is
why the helper leaves such entries out. The refused names are the shim's, so
they are compared with the OCaml sources rather than restated here.
"""
import json
import re
import subprocess
from pathlib import Path

BENCH = Path(__file__).resolve().parents[1]
REPO = BENCH.parents[1]
HELPER = BENCH / "driver" / "endpoint_env.sh"


def env_lines_of(raw, record=""):
    done = subprocess.run(
        ["bash", "-c", 'source "$1" && bench_endpoint_env_lines "$2"', "_", str(HELPER), record],
        input=raw, capture_output=True, check=True)
    return done.stdout.decode().splitlines(), done.stderr.decode()


def env_lines(entries):
    return env_lines_of(b"".join(e.encode() + b"\0" for e in entries))


def test_the_image_environment_becomes_one_line_per_name():
    lines, stderr = env_lines([
        "VIRTUAL_ENV=/opt/venv",
        "LD_LIBRARY_PATH=/usr/local/cuda/lib64",
        "EMPTY=",
        "URL=postgres://db:5432/app?sslmode=disable",
        "SPACED=  kept as is  ",
    ])
    assert lines == [
        "VIRTUAL_ENV=/opt/venv",
        "LD_LIBRARY_PATH=/usr/local/cuda/lib64",
        "EMPTY=",
        "URL=postgres://db:5432/app?sslmode=disable",
        "SPACED=  kept as is  ",
    ]
    assert stderr == ""


def test_what_the_shim_would_refuse_is_left_out_by_name():
    lines, stderr = env_lines([
        "PATH=/opt/venv/bin:/usr/bin",
        "GH_TOKEN=ghp_not_for_the_file",
        "GITHUB_TOKEN=ghs_not_for_the_file",
        "GH_CONFIG_DIR=/root/.config/gh",
        "GIT_TERMINAL_PROMPT=0",
        "MULTI=first\nsecond=line",
        "CARRIAGE=value\r",
        "1NUMERIC=x",
        "KEPT=first",
        "KEPT=second",
        "NO_EQUALS",
        "AFTER=still read",
    ])
    assert lines == ["KEPT=first", "AFTER=still read"]
    for name in ("GH_TOKEN", "GITHUB_TOKEN", "GH_CONFIG_DIR", "GIT_TERMINAL_PROMPT"):
        assert f"left out {name} (refused_by_shim)" in stderr
    # path= carries PATH, so it is not reported as a variable the keeper lacks.
    assert "PATH" not in stderr
    for name in ("MULTI", "CARRIAGE"):
        assert f"left out {name} (not_one_line)" in stderr
    assert "left out KEPT (repeated)" in stderr
    assert "left out an entry (not_a_name)" in stderr
    # Names are reported, never values.
    for value in ("ghp_not_for_the_file", "ghs_not_for_the_file", "second=line", "/root/.config/gh"):
        assert value not in stderr


def test_every_line_is_one_the_shim_reads():
    lines, _ = env_lines([
        "A=1", "B=x\ny", "C=z\r", "D=trailing\\", "E=#not a comment", "F= ",
    ])
    grammar = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=[^\n]*$")
    assert lines == ["A=1", "D=trailing\\", "E=#not a comment", "F= "]
    assert all(grammar.match(line) and not line.endswith("\r") for line in lines)


def test_an_entry_the_input_ends_without_a_nul_is_read():
    lines, stderr = env_lines_of(b"A=1\0B=2")
    assert lines == ["A=1", "B=2"]
    assert stderr == ""


def test_what_is_left_out_is_recorded_for_the_result(tmp_path):
    record = tmp_path / "left-out.tsv"
    record.write_text("stale\tfrom an earlier bootstrap\n")
    lines, _ = env_lines_of(
        b"PATH=/usr/bin\0GH_TOKEN=ghp_x\0MULTI=a\nb\0A=1\0A=2\0" + b"1BAD=x\0KEEP=yes\0",
        str(record))
    assert lines == ["A=1", "KEEP=yes"]
    assert record.read_text().splitlines() == [
        "GH_TOKEN\trefused_by_shim", "MULTI\tnot_one_line", "A\trepeated", "\tnot_a_name"]
    assert "ghp_x" not in record.read_text()
    as_json = subprocess.run(
        ["bash", "-c", 'source "$1" && bench_env_left_out_json "$2"', "_", str(HELPER), str(record)],
        capture_output=True, text=True, check=True).stdout
    assert json.loads(as_json) == [
        {"name": "GH_TOKEN", "reason": "refused_by_shim"},
        {"name": "MULTI", "reason": "not_one_line"},
        {"name": "A", "reason": "repeated"},
        {"name": "", "reason": "not_a_name"},
    ]


def test_no_record_is_an_empty_list(tmp_path):
    as_json = subprocess.run(
        ["bash", "-c", 'source "$1" && bench_env_left_out_json "$2"', "_", str(HELPER),
         str(tmp_path / "never-written.tsv")],
        capture_output=True, text=True, check=True).stdout
    assert json.loads(as_json) == []


def ocaml_string_list(source, binding):
    match = re.search(rf"let {binding}\s*=\s*\[(.*?)\]", source, re.S)
    assert match, f"{binding} is no longer a list literal"
    return re.findall(r'"([A-Za-z_][A-Za-z0-9_]*)"', match.group(1))


def test_the_left_out_names_are_the_shims_refusals():
    shim = (REPO / "lib/exec_shim/exec_shim.ml").read_text()
    protocol = (REPO / "lib/exec_ssh_protocol/exec_ssh_protocol.ml").read_text()
    refused = (ocaml_string_list(protocol, "github_token_env_names")
               + ocaml_string_list(shim, "runtime_env_allowlist"))
    listed = subprocess.run(
        ["bash", "-c", 'source "$1" && printf "%s\\n" "${BENCH_ENV_FILE_REFUSED_NAMES[@]}"',
         "_", str(HELPER)],
        capture_output=True, text=True, check=True).stdout.split()
    assert sorted(listed) == sorted(refused)

