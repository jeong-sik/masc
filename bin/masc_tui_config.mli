(* TUI settings read from the [tui] table of runtime.toml. See the .ml. *)

(* [tui].theme, given an already-parsed runtime.toml document. [None] when the
   key (or the [tui] table) is absent. Pure, so the caller's file read stays
   separate from the extraction. *)
val theme_of_doc : Keeper_toml_loader.toml_doc -> string option

(* [tui].theme read from the runtime.toml under [base_path]'s resolved config
   root. [None] when the file is absent, unreadable, unparseable, or carries no
   [tui].theme -- all of which mean "no stored choice". *)
val theme : base_path:string -> string option

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

val coalesce_queued_input_of_doc : Keeper_toml_loader.toml_doc -> bool option
val coalesce_queued_input : base_path:string -> bool option
(** [tui].coalesce_queued_input: whether a new line joins the line already
    waiting for the same Keeper instead of queueing behind it. [None] where
    the file, the table or the key is absent -- reads as "yes".

    Only a next-turn line waiting for that same Keeper is joined. A steer
    keeps its own entry: it was created to replace one exact operation, and
    folding another line into it would move that causal parent. *)
