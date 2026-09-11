(** Private local setup IPC. These commands never accept a client-supplied
    validator executable, and never return raw provider responses. *)
val render : spec_path:string -> int
val inventory : base_path:string -> int
val configure : base_path:string -> request_path:string -> int
