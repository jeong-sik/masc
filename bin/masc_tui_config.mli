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
