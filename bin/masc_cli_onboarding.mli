(** Run the release's embedded setup journey with the terminal attached.
    No workspace/environment resolution occurs at module initialization.
    [resume] opens a previously prepared workspace without reselecting models;
    it never represents persisted configuration as an authenticated runtime.
    [sandbox_step] resumes the saved model configuration at sandbox selection;
    the caller must validate a changed account session before setting it. *)
val run : base_path:string option -> port:int -> resume:bool -> sandbox_step:bool -> int

val python : string -> string option
(** Resolve the packaged interpreter first, then an available PATH interpreter. *)
