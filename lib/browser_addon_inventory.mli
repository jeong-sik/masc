(** Typed worker inventory shared by owner publication and host selection. *)
val observe : unit -> Browser_selection.snapshot
(** The worker's own browsers: its live clients and the owned automation and
    Stagehand sessions of this process. Only the worker reads this; the host
    chooses from the worker's [Snapshot] reply. *)
val owned_to_json : Browser_selection.snapshot -> Yojson.Safe.t
val owned_of_json : Yojson.Safe.t ->
  (Browser_selection.work_browser * Browser_selection.work_browser, string) result
