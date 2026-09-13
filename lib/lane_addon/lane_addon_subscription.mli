(** Subscriptions publish references, never original source bodies or wakeups.
    Read receipts and explicit acknowledgements are distinct from semantic use. *)
type subscription = {keeper_name:string; run_id:string; installation_id:string; output_id:string}
type operation = Inspect | Save | Read | Acknowledge
val json : subscription -> Yojson.Safe.t
val decode : Yojson.Safe.t -> (subscription, string) result
val dispatch : config:Workspace.config -> caller:string -> operation:operation ->
  Yojson.Safe.t -> (Yojson.Safe.t, string) result
val observe : config:Workspace.config -> keeper_name:string -> (Yojson.Safe.t, string) result
val render : (Yojson.Safe.t, string) result -> string option
val handle : config:Workspace.config -> caller:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result
