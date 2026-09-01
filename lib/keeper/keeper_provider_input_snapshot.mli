(** Exact canonical model input retained per Keeper turn.

    The provider SDK intentionally exposes only the serialized HTTP body's
    digest and byte count. At that same pre-dispatch boundary MASC owns the
    final projected message list, system prompt, and effective tool surface.
    This store persists those values as content-addressed artifacts and joins
    them to the TurnRecord with the same [turn_ref]. Repeated history messages
    therefore occupy one blob even when many turns transmit them, and a
    successful prior snapshot lets the next turn reuse those durable
    references without rewriting and fsyncing the same bytes. Snapshot rows
    keep empty artifact previews, so message text lives only in the blob and
    is exposed through the administrator-only resolving endpoint. *)

type artifact =
  { art_bytes : int
  ; art_content_ref : string
  }

type message =
  { msg_index : int
  ; msg_role : string
  ; msg_artifact : artifact
  }

type tool_schema =
  { ts_index : int
  ; ts_name : string
  ; ts_artifact : artifact
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
  { rmsg_index : int
  ; rmsg_role : string
  ; rmsg_bytes : int
  ; rmsg_sha256 : string
  ; rmsg_content : Yojson.Safe.t
  }

type resolved_tool_schema =
  { rts_index : int
  ; rts_name : string
  ; rts_bytes : int
  ; rts_sha256 : string
  ; rts_content : Yojson.Safe.t
  }

type resolved_system_prompt =
  { rsp_bytes : int
  ; rsp_sha256 : string
  ; rsp_text : string
  }

(* The record was [resolved] and its fields repeated [resolved_], so a reader
   met the word twice for one fact. The prefix now names the record, not the
   state. *)
type resolved =
  { rv_snapshot : t
  ; rv_system_prompt : resolved_system_prompt option
  ; rv_messages : resolved_message list
  ; rv_tool_schemas : resolved_tool_schema list
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
