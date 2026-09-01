(** Exact canonical model input retained per Keeper turn.

    The provider SDK intentionally exposes only the serialized HTTP body's
    digest and byte count. At that same pre-dispatch boundary MASC owns the
    final projected message list, system prompt, and effective tool surface.
    This store persists those values as content-addressed artifacts and joins
    them to the TurnRecord with the same [turn_ref]. Repeated history messages
    therefore occupy one blob even when many turns transmit them. *)

type artifact =
  { bytes : int
  ; content_ref : string
  }

type message =
  { index : int
  ; role : string
  ; artifact : artifact
  }

type tool_schema =
  { index : int
  ; name : string
  ; artifact : artifact
  }

type t =
  { keeper : string
  ; trace_id : string
  ; absolute_turn : int
  ; turn_ref : Ids.Turn_ref.t
  ; runtime_profile : string
  ; captured_at : float
  ; wire : Llm_provider.Request_wire_observer.observation
  ; system_prompt : artifact option
  ; messages : message list
  ; tool_schemas : tool_schema list
  }

type resolved_message =
  { index : int
  ; role : string
  ; bytes : int
  ; sha256 : string
  ; content : Yojson.Safe.t
  }

type resolved_tool_schema =
  { index : int
  ; name : string
  ; bytes : int
  ; sha256 : string
  ; content : Yojson.Safe.t
  }

type resolved_system_prompt =
  { bytes : int
  ; sha256 : string
  ; text : string
  }

type resolved =
  { snapshot : t
  ; resolved_system_prompt : resolved_system_prompt option
  ; resolved_messages : resolved_message list
  ; resolved_tool_schemas : resolved_tool_schema list
  }

type read_error =
  | Unknown_keeper of string
  | Store_read_failed of Dated_jsonl.read_error
  | Malformed_snapshot of string
  | Snapshot_not_found of Ids.Turn_ref.t
  | Invalid_artifact_reference of string
  | Artifact_read_failed of string
  | Artifact_missing of string
  | Artifact_length_mismatch of
      { sha256 : string
      ; expected : int
      ; actual : int
      }
  | Artifact_json_invalid of
      { sha256 : string
      ; detail : string
      }

val read_error_to_string : read_error -> string

val write_best_effort :
  config:Workspace.config ->
  keeper:string ->
  trace_id:string ->
  absolute_turn:int ->
  runtime_profile:string ->
  wire:Llm_provider.Request_wire_observer.observation ->
  system_prompt:string ->
  messages:Agent_core.Types.message list ->
  tools:Agent_core.Tool.t list ->
  unit
(** Persist one immutable snapshot. Cancellation propagates; storage failures
    are logged and do not fail the Keeper turn. *)

val read_resolved :
  config:Workspace.config ->
  keeper:string ->
  turn_ref:Ids.Turn_ref.t ->
  (resolved, read_error) result

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
val resolved_to_json : resolved -> Yojson.Safe.t
