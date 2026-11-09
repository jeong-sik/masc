(** Starting the container or guest of a turn: the dispatch of a microvm start
    to its backend, the start of a Docker container (adopt a running one,
    restart a stopped one, or create it), and the entrypoints that start a
    runtime once and report a failure with the side that is at fault or as one
    message.

    [Keeper_turn_sandbox_runtime] includes this module. *)

open Keeper_turn_sandbox_runtime_record
open Keeper_turn_sandbox_runtime_start_failure

val start_microvm_container :
  ?timeout_sec:float ->
  t ->
  (string,
   github_identity_preparation_error)
  result

val start_container :
  ?timeout_sec:float ->
  t ->
  (string,
   github_identity_preparation_error)
  result

val ensure_started_with_cause :
  ?validate_running:bool ->
  ?timeout_sec:float ->
  t ->
  (string,
   github_identity_preparation_error)
  result

val ensure_started :
  ?validate_running:bool ->
  ?timeout_sec:float ->
  t -> (string, string) result
