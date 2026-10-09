(** Pure chat projections. Audio expiry and trace lookup are resolved by the
    caller before rendering; this module does not read files or run callbacks. *)

open Keeper_chat_types

val speaker_fields : speaker option -> (string * Yojson.Safe.t) list
val audio_fields : audio_clip option -> (string * Yojson.Safe.t) list
val blocks_fields : chat_block list option -> (string * Yojson.Safe.t) list
val stream_lifecycle_fields : stream_lifecycle_event list option -> (string * Yojson.Safe.t) list
val approval_lifecycle_fields : approval_lifecycle option -> (string * Yojson.Safe.t) list

val message_to_json :
  trace_lookup_available:bool -> trace_block:chat_block option ->
  chat_message -> Yojson.Safe.t

type turn_transcript = {
  user : chat_message list;
  assistant : chat_message list;
}

val transcript_of_messages :
  chat_message list -> turn_ref:Ids.Turn_ref.t -> turn_transcript
val turn_transcript_to_json :
  keeper:string -> turn_ref:Ids.Turn_ref.t -> turn_transcript -> Yojson.Safe.t
