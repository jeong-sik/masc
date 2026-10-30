(** Explicit ordinary-account Docker access and terminal session continuation. *)
val run : action:string option -> base_path:string option -> port:int -> int
val resume : base_path:string -> port:int -> expected_uid:int -> int
