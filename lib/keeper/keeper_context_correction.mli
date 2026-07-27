(** Per-turn LLM semantic replacement after the main provider run. Uses an
    isolated exact flow and the existing checkpoint CAS only. *)

val lane_id : string
val state_context_key : string

type submission = Unavailable | Coalesced | Submitted

val init : sw:Eio.Switch.t -> unit
val submit :
  base_path:string -> keeper_name:string -> (unit -> unit) -> submission

val bind_marker_from_resume :
  resume_checkpoint:Agent_sdk.Checkpoint.t option ->
  Agent_sdk.Context.t ->
  unit

val prepare_raw_checkpoint :
  resume_checkpoint:Agent_sdk.Checkpoint.t option ->
  Agent_sdk.Checkpoint.t ->
  Agent_sdk.Checkpoint.t

type provenance =
  { slot_id : string; call_id : string; plan_fingerprint : string;
    request_body_sha256 : string; response_body_sha256 : string;
    http_status : int option; provider_trace_fingerprint : string option;
    catalog_generation_fingerprint : string; catalog_evidence_sha256 : string;
    target_identity_fingerprint : string }

type preserved_reason =
  | Control_checkpoint | Raw_save_superseded | Fresh_state_required
  | Marker_corrupt
  | No_closed_delta | Closed_unit_over_budget | Network_unavailable
  | Clock_unavailable | Exact_lane_unavailable | Exact_flow_failed
  | Semantic_output_invalid | Deadline_exceeded
  | Deadline_exceeded_before_cas | Cas_conflict | Cas_not_installed

type outcome =
  | Applied of
      { checkpoint : Agent_sdk.Checkpoint.t; raw_ref : Keeper_checkpoint_ref.t;
        installed_ref : Keeper_checkpoint_ref.t; provenance : provenance }
  | Preserved of
      { checkpoint : Agent_sdk.Checkpoint.t; raw_ref : Keeper_checkpoint_ref.t;
        reason : preserved_reason; detail : Yojson.Safe.t option }
  | Skipped of { reason : preserved_reason; detail : Yojson.Safe.t option }

val run :
  timeout_s:float ->
  keeper_name:string ->
  session_dir:string ->
  raw_checkpoint:Agent_sdk.Checkpoint.t ->
  raw_ref:Keeper_checkpoint_ref.t ->
  outcome

val checkpoint_of_outcome : outcome -> Agent_sdk.Checkpoint.t option
val outcome_to_json : outcome -> Yojson.Safe.t
val submission_to_json : submission -> Yojson.Safe.t

module For_testing : sig
  type marker

  val genesis_marker : marker
  val marker_to_json : marker -> Yojson.Safe.t
  val marker_of_json : Yojson.Safe.t -> (marker, preserved_reason) result

  val prepare_candidate : marker:marker -> raw_checkpoint:Agent_sdk.Checkpoint.t ->
    semantic_context:string ->
    (Agent_sdk.Checkpoint.t * marker, preserved_reason) result

  val classify_installation : raw_checkpoint:Agent_sdk.Checkpoint.t ->
    raw_ref:Keeper_checkpoint_ref.t -> candidate:Agent_sdk.Checkpoint.t ->
    provenance:provenance ->
    Keeper_checkpoint_store.checkpoint_installation ->
    outcome

  val reset_executor : unit -> unit
  val in_flight : base_path:string -> keeper_name:string -> bool
  val pending : base_path:string -> keeper_name:string -> bool
  val executor_generation : unit -> int option
end
