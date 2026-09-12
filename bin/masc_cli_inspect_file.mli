(** Inspect an explicitly selected original PDF/PPTX/MP4 with the same native
    tools as verifier Read. JSON goes to stdout. No model verdict or Task/Goal
    transition is requested. Returns zero only after complete inspection. *)
val run : base_path:string -> path:string -> int
