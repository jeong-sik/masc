(** The readers that return a whole transcript, or a page of it, from the file.

    [load_all] returns every valid row in source order and is the reader that
    uses the cache: when the file is the one the cache was built from, it
    parses only the rows after the last parsed boundary, and otherwise it
    reloads the transcript through [load_transcript_fully]. A missing file is
    empty.
    [load_all_using] reads the durable file without the cache and hands its
    rows to a parser. [load_all_result] (every message) and
    [load_captured_result] (the captured rows that [select] picks) are built on
    it: an unreadable row or an incomplete final row is a [strict_decode_error],
    never a shorter history.
    [load_result] returns the window of [load] from the strict reader, and
    [load_history_page_result] returns a [history_page] in file append order
    with the cursor of the next page.
    [purge_transcript] removes a transcript through the caller's [remove] and
    forgets both things this process keeps from reading it: the [load_all]
    cache and the provenance index of the append-once writers.
    [Keeper_chat_store] includes this module. *)
open Keeper_chat_types
open Keeper_chat_store_line_decode
open Keeper_chat_store_transcript_rows

val purge_transcript : string -> remove:(string -> 'a) -> 'a

val load_all :
  base_dir:string -> keeper_name:string -> chat_message list

val load_captured_result : select:(chat_message -> bool) -> base_dir:string -> keeper_name:string ->
  (captured_row list, strict_decode_error) result

val load_all_result :
  base_dir:string -> keeper_name:string ->
  (chat_message list, strict_decode_error) result

type history_page =
  { history_messages : chat_message list
  ; next_cursor : Keeper_chat_history_page.cursor option
  }

val load_result :
  base_dir:string -> keeper_name:string ->
  (chat_message list, Keeper_chat_history_page.error) result

val load_history_page_result :
  base_dir:string -> keeper_name:string ->
  ?cursor:Keeper_chat_history_page.cursor -> ?max_total:int -> unit ->
  (history_page, Keeper_chat_history_page.error) result
