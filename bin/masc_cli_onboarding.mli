(** Run the release's embedded setup journey with the terminal attached.
    No workspace/environment resolution occurs at module initialization.
    [resume] opens a previously prepared workspace without reselecting models;
    it never represents persisted configuration as an authenticated runtime. *)
val run : base_path:string option -> port:int -> resume:bool -> int

val python : string -> string option
(** Resolve the release-bundled Python, then an available PATH interpreter. *)
