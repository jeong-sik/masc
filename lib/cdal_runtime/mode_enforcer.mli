(** Mode enforcement middleware for CDAL.

    Creates hooks that block tool calls violating the effective execution mode.
    Violations are recorded as evidence for the proof bundle.

    Tool classification uses a descriptor-driven registry:
    - Read_only: read, glob, grep, search, etc.
    - Local_mutation: write, edit, create_text_file, etc.
    - External_effect: mcp__*, unknown tools (fail closed)
    - Shell_dynamic: bash, execute_shell_command (resolved via input analysis)

    @stability Evolving
    @since 0.93.1 *)

type tool_effect_class =
  | Read_only
  | Local_mutation
  | External_effect
  | Shell_dynamic

(** Backward-compatible alias for [tool_effect_class]. *)
type mutation_class = tool_effect_class

type violation_kind =
  | Mutating_in_diagnose
  | External_in_draft
  | Scope_violation

val violation_kind_to_string : violation_kind -> string
val violation_kind_of_string : string -> (violation_kind, string) result
val violation_kind_to_yojson : violation_kind -> Yojson.Safe.t
val violation_kind_of_yojson : Yojson.Safe.t -> (violation_kind, string) result

type violation =
  { ts : float
  ; tool_name : string
  ; input_summary : string
  ; effective_mode : Execution_mode.t
  ; violation_kind : violation_kind
  }

(** Canonical JSON serialization for violation records.
    Downstream consumers should use these instead of manual JSON parsing. *)
val violation_to_yojson : violation -> Yojson.Safe.t

val violation_of_yojson : Yojson.Safe.t -> (violation, string) result

type token_snapshot =
  { input_tokens : int
  ; output_tokens : int
  ; cost_usd : float option
  ; turn : int
  }

type state

val create
  :  contract:Risk_contract.t
  -> effective_mode:Execution_mode.t
  -> ?tool_classifications:(string * tool_effect_class) list
  -> unit
  -> state

(** Returns hooks that enforce mode constraints.
    PreToolUse returns [Hooks.Skip] on violation. *)
val hooks : state -> Hooks.hooks

val violations : state -> violation list
val token_snapshots : state -> token_snapshot list
val review_warning : state -> string option

(** Tool-effect decision evidence recorded for every PreToolUse decision,
    including allowed attempts and denied/skipped attempts. *)
val effect_evidence : state -> Effect_evidence.t list

(** Classify a tool by name using the global registry.
    Returns [Shell_dynamic] for bash/execute_shell_command.
    Unknown tools default to [External_effect] (fail closed). *)
val classify_tool : string -> tool_effect_class

(** Register or override a tool classification in the global registry. *)
val register_tool_class : string -> tool_effect_class -> unit

(** Parse a [tool_effect_class] from a descriptor string.
    Accepted values: "read_only", "workspace", "workspace_mutating",
    "local_mutation", "external", "external_effect", "shell_dynamic". *)
val tool_effect_class_of_string : string -> tool_effect_class option

(** Backward-compatible alias for [tool_effect_class_of_string]. *)
val mutation_class_of_string : string -> mutation_class option

(** Derive a [Tool.descriptor] from the builtin registry for a given tool name.
    Returns [None] for unknown tools.
    Read-only tools get [Parallel_read], mutation tools get [Sequential_workspace],
    external/shell tools get [Exclusive_external].
    @since 0.104.0 *)
val builtin_descriptor : string -> Tool.descriptor option

(** Check if all tools in a list are read-only. *)
val all_read_only : string list -> bool

(** Check if all tools are at most local-mutation (no external effects).
    [Shell_dynamic] tools are treated as potentially external. *)
val all_workspace_only : string list -> bool
