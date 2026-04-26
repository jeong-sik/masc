[@@@warning "-32-69"]

module Tui_decode = Masc_mcp.Tui_decode

(** TUI shared types — split from masc_tui.ml (#3808) *)

(** Agent type with status (from Tui_decode) *)
type agent = Tui_decode.agent

(** Task type (from Tui_decode) *)
type task = Tui_decode.task

(** Event for the event log *)
type event =
  { timestamp : string
  ; event_type : string
  ; content : string
  }

(** Keeper metadata (from Tui_decode) *)
type keeper = Tui_decode.keeper

(** A single metrics/log entry (from Tui_decode) *)
type log_entry = Tui_decode.log_entry

(** Message history entry *)
type msg_entry =
  { me_role : string
  ; me_text : string
  ; me_timestamp : string
  }

(** TUI view mode *)
type view_mode =
  | Dashboard
  | Keeper_list
  | Keeper_detail
  | Keeper_logs
  | Keeper_message

(** Dashboard state *)
type state =
  { mutable agents : agent list
  ; mutable tasks : task list
  ; mutable events : event list
  ; mutable keepers : keeper list
  ; mutable connection_status : string
  ; mutable last_refresh : float
  ; mutable view : view_mode
  ; mutable keeper_cursor : int
  ; mutable log_entries : log_entry list
  ; mutable log_scroll : int
  ; mutable live_context_ratio : float
  ; mutable live_context_tokens : int
  ; mutable live_context_max : int
  ; mutable live_message_count : int
  ; mutable msg_input : Buffer.t
  ; mutable msg_history : msg_entry list
  ; mutable msg_sending : bool
  ; mutable detail_scroll : int
  ; room : string
  ; port : int
  ; refresh_interval : float
  }

(** Create initial state *)
let create_state ~room ~port ~refresh_interval =
  { agents = []
  ; tasks = []
  ; events = []
  ; keepers = []
  ; connection_status = "disconnected"
  ; last_refresh = 0.0
  ; view = Dashboard
  ; keeper_cursor = 0
  ; log_entries = []
  ; log_scroll = 0
  ; live_context_ratio = 0.0
  ; live_context_tokens = 0
  ; live_context_max = 0
  ; live_message_count = 0
  ; msg_input = Buffer.create 256
  ; msg_history = []
  ; msg_sending = false
  ; detail_scroll = 0
  ; room
  ; port
  ; refresh_interval
  }
;;
