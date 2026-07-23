(** MASC-owned HITL domain judgment over the provider-neutral OAS exact-output
    flow. MASC freezes the request and domain schema, validates the returned
    judgment, and owns approval queue durability. OAS alone owns candidate
    admission, attempt allocation, execution, failover, receipts, and
    provenance. *)

val readiness : unit -> (unit, string) result
(** Verify that the Gate prompt and the registry-owned [hitl_auto_judge] exact
    lane are currently available. No provider/model/runtime scalar is read. *)

val spawn
  :  sw:Eio.Switch.t
  -> entry:Keeper_approval_queue.pending_approval
  -> on_summary:(Keeper_approval_queue.hitl_context_summary -> unit)
  -> on_finish:(unit -> unit)
  -> unit
  -> (unit, string) result
(** Freeze and admit the whole ordered flow before forking. The production OAS
    callbacks bind/release the real candidate receipt in the durable approval
    queue. A summary reaches [on_summary] only after domain validation, exact
    receipt/provenance verification, and [Fsync_completed] completion. *)

module For_testing : sig
  val system_prompt : unit -> (string, string) result

  type context_bundle_error = Exact_request_context_unavailable

  val build_context_bundle
    :  entry:Keeper_approval_queue.pending_approval
    -> (Yojson.Safe.t, context_bundle_error) result

  val context_bundle_error_to_string : context_bundle_error -> string

  val messages_for_summary
    :  system_prompt:string
    -> context_bundle:Yojson.Safe.t
    -> Agent_sdk.Types.message list

  val parse_summary
    :  generated_at:float
    -> model_run_id:string
    -> Yojson.Safe.t
    -> (Keeper_approval_queue.hitl_context_summary, string) result

  type prepared_flow

  val prepare_flow
    :  entry:Keeper_approval_queue.pending_approval
    -> (prepared_flow, string) result

  val execute_prepared_flow
    :  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
    -> ?clock:_ Eio.Time.clock
    -> on_summary:(Keeper_approval_queue.hitl_context_summary -> unit)
    -> prepared_flow
    -> unit

  val flow_evidence : prepared_flow -> Agent_sdk.Exact_output.flow_evidence
  val success_provenance_matches : Agent_sdk.Exact_output.flow_success -> bool
  val summary_version : int
  val lane_id : string
end
