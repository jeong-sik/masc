(** Search the workspace's published reports from an admitted Keeper turn.
    A search returns candidates, never an identity decision or permission to
    replace a document. Pagination is bound to the observed catalog and query. *)
type query

val query_of_json : Yojson.Safe.t -> (query, string) result
val published_id_of_json : Yojson.Safe.t -> (string, string) result

val find : base_path:string -> query -> Keeper_tool_execution.t
val published : base_path:string -> id:string -> Keeper_tool_execution.t
