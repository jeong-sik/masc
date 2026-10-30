(** Exact original-body pages. Caller must enforce CanAdmin and run this
    blocking lookup/scan through the existing I/O worker boundary. *)
val response :
  config:Workspace.config -> keeper:string -> Httpun.Request.t ->
  [ `OK | `Bad_request | `Not_found | `Conflict | `Service_unavailable ] * Yojson.Safe.t
