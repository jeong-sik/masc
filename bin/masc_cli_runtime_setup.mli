(** Private local setup IPC. These commands never accept a client-supplied
    validator executable, and never return raw provider responses. *)
val render : base_path:string option -> spec_path:string -> int
val inventory : base_path:string -> port:int -> agent:string -> int
(** The setup choices and their revision, read from the runtime.toml the
    workspace's running server holds while the process that holds the lease
    announces [port] as the server of a single user. *)
val configure : base_path:string -> port:int -> agent:string -> request_path:string -> int
(** While the process that holds the lease of the workspace announces [port]
    as the server of a single user, the save is decided against the
    runtime.toml it holds and published through it (RFC-0482 §3.2). With
    nothing holding the lease the command writes the file itself. Any other
    lease holder stops the command. *)
