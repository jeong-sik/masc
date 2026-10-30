(** Full description search data, fetched separately from task list previews.
    Consumers intersect IDs with their displayed tasks and retain their existing
    Unicode/substring matching semantics. No task or description is truncated. *)
type error = Search_text_unavailable
type status = [ `OK | `Service_unavailable ]
val read : config:Workspace.config -> (Yojson.Safe.t, error) result
val response : (Yojson.Safe.t, error) result -> status * Yojson.Safe.t
