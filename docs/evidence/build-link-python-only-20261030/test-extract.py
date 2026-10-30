#!/usr/bin/env python3
"""Run selected exact test functions with extracted request builders and stubs."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

worktree = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=True)
source = (worktree / "lib/keeper/keeper_sandbox_microvm.ml").read_text()
tests = (worktree / "test/test_keeper_sandbox_microvm.ml").read_text()
def slice_between(s, start, end):
    begin = s.index(start)
    return s[begin:s.index(end, begin)]

builder = slice_between(source, "let checked_build_input_script consumer =", "(** The keeper's root on the work volume")
helpers = slice_between(tests, "let build_input_args_after", "let test_build_scan_does_not_turn_newlines")
collision = slice_between(tests, "let test_build_link_apply_preserves_racing_entries", "let test_build_target_mkdir_argv_runs_as_root")
validation = slice_between(tests, "let test_build_link_input_is_checked_before_effects", "let test_volume_create_argv_carries_a_size")
stub = '''module Backend = struct type t = Apple_container | Microsandbox | Nerdctl_kata end
module Agent_core_sha256 = Digestif.SHA256
module M = struct
let build_volume_guest_root = "/masc-build"
let exec_argv_for _ ~container_name:_ ~uid:_ ~gid:_ ~container_cwd:_ ~stdin ~command_argv =
  (if stdin then ["exec"; "-i"] else ["exec"]) @ command_argv
'''
extra = '''end
let temp_dir prefix =
  let path = Filename.temp_file prefix "" in Sys.remove path; Unix.mkdir path 0o700; path
module Fs_compat = struct
  let rec remove_tree path =
    match (Unix.lstat path).st_kind with
    | Unix.S_DIR -> Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
    | _ -> Sys.remove path
end
'''
main = """
let () = Alcotest.run "extracted build input tests" [
  "python wrapper", [
    Alcotest.test_case "interpreter selection" `Quick test_build_input_wrapper_selects_one_interpreter;
    Alcotest.test_case "collision" `Quick test_build_link_apply_preserves_racing_entries_and_continues;
    Alcotest.test_case "link validation" `Quick test_build_link_input_is_checked_before_effects;
    Alcotest.test_case "mkdir validation" `Quick test_build_target_input_is_checked_before_effects ] ]
"""

(out / "check.ml").write_text(stub + builder + extra + helpers + collision + validation + main)
compiled = subprocess.run(["ocamlfind", "ocamlc", "-package", "unix,digestif.c,alcotest", "-linkpkg", "-o", "check", "check.ml"], cwd=out, capture_output=True, text=True)
executed = None
if compiled.returncode == 0:
    executed = subprocess.run(["./check", "--color=never"], cwd=out, capture_output=True, text=True, timeout=120)
receipt = {"scope": "exact selected test functions and request builder source, simplified backend/exec/filesystem stubs; not full MASC test suite",
           "source_sha256": hashlib.sha256(source.encode()).hexdigest(),
           "test_sha256": hashlib.sha256(tests.encode()).hexdigest(),
           "compile_exit": compiled.returncode, "compile_stderr": compiled.stderr,
           "test_exit": None if executed is None else executed.returncode,
           "test_stdout": None if executed is None else executed.stdout,
           "test_stderr": None if executed is None else executed.stderr}
print(json.dumps(receipt))
sys.exit(0 if executed is not None and executed.returncode == 0 else 1)
