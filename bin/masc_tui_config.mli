(* TUI settings read from the [tui] table of runtime.toml. See the .ml. *)

type opening = Overview | Last of Keeper_id.Keeper_name.t option | Keeper of Keeper_id.Keeper_name.t

type t = private {
  opening : (opening, string) result;
  last_chat_keeper : (Keeper_id.Keeper_name.t option, string) result;
  theme : string option;
  board_sort : string option;
  candle : string option;
  reduce_motion : bool option;
  lift_colours : bool option;
  table_frame : bool option;
  hints_visible : bool option;
  coalesce_queued_input : bool option;
  send_on_stop : bool option;
  user_input_priority_next : bool option;
}

val opening_keeper_of_doc :
  Keeper_toml_loader.toml_doc -> (Keeper_id.Keeper_name.t option, string) result
val opening_of_doc : Keeper_toml_loader.toml_doc -> (opening, string) result

val last_chat_keeper_of_doc :
  Keeper_toml_loader.toml_doc -> (Keeper_id.Keeper_name.t option, string) result
(** Missing is [Ok None]; invalid receipt data is [Error], never a target. *)

val record_chat_visit :
  base_path:string -> Keeper_id.Keeper_name.t ->
  (Runtime.config_durability, string) result
(** Store an explicitly opened conversation under Runtime's config write
    lock. The current on-disk [Last] mode also updates its opening target in
    that same commit; [Overview] and [Keeper] leave the startup choice and
    target untouched. A visible commit retains its durability distinction. *)

val load : base_path:string -> t
(** Resolve and parse runtime.toml once, then extract an immutable snapshot of
    all TUI settings. A later call reads current disk state; no process cache.
    Missing, unreadable or unparseable files leave optional settings [None]
    and [opening] at [Ok Overview]. [last_chat_keeper] retains read/parse errors
    so unread history is not presented as missing. Explicit [false] stays
    [Some false]. *)

(* [tui].theme, given an already-parsed runtime.toml document. [None] when the
   key (or the [tui] table) is absent. Pure, so the caller's file read stays
   separate from the extraction. *)
val theme_of_doc : Keeper_toml_loader.toml_doc -> string option

val text_with_theme : string -> theme:string option -> string
(** runtime.toml text with [tui].theme set to [theme], or without the key
    when [theme] is [None]. The [tui] table is created when absent; comments
    and every other line are kept. Pure; the commit is {!set_theme}'s. *)

val set_theme : base_path:string -> string option -> (unit, string) result
(** Store the reader's theme pick in the runtime.toml {!load} reads, so it is
    still there on the next start. [None] withdraws the pick. The load, the
    edit and the write happen under Runtime's config write lock, so a
    concurrent write to another table of the same file is not lost. [Error]
    carries what stopped the write; the scheme is already applied to the
    screen by then, so the caller has to say which of the two happened.

    A write whose durability could not be confirmed is [Ok]: the replacement
    is already visible, which is what "stored" means to the next start. *)

val reduce_motion_of_doc : Keeper_toml_loader.toml_doc -> bool option
(** [tui].reduce_motion: show /about's final roster immediately. Absent
    preserves the finite arrival animation. *)

val table_frame_of_doc : Keeper_toml_loader.toml_doc -> bool option
(** Whether tables draw their outer box, [tui].table_frame. Pure, so a test
    can hand it a parsed doc without a file. *)

val lift_colours_of_doc : Keeper_toml_loader.toml_doc -> bool option
(** [tui].lift_colours. [None] is absent, which the caller reads as on.

    On, a colour the scheme leaves under the readable floor is raised in
    lightness until it clears -- so a status masc says with colour stays
    visible. Off, the scheme's own colour goes out untouched, which is what
    every other terminal UI does and what a reader on a high-contrast scheme
    wants: for them the lift moves a colour their theme placed on purpose. *)

val hints_visible_of_doc : Keeper_toml_loader.toml_doc -> bool option
(** [tui].hints_visible: whether footers spell their key hints. [None]
    where the file, the table or the key is absent -- reads as "yes". *)

val send_on_stop_of_text : string -> bool option
(** [\[voice.stt\]].send_on_stop, parsed out of runtime.toml's source text:
    whether ^Y ending a voice capture also sends what was heard, instead of
    leaving it in the draft for the operator to send. [None] where the file,
    the section or the key is absent — reads as "no", unlike the toggles
    around it. They pick between two ways of showing the same thing; this one
    sends a message without the operator confirming it, and the draft is also
    where a spoken half-sentence waits for typing.

    Takes text and goes through {!Voice_config.parse_runtime_toml_text} rather
    than reading a key path, so the field has one definition. It had two: this
    file used to read [\[tui\]].voice_send_on_stop, which no surface
    published, while [\[voice.stt\]].send_on_stop was published by
    [GET /api/v1/voice/config] and by the voice setup route and read by
    nothing. A [\[voice\]] section that does not parse reads as [None]: the
    TUI is not where a broken voice config is reported, and off is the
    direction that does not send a message nobody confirmed. *)

val coalesce_queued_input_of_doc : Keeper_toml_loader.toml_doc -> bool option
(** [tui].coalesce_queued_input: whether a new line joins the line already
    waiting for the same Keeper instead of queueing behind it. [None] where
    the file, the table or the key is absent -- reads as "no".

    Only a next-turn line waiting for that same Keeper is joined. A steer
    keeps its own entry: it was created to replace one exact operation, and
    folding another line into it would move that causal parent. *)

val user_input_priority_next_of_doc : Keeper_toml_loader.toml_doc -> bool option
(** [tui].user_input_priority_next: whether a newly queued user chat message
    requests first place after the server confirms its admission.
    [None] where absent -- defaults to [false]. *)

val set_board_sort : base_path:string -> string -> (unit, string) result

val set_candle : base_path:string -> string -> (unit, string) result
(** Store how /about draws the candle, [\[tui\].candle], under
    the same lock and in the same file as {!set_board_sort}. *)
