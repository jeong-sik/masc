(** Keeper_execution — keeper tool execution loop, prompting,
    checkpointing, and keepalive runtime.

    Internal helpers (proactive quality checks, explicit workspace replies,
    autonomous execution) are hidden. Only externally-called functions
    and types are exposed.
*)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(** {1 Error Logging} *)

(** Log a keeper exception with a descriptive label. *)
val log_keeper_exn : label:string -> exn -> unit

(** {1 Context and Checkpoint} *)

(** Load keeper context from checkpoint for resumption. *)
val load_context_from_checkpoint :
  trace_id:string ->
  base_dir:string ->
  Keeper_context_runtime.session_context * Keeper_context_runtime.working_context option

(** {1 Keepalive Runtime} *)

(* Proactive emission and explicit workspace replies are now handled
   by Keeper_unified_turn via the unified keeper loop. *)

(** {1 Trace and Model} *)

(** Generate unique trace ID for a keeper turn. *)
val generate_trace_id : ?now:float -> unit -> string

(** Resolve effective model labels for a turn. *)
val effective_model_labels_for_turn : keeper_meta -> string list

(** {1 Mention Detection} *)

(** Check if any target mention is directly present in content. *)
val exact_direct_mention_present : targets:string list -> string -> bool

(** {1 System Prompt and Identity} *)

(** Build system prompt for keeper agent. *)
val build_keeper_system_prompt :
  instructions:string ->
  ?keeper_name:string ->
  ?workspace_root:string ->
  unit ->
  string

(** Check if text appears fragmentary (incomplete sentence fragments). *)
val looks_fragmentary_history_text : string -> bool
