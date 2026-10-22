(** Offline input-journal recovery. Preparation preserves original journals;
    explicit installation and conditional restoration hold the BasePath lease
    and retain immutable source/adoption/intent evidence. *)

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
  | Installation_intent_unconfirmed of Fs_compat.atomic_replace_failure

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
    Reconfirmation refreshes only that exact retained file's captured identity;
    unrelated evidence and subsequent edits still invalidate publication.
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

type installation_plan
type installation_record
type replacement = Replaced of installation_record | Replacement_unconfirmed of installation_record
type installed_journal = Original_present | Adopted_present | Changed | Missing

val assess_installation : base_path:string -> adoption_id:string -> (installation_plan, error) result
(** Read-only verification of the adoption and source bundles against the exact
    original live journal and current metadata/canonical input. No installation
    authority is inferred from a manifest or a missing historical input row. *)
val installation_plan_to_json : installation_plan -> Yojson.Safe.t
val install : run_dir:string -> expected_source_sha256:string -> expected_adopted_sha256:string ->
  installation_plan -> (replacement, error) result
(** Holds the configured BasePath lease, reconfirms exact retained-payload
    durability, durably writes a private intent, then revalidates all captured
    evidence and atomically replaces only the selected
    journal. Source/adoption bundles remain immutable. After-rename sync failure
    is [Replacement_unconfirmed]. An intent may exist without any replacement.
    Cancellation propagates; use restart inspection to determine actual bytes.
    Independent editors must respect offline maintenance. Revalidation is not
    an atomic POSIX CAS against noncooperating writers. *)
val installation_id : installation_record -> string
val installation_record_to_json : installation_record -> Yojson.Safe.t
val load_installation : base_path:string -> installation_id:string -> (installation_record, error) result
(** Read-only verification of a private intent and its source/adoption evidence;
    existence of an intent is not installation, durability or authorship proof. *)
val inspect_installation : base_path:string -> installation_id:string ->
  (installation_record * installed_journal, error) result
(** Snapshot classification of actual live journal bytes. Does not certify past
    fsyncs, current input freshness, or future replacement/rollback permission. *)
val installed_journal_to_string : installed_journal -> string
val list_installations : base_path:string ->
  ((string * (installation_record * installed_journal, error) result) list, error) result
(** Read-only owned directory discovery after a crash before an id was returned.
    Missing inventory stays absent. Every observed entry keeps its id and either
    its verified byte classification or its error; partial/corrupt entries do
    not hide other records, infer no-write or trigger repair. *)
val restore_installation : run_dir:string -> installation_record -> (replacement, error) result
(** Restores only if the live journal is exactly the recorded adopted bytes and
    current metadata/canonical still match the adopted selection. Holds the same
    BasePath lease, refuses SQLite companions and preserves current permissions.
    The source/adoption/intent evidence remains. Later edits refuse restoration. *)

module For_testing : sig
  val install : ?sync_intent_parent:(string -> unit) -> before_replacement:(unit -> unit) -> sync_target_parent:(string -> unit) ->
    run_dir:string -> expected_source_sha256:string -> expected_adopted_sha256:string ->
    installation_plan -> (replacement, error) result
  val restore_installation : before_replacement:(unit -> unit) -> sync_target_parent:(string -> unit) ->
    run_dir:string -> installation_record -> (replacement, error) result
  val confirm_input_retention : Keeper_checkpoint_store.checkpoint_installation -> (unit, error) result
  val prepare : before_publication:(unit -> unit) -> sync_manifest_parent:(string -> unit) ->
    run_dir:string -> plan -> (publication, error) result
  val adopt_input : before_publication:(unit -> unit) -> sync_manifest_parent:(string -> unit) ->
    run_dir:string -> expected_checkpoint_sha256:string -> input_plan -> (input_publication, error) result
end
