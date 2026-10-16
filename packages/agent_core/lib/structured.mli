(** Structured output helpers.

    Direct extraction prefers provider-native JSON schema output via
    {!Llm_provider.Complete}.

    @stability Evolving
    @since 0.93.1 *)

open Types

(** {1 Schema} *)

type 'a schema =
  { params : tool_param list
  ; parse : Yojson.Safe.t -> ('a, string) result
  }

(** Return the object JSON schema used for provider-native structured output. *)
val schema_to_json_schema : _ schema -> Yojson.Safe.t

(** {1 Direct extraction} *)

(** Uses provider-native JSON schema output when the resolved provider kind
    is wired for it. Unsupported providers fail fast. *)
val extract
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> provider_config:Llm_provider.Provider_config.t
  -> config:agent_config
  -> schema:'a schema
  -> string
  -> ('a, Error.t) result

(** {1 Extractors} *)

type 'a extractor = api_response -> ('a, string) result

(** Shape requirement for extracting a provider-native structured-output JSON
    payload from an API response. *)
type response_json_shape =
  | Any_json
  | Object_json

type 'a response_outcome =
  | Ready of 'a
  | Awaiting_tool_results
  | Refused of Error.structured_refusal
  | Truncated of Error.structured_truncation
  | Interrupted of Error.structured_interruption
  | Invalid of Error.t

(** Inspect the authoritative stop reason before parsing. Actual tool calls
    are intermediate turns, even with text present. Refusal and truncation
    cannot be accepted as JSON success. A terminal payload requires exactly
    one [Text] block, including when an extra block contains only whitespace;
    thinking and tool-result blocks are excluded. No tool is executed here. *)
val inspect_response_json :
  ?shape:response_json_shape -> api_response -> Yojson.Safe.t response_outcome

(** Result projection of {!inspect_response_json}. Nonterminal/refused/truncated
    states become {!Error.StructuredOutputStateError}, not parse errors. *)
val extract_response_json
  :  ?shape:response_json_shape
  -> api_response
  -> (Yojson.Safe.t, Error.t) result

(** Parse an already received response with a typed schema. Post-response JSON
    and schema failures retain bounded private model-output evidence in
    {!Error.StructuredOutputParseError}. No public text projection includes it. *)
val extract_response
  :  schema:'a schema
  -> api_response
  -> ('a, Error.t) result

(** Agent-level extractor form of {!extract_response_json}. *)
val response_json_extractor
  :  ?shape:response_json_shape
  -> unit
  -> Yojson.Safe.t extractor

(** Build an {!extractor} from a typed schema.

    This is the Agent-level counterpart to {!extract}: it parses the response
    text as JSON and delegates shape validation to [schema.parse]. Its string
    error projection omits private output evidence; use {!extract_response}
    when the caller needs the typed failure. *)
val schema_extractor : 'a schema -> 'a extractor

val json_extractor : (Yojson.Safe.t -> 'a) -> 'a extractor
val text_extractor : (string -> 'a option) -> 'a extractor

(** {1 Agent-level structured output} *)


(** {1 Streaming extraction} *)

val extract_stream
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> provider_config:Llm_provider.Provider_config.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> config:agent_config
  -> schema:'a schema
  -> on_event:(sse_event -> unit)
  -> string
  -> ('a * api_response, Error.t) result
