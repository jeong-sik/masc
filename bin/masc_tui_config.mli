(* TUI settings read from the [tui] table of runtime.toml. See the .ml. *)

(* [tui].theme, given an already-parsed runtime.toml document. [None] when the
   key (or the [tui] table) is absent. Pure, so the caller's file read stays
   separate from the extraction. *)
val theme_of_doc : Keeper_toml_loader.toml_doc -> string option

(* [tui].theme read from the runtime.toml under [base_path]'s resolved config
   root. [None] when the file is absent, unreadable, unparseable, or carries no
   [tui].theme -- all of which mean "no stored choice". *)
val theme : base_path:string -> string option
