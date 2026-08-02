(** Dashboard projection for immutable verification submissions.

    Requests contain the submit-time completion contract and evidence envelope.
    Task status is the sole source of the pending obligation and terminal
    outcome; this projection therefore exposes no request-level status, verdict,
    or authority identity. *)

val requests_json :
  base_path:string ->
  ?task_id:string ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t

(** Summary of immutable submissions: update time and total count only. *)
val summary_json : base_path:string -> unit -> Yojson.Safe.t

val proof_compose :
  base_path:string ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t * Yojson.Safe.t
