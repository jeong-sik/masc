(** The model behind the Stagehand extension's [llm.generate]: masc answers
    it through the [browser_stagehand_exact] exact-output lane
    (RFC-browser-lane-stagehand §3.7).

    The request shape is [LLMGenerateParams] of the Stagehand v4 protocol
    ([packages/protocol/stagehand.v4.json] in browserbase/stagehand, read at
    476658b595b5). This step serves one shape of it: a structured
    ([json_schema]) answer over text-only messages. Everything else is
    refused with a typed reason before any provider is called.

    The schema goes to AGENT_CORE with [Json_syntax]: the schema is written
    into the prompt and masc checks only that the answer is one JSON value.
    [Provider_schema] is not used because providers accept different schema
    dialects (Gemini's allowlist has no [$schema] or [pattern]; OpenAI strict
    mode refuses [additionalProperties: {}], which Stagehand's extract schema
    carries). The extension checks the answer's shape with its own Zod schema,
    so masc adds no JSON Schema validator.

    The lane's [cli_slots] (subscription official clients) are walked as
    one-shots ({!Keeper_lane_cli_oneshot}) after every HTTP slot failed, or
    alone when the lane admits no HTTP slot. A one-shot gets the same schema
    sentence and the same one-JSON-value check. It takes one prompt and a
    separate system prompt, so a conversation with an assistant turn is not
    sent to it ({!cli_unfit}). *)

type role =
  | User
  | Assistant

(** A content block kind this step does not send to a provider. *)
type unserved_block =
  | Image_block
  | Tool_use_block
  | Tool_result_block

type block =
  | Text of string
  | Unserved of unserved_block

type message =
  { role : role
  ; content : block list
        (** The protocol allows one block or an array of them; one block is
            read as a one-element list. *)
  }

(** What the request asks the model to produce. *)
type generation =
  | Structured of
      { name : string
      ; schema : Yojson.Safe.t
      }
      (** [response_format.type = "json_schema"]. *)
  | Text_generation
      (** No [response_format], or [{"type": "text"}], and no tools. *)
  | Tool_generation of { tool_names : string list }
      (** The request declares client tools. *)

type request =
  { messages : message list
  ; system_prompt : string option
  ; temperature : float option
  ; stop_sequences : string list option  (** [None] when the request has none. *)
  ; generation : generation
  }
(** [temperature] and [stop_sequences] are read and not sent: an exact-output
    request carries no sampling controls, so the lane's binding decides them. *)

val parse_params : Yojson.Safe.t -> (request, string) result
(** Read [llm.generate] params. [Error] names the field that does not match
    the protocol. Keys the protocol does not define are ignored. *)

type slot_refusal =
  | System_prompt_not_accepted
      (** The slot's model takes no system prompt, and Stagehand's
          [system_prompt] must reach the system slot. *)

type refused_slot =
  { slot_id : string
  ; refusal : slot_refusal
  }

type admitted_lane =
  { http_slots : Runtime_exact_output_registry.selected_slot list
  ; cli_slots : string list
  ; refused_slots : refused_slot list
  }
(** At least one HTTP or CLI slot. HTTP slots are walked first in declaration
    order, then the CLI slots in {!Keeper_lane_cli_oneshot.walk}'s order. *)

val refused_slot_to_string : refused_slot -> string

type lane_refusal =
  | No_slot_admitted of refused_slot list
      (** The lane declares no [cli_slots] and every HTTP slot was refused. *)

val admit_lane
  :  Runtime_exact_output_registry.resolved_lane
  -> (admitted_lane, lane_refusal) result
(** Keep the HTTP slots whose model takes a system prompt, read from the same
    capabilities AGENT_CORE's admission reads for [Unsupported_system_prompt],
    in declaration order, and every declared CLI slot: a one-shot takes the
    system prompt as its own argument. *)

type lane_unavailable =
  | Registry_unavailable of Runtime_exact_output_registry.publication_error
  | Lane_unresolved of Runtime_exact_output_registry.lane_resolution_error

val published_lane
  :  unit
  -> (Runtime_exact_output_registry.resolved_lane, lane_unavailable) result
(** [browser_stagehand_exact] as the published registry resolves it now. *)

type no_callback_error = |

type flow_not_started =
  | Candidate_refused of Agent_core.Exact_output.flow_candidate_error
  | Snapshot_refused of Agent_core.Exact_output.flow_snapshot_error
  | Start_refused of Agent_core.Exact_output.flow_start_error

type unserved_generation =
  | Text_generation_requested
  | Tool_generation_requested of { tool_names : string list }

(** Why a request could not go to the CLI slots. *)
type cli_unfit =
  | Assistant_turn_in_conversation
      (** A one-shot takes one prompt; user turns join into it, but an
          assistant turn has no place in it that keeps its role. *)

type cli_tail =
  | Cli_tail_undeclared  (** The lane declares no [cli_slots]. *)
  | Cli_tail_unfit of cli_unfit
  | Cli_tail_exhausted of Keeper_lane_cli_oneshot.failure list
      (** Every CLI slot failed, in walk order. *)

type generation_failure =
  { http_failure : no_callback_error Agent_core.Exact_output.flow_execution_error option
        (** [None] when the lane admitted no HTTP slot. *)
  ; cli_tail : cli_tail
  }

type refusal =
  | Params_malformed of string
  | Generation_not_served of unserved_generation
      (** Only [Structured] is served in this step. *)
  | Content_not_served of unserved_block
  | Lane_unavailable of lane_unavailable
  | Lane_refused of lane_refusal
  | Flow_not_started of flow_not_started
  | Generation_failed of generation_failure
      (** Neither the HTTP flow nor the CLI tail answered. The rendering names
          each slot reached and why it did not answer. *)

val refusal_to_string : refusal -> string

val refusal_to_rpc_error : refusal -> Browser_stagehand_wire.rpc_error
(** Code {!Browser_stagehand_wire.host_refused}, message
    {!refusal_to_string}. *)

val answer_of_success : Agent_core.Exact_output.success -> Yojson.Safe.t
(** The [LLMStructuredGenerateResult]: [role], a text [content] block holding
    the JSON as a string, [output_format = "json_schema"] and
    [structured_content]. [usage] is present only when the provider reported
    usage ({!Agent_core.Exact_output.success}); it is left out, not zeroed,
    otherwise. Its [input_tokens] is the inclusive prompt total,
    [total_tokens] is input plus output, and [cached_input_tokens] is the
    cache-read count, the tokens served from the prompt cache — the meaning
    Stagehand's AI SDK client gives [cachedInputTokens]. A cache-read count of
    0 is left out, because the parsers write 0 for a count the body did not
    report (#38669). Cache-write tokens have no field in [LLMUsage] and are
    already inside [input_tokens]. *)

val create
  :  ?cli_runner:Keeper_lane_cli_oneshot.runner
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> clock:_ Eio.Time.clock
  -> base_path:string
  -> resolve_lane:
       (unit -> (Runtime_exact_output_registry.resolved_lane, lane_unavailable) result)
  -> Browser_stagehand_session.model
(** A model for {!Browser_stagehand_session.create}. Each [llm.generate] is
    parsed, checked for what this step serves, then sent through the lane
    [resolve_lane] answers at that moment, so a reloaded registry applies to
    the next request. Production passes {!published_lane}. [base_path] is
    where an official client runs; [cli_runner] replaces the official-client
    edge in tests. An answer from a CLI slot carries no [usage]. The model
    never raises: every refusal is a {!refusal} rendered as an rpc error. *)
