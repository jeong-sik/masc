#!/usr/bin/env python3
"""Compile the actual Apple scope helpers against an intentionally tiny provider stub."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--source", required=True, type=Path)
parser.add_argument("--receipt", required=True, type=Path)
args = parser.parse_args()
source = args.source.read_text()
observation = source[source.index("type apple_guest_observation ="):source.index("let read_apple_guest", source.index("type apple_guest_observation ="))]
helpers = source[source.index("let check_apple_guest_scope"):source.index("(* OCI Entrypoint", source.index("let check_apple_guest_scope"))]
stubs = r'''
module Result = struct
  include Stdlib.Result
  module Syntax = struct let ( let* ) = Stdlib.Result.bind end
end
module Keeper_microvm_boot_plan = struct
  type facts = { labels : (string * string) list }
  type reading = Facts of facts | Unreadable of string
end
module Keeper_microvm_backend = struct
  type t = Apple_container
  let to_string Apple_container = "apple"
end
module Keeper_sandbox_microvm = struct
  let keeper_vm_container_kind = "keeper-vm"
  let microvm_backend_label_key = "backend"
end
module Keeper_types_profile_sandbox = struct
  type network_mode = None_mode | Inherit | Policy
  let all_network_modes = [None_mode; Inherit; Policy]
  let network_mode_to_string = function
    | None_mode -> "none" | Inherit -> "inherit" | Policy -> "policy"
end
module Keeper_sandbox_runtime_setup = struct
  let stable_labels ~base_path ~keeper_name ~container_kind ~network_label =
    ["base", base_path; "keeper", keeper_name; "kind", container_kind;
     "network", network_label; "component", "masc"]
end
module Keeper_sandbox_container_name = struct
  type t = Micro_vm_persistent of {base_path:string; keeper_name:string;
                                 network_mode:Keeper_types_profile_sandbox.network_mode}
  let make (Micro_vm_persistent {base_path=_; keeper_name=_; network_mode}) =
    Keeper_types_profile_sandbox.network_mode_to_string network_mode
  let to_string x = x
end
'''
provider = r'''
let guests = Hashtbl.create 4
let reads = ref []
let effects = ref []
let read_apple_guest ~timeout_sec ~container_name =
  reads := (container_name, timeout_sec) :: !reads;
  match Hashtbl.find_opt guests container_name with
  | Some observation -> Ok observation
  | None -> Ok Apple_absent
let microvm_start_failure_message x = x
let stop_and_delete_microvm_container ~timeout_sec:_ ~backend:_ name =
  effects := name :: !effects; Ok ()
'''
tests = r'''
let require name condition = if not condition then failwith name else Printf.printf "PASS %s\n" name
let base_path = "workspace-A" and keeper_name = "shared" and timeout_sec = 2.5
let mode = Keeper_types_profile_sandbox.None_mode
let labels = Keeper_sandbox_runtime_setup.stable_labels ~base_path ~keeper_name
    ~container_kind:Keeper_sandbox_microvm.keeper_vm_container_kind ~network_label:"none"
  @ [Keeper_sandbox_microvm.microvm_backend_label_key, "apple"]
let reading labels = Keeper_microvm_boot_plan.Facts {labels}
let check reading = check_apple_guest_scope ~base_path ~keeper_name ~network_mode:mode
    ~container_name:"none" reading
let observe x = check_apple_guest_observation ~base_path ~keeper_name ~network_mode:mode
    ~container_name:"none" x
let stop () = stop_owned_apple_guest ~base_path ~keeper_name ~network_mode:mode
    ~timeout_sec ~container_name:"none"
let preflight () = check_apple_guest_modes ~base_path ~keeper_name ~timeout_sec
let is_error = function Error _ -> true | Ok _ -> false
let () =
  require "matching labels accepted" (check (reading (("extra","x") :: labels)) = Ok ());
  List.iter (fun (key, _) ->
    require ("missing " ^ key ^ " refused")
      (is_error (check (reading (List.remove_assoc key labels))));
    require ("different " ^ key ^ " refused")
      (is_error (check (reading ((key,"foreign") :: List.remove_assoc key labels))))) labels;
  require "unreadable refused" (is_error (check (Keeper_microvm_boot_plan.Unreadable "invalid")));
  require "absent observation accepted" (observe Apple_absent = Ok ());
  require "owned stopped accepted" (observe (Apple_stopped (reading labels)) = Ok ());
  require "owned running accepted" (observe (Apple_running (reading labels)) = Ok ());
  let foreign = ("base","workspace-B") :: List.remove_assoc "base" labels in
  require "foreign stopped refused" (is_error (observe (Apple_stopped (reading foreign))));
  require "foreign running refused" (is_error (observe (Apple_running (reading foreign))));
  require "absent stop has no effect" (stop () = Ok () && !effects = []);
  Hashtbl.replace guests "none" (Apple_running (reading foreign));
  require "foreign stop has no effect" (is_error (stop ()) && !effects = []);
  Hashtbl.replace guests "none" (Apple_running (reading labels));
  Hashtbl.replace guests "inherit" (Apple_stopped (reading foreign));
  require "all-mode preflight refuses foreign guest before effects" (is_error (preflight ()) && !effects = []);
  Hashtbl.remove guests "inherit";
  require "all-mode preflight accepts owned or absent" (preflight () = Ok ());
  Hashtbl.replace guests "none" (Apple_running (reading foreign));
  require "stop rechecks after preflight" (is_error (stop ()) && !effects = []);
  Hashtbl.replace guests "none" (Apple_running (reading labels));
  require "owned stop attempts effect" (stop () = Ok () && !effects = ["none"]);
  require "stub reads receive requested timeout" (List.for_all (fun (_, t) -> t = timeout_sec) !reads)
'''
program = stubs + observation + provider + helpers + tests
with tempfile.TemporaryDirectory(prefix="masc-scope-extract-") as temp:
    tmp = Path(temp)
    (tmp / "scope.ml").write_text(program)
    compile_result = subprocess.run(["ocamlc", "-o", str(tmp / "scope"), str(tmp / "scope.ml")], capture_output=True, text=True)
    run = None if compile_result.returncode else subprocess.run([str(tmp / "scope")], capture_output=True, text=True)
receipt = {
    "scope": "actual scope/stop/preflight functions compiled against fake labels, names, provider, errors and effects; no repository runtime or VM",
    "source_sha256": hashlib.sha256(source.encode()).hexdigest(),
    "program_sha256": hashlib.sha256(program.encode()).hexdigest(),
    "compile_exit": compile_result.returncode,
    "compile_stderr": compile_result.stderr,
    "run_exit": None if run is None else run.returncode,
    "stdout": None if run is None else run.stdout,
    "stderr": None if run is None else run.stderr,
}
args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps(receipt, indent=2))
raise SystemExit(0 if compile_result.returncode == 0 and run and run.returncode == 0 else 1)
