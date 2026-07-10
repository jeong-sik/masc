(** Keeper_execution — keeper tool execution loop, prompting,
    compaction, and keepalive runtime.

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
  max_checkpoint_messages:int ->
  trace_id:string ->
  primary_model_max_tokens:int ->
  base_dir:string ->
  Keeper_context_runtime.session_context * Keeper_context_runtime.working_context option

(** Default JSON for memory check tool. *)
val memory_check_default_json : unit -> Yojson.Safe.t

(** {1 Keepalive Runtime} *)

(* Proactive emission and explicit workspace replies are now handled
   by Keeper_unified_turn via the unified keeper loop. *)

(** {1 Compaction} *)

(** Extract compaction policy tuple from keeper metadata. *)
val compaction_policy_of_keeper : keeper_meta -> float * int * int

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
  goal:string ->
  instructions:string ->
  ?persona_extended:string ->
  ?keeper_name:string ->
  ?home_ground:string ->
  ?active_goals:(string * string) list ->
  unit ->
  string

(** Append trait clause to existing trait string. *)
val append_trait_clause : base:string -> clause:string -> string

(** {1 Text Processing} *)

(** Extract user-visible reply text, stripping internal markup. *)
val user_visible_reply_text : ?fallback:string -> string -> string

(** Check if text appears fragmentary (incomplete sentence fragments). *)
val looks_fragmentary_history_text : string -> bool
