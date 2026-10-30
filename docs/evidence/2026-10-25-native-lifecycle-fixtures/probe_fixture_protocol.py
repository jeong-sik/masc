"""Run exact CLI fixture generators and their stdio protocol, without MASC/SDK."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
BASE = "32805eb764eab2710262446e925b0ea5c3a44c08"
FILE = "test/test_keeper_claude_code_runtime.ml"


def part(text, start, end):
    return text[text.index(start):text.index(end)]


old = subprocess.check_output(["git", "show", BASE + ":" + FILE], cwd=ROOT, text=True)
new = (ROOT / FILE).read_text()
records = []
with tempfile.TemporaryDirectory(prefix="masc-cli-fixture-protocol-") as temporary:
    directory = Path(temporary)
    for label, source, read_frames in [
        ("before", old, "repeated_tool_fixture"),
        ("after", new, "repeated_read_frames"),
        ("auth_retry_after", new, "repeated_read_frames"),
    ]:
        # These are complete actual pure definitions; no substitute generator.
        generator = (
            part(source, "let shell_quote value =", "let auth_subscription =")
            + part(source, "let auth_subscription =", "type fixture_step =")
            + part(source, "type fixture_step =", "let with_fixture ")
            + part(source, "let " + read_frames + " =", "let repeated_tool ")
        )
        terminal = "" if label == "before" else (
            ' @ [Emit (result ~turn_id:"turn-read-complete" "READS_COMPLETE")]'
        )
        invocation = ("fixture_script (" + read_frames + terminal + ")")
        if label == "auth_retry_after":
            invocation = ('fixture_script ~auth_first_body:"{\\\"loggedIn\\\":true," '
                          '[Emit (result ~turn_id:"auth-retry-complete" "AUTH_RETRY_COMPLETE")]')
        program = generator + "let () = let path = " + invocation + " in print_endline path\n"
        ml = directory / "fixture.ml"
        ml.write_text(program)
        built = subprocess.run([
            "ocamlfind", "ocamlc", "-package", "unix,yojson", "-linkpkg",
            "-w", "+4+32+69", "-warn-error", "+a", str(ml), "-o", str(directory / "generator"),
        ], capture_output=True, text=True)
        if built.returncode:
            raise RuntimeError(built.stdout + built.stderr)
        generated = subprocess.check_output([str(directory / "generator")], text=True).strip()
        script = Path(generated)
        try:
            auth_results = None
            if label == "auth_retry_after":
                first = subprocess.check_output([str(script), "auth", "status"], text=True)
                second = subprocess.check_output([str(script), "auth", "status"], text=True)
                assert first.strip() == '{"loggedIn":true,'
                assert json.loads(second)["loggedIn"] is True
                auth_results = {"first_is_expected_cut_document": True, "second_is_valid_logged_in_document": True}
            # Actual client initialization, actual owner User packet, then one
            # response per fixture MCP request. Closing stdin lets the old
            # fixture exit; its lack of a result is not called a runtime test.
            inputs = [json.dumps({"request_id": "control-init"}, separators=(",", ":")),
                      json.dumps({"uuid": "input-one", "message": {"role": "user", "content": "OWNER"}})]
            inputs += ["{}"] * 5
            ran = subprocess.run([str(script), "--session-id=fixture-session"],
                                 input="\n".join(inputs) + "\n", capture_output=True, text=True)
            assert ran.returncode == 0, ran.stderr
            frames = [json.loads(line) for line in ran.stdout.splitlines()]
            calls = [frame["request"]["message"] for frame in frames
                     if frame.get("type") == "control_request"
                     and frame["request"]["message"].get("method") == "tools/call"]
            terminals = [frame for frame in frames if frame.get("type") == "result"]
            expected_ids = [] if label == "auth_retry_after" else ["call-repeat-1", "call-repeat-2", "call-repeat-3"]
            assert [call["id"] for call in calls] == expected_ids
            expected_uuid = "auth-retry-complete" if label == "auth_retry_after" else "turn-read-complete"
            expected_text = "AUTH_RETRY_COMPLETE" if label == "auth_retry_after" else "READS_COMPLETE"
            assert (len(terminals) == 0) if label == "before" else (
                len(terminals) == 1 and terminals[0]["uuid"] == expected_uuid
                and terminals[0]["session_id"] == "fixture-session"
                and terminals[0]["result"] == expected_text
            )
            records.append({"variant": label, "source_sha256": hashlib.sha256(source.encode()).hexdigest(),
                            "generator_source_sha256": hashlib.sha256(generator.encode()).hexdigest(),
                            "generated_script_sha256": hashlib.sha256(script.read_bytes()).hexdigest(),
                            "compile_exit": built.returncode, "compile_stderr": built.stderr,
                            "protocol_exit": ran.returncode, "actual_tool_call_ids": [call["id"] for call in calls],
                            "auth_probe": auth_results,
                            "explicit_terminal_frames": terminals,
                            "checks": ("first auth document is cut, second is valid, then one explicit terminal"
                                       if label == "auth_retry_after" else
                                       "actual three requests acknowledged; old fixture has no result; repaired fixture emits one explicit terminal")})
        finally:
            script.unlink()
            script.with_name(script.name + ".auth-first").unlink(missing_ok=True)

receipt = {"scope": "Actual fixture OCaml generator and generated shell/stdin/stdout protocol only; not Host, Owner, native MASC suite, SDK, vendor, runtime or model-success execution",
           "base_head": BASE, "results": records}
(OUT / "fixture-protocol-check.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps({"variants": [{"name": row["variant"], "calls": len(row["actual_tool_call_ids"]),
                                "terminal_frames": len(row["explicit_terminal_frames"])} for row in records],
                  "result": "PASS", "scope": receipt["scope"]}, indent=2))
