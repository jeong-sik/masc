(** Converged 22 orthogonal slash commands with strict typed parsing, fuzzy
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
(** All 22 canonical slash command specifications in display order. *)

val equal_command_id : command_id -> command_id -> bool
val equal_category : category -> category -> bool
val equal_tools_mode : tools_mode -> tools_mode -> bool
val equal_parsed : parsed -> parsed -> bool
val equal_parse_error : parse_error -> parse_error -> bool

val parse : string -> (parsed, parse_error) result
(** Strictly parse a slash command string (leading/trailing whitespace trimmed). *)

val filter : query:string -> lang:Say.lang -> spec list
(** Fuzzy-match and rank {!all} against [query] (with or without leading ['/']). *)

val complete : prefix:string -> string list
(** Return matching completion candidates for a partial slash input, including
    typed argument completions for [/theme], [/lang], and [/tools]. *)
