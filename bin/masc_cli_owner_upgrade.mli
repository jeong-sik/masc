val inspect : base_path:string -> port:int -> int
val stop : base_path:string -> port:int -> agent:string -> expected_version:string -> login:(unit -> int) -> int
(** Requests graceful termination only after explicit selection. Never forces a
    process down; waits for the authenticated workspace owner's lease release. *)
