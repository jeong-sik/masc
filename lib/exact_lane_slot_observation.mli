(** Passive facts about original visits, never dispatch/retry/ACK authority. *)

type binding =
  | Http of { provider_id:string option; model_id:string; provider_kind:string; endpoint:string }
  | Http_unobserved
  | Official_client
[@@deriving yojson]

type phase = Prepared | Before_dispatch | Dispatch_started | Response_received | Terminal
[@@deriving yojson]

type outcome =
  | Unresolved
  | Accepted
  | Semantic_rejected
  | Admission_rejected of Keeper_exact_walk_failure.local_rejection
  | Execution_failed of Keeper_exact_walk_failure.api_observation
  | Cli_failed of Keeper_exact_walk_failure.cli_observation
[@@deriving yojson]

type t = private
  { slot_id:string; lane_key:string option; binding:binding; call_id:string option; flow_id:string option;
    visit_ordinal:int option; plan_fingerprint:string option; request_body_sha256:string option;
    catalog_generation:string option; catalog_evidence:string option; target_identity:string option;
    phase:phase; generation_dispatched:bool;
    started_at:float option; finished_at:float option; outcome:outcome }

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t,string) result
(** Checks diagnostic data only. A malformed observation must never invalidate
    the original domain completion or an authoritative execution receipt. *)
val with_owner : Runtime_schema.exact_lane_owner -> t -> t
(** Freeze the producing route's typed owner. Logical run labels cannot supply it. *)

val of_evidence : Agent_core.Exact_output.flow_evidence -> t list
(** Retain reached visits and typed predecessor failures after cancellation.
    A return/acceptance is never inferred from a phase or run outcome. *)
val of_result :
  (('a,'b) Agent_core.Exact_output.validated_flow_success,
   ('c,'b) Agent_core.Exact_output.validated_flow_error) result -> t list

val cli : slot_id:string -> started_at:float option -> finished_at:float option ->
  generation_dispatched:bool -> outcome:outcome -> t
(** The official client's provider endpoint is unobserved by the host. *)
