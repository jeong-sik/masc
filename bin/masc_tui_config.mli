(* TUI settings read from the [tui] table of runtime.toml. See the .ml. *)

(* [tui].theme, given an already-parsed runtime.toml document. [None] when the
   key (or the [tui] table) is absent. Pure, so the caller's file read stays
   separate from the extraction. *)
val theme_of_doc : Keeper_toml_loader.toml_doc -> string option

(* [tui].theme read from the runtime.toml under [base_path]'s resolved config
   root. [None] when the file is absent, unreadable, unparseable, or carries no
   [tui].theme -- all of which mean "no stored choice". *)
val theme : base_path:string -> string option

val text_with_theme : string -> theme:string option -> string
(** runtime.toml text with [tui].theme set to [theme], or without the key
    when [theme] is [None]. The [tui] table is created when absent; comments
    and every other line are kept. Pure; the commit is {!set_theme}'s. *)

val set_theme : base_path:string -> string option -> (unit, string) result
(** Store the reader's theme pick in the runtime.toml [theme] reads, so it is
    still there on the next start. [None] withdraws the pick. The load, the
    edit and the write happen under Runtime's config write lock, so a
    concurrent write to another table of the same file is not lost. [Error]
    carries what stopped the write; the scheme is already applied to the
    screen by then, so the caller has to say which of the two happened.

    A write whose durability could not be confirmed is [Ok]: the replacement
    is already visible, which is what "stored" means to the next start. *)

val table_frame_of_doc : Keeper_toml_loader.toml_doc -> bool option
(** Whether tables draw their outer box, [tui].table_frame. Pure, so a test
    can hand it a parsed doc without a file. *)

val table_frame : base_path:string -> bool option
(** [table_frame_of_doc] read from the runtime file. [None] where the file,
    the table or the key is absent -- all three read as "no stored choice",
    and the caller then draws what it drew before the key existed. *)

val lift_colours_of_doc : Keeper_toml_loader.toml_doc -> bool option
val lift_colours : base_path:string -> bool option
(** [tui].lift_colours. [None] is absent, which the caller reads as on.

    On, a colour the scheme leaves under the readable floor is raised in
    lightness until it clears -- so a status masc says with colour stays
    visible. Off, the scheme's own colour goes out untouched, which is what
    every other terminal UI does and what a reader on a high-contrast scheme
    wants: for them the lift moves a colour their theme placed on purpose. *)

val hints_visible_of_doc : Keeper_toml_loader.toml_doc -> bool option
val hints_visible : base_path:string -> bool option
(** [tui].hints_visible: whether footers spell their key hints. [None]
    where the file, the table or the key is absent -- reads as "yes". *)

val voice_send_on_stop_of_doc : Keeper_toml_loader.toml_doc -> bool option
val voice_send_on_stop : base_path:string -> bool option
(** [tui].voice_send_on_stop: whether ^Y ending a voice capture also sends what
    was heard, instead of leaving it in the draft for the operator to send.
    [None] where the file, the table or the key is absent — reads as "no",
    unlike the toggles around it. They pick between two ways of showing the
    same thing; this one sends a message without the operator confirming it,
    and the draft is also where a spoken half-sentence waits for typing. *)

val coalesce_queued_input_of_doc : Keeper_toml_loader.toml_doc -> bool option
val coalesce_queued_input : base_path:string -> bool option
(** [tui].coalesce_queued_input: whether a new line joins the line already
    waiting for the same Keeper instead of queueing behind it. [None] where
    the file, the table or the key is absent -- reads as "yes".

    Only a next-turn line waiting for that same Keeper is joined. A steer
    keeps its own entry: it was created to replace one exact operation, and
    folding another line into it would move that causal parent. *)
