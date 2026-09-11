(** Apply saved model settings to the authenticated owner of this workspace.
    No provider inference, guest boot, or token rotation is performed. *)
val run : base_path:string -> port:int -> agent:string -> int
