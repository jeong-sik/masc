val install : (base_path:string -> keeper_name:string -> unit) -> unit
val changed : base_path:string -> keeper_name:string -> unit
(** Nonblocking notification after a queue commit or a finished turn. The
    installed callback only submits a latest-wins working-context pass; it
    must not read or mutate queues. *)
