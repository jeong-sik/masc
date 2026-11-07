(** The writers that append one message to a transcript.

    The writers whose names end in [_once] are idempotent. A delivery key and a
    transcript slot name the row, so a replay answers with the row that is
    already there.
    [append_terminal_message_once] writes the terminal row of a delivery. A
    [terminal_row] says which: a [Reply] is an assistant row in the
    [Terminal_result] slot, a [Failed_request] is a failed-request row in the
    same slot, and a [Settled_failure] is a failed-request row in its own
    slot. [append_assistant_message_once], [append_request_failure_once] and
    [append_settled_failure_once] are fixed to one of the three.
    [append_settled_failures_once] appends a list of failures, each a
    [Settled_failure.t], against one read of the transcript.
    [append_user_message_once] writes the user row of a delivery. Its
    [mention_policy] says whether the mentions are parsed from the content or
    the row is passive context.
    [append_assistant_message] and [append_user_message] write one row with no
    delivery key, and count and log a write failure instead of returning it.
    [Keeper_chat_store] includes this module. *)
open Keeper_chat_store_append_once
open Keeper_chat_types

type terminal_row = Reply of string | Failed_request of string | Settled_failure of string

val append_assistant_message_once :
  base_dir:string ->
  keeper_name:string ->
  delivery_key:Keeper_chat_delivery_identity.delivery_key ->
  content:string ->
  ?surface:Surface_ref.t ->
  ?conversation_id:string ->
  ?tool_calls:tool_call list ->
  ?blocks:chat_block list ->
  ?turn_ref:Ids.Turn_ref.t ->
  ?stream_lifecycle:stream_lifecycle_event list ->
  unit ->
  (append_once_result, string) result

val append_request_failure_once :
  base_dir:string -> keeper_name:string ->
  delivery_key:Keeper_chat_delivery_identity.delivery_key -> content:string ->
  ?route:Row_route.t Lazy.t -> ?tool_calls:tool_call list ->
  ?blocks:chat_block list -> ?turn_ref:Ids.Turn_ref.t ->
  ?stream_lifecycle:stream_lifecycle_event list -> unit ->
  (append_once_result, string) result

val append_settled_failure_once :
  base_dir:string -> keeper_name:string ->
  delivery_key:Keeper_chat_delivery_identity.delivery_key -> content:string ->
  route:Row_route.t Lazy.t -> unit -> (append_once_result, string) result

module Settled_failure :
  sig
    type t = {
      delivery_key : Keeper_chat_delivery_identity.delivery_key;
      content : string;
      route : Row_route.t lazy_t;
    }
  end

val append_settled_failures_once :
  base_dir:string -> keeper_name:string -> ('tag * Settled_failure.t) list ->
  (('tag * (append_once_result, string) result) list, string) result

val append_assistant_message :
  base_dir:string ->
  keeper_name:string ->
  content:string ->
  ?tool_calls:tool_call list ->
  ?surface:Surface_ref.t ->
  ?conversation_id:string ->
  ?audio:audio_clip ->
  ?blocks:chat_block list ->
  ?turn_ref:Ids.Turn_ref.t ->
  ?stream_lifecycle:stream_lifecycle_event list ->
  unit ->
  unit

val append_user_message :
  base_dir:string ->
  keeper_name:string ->
  content:string ->
  ?attachments:attachment list ->
  ?surface:Surface_ref.t ->
  ?conversation_id:string ->
  ?external_message_id:string ->
  ?speaker:speaker ->
  ?extra_mentions:Keeper_identity.Keeper_id.t list ->
  unit ->
  unit

type mention_policy = Parse_mentions | Passive_context

val append_user_message_once :
  base_dir:string ->
  keeper_name:string ->
  delivery_key:Keeper_chat_delivery_identity.delivery_key ->
  content:string ->
  ?attachments:attachment list ->
  ?surface:Surface_ref.t ->
  ?conversation_id:string ->
  ?external_message_id:string ->
  ?workspace_id:string ->
  ?speaker:speaker ->
  ?mention_policy:mention_policy ->
  ?extra_mentions:Keeper_identity.Keeper_id.t list ->
  unit ->
  (append_once_result, string) result
