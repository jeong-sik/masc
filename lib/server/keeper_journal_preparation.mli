(** Offline recovery bundles for the input ownership journal. These functions
    never install a copy or modify the original journal. *)

type plan
type receipt

type failure =
  | Invalid_keeper of string
  | Workspace_in_use
  | Unsafe_path of string
  | Source_absent
  | Source_changed
  | Companion_present of string
  | Store_failed of Keeper_chat_operation_store.error
  | Io_failed of { path : string; detail : string }
  | Invalid_bundle
  | Bundle_workspace_mismatch of { recorded_base_path : string; current_base_path : string }

type error = { bundle_id : string option; failure : failure }
val error_message : error -> string

val assess : base_path:string -> keeper_name:string -> (plan, error) result
(** Owned read of the existing canonical journal. No lease, schema conversion,
    initialization or write. A plan is an observation, not permission to install. *)
val plan_to_json : plan -> Yojson.Safe.t
val source_sha256 : plan -> string

type publication = Published of receipt | Publication_unconfirmed of receipt

val prepare : run_dir:string -> plan -> (publication, error) result
(** Acquires the same exclusive BasePath lease as server startup; [run_dir]
    must be the configured host lease directory. Refuses changed source bytes,
    descriptor identity or SQLite companions. Saves an owned private original
    and prepared copy, closes and syncs them, rechecks the source, then publishes
    the manifest through the shared atomic writer. After-rename sync failure
    is Publication_unconfirmed, never no-write or permission to retry blindly.

    Errors may leave an incomplete bundle identified by [error.bundle_id];
    retain it for inspection. No cleanup, source replacement or installation
    occurs. Prior input remains unavailable and ready_to_install is false. *)

val receipt_to_json : receipt -> Yojson.Safe.t
val bundle_id : receipt -> string
val load_recovery : base_path:string -> bundle_id:string -> (receipt, error) result
(** Owned read-only recovery of a published bundle. Verifies hashes, exact
    original/prepared schemas and every original cell/sequence, unavailable
    prior input, and the recomputed manifest. Does not certify past fsyncs or
    current live-source freshness. Never supplies an installation capability.

    Bundles remain bound to their recorded canonical workspace location.
    A valid bundle read after moving or copying the workspace returns
    [Bundle_workspace_mismatch]; it is not silently rebound to the new path.
    A symlink spelling of the same canonical workspace is accepted. *)

module For_testing : sig
  val prepare : before_publication:(unit -> unit) -> sync_manifest_parent:(string -> unit) ->
    run_dir:string -> plan -> (publication, error) result
end
