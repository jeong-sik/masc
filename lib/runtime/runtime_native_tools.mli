(** Native-tool posture for official-client runtimes (RFC-0390).

    Each CLI runtime (Claude Code, Codex, Antigravity) ships its own agent
    tools. MASC decides per keeper how much of that built-in surface a turn
    may use; effects beyond the declared posture run through MASC tools,
    which the approval gate can see. *)

type posture =
  | Native_none  (** Reads and effects both go through MASC tools only. *)
  | Native_read  (** Built-in read tools allowed; effects stay MASC-owned. *)
  | Native_full  (** The full built-in surface, effects included. *)

type action_identity =
  | Call_id of string
  | Provider_step of
      { conversation_id : string
      ; step_index : int
      }

type origin =
  | Built_in
  | Mcp_wrapper

type observation =
  { identity : action_identity option
  ; tool_name : string option
  ; origin : origin
  }
(** Bounded identity reported by an official CLI for one built-in tool step.
    Missing fields stay [None]; adapters must not turn a provider step ordinal
    into a call id. *)

type exact_action = action_identity * string
(** Admit only an exact built-in provider identity with a non-empty tool name.
    MCP wrapper steps are observed but their canonical MASC invocation is the
    action authority; the admitting projection stays internal to
    [observe_exact_action]. *)
val observe_exact_action :
  official_turn:int ->
  observe:(official_turn:int -> identity:action_identity -> tool_name:string -> unit) ->
  observation -> unit

val call_id : observation -> string option
(** Return a literal provider call id when one exists. A provider step is not
    flattened into this field. *)

val stream_content_type : string
(** Internal AGENT_CORE content-block discriminator used only to carry a typed
    native observation through the Keeper stream bridge. *)

val to_string : posture -> string
val of_string : string -> posture option

val valid_posture_strings : string list
(** For error messages, in declaration order. *)

(** Current hard-coded stance of each runtime, kept as the default when a
    keeper profile declares nothing. One value per runtime because the
    runtimes genuinely differ today; unifying them silently would change
    some lane's behaviour. *)

val claude_code_default : posture
val codex_default : posture
val antigravity_default : posture

val claude_code_read_tool_names : string list
(** Built-in Claude Code tools that observe without effect. *)

val degrade_on_admission : posture:posture -> none_supported:bool -> unit -> posture
(** The safest posture the client can run when admission cannot honor the
    declared one: [full] degrades to [read] (effects stay behind the MASC
    approval gate), [none] on a client without a disable switch degrades
    to [read]. Used with a typed event, never silently — see
    RFC-0390 admission review. *)

val claude_code_tools_arg : posture -> string
(** Value for the [--tools] flag: [""] disables the built-in set,
    ["default"] enables all of it, otherwise a comma-separated allowlist. *)

(** Which Claude Code settings layers the CLI may load ([--setting-sources]).
    The empty list — the default everywhere — keeps the historical no-layer
    stance, so skills, hooks, subagents, and CLAUDE.md from disk stay off
    unless a keeper profile opts in (and admission requires the yolo approval
    mode: a loaded settings layer can execute code outside the MASC gate). *)
type claude_setting_source =
  | Settings_user
  | Settings_project
  | Settings_local



val claude_setting_sources_arg : claude_setting_source list -> string
(** The complete [--setting-sources=...] argv token; the empty list renders
    the historical [--setting-sources=]. *)
