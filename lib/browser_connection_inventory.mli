(** Read-only, sequential browser-worker observations. This inventory grants
    no control and is revalidated by a later explicit browser call. *)
type issue =
  | Source_unavailable of {instance_id:string; message:string}
  | Source_unreadable of {instance_id:string; message:string}
  | Source_unready of {instance_id:string; message:string}
  | Duplicate_client of {client_id:Browser_lane.client_id; instances:string list}
  | Duplicate_ego_space of {space_id:int; instances:string list}
  | Ego_user_owned_space of {instance_id:string; space:string; observed_at:float}
  | Ego_space_missing of {instance_id:string; space:string; space_id:int; observed_at:float}
val breaks_completeness : issue -> bool
(** A lane fact the worker answered whole (a refused or a missing ego task
    Space) does
    not break inventory completeness; a worker that did not answer, an
    unreadable answer or a duplicate controller does. The server and the
    TUI agree through this one predicate. *)
val issue_message : issue -> string
val issues_to_json : issue list -> Yojson.Safe.t
val issues_of_json : Yojson.Safe.t -> (issue list, string) result
type observation = {instance_id:string; published:Browser_addon_observation.published}
type t
val build : observations:observation list -> issues:issue list -> t
(** Keep valid rows from readable workers; exclude every duplicate client ID
    and every controller advertising a conflicting native Ego Space ID.
    Any issue refuses automatic selection without claiming no browser exists.
    With several workers only concrete live UUIDs can be recommended; owned
    work routes still require an unambiguous worker scope. *)
val to_json : t -> Yojson.Safe.t
(** [clients], [inventoryIssues], [inventoryComplete], [automatic]. One-worker
    complete observations retain the existing browser-selection policy. *)
