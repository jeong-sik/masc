(** Private affine generation receipt and immutable evidence snapshot. *)

type call_id = Call_id of string
type provider_trace = Exact_output_provider_trace.t
type response_family = Openai_responses_codec | Other_http_codec

type effect_phase =
  | Not_started
  | Before_dispatch
  | Dispatch_started
  | Response_received
  | Terminal

type response_evidence_field =
  | Http_status_field
  | Provider_trace_field

exception Conflicting_response_evidence of response_evidence_field

type t
type snapshot

val create
  :  call_id:call_id
  -> plan_fingerprint:string
  -> request_body_sha256:string
  -> binding:Exact_output_plan.binding_observation
  -> response_family:response_family
  -> catalog_generation:Exact_output_resolver.catalog_generation
  -> catalog_evidence:Exact_output_resolver.catalog_evidence
  -> target_identity:Exact_output_resolver.target_identity
  -> t

val start : t -> unit
val observe_execution_started : t -> at:float -> unit
val observe_execution_finished : t -> at:float -> unit
(** Host wall-clock boundaries of the generation executor. A finish is only
    recorded after a start; cancellation can leave it absent. Neither time
    proves dispatch, provider acceptance or remote termination. *)
val call_id : t -> call_id
val phase : t -> effect_phase
val dispatch_count : t -> int
val http_status : t -> int option
val provider_trace : t -> provider_trace option
val plan_fingerprint : t -> string
val request_body_sha256 : t -> string
val catalog_generation : t -> Exact_output_resolver.catalog_generation
val catalog_evidence : t -> Exact_output_resolver.catalog_evidence
val target_identity : t -> Exact_output_resolver.target_identity
val generation_dispatched : t -> bool
val observe_phase : t -> Http_client_phase_observer.phase -> unit
val synchronize : t -> Exact_output_execution.one_dispatch_receipt -> unit
val record_provider_trace : t -> provider_trace -> unit
val snapshot : t -> snapshot
val snapshot_phase : snapshot -> effect_phase
val snapshot_dispatch_count : snapshot -> int
val snapshot_generation_dispatched : snapshot -> bool
val snapshot_http_status : snapshot -> int option
val snapshot_response_family : snapshot -> response_family
val snapshot_response_body_sha256 : snapshot -> string option
val snapshot_responses_lifecycle : snapshot -> Backend_openai_responses.lifecycle_observation option
val snapshot_call_id : snapshot -> call_id
val snapshot_plan_fingerprint : snapshot -> string
val snapshot_request_body_sha256 : snapshot -> string
val snapshot_binding : snapshot -> Exact_output_plan.binding_observation
val snapshot_execution_started_at : snapshot -> float option
val snapshot_execution_finished_at : snapshot -> float option
