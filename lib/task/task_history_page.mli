(** Contiguous, Task-bound reads of the dated event store. Read-only: no
    snapshot files, cache, migration or scheduling authority. *)
type cursor
type error =
  | Invalid_request
  | Invalid_cursor
  | Source_changed
  | Invalid_event of { file : string; offset : int }
  | Invalid_layout of { entry : string }
  | Source_unavailable
val cursor_to_string : cursor -> string
val cursor_of_string : string -> (cursor, error) result
type page =
  { task_id : string
  ; cursor : cursor option
  ; events : Yojson.Safe.t list
  ; next_cursor : cursor option }
val read : config:Workspace_core.config -> task_id:string -> max_events:int ->
  ?cursor:cursor -> unit -> (page, error) result
(** Newest first. [max_events] controls one response, never total history.
    [next_cursor = None] means the captured dated prefix was exhausted, not
    that deleted/retained-away history never existed. A continuation binds the
    Task, workspace, dated inventory and original physical row boundary.
    Appends above that boundary are excluded. Replacement, removal, a changed
    anchor, malformed data or invalid dated layout refuses advancement. This is an observed prefix,
    not an atomic multi-file snapshot. Missing/unreadable stores are errors. *)
val to_json : page -> Yojson.Safe.t
