(** Converged 25 orthogonal slash commands with strict typed parsing, fuzzy
    filtering, and prefix completion.

    Strict parse contract ([constitution.xml#strict_parse_no_default]):
    unknown commands or invalid enum arguments always return [Error _] and
    never silently coerce to defaults. *)

module Say = Masc_tui_core.Say
module Theme = Masc_tui_core.Theme

type command_id =
  | Cmd_pulse
  | Cmd_work
  | Cmd_knowledge
  | Cmd_keepers
  | Cmd_runtime
  | Cmd_infra
  | Cmd_keeper
  | Cmd_model
  | Cmd_config
  | Cmd_incidents
  | Cmd_jump
  | Cmd_voice
  | Cmd_btw
  | Cmd_queue
  | Cmd_context
  | Cmd_ctl
  | Cmd_gate
  | Cmd_exec
  | Cmd_tools
  | Cmd_clear
  | Cmd_theme
  | Cmd_lang
  | Cmd_help
  | Cmd_restart
  | Cmd_quit

type category =
  | Slash_navigation
  | Slash_pickers
  | Slash_interaction
  | Slash_display
  | Slash_session

type tools_mode =
  | Tools_compact
  | Tools_results
  | Tools_full

type keeper_ctl_action =
  | Ctl_boot
  | Ctl_up
  | Ctl_shutdown
  | Ctl_pause
  | Ctl_resume
  | Ctl_wakeup
  | Ctl_reset
  | Ctl_clear
  | Ctl_checkpoints
  | Ctl_purge_preview
  | Ctl_purge_apply
  | Ctl_delete_history
  | Ctl_note
  | Ctl_run_next

type gate_action =
  | Gate_mode_set of string
  | Gate_external_mode_set of string
  | Gate_rule_delete of string
  | Gate_approve_always of string
  | Gate_retry of string
  | Gate_keeper_mode_set of { keeper : string; mode : string }
  | Gate_ack_uncertain of { keeper : string; consume_id : string }
  | Gate_restore_late

type parsed =
  | Pulse
  | Work
  | Knowledge
  | Keepers
  | Runtime
  | Infra
  | Keeper of string option
  | Model of string option
  | Config of string option
  | Incidents
  | Jump
  | Voice
  | Btw of string
  | Queue
  | Context
  | Ctl of { action : keeper_ctl_action; target : string option }
  | Gate of gate_action
  | Exec of { tool_name : string; args_json : string option }
  | Tools of tools_mode option
  | Clear
  | Theme of Theme.preset option
  | Lang of Say.lang option
  | Help
  | Restart
  | Quit

type parse_error =
  | Not_a_slash_command
  | Empty_command
  | Unknown_command of string
  | Unexpected_argument of { command : string; arg : string }
  | Invalid_argument of { command : string; expected : Say.t; got : string }

type spec = {
  id : command_id;
  name : string;        (** Canonical slash token including leading ['/'], e.g. ["/pulse"]. *)
  arg_hint : Say.t option;
  description : Say.t;
  category : category;
}

val all : spec list
(** All 25 canonical slash command specifications in display order. *)

val equal_command_id : command_id -> command_id -> bool
val equal_category : category -> category -> bool
val equal_tools_mode : tools_mode -> tools_mode -> bool
val equal_keeper_ctl_action : keeper_ctl_action -> keeper_ctl_action -> bool
val equal_gate_action : gate_action -> gate_action -> bool
val equal_parsed : parsed -> parsed -> bool
val equal_parse_error : parse_error -> parse_error -> bool

val parse : string -> (parsed, parse_error) result
(** Strictly parse a slash command string (leading/trailing whitespace trimmed). *)

val filter : query:string -> lang:Say.lang -> spec list
(** Fuzzy-match and rank {!all} against [query] (with or without leading ['/']). *)

val complete : prefix:string -> string list
(** Return matching completion candidates for a partial slash input, including
    typed argument completions for [/theme], [/lang], [/tools], [/ctl], and [/gate]. *)
