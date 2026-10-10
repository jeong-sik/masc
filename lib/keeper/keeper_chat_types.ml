(** Shared chat data and closed wire vocabularies. *)

open Keeper_approval_lifecycle

type attachment = {
  id : string;
  att_type : string;
  name : string;
  size : int;
  mime_type : string;
  data : string;
  (* Dimensions are measured before externalization so history pages need
     only metadata. [data] becomes a canonical marker for retained wire bytes. *)
  width : int option;
  height : int option;
}

type tool_call = {
  call_id : string;
  execution_id : Ids.Execution_id.t option;
  call_name : string;
  args : string;
}

(** Closed transcript row classification. Assistant is Keeper speech;
    Request_failure is a server-owned request result and cannot acknowledge
    input or enter conversation memory. Unknown labels are refused. *)
module Role = struct
  type t =
    | User
    | Assistant
    | System
    | Request_failure
    | Tool

  let to_label = function
    | User -> "user"
    | Assistant -> "assistant"
    | System -> "system"
    | Tool -> "tool"
    | Request_failure -> "request_failure"

  let of_label = function
    | "user" -> Some User
    | "assistant" -> Some Assistant
    | "system" -> Some System
    | "tool" -> Some Tool
    | "request_failure" -> Some Request_failure
    | _ -> None

  let equal a b =
    match a, b with
    | User, User | Assistant, Assistant | System, System | Tool, Tool -> true
    | Request_failure, Request_failure -> true
    | (User | Assistant | System | Tool | Request_failure), _ -> false
end

type stream_lifecycle_event =
  | Run_started
  | Text_message_start
  | Text_message_end
  | Run_finished
  | Run_error

type approval_lifecycle =
  { approval_id : string
  ; tool_name : string option
  ; phase : approval_lifecycle_phase
  ; artifact_ref : Tool_output.artifact_ref option
  ; call_summary : string option
  }

type append_once_result =
  | Appended of { row_id : string }
  | Already_present of { row_id : string }

type user_row_origin =
  | Needs_append
  | Already_persisted_upstream

let stream_lifecycle_event_to_label = function
  | Run_started -> "RUN_STARTED"
  | Text_message_start -> "TEXT_MESSAGE_START"
  | Text_message_end -> "TEXT_MESSAGE_END"
  | Run_finished -> "RUN_FINISHED"
  | Run_error -> "RUN_ERROR"

let stream_lifecycle_event_of_label = function
  | "RUN_STARTED" -> Some Run_started
  | "TEXT_MESSAGE_START" -> Some Text_message_start
  | "TEXT_MESSAGE_END" -> Some Text_message_end
  | "RUN_FINISHED" -> Some Run_finished
  | "RUN_ERROR" -> Some Run_error
  | _ -> None

type speaker_authority =
  | Owner
  | External
  | Keeper

let authority_label = function
  | Owner -> "owner"
  | External -> "external"
  | Keeper -> "keeper"

let authority_of_label = function
  | "owner" -> Some Owner
  | "external" -> Some External
  | "keeper" -> Some Keeper
  | _ -> None

type chat_block = Keeper_chat_blocks.chat_block

type audio_clip = {
  token : string;
  audio_url : string option;
  mime : string;
  duration_sec : float option;
  message_text : string;
  device_id : string option;
  expired : bool;
}

type speaker = {
  speaker_id : string option;
  speaker_name : string option;
  speaker_authority : speaker_authority;
}

let keeper_speaker keeper_id =
  let id = Keeper_identity.Keeper_id.to_string keeper_id in
  { speaker_id = Some id; speaker_name = Some id; speaker_authority = Keeper }

type chat_message = {
  id : string;
      (* R3: producer-assigned stable message id.  Minted once at append
         by [encode_line] (the sole writer) and read back verbatim, so the
         dashboard keys off a server identity instead of synthesising an
         index-derived id at render. Rows without a nonblank persisted id
         are rejected at the read boundary. *)
  role : Role.t;
  content : string;
  ts : float;
  attachments : attachment list option;
  tool_call_id : string option;
  execution_id : Ids.Execution_id.t option;
  tool_call_name : string option;
  surface : Surface_ref.t option;
      (* RFC-0232 P5: the typed surface, persisted as a structured
         [surface] field.  [None] on rows written before P5. *)
  conversation_id : string option;
  external_message_id : string option;
  workspace_id : string option;
  speaker : speaker option;
  audio : audio_clip option;
  blocks : Keeper_chat_blocks.chat_block list option;
      (* Completed rich output persisted by the producer. Assistant speech
         has a default text projection; server failure records retain only
         explicitly completed output. None means no persisted blocks. *)
  mentions : Keeper_identity.Keeper_id.t list;
      (* RFC-0232 §3.3: parsed once at append from the persisted content
         (plus connector-provided explicit mentions); [] = none.  Rows
         written before P4 lack the field and read as []; the offline
         backfill tool stamps them. *)
  turn_ref : Ids.Turn_ref.t option;
      (* RFC-0233 §7: "<trace_id>#<absolute_turn>" join key for the turn
         that produced this row.  Stamped by [append_turn] /
         [append_assistant_message] when the caller supplies it; [None] on
         inbound user lines (no turn yet) and rows written before §7.  A
         malformed persisted value is reported as a persistence read drop
         and reads as [None]; the row stays valid. *)
  stream_lifecycle : stream_lifecycle_event list option;
      (* K1f: closed list of server lifecycle events for the direct chat
         stream response represented by this row. [None] means pre-K1f row or
         no lifecycle proof. Malformed persisted values are reported and read
         as [None], keeping the row valid. *)
  approval_lifecycle : approval_lifecycle option;
  delivery_provenance :
    Keeper_chat_delivery_identity.delivery_provenance option;
      (* The exact delivery identity and transcript slot persisted atomically
         by the idempotent append-once paths.  [None] on rows written by the
         plain append paths and on rows written before this pair existed.  A
         malformed persisted value is reported as a persistence read drop and
         reads as [None]; the row stays valid. *)
}
