(** Private local setup IPC. These commands never accept a client-supplied
    validator executable, and never return raw provider responses. *)
val render : base_path:string option -> spec_path:string -> int
val inventory : base_path:string -> port:int -> agent:string -> int
(** The setup choices and their revision, read from the runtime.toml the
    workspace's running server holds while it answers on [port]. *)
val configure : base_path:string -> port:int -> agent:string -> request_path:string -> int
(** While this workspace's server answers on [port], the save is decided
    against the runtime.toml it holds and published through it (RFC-0482
    §3.2); otherwise the command writes the file itself. *)
