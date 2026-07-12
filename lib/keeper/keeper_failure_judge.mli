(** Independent, tool-free LLM boundary for durable
    {!Keeper_event_queue.Failure_judgment} stimuli.

    Runtime/provider selection remains an OAS concern reached through the
    opaque [Runtime.runtime_id_for_structured_judge] identity. MASC supplies
    one provider-neutral JSON schema and strictly decodes the response. *)

type run_error =
  | Runtime_configuration_error of string
  | Prompt_contract_error of string
  | Oas_error of
      { runtime_id : string
      ; error : Agent_sdk.Error.sdk_error
      }
  | Response_contract_error of
      { runtime_id : string
      ; detail : string
      }

type run_result =
  { runtime_id : string
  ; verdict : Keeper_failure_judgment_contract.verdict
  }

type error_disposition = Escalate_judge_failure

type claim_eligibility =
  | Claim_eligible
  | Claim_deferred_by_runtime_pacing of
      { runtime_id : string
      ; remaining_seconds : float
      }

val error_detail : run_error -> string
val error_disposition : run_error -> error_disposition
val error_disposition_label : error_disposition -> string
(** A failure of the single configured structured-judge boundary terminates the
    judgment stimulus explicitly. There is no alternate judge runtime to rotate
    to, and a process-local pacing table is not durable retry authority. *)

val resolve_runtime_id : unit -> (string, run_error) result
(** Resolve the same configured structured-judge lane used by {!run}. This
    lets the Keeper scheduler consult only that lane's pacing state; a
    configuration error is left runnable so {!run} can settle it explicitly. *)

val claim_eligibility : keeper_name:string -> claim_eligibility
(** Decide whether a durable failure-judgment stimulus may be claimed now.
    When pacing enforcement is active, only the exact configured judge runtime
    can defer the claim. Configuration errors remain eligible so one judge
    execution can settle them as explicit terminal evidence. *)

val build_prompt :
  keeper_name:string ->
  Keeper_event_queue.failure_judgment ->
  (string, string) result
(** Render [config/prompts/keeper.failure_judgment.md]. Failure evidence is
    injected as one JSON value so error text cannot become prompt authority. *)

val run :
  base_path:string ->
  keeper_name:string ->
  Keeper_event_queue.failure_judgment ->
  (run_result, run_error) result
(** Execute one tool-free call on the configured structured-judge runtime.
    Providers without native schema support use the prompt tier, but response
    parsing remains strict and fail-loud. *)
