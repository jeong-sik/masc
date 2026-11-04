(** The [tui] table of runtime.toml: what a terminal reader picked on its
    screen. While the server runs it is the one writer of this table
    (RFC-0482 §3.1). A change names one key and carries the value already
    parsed, so the server takes a change only in a shape it can write. *)

(** The keys of the [tui] table a terminal reader reads, some of which a
    change writes. *)
module Key : sig
  type t =
    | Opening
    | Opening_keeper
    | Last_chat_keeper
    | Theme
    | Language
    | Board_sort
    | Candle
    | Help_hint_shown
    | Reduce_motion
    | Lift_colours
    | Table_frame
    | Hints_visible
    | Coalesce_queued_input
    | User_input_priority_next
    | Midi_soundfont
    | Audio_input_device

  val name : t -> string
  (** The key's spelling inside the [tui] table. *)

  val doc_path : t -> string
  (** The key's dotted path in a parsed runtime.toml document, as
      {!Keeper_toml_loader.toml_string_opt} looks it up. *)
end

type language =
  | Lang_ko
  | Lang_en

val language_to_string : language -> string

val language_of_string : string -> language option
(** ["ko"] or ["en"], ignoring case and surrounding blanks. *)

type candle =
  | Painted
  | Dotted

val candle_to_string : candle -> string
val candle_of_string : string -> candle option

type opening =
  | Overview
  | Last of Keeper_id.Keeper_name.t option
  | Keeper of Keeper_id.Keeper_name.t

val opening_keeper_of_doc :
  Keeper_toml_loader.toml_doc -> (Keeper_id.Keeper_name.t option, string) result

val last_chat_keeper_of_doc :
  Keeper_toml_loader.toml_doc -> (Keeper_id.Keeper_name.t option, string) result
(** Missing is [Ok None]; a value that is not a Keeper name is [Error], never
    a target. *)

val opening_of_doc : Keeper_toml_loader.toml_doc -> (opening, string) result
(** [tui].opening. Absent reads as [Overview]. *)

type change =
  | Chat_visited of Keeper_id.Keeper_name.t
      (** The reader opened this Keeper's chat. When [opening] is [last] the
          opening target moves with it, in the same edit. *)
  | Theme_chosen of string option  (** [None] goes back to the terminal's colours. *)
  | Language_chosen of language
  | Board_sort_chosen of Board_dispatch.sort_order
  | Candle_chosen of candle
  | Help_hint_retired

val edit : change -> string -> string
(** runtime.toml text with [change] written into the [tui] table. The table
    is made when absent; comments and every other line are kept. Pure; the
    commit is the caller's. *)

val change_to_yojson : change -> Yojson.Safe.t

val change_of_yojson : Yojson.Safe.t -> (change, string) result
(** One change, as [{"change": <kind>, ...}] with exactly the fields its kind
    names. An unknown kind, a missing or extra field, a repeated field, a
    value that does not parse, or a theme name that is blank or has blanks
    around it is [Error]. *)

val change_kind : change -> string
(** The [change] field's value for this change; audit records it. *)

(** What a terminal reader starts with, read from runtime.toml by the rules
    the terminal used when it read the file itself. *)
type settings =
  { opening : (opening, string) result
      (** [Ok Overview] when the file is absent or does not parse. *)
  ; last_chat_keeper : (Keeper_id.Keeper_name.t option, string) result
      (** [Error] when the file cannot be read or parsed: unread history is
          not presented as none. *)
  ; theme : string option
  ; language : string option
      (** As stored; the reader reports a value it does not know. *)
  ; board_sort : string option
  ; candle : string option
  ; reduce_motion : bool option
  ; lift_colours : bool option
  ; table_frame : bool option
  ; hints_visible : bool option
  ; help_hint_shown : bool option
  ; coalesce_queued_input : bool option
  ; send_on_stop : bool option
      (** [voice.stt].send_on_stop, through {!Voice_config}; a [voice]
          section that does not parse reads as [None]. *)
  ; user_input_priority_next : bool option
  ; midi_soundfont : string option
  ; audio_input_device : string option
      (** A blank value reads as [None]; a stored one is trimmed. *)
  }

val settings_of_reading : (string option, string) result -> settings
(** The settings in a runtime.toml text: [Ok None] is an absent file, [Error]
    a file that could not be read. *)

val read_settings : path:string -> settings
(** {!settings_of_reading} over the file at [path]. *)

val settings_to_yojson : settings -> Yojson.Safe.t
(** The settings only; nothing else in runtime.toml is carried. *)

val settings_of_yojson : Yojson.Safe.t -> (settings, string) result
(** The reverse of {!settings_to_yojson}: exactly its fields, its schema and
    value shapes; anything else is [Error]. *)
