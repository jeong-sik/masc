(* What a terminal reader starts with: the [tui] settings the server answers,
   and the Keeper list preferences of this terminal's [tui-keepers.toml]. *)

type opening = Masc.Tui_preference.opening =
  | Overview
  | Last of Keeper_id.Keeper_name.t option
  | Keeper of Keeper_id.Keeper_name.t

type t = private {
  opening : (opening, string) result;
  last_chat_keeper : (Keeper_id.Keeper_name.t option, string) result;
  theme : string option;
  language : string option;
  (** [tui].language: the UI display language as stored, ["ko"] or ["en"].
      [None] where the file, the table or the key is absent — the caller
      keeps its default. The typed reading lives with the UI state
      (ui_language_of_string); an unknown stored value is reported,
      never forced into a default. *)
  board_sort : string option;
  keeper_list_sort : string option;
  keeper_list_layout : string option;
  keeper_list_error : string option;
  candle : string option;
  reduce_motion : bool option;
  lift_colours : bool option;
  table_frame : bool option;
  hints_visible : bool option;
  help_hint_shown : bool option;
  coalesce_queued_input : bool option;
  send_on_stop : bool option;
  user_input_priority_next : bool option;
  midi_soundfont : string option;
  (** [tui].midi_soundfont: the SoundFont file fluidsynth plays MIDI
      attachments with. [None] where the file, the table or the key is
      absent — MIDI playback then hands the file to the local app and says
      the setting is missing. *)
  audio_input_device : string option;
  (** [tui].audio_input_device: the input device voice captures open. [None]
      where the file, the table or the key is absent — captures then record
      whatever the operating system calls the default input, exactly as they
      did before the key existed. *)
  settings_unread : string option;
  (** [Some reason] when the server's settings could not be read; every
      setting above then holds its default. *)
}

val of_settings :
  base_path:string -> (Masc.Tui_preference.settings, string) result -> t
(** The snapshot from the server's settings, or from the defaults with the
    reason in [settings_unread] when they could not be read, together with
    the Keeper list preferences read now from [tui-keepers.toml]. *)

type startup_snapshot = private {
  settings : t;
  reader_entered_ns : int64;
  reader_returned_ns : int64;
}
type startup_read = private {
  started_ns : int64;
  result : startup_snapshot Eio.Promise.or_exn;
}
val prepare_startup_read :
  sw:Eio.Switch.t option -> base_path:string ->
  read_settings:(unit -> (Masc.Tui_preference.settings, string) result) ->
  startup_read
(** Prepare the immutable settings snapshot while the caller performs
    independent terminal initialization. [read_settings] asks the server
    (RFC-0482 §3.1); the Keeper list file is read on the I/O pool. The caller
    awaits this exact promise and applies settings before its terminal
    ownership, first setting-dependent output or key handling. No late UI
    application, cross-session cache or retry is introduced. A missing switch
    reads synchronously, including synchronous exceptions. A supplied switch
    owns the child; its cancellation and exceptions remain failed promise
    outcomes, not defaults. *)

val set_keeper_list_sort : base_path:string -> string -> (unit, string) result
val set_keeper_list_layout : base_path:string -> string -> (unit, string) result
(** Update one preference in the resolved config directory's
    [tui-keepers.toml], under its own read-modify-write lock. A held lock is
    reported without waiting. Symbolic links and special files are refused.
    An error can mean a post-rename durability failure, so the stored value is
    unconfirmed. *)

type keeper_preference = Keeper_order of string | Keeper_view of string
type keeper_preference_outcome =
  | Preference_saved
  | Preference_unconfirmed of string
  | Preference_not_started of string
type keeper_preference_completion = {
  request_id : int;
  preference : keeper_preference;
  outcome : keeper_preference_outcome;
}
type keeper_preference_writer
val create_keeper_preference_writer : unit -> keeper_preference_writer
val submit_keeper_preference :
  keeper_preference_writer -> on_request_id:(int -> unit) ->
  sw:Eio.Switch.t option -> base_path:string ->
  keeper_preference -> int
(** Queue one immutable choice. A session writer commits choices in order on
    a blocking worker; submission does not wait for the file lock. Before the
    request is queued or its worker launched, [on_request_id] receives its
    ID, which orders submissions including requests that cannot be started.
    The callback must not yield; if it raises, no request is queued and its
    exception propagates. Cancellation during submission also propagates, so
    callers must register the ID in the callback to handle its completion. *)
val drain_keeper_preferences :
  keeper_preference_writer -> can_take:(unit -> bool) ->
  apply:(keeper_preference_completion -> unit) -> unit
val close_keeper_preference_writer : keeper_preference_writer -> unit
(** Await submitted effects on graceful exit. A blocked filesystem or lock can
    delay exit; closing does not manufacture a result for an active write. *)
