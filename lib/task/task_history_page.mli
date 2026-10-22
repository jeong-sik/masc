(** Read-only original Task observations from the two active dated stores. *)
type source = Activity | Audit
type availability = Observed | Not_created
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
  ; sources : (source * availability) list
  ; events : Yojson.Safe.t list
  ; next_cursor : cursor option }
val read : config:Workspace_core.config -> task_id:string -> max_events:int ->
  ?cursor:cursor -> unit -> (page, error) result
(** Newest dated file first, activity before audit within the same day file,
    then reverse physical row order. This is source order, not a merged event
    timestamp order or a count of state transitions. Each event preserves its
    source, relative file, byte offset and original JSON row. Distinct lifecycle
    and audit observations are never heuristically deduplicated.

    [max_events] controls one response, never total history. Continuations bind
    the Task/workspace, both source inventories and original physical boundary.
    Appends above each source's captured ceiling are excluded. Removal,
    replacement, truncation, changed anchors, malformed data and layout refuse
    advancement. A source not yet created is explicitly reported and pinned;
    unreadable sources and both absent are errors. Exhaustion applies only to
    the observed stored prefix, never deleted/retained-away history. *)
val to_json : page -> Yojson.Safe.t
