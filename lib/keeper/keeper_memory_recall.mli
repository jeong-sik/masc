(** Keeper_memory_recall — memory recall and memory evaluation. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(** {1 File Reading} *)

val read_file_tail_lines_result :
  string -> max_bytes:int -> max_lines:int
  -> (string list, Keeper_memory_recall_exn_class.t) result
(** Result-returning tail reader.  [Ok []] covers both "no recorded
    memory" (file missing, or [max_lines <= 0]) and "empty file"; the
    caller cannot disambiguate at this entry point and should not try.
    [Error class] surfaces an IO/parse failure classified through the
    bounded {!Keeper_memory_recall_exn_class.t} closed sum so callers
    can branch on a typed value instead of inspecting a stringified
    exception (RFC-0149 §3.1).

    Use this entry point when the caller can produce a meaningful
    operator-visible signal on [Error] (e.g. propagate
    {b Memory_unavailable} up the chain instead of silently rendering
    an empty summary).

    @since RFC-0149 Phase 1 *)

val record_memory_recall_read_error :
  site:string -> string -> Keeper_memory_recall_exn_class.t -> unit
(** Emit the bounded read-failure metric and WARN line for call sites
    that intentionally degrade after consuming
    {!read_file_tail_lines_result}.  This is logging only; callers must
    choose their own degraded value explicitly. *)

val recent_lines_or_record :
  string list Jsonl_incremental_projection.t ->
  site:string ->
  key:string ->
  path:string ->
  window:int ->
  initial_tail_bytes:int ->
  string list
(** Snapshot read-path helper: project the most recent [window] lines of
    [path] through {!Jsonl_incremental_projection.recent_lines} (steady-state
    O(new bytes) rather than a full tail re-read per snapshot), returning them
    in file order (oldest-first).  On file I/O failure it records the bounded
    read-error metric via {!record_memory_recall_read_error} and returns [],
    matching the prior tail read's graceful degradation;
    {!Eio.Cancel.Cancelled} is re-raised verbatim (RFC-0106).  Shared by the
    operator tool-audit and keeper status-metrics snapshot paths. *)

(** {1 Query Detection} *)

val is_memory_recall_query : string -> bool
val expected_topic_hint : string -> string option

(** {1 User Message Extraction} *)

val recent_user_messages :
  Agent_sdk.Types.message list -> max_n:int -> string list

val load_history_user_messages_result :
  path:string ->
  max_n:int ->
  (string list, Keeper_memory_recall_exn_class.t) result
(** Result-returning variant of {!load_history_user_messages}.  On
    [Error class] the caller can distinguish "no user messages in the
    history file" ([Ok []]) from "the history file read failed"
    ([Error class]).

    @since RFC-0149 §3.1 *)

val recall_candidates_with_history :
  checkpoint_messages:Agent_sdk.Types.message list ->
  history_path:string ->
  max_checkpoint:int ->
  max_history:int ->
  string list

(** {1 Memory Recall Evaluation} *)

type memory_recall_eval = {
  performed : bool;
  query_kind : string;
  expected_topic : string option;
  candidate_count : int;
  initial_score : float;
  final_score : float;
  threshold : float;
  passed : bool;
  best_match : string option;
}

val evaluate_memory_recall :
  user_message:string ->
  assistant_reply:string ->
  candidates:string list ->
  memory_recall_eval

val memory_eval_to_json :
  memory_recall_eval ->
  correction_applied:bool ->
  correction_success:bool ->
  correction_skipped_budget:bool ->
  prompt_fallback_applied:bool ->
  prompt_fallback_success:bool ->
  prompt_fallback_skipped_budget:bool ->
  postpass_budget_ms:int ->
  postpass_budget_remaining_ms:int ->
  recall_fallback_applied:bool ->
  Yojson.Safe.t

val work_kind_of_eval : memory_recall_eval -> string
