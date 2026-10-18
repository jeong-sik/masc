(** Pure chat projections. Audio expiry and trace lookup are resolved by the
    caller before rendering; this module does not read files or run callbacks. *)

open Keeper_chat_types

val speaker_fields : speaker option -> (string * Yojson.Safe.t) list
val audio_fields : audio_clip option -> (string * Yojson.Safe.t) list
val blocks_fields : chat_block list option -> (string * Yojson.Safe.t) list
val stream_lifecycle_fields : stream_lifecycle_event list option -> (string * Yojson.Safe.t) list
val approval_lifecycle_fields : approval_lifecycle option -> (string * Yojson.Safe.t) list

(** A chat row as JSON. When [omit_stream_contract] is true the
    [stream_contract] object is left out: the keeper-chat page route serves
    only the TUI, which never reads that object, and it is about a quarter
    of a page's bytes (#42200). The transcript route keeps it -- the
    dashboard reads it there. *)
val message_to_json :
  ?omit_stream_contract:bool ->
  trace_lookup_available:bool -> trace_block:chat_block option ->
  chat_message -> Yojson.Safe.t

type turn_transcript = {
  user : chat_message list;
  assistant : chat_message list;
}

val transcript_of_messages :
  chat_message list -> turn_ref:Ids.Turn_ref.t -> turn_transcript
val user_matches_turn :
  messages:chat_message list -> turn_ref:Ids.Turn_ref.t -> (chat_message -> bool)
(** Capture the exact terminal delivery keys once, then select User rows by
    their own Turn_ref or those keys. Shared by list and streamed transcript
    reads; no text, timestamp or physical append-order inference. *)
val turn_transcript_to_json :
  keeper:string -> turn_ref:Ids.Turn_ref.t -> turn_transcript -> Yojson.Safe.t
