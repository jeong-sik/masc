(** One-shot LLM planning over structurally eligible Keeper history.

    The caller owns the Eio resources and Runtime assignment. Every rejected
    candidate remains typed and ordered; this boundary never substitutes a
    default Runtime or hides failure as [None]. *)

module History = Keeper_compaction_eligible_history
module Plan = Keeper_compaction_eligible_plan

type complete_fn = Keeper_provider_subcall.complete_fn

type structured_response_error =
  | Missing_text
  | Invalid_json of string

type candidate_failure_reason =
  | Runtime_missing
  | Schema_rejected of string
  | Transport_failed of Llm_provider.Http_client.http_error
  | Structured_response_rejected of structured_response_error
  | Plan_rejected of Plan.decode_error

type candidate_failure =
  { runtime_id : string
  ; reason : candidate_failure_reason
  }

type success =
  { plan : Plan.t
  ; selected_runtime_id : string
  ; failed_candidates : candidate_failure list
    (** Earlier candidates rejected in exact declaration order. *)
  }

type error =
  | Assignment_missing of string
  | Candidates_exhausted of
      { assignment_id : string
      ; failures : candidate_failure list
      }

(** Resolve [assignment_id] as a Runtime or ordered Lane and ask each
    candidate for a plan over [source]. The request contains only
    {!Plan.input_json}; protected history is never sent. Provider model,
    temperature, and sampling configuration remain those of the selected
    Runtime, while tools are disabled and {!Plan.output_schema} is required.

    No timeout, turn limit, budget, retry cap, ambient Eio context, or live
    Keeper heartbeat wiring exists here. *)
val run
  :  ?complete:complete_fn
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> keeper_name:string
  -> assignment_id:string
  -> source:History.t
  -> unit
  -> (success, error) result
