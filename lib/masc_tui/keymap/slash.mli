(** Converged 36 orthogonal slash commands with strict typed parsing, fuzzy
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
  | Cmd_discord_reply
  | Cmd_wake
  | Cmd_up
  | Cmd_resume
  | Cmd_pause
  | Cmd_down
  | Cmd_queue
  | Cmd_context
  | Cmd_ctl
  | Cmd_gate
  | Cmd_exec
  | Cmd_skill
  | Cmd_prompt
  | Cmd_preset
  | Cmd_lane
  | Cmd_addon
  | Cmd_browser
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

type skill_action =
  | Skill_refresh
  | Skill_new
  | Skill_read of string
  | Skill_edit of string
  | Skill_delete of string

type prompt_action =
  | Prompt_set of { key : string; value : string option }
  | Prompt_clear of string
  | Param_set of { key : string; value_raw : string option }
  | Param_clear of string

type preset_action =
  | Preset_list
  | Preset_show of string
  | Preset_save of { name : string; description : string }
  | Preset_create of { name : string option; description : string }
  | Preset_restore of string
  | Preset_delete of string

type lane_action =
  | Lane_create of { lane : string; runtime_ids : string list }
  | Lane_remove of string
  | Lane_rename of { lane : string; to_lane : string }
  | Lane_set of { lane : string; runtime_ids : string list }
  | Lane_exact_append of { lane_id : string; runtime_id : string }
  | Lane_exact_drop of { lane_id : string; runtime_id : string }
  | Lane_exact_move of {
      lane_id : string;
      runtime_id : string;
      direction : [ `Up | `Down | `First ];
    }
  | Lane_exact_replace of {
      lane_id : string;
      runtime_id : string;
      replacement : string;
    }
  | Lane_run_inspect of string
  | Lane_quarantines of string
  | Lane_quarantine_recover of {
      keeper : string;
      partition_id : string;
      candidate_id : string;
      quarantine_id : string;
    }
  | Lane_raw_preview

type addon_action =
  | Addon_attach of {
      manifest_path : string;
      run_id : string;
      binding_json : string option;
    }
  | Addon_detach of string
  | Addon_observe of string
  | Addon_retain of string
  | Addon_act of { instance_id : string; action_json : string option }
  | Addon_evidence of {
      instance_id : string;
      row_ids : string list;
      keeper_name : string option;
    }
  | Addon_decl_read of string
  | Addon_decl_new of string
  | Addon_slice of { run_id : string option; lane_id : string option }
  | Addon_asks of { include_resolved : bool }
  | Addon_ask_answer of {
      declaration_id : string;
      ask_id : string;
      answers_json : string;
    }
  | Addon_operator of { instance_id : string; args_json : string option }

type browser_action =
  | Browser_scene of {
      client_id : string option;
      tab_id : int option;
      view : [ `Content | `Regions ];
    }
  | Browser_screenshot of { client_id : string option; tab_id : int option }
  | Browser_interact of {
      client_id : string option;
      tab_id : int option;
      action : string option;
      selector : string option;
      text : string option;
    }
  | Browser_command of string

(** Arguments of the unlisted [/music] command: [parse] accepts it, but
    {!all}, the slash popup and the help overlay do not list it. *)
type music_action =
  | Music_workbench
  | Music_import_midi of string  (** path of a Standard MIDI File *)

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
  | Discord_reply
  | Wake of string option
  | Up of string option
  | Resume of string option
  | Pause of string option
  | Down of string option
  | Queue
  | Context
  | Ctl of { action : keeper_ctl_action; target : string option }
  | Gate of gate_action
  | Exec of { tool_name : string; args_json : string option }
  | Skill of skill_action
  | Prompt of prompt_action
  | Preset of preset_action
  | Lane of lane_action
  | Addon of addon_action
  | Browser of browser_action
  | Tools of tools_mode option
  | Clear
  | Theme of Theme.preset option
  | Lang of Say.lang option
  | Help
  | Restart
  | Quit
  | Music of music_action
  | Score of int
      (** The unlisted [/score] command: the [n]-th newest closed alphaTex
          block of the open conversation, counted from 1. *)

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
(** All 36 canonical slash command specifications in display order. *)

val equal_command_id : command_id -> command_id -> bool
val equal_category : category -> category -> bool
val equal_tools_mode : tools_mode -> tools_mode -> bool
val equal_keeper_ctl_action : keeper_ctl_action -> keeper_ctl_action -> bool
val equal_gate_action : gate_action -> gate_action -> bool
val equal_skill_action : skill_action -> skill_action -> bool
val equal_prompt_action : prompt_action -> prompt_action -> bool
val equal_preset_action : preset_action -> preset_action -> bool
val equal_lane_action : lane_action -> lane_action -> bool
val equal_addon_action : addon_action -> addon_action -> bool
val equal_browser_action : browser_action -> browser_action -> bool
val equal_music_action : music_action -> music_action -> bool
val equal_parsed : parsed -> parsed -> bool
val equal_parse_error : parse_error -> parse_error -> bool

val parse : string -> (parsed, parse_error) result
(** Strictly parse a slash command string (leading/trailing whitespace trimmed). *)

val filter : query:string -> lang:Say.lang -> spec list
(** Fuzzy-match and rank {!all} against [query] (with or without leading ['/']).
    An exactly typed unlisted command word matches nothing, so the popup
    never offers a listed command in its place. *)

val names_unlisted_command : string -> bool
(** Whether the first word of the text is a command that {!parse} accepts and
    {!all} does not list. The composer popup asks it with the whole draft, so
    a cursor inside the word cannot open a popup of listed commands in its
    place. *)

val complete : prefix:string -> string list
(** Return matching completion candidates for a partial slash input, including
    typed argument completions for [/theme], [/lang], [/tools], [/ctl], [/gate],
    [/skill], [/prompt], and [/preset]. *)
