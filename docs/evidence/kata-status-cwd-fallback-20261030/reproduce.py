#!/usr/bin/env python3
"""Exercise extracted Kata cwd selection in isolated child processes.

No container runtime, server, VM, or network connection is started. The caller
must supply a new output path; an existing receipt is never overwritten.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[3]
CONTROL = ROOT / "lib/keeper/keeper_sandbox_control.ml"
RESOLVER = ROOT / "lib/config_dir_resolver/config_dir_resolver.ml"
SCRUB = ROOT / "lib/env_keeper_scrub.ml"


def between(source, start, end):
    first = source.index(start)
    return source[first : source.index(end, first)]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    control = CONTROL.read_text()
    resolver = RESOLVER.read_text()
    resolver_part = between(resolver, "let fallback_cwd_from_env () =", "let base_path_or_cwd () =")
    context_part = between(control, "type kata_host_environment_alignment =", "let read_kata_name_with ")
    alignment_part = between(control, "let kata_alignment_json =", "let kata_name_state =")
    logs_part = between(control, "let sandbox_log_commands_with ", "let sandbox_log_list_containers ")

    prelude = r'''
module Env_config_core = struct exception Config_error of string end
module Host_config = struct
  type t = {base_path:string option; home:string option}
  let from_env () =
    if Sys.getenv_opt "FIXTURE_RESOLVER_FAILURE" = Some "1" then
      raise (Env_config_core.Config_error "fixture");
    let read key = match Sys.getenv_opt key with
      | Some value when String.trim value <> "" -> Some value
      | Some _ | None -> None in
    {base_path=read "MASC_BASE_PATH"; home=read "HOME"}
end
module Config_dir_resolver = struct
'''
    stubs = r'''
end
type sandbox_profile = Docker | Micro_vm | Remote_ssh
module Keeper_microvm_backend = struct
  type t = Nerdctl_kata | Apple_container | Microsandbox
end
type keeper_meta = {sandbox_profile:sandbox_profile;
  microvm_backend:Keeper_microvm_backend.t option; name:string}
module Workspace = struct type config = {base_path:string} end
module Keeper_sandbox_runtime = struct
  type live_container = {id:string; name:string; running:bool option}
end
module Keeper_sandbox_exec_failure = struct let status_label _ = "fixture" end
module Json_util = struct
  let bool_opt_to_json = function Some value -> `Bool value | None -> `Null
end
type sandbox_log_backend = Docker_logs | Micro_vm_logs of Keeper_microvm_backend.t
type sandbox_logs_error = Sandbox_logs_backend_failed of string
let sandbox_log_backend_label _ = "nerdctl_kata"
let sandbox_log_argv _ ~tail:_ ~container_id = ["nerdctl"; "logs"; container_id]
'''
    probe = r'''
let () =
  let meta = {sandbox_profile=Micro_vm;
    microvm_backend=Some Keeper_microvm_backend.Nerdctl_kata; name="fixture"} in
  let config : Workspace.config = {base_path="/fixture"} in
  let context = kata_execution_context meta in
  let expected = Sys.getenv "FIXTURE_EXPECT" in
  let expected_cwd = Sys.getenv_opt "FIXTURE_EXPECT_CWD" in
  let inventory_calls = ref 0 and log_lists = ref 0 and log_reads = ref 0 in
  let check_context = function
    | Some (env, cwd) ->
      assert (Some cwd = expected_cwd);
      assert (not (Array.exists (String.starts_with ~prefix:"FIXTURE_SECRET=") env))
    | None -> failwith "missing explicit execution context" in
  let observe ~execution_context ~config:_ ~meta:_ ~timeout_sec:_ =
    incr inventory_calls; check_context execution_context; Ok [] in
  let list_containers ~env ~cwd ~backend:_ ~config:_ ~keeper_name:_ ~timeout_sec:_ =
    incr log_lists;
    check_context (Option.bind env (fun env -> Option.map (fun cwd -> env,cwd) cwd));
    Ok [{Keeper_sandbox_runtime.id="fixture-id"; name="fixture"; running=None}] in
  let read_logs ~env ~cwd ~timeout_sec:_ ~argv:_ =
    incr log_reads;
    check_context (Option.bind env (fun env -> Option.map (fun cwd -> env,cwd) cwd));
    Unix.WEXITED 0, "fixture-stdout", "fixture-stderr" in
  let inventory = read_microvm_inventory_with ~observe ~context ~config ~meta ~timeout_sec:1. in
  let logs = sandbox_log_commands_with ~list_containers ~read_logs ~config ~meta
      ~backend:(Micro_vm_logs Keeper_microvm_backend.Nerdctl_kata) ~context ~timeout_sec:1. ~tail:1 in
  if expected = "ok" then
    (match context with
     | Some (Ok context) ->
       assert (Some context.cwd = expected_cwd);
       assert (Result.is_ok inventory && Result.is_ok logs);
       assert (!inventory_calls = 1 && !log_lists = 1 && !log_reads = 1)
     | Some (Error ()) | None -> failwith "expected a usable context")
  else if expected = "error" then
    (match context with
     | Some (Error ()) ->
       assert (Result.is_error inventory && Result.is_error logs);
       assert (!inventory_calls = 0 && !log_lists = 0 && !log_reads = 0)
     | Some (Ok _) | None -> failwith "expected an unavailable context")
  else failwith "invalid fixture expectation";
  print_endline "passed"
'''

    with tempfile.TemporaryDirectory(prefix="masc-kata-cwd-fixture-") as temp:
        work = Path(temp).resolve()
        (work / "env_keeper_scrub.ml").write_bytes(SCRUB.read_bytes())
        (work / "fixture.ml").write_text(prelude + resolver_part + stubs + context_part + alignment_part + logs_part + probe)
        compile_result = subprocess.run(
            ["ocamlfind", "ocamlc", "-w", "+4", "-warn-error", "+4", "-package", "yojson,unix",
             "-linkpkg", "-o", "fixture", "env_keeper_scrub.ml", "fixture.ml"],
            cwd=work, capture_output=True, text=True, timeout=30, check=False,
        )
        if compile_result.returncode:
            raise RuntimeError("fixture compilation failed: " + compile_result.stderr)
        base, home, temporary = (work / name for name in ("base", "home", "tmp"))
        for path in (base, home, temporary):
            path.mkdir()
        regular = work / "regular"
        regular.write_text("fixture")
        cases = [
            ("current_directory", False, str(base), str(home), "ok", str(base), False),
            ("deleted_cwd_base_fallback", True, str(base), str(home), "ok", str(base), False),
            ("deleted_cwd_home_fallback", True, "", str(home), "ok", str(home), False),
            ("deleted_cwd_temp_fallback", True, "", "", "ok", str(temporary), False),
            ("deleted_cwd_missing_base", True, str(work / "missing"), str(home), "error", "", False),
            ("deleted_cwd_regular_base", True, str(regular), str(home), "error", "", False),
            ("deleted_cwd_resolver_failure", True, str(base), str(home), "error", "", True),
        ]
        outcomes = []
        for label, delete_cwd, base_value, home_value, expected, expected_cwd, resolver_failure in cases:
            cwd = work / ("cwd-" + label)
            cwd.mkdir()
            env = {"PATH": "/usr/bin:/bin", "TMPDIR": str(temporary),
                   "MASC_BASE_PATH": base_value, "HOME": home_value,
                   "FIXTURE_EXPECT": expected, "FIXTURE_SECRET": "synthetic-secret"}
            if expected_cwd:
                env["FIXTURE_EXPECT_CWD"] = str(cwd if label == "current_directory" else expected_cwd)
            if resolver_failure:
                env["FIXTURE_RESOLVER_FAILURE"] = "1"

            def prepare():
                os.chdir(cwd)
                if delete_cwd:
                    os.rmdir(cwd)

            result = subprocess.run([str(work / "fixture")], cwd=work, env=env,
                preexec_fn=prepare, capture_output=True, text=True, timeout=10, check=False)
            if result.returncode != 0 or result.stdout.strip() != "passed":
                raise RuntimeError(f"{label} failed (exit {result.returncode}): {result.stderr}")
            outcomes.append({"case": label, "exit": result.returncode, "decision": expected})
        receipt = {"schema": 1, "source_sha256": {
            "keeper_sandbox_control.ml": digest(CONTROL),
            "config_dir_resolver.ml": digest(RESOLVER),
            "env_keeper_scrub.ml": digest(SCRUB),
            "reproduce.py": digest(Path(__file__))},
            "scope": "extracted OCaml with stub Host_config, runtime and CLI callbacks",
            "cases": outcomes}
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(receipt, stream, indent=2, sort_keys=True)
            stream.write("\n")
        print(f"{len(outcomes)} isolated cwd cases passed; receipt written")


if __name__ == "__main__":
    run()
