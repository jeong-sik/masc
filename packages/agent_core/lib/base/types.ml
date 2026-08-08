(** Core types for Anthropic Agent SDK.

    LLM-level types (role, message, content_block, etc.) are defined in
    {!Llm_provider.Types} and re-exported here for backward compatibility.
    Agent-specific types (model, agent_config, agent_state) remain local. *)

(* ================================================================ *)
(* Re-export all LLM provider types                                  *)
(* ================================================================ *)
include Llm_provider.Types

(* ================================================================ *)
(* tool_choice JSON parsing -- depends on OAS Error module           *)
(* ================================================================ *)

let tool_choice_of_json json =
  let open Yojson.Safe.Util in
  try
    match json |> member "type" |> to_string with
    | "auto" -> Ok Auto
    | "any" -> Ok Any
    | "tool" ->
      let name = json |> member "name" |> to_string in
      Ok (Tool name)
    | "none" -> Ok None_
    | other ->
      Error
        (Error.Serialization (UnknownVariant { type_name = "tool_choice"; value = other }))
  with
  | Yojson.Safe.Util.Type_error (msg, _) ->
    Error
      (Error.Serialization
         (JsonParseError { detail = Printf.sprintf "Invalid tool_choice JSON: %s" msg }))
;;

let response_format_of_json json =
  let open Yojson.Safe.Util in
  try
    match json with
    | `Assoc _ ->
      (match json |> member "type" |> to_string with
       | "off" -> Ok Off
       | "json_mode" -> Ok JsonMode
       | "json_schema" ->
         (match json |> member "schema" with
          | `Null ->
            Error
              (Error.Serialization
                 (JsonParseError
                    { detail = "Invalid response_format JSON: missing schema" }))
          | schema -> Ok (JsonSchema schema))
       | other ->
         Error
           (Error.Serialization
              (UnknownVariant { type_name = "response_format"; value = other })))
    | _ ->
      Error
        (Error.Serialization
           (JsonParseError { detail = "Invalid response_format JSON: expected object" }))
  with
  | Yojson.Safe.Util.Type_error (msg, _) ->
    Error
      (Error.Serialization
         (JsonParseError
            { detail = Printf.sprintf "Invalid response_format JSON: %s" msg }))
;;

(* ================================================================ *)
(* Agent-specific types (internal to OAS)                             *)
(* ================================================================ *)

(** Exact provider model identifier.

    OAS does not expand aliases or choose a model on the caller's behalf.
    Provider/model catalogs may expose their own explicit defaults at their
    typed resolution boundary. *)
type model = string [@@deriving yojson, show]

(** Project an exact model identifier to its wire representation. *)
let model_to_string model = model

(** Agent configuration *)
type agent_config =
  { name : string
  ; model : model
  ; system_prompt : string option
  ; max_tokens : int option
    (** [None] = resolve from model capabilities at request time *)
  ; temperature : float option
  ; top_p : float option
  ; top_k : int option
  ; min_p : float option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
  ; response_format : response_format
  ; thinking_budget : int option (* For Claude 3.7+ extended thinking *)
  ; reasoning_effort : Llm_provider.Reasoning_effort.t option
  ; tool_choice : tool_choice option
  ; disable_parallel_tool_use : bool
    (* Anthropic: tool_choice.disable_parallel_tool_use, Openai: parallel_tool_calls=false *)
  ; cache_system_prompt : bool (* Wrap system prompt with cache_control ephemeral *)
  ; cache_extended_ttl : bool (* true=1h TTL (2x write cost), false=5min default *)
  ; initial_messages : message list
    (* Seed conversation with prior history on first run *)
  ; yield_on_tool : bool
    (** Release LLM slot during tool execution, re-acquire before next turn. @since 0.100.0 *)
  }
[@@deriving show]

let default_config ~model =
  { name = "agent"
  ; model
  ; system_prompt = None
  ; max_tokens = None
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; response_format = Off
  ; thinking_budget = None
  ; reasoning_effort = None
  ; tool_choice = None
  ; disable_parallel_tool_use = false
  ; cache_system_prompt = false
  ; cache_extended_ttl = false
  ; initial_messages = []
  ; yield_on_tool = false
  }
;;

type pricing_gap =
  | Model_identity_unavailable
  | Pricing_unavailable of string
[@@deriving show]

(** Usage tracking accumulated across provider calls. Per-response usage stays
    in [Llm_provider.Types.api_usage]. [pricing_gap] records why the observed
    cost is incomplete without inventing a model identifier. Cost is telemetry
    only and never gates execution. *)
type usage_stats =
  { total_input_tokens : int
  ; total_output_tokens : int
  ; total_cache_creation_input_tokens : int
  ; total_cache_read_input_tokens : int
  ; api_calls : int
  ; estimated_cost_usd : float
  ; pricing_gap : pricing_gap option
  }
[@@deriving show]

let empty_usage =
  { total_input_tokens = 0
  ; total_output_tokens = 0
  ; total_cache_creation_input_tokens = 0
  ; total_cache_read_input_tokens = 0
  ; api_calls = 0
  ; estimated_cost_usd = 0.0
  ; pricing_gap = None
  }
;;

let add_usage stats (u : api_usage) =
  { total_input_tokens = stats.total_input_tokens + u.input_tokens
  ; total_output_tokens = stats.total_output_tokens + u.output_tokens
  ; total_cache_creation_input_tokens =
      stats.total_cache_creation_input_tokens + u.cache_creation_input_tokens
  ; total_cache_read_input_tokens =
      stats.total_cache_read_input_tokens + u.cache_read_input_tokens
  ; api_calls = stats.api_calls + 1
  ; estimated_cost_usd = stats.estimated_cost_usd
  ; pricing_gap = stats.pricing_gap
  }
;;

(** Agent state *)
type agent_state =
  { config : agent_config
  ; messages : message list
  ; turn_count : int
  ; usage : usage_stats
  }
[@@deriving show]
