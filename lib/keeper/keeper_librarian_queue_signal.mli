val install : (base_path:string -> keeper_name:string -> unit) -> unit
val changed : base_path:string -> keeper_name:string -> unit
(** Nonblocking notification after queue commit. The installed callback only
    submits latest-wins Librarian work; it must not read or mutate queues. *)
