(** Pure workflow rejection logic.

    No mutable state.  All functions are deterministic.

    @since P2 extraction *)

(** Structured info extracted from a workflow-rejection tool result. *)
type workflow_rejection_info =
  { task_id : string option
  ; rule_id : string option
  ; tool_suggestion : string option
  ; hint : string option
  }

(** Extract [workflow_rejection_info] from a raw JSON string. *)
val workflow_rejection_info_of_raw : string -> workflow_rejection_info option

(** Build a stable family key for deduplication. *)
val workflow_rejection_family_key
  :  tool_name:string
  -> workflow_rejection_info
  -> string

(** Human-readable recovery instruction. *)
val workflow_rejection_recovery_instruction
  :  tool_name:string
  -> count:int
  -> workflow_rejection_info
  -> string

(** Build recovery fields for insertion into the tool-result JSON. *)
val workflow_rejection_recovery_fields
  :  tool_name:string
  -> count:int
  -> string
  -> (string * Yojson.Safe.t) list

(** Extract a non-empty string value from JSON. *)
val json_nonempty_string_opt : string -> Yojson.Safe.t -> string option

(** Check if handoff_context has non-empty evidence_refs. *)
val json_has_nonempty_evidence_refs : Yojson.Safe.t -> bool

(** Build a workflow-submit evidence marker string. *)
val workflow_submit_evidence_marker : Yojson.Safe.t -> string

(** Build a scope key from tool input for workflow rejection dedup. *)
val workflow_scope_key_of_input
  :  tool_name:string
  -> Yojson.Safe.t
  -> string option

(** Block record stored in [failure_counts.workflow_block_table].
    Defined here because [workflow_rejection_scope_block_fields] uses it. *)
type workflow_rejection_block =
  { count : int
  ; task_id : string option
  ; rule_id : string option
  ; tool_suggestion : string option
  ; hint : string option
  }

(** Build structured recovery fields from a workflow rejection block. *)
val workflow_rejection_scope_block_fields
  :  tool_name:string
  -> workflow_rejection_block
  -> (string * Yojson.Safe.t) list

