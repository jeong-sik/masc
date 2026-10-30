#!/usr/bin/env python3
"""Compile selected cache functions from source with base and Eio stubs."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--repo", required=True, type=Path)
parser.add_argument("--receipt", required=True, type=Path)
args = parser.parse_args()
runtime = (args.repo / "lib/keeper/keeper_turn_sandbox_runtime.ml").read_text()
shim = (args.repo / "lib/keeper/keeper_microvm_shim_readiness.ml").read_text()
def section(source, start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]

cache_code = section(runtime, "type microvm_work_root_key =", "(* Whether an adoptable")
shim_types = section(shim, "type key =", "let current_token")
shim_forget = shim[shim.index("let rec forget ~backend ~guest_name ="):]
stubs = r'''
module Keeper_microvm_backend = struct type t = Apple_container | Nerdctl_kata | Microsandbox end
module Keeper_sandbox_runtime_setup = struct let normalize_base_path_for_hash x = x end
module Keeper_microvm_guest_size = struct type t = unit end
module Eio = struct module Lazy = struct type 'a t = unit end end
module Keeper_microvm_shim_readiness = struct
type error = unit
let ( let* ) = Result.bind
let base_key ~base_path = Ok base_path
let error_message (_ : error) = "shim error"
'''
tests = r'''
let () =
  let module B = Keeper_microvm_backend in
  let module S = Keeper_microvm_shim_readiness in
  let guest = "same-name" and other = "other-name" and first = "/first" and second = "/second" in
  let a = B.Apple_container and k = B.Nerdctl_kata in
  let mark base backend = mark_microvm_work_root_ready ~base_path:base ~backend ~container_name:guest in
  let ready base backend = microvm_work_root_ready ~base_path:base ~backend ~container_name:guest in
  let entry = {S.token=ref (); work=()} in
  Atomic.set S.verifications [((first,a,guest),entry); ((second,a,guest),entry);
    ((first,k,guest),entry); ((first,a,other),entry)];
  mark first a; mark second a; mark first k;
  mark_microvm_work_root_ready ~base_path:first ~backend:a ~container_name:other;
  let boot = {policy_port=None; image="kata-fixture"; guest_size=()} in
  record_microvm_boot guest boot;
  forget_microvm_guest_state ~backend:a ~container_name:guest;
  assert (not (ready first a)); assert (not (ready second a)); assert (ready first k);
  assert (microvm_work_root_ready ~base_path:first ~backend:a ~container_name:other);
  assert (microvm_boot guest = Some boot);
  assert (List.length (Atomic.get S.verifications) = 2);
  assert (List.mem_assoc (first,k,guest) (Atomic.get S.verifications));
  assert (List.mem_assoc (first,a,other) (Atomic.get S.verifications));
  print_endline "PASS: Apple invalidation clears same-name bases and preserves other-name and Kata state"
'''
program = stubs + shim_types + shim_forget + "\nend\n" + cache_code + tests
with tempfile.TemporaryDirectory(prefix="masc-cache-extract-") as temp:
    tmp = Path(temp)
    (tmp / "cache.ml").write_text(program)
    compiled = subprocess.run(["ocamlc", "-o", str(tmp / "cache"), str(tmp / "cache.ml")], capture_output=True, text=True)
    run = None if compiled.returncode else subprocess.run([str(tmp / "cache")], capture_output=True, text=True)
receipt = {
    "scope": "actual readiness and invalidation functions with stub base normalization, Eio and guest size; no runtime or VM",
    "runtime_source_sha256": hashlib.sha256(runtime.encode()).hexdigest(),
    "shim_source_sha256": hashlib.sha256(shim.encode()).hexdigest(),
    "program_sha256": hashlib.sha256(program.encode()).hexdigest(),
    "compile_exit": compiled.returncode,
    "compile_stderr": compiled.stderr,
    "run_exit": None if run is None else run.returncode,
    "stdout": None if run is None else run.stdout,
    "stderr": None if run is None else run.stderr,
}
args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps(receipt, indent=2))
raise SystemExit(0 if compiled.returncode == 0 and run and run.returncode == 0 else 1)
