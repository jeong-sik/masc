(** Binding a turn runtime to the current GitHub identity: retiring the
    current snapshot, stopping the container or guest so the next start
    mounts a fresh identity, and the preparation that refreshes an app token,
    starts the runtime and returns the credential files to redact.

    [Keeper_turn_sandbox_runtime] includes this module. *)

open Keeper_turn_sandbox_runtime_record
open Keeper_turn_sandbox_runtime_start_failure

val prepare_github_identity_secret_files :
  ?timeout_sec:float -> t -> (string list, github_identity_preparation_error) result
