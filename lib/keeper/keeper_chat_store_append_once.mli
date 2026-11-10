(** The idempotent append of a batch of rows that belong to one delivery.

    An [append_once_line] is a row with its transcript slot, its row id and a
    line that is encoded only when the slot is absent. [Row_route] holds the
    surface and the conversation id that a row is routed by.
    [validate_append_once_lines] rejects a batch that repeats a slot, a tool
    ordinal or a canonical execution id.
    [append_lines_once] appends the lines whose slots the transcript does not
    have yet in one durable write under the file lock. It answers with the row
    of the result slot: [Appended] when it added any line and
    [Already_present] when every line was there. [announce_if_appended]
    announces an appended row.
    [tool_call_append_lines] builds the lines of the tool calls of a delivery
    and [append_tool_calls_once] appends them.
    [Keeper_chat_store] includes this module. *)
open Keeper_chat_types

module Row_route :
  sig
    type t = {
      surface : Surface_ref.t option;
      conversation_id : string option;
    }
    val none : t
  end

val announce_if_appended :
  keeper_name:string ->
  route:Row_route.t lazy_t ->
  (append_once_result, 'a) result ->
  (append_once_result, 'a) result

(* Ordinary delivery lines are encoded under the file lock only when their
   slot is absent. Autonomous candidates are also decoded for owner/binding
   validation before writing; their wrapper uses a fixed route. Stdlib.Lazy:
   the lock body runs in a systhread where Eio.Lazy cannot run, and each lazy
   belongs to one append call, so nothing forces it concurrently. *)
type append_once_line =
  { transcript_slot : Keeper_chat_delivery_identity.transcript_slot
  ; row_id : string
  ; line : string Lazy.t
  }

val append_lines_once :
  ?reject_partial_after_result:bool ->
  string ->
  delivery_key:Keeper_chat_delivery_identity.delivery_key ->
  result_slot:Keeper_chat_delivery_identity.transcript_slot ->
  append_once_line list ->
  (append_once_result, string) result

val tool_call_append_lines :
  ts:float ->
  route:Row_route.t lazy_t ->
  turn_ref:Ids.Turn_ref.t option ->
  delivery_key:Keeper_chat_delivery_identity.delivery_key ->
  tool_call list -> append_once_line list

val append_tool_calls_once :
  base_dir:string ->
  keeper_name:string ->
  delivery_key:Keeper_chat_delivery_identity.delivery_key ->
  tool_calls:tool_call list ->
  ?surface:Surface_ref.t ->
  ?conversation_id:string ->
  ?turn_ref:Ids.Turn_ref.t ->
  unit ->
  (append_once_result, string) result

val append_autonomous_tool_calls_once :
  base_dir:string -> keeper_name:string -> turn_ref:Ids.Turn_ref.t ->
  input_binding:Keeper_chat_delivery_identity.approval_input_binding list ->
  tool_calls:tool_call list -> unit ->
  (append_once_result * Keeper_chat_store_append_primitives.tool_ownership list, string) result
(** Append the turn's internal binding and common tool rows under one existing
    chat lock and durable update. Even an empty tool list records the binding.
    A different vector or mismatched row owner refuses the whole append.
    The receipt names only execution slots actually added under that lock;
    an existing prefix is never announced as newly committed ownership. *)
