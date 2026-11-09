(** The start of a keeper's guest on a process-bound backend (Nerdctl with
    Kata, or Microsandbox): it reads the backend, the image and the guest
    size, probes the guest, adopts a running one whose boot record, identity
    snapshot, image, size and proxy port still match, and otherwise replaces
    it and boots a fresh guest with its provisions and identity snapshot.

    [Keeper_turn_sandbox_runtime] includes this module. *)

open Keeper_turn_sandbox_runtime_record
open Keeper_turn_sandbox_runtime_start_failure

val start_process_bound_microvm_container :
  ?timeout_sec:float ->
  t ->
  (string,
   microvm_start_failure)
  result
