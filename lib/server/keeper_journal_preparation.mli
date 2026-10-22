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
  | Input_selection_invalid of string
  | Input_source_changed of string
  | Input_history_unresolved of string
  | Input_retention_unconfirmed of Keeper_checkpoint_store.checkpoint_installation

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

type input_plan
type input_adoption
type input_publication = Input_adopted of input_adoption | Input_adoption_unconfirmed of input_adoption

val assess_input : base_path:string -> bundle_id:string -> trace_id:string ->
  (input_plan, error) result
(** Owned read-only assessment of the verified source bundle, unchanged live
    journal, strict Keeper metadata/current trace and exact canonical bytes.
    Current retained continuations must preserve their full pending request
    and messages in the selected source. Immutable native seeds instead require
    preserved seed-to-latest messages; phase references keep their full check.
    Active or unknown-effect native calls and
    conflicting histories require repair; no newest-file or empty-pending
    inference selects authority. Assessment does not retain or write anything. *)
val input_plan_to_json : input_plan -> Yojson.Safe.t
val input_checkpoint_sha256 : input_plan -> string

val adopt_input : run_dir:string -> expected_checkpoint_sha256:string -> input_plan ->
  (input_publication, error) result
(** Explicit operator adoption of the assessed exact input state. Acquires the
    configured BasePath lease, revalidates all captured evidence, confirms
    durable retention at the input-owner location and derives a separate DB.
    Preserves source bundle, live journal, metadata and canonical checkpoint;
    publishes private metadata/checkpoint evidence and a separate manifest last.
    Retention failures preserve their exact installation evidence. Cancellation
    recorded during post-commit unwind is re-raised with its original backtrace;
    retained artifacts and partial bundles remain for inspection.
    Omitted traces remain unavailable. Before-publication changes refuse the
    manifest without deleting partial evidence. Uncertain manifest publication
    is distinct from no write. No journal installation or native dispatch. *)
val input_adoption_to_json : input_adoption -> Yojson.Safe.t
val input_adoption_id : input_adoption -> string
val load_input_adoption : base_path:string -> adoption_id:string ->
  (input_adoption, error) result
(** Owned read-only restart verification of the original bundle, private
    metadata/checkpoint/derivative, exact selection and retained payload. Does
    not validate current live-source freshness, certify past fsyncs or human
    authorship, or grant installation. All outputs keep ready_to_install=false. *)

module For_testing : sig
  val confirm_input_retention : Keeper_checkpoint_store.checkpoint_installation -> (unit, error) result
  val prepare : before_publication:(unit -> unit) -> sync_manifest_parent:(string -> unit) ->
    run_dir:string -> plan -> (publication, error) result
  val adopt_input : before_publication:(unit -> unit) -> sync_manifest_parent:(string -> unit) ->
    run_dir:string -> expected_checkpoint_sha256:string -> input_plan -> (input_publication, error) result
end
