(** Persist a browser PNG in the owning Keeper's existing Vision artifact store.
    No encoded pixels are returned on the tool's text channel. *)
val persist : keeper_name:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result
