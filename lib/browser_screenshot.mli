(** Persist a browser PNG in the owning Keeper's existing Vision artifact store.
    [base_path] is the served Workspace, not page or tool-body data. Storage uses
    its config-root resolution, including an operator's explicit config override.
    No encoded pixels are returned on the tool's text channel. *)
val persist : base_path:string -> keeper_name:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result
