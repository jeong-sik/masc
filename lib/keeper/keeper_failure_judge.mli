(** Independent, tool-free LLM boundary for durable
    {!Keeper_event_queue.Failure_judgment} stimuli.

    Runtime/provider selection remains an OAS concern reached through the
    opaque [Runtime.runtime_id_for_structured_judge] identity. MASC supplies
    one provider-neutral JSON schema and strictly decodes the response.

    That identity may name a lane or a single runtime, the two-shape value
    [runtime].cross_verifier already carries. When it names a lane, a response
    that does not satisfy the contract advances to the next candidate instead of
    ending the walk — see {!advances_walk} for which failures do that and why. *)

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

val error_detail : run_error -> string
val error_disposition : run_error -> error_disposition
val error_disposition_label : error_disposition -> string
(** A failure that survives the whole candidate walk terminates the judgment
    stimulus explicitly; process-local observations are not durable retry
    authority. Before 2026-07-26 this also read "there is no alternate judge
    runtime to rotate to", which described a single-id identity — a lane now
    supplies candidates and {!advances_walk} says which failures use them. *)

val advances_walk : run_error -> bool
(** Whether this failure should be re-asked of the next lane candidate.

    True only for {!Response_contract_error}. The request states its object shape
    in the prompt and asks the provider for no wire format, so whether the reply
    parses is that runtime's formatting behaviour and another candidate is a
    different behaviour. False for the other three: a prompt-contract error is
    identical for every candidate, a runtime-configuration error is about the
    configured identity rather than the runtime that answered, and an
    {!Oas_error} has already been through OAS's own candidate handling, so
    walking it again would dispatch the same turn twice for one stimulus. *)

val resolve_candidates : unit -> (string list, run_error) result
(** Ordered candidates for {!run}, from the configured structured-judge identity.
    A lane yields its ordered candidates; a single runtime yields a one-element
    list, so both shapes take one code path. An empty lane and an identity that
    names neither are configuration errors rather than an empty walk.

    Configuration errors are returned explicitly when the durable stimulus
    executes; they do not become pre-claim admission authority. *)

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
