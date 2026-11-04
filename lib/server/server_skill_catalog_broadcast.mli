(** Says that the skill catalog snapshot was published (RFC-0480 §3.4).

    {!Skill_catalog_snapshot_service.publish} is the one store function for the
    snapshot and calls the process-wide publication observer after every
    [Published] publication (boot, a runtime-config apply, the skill editor,
    a Keeper's skill publish, a lane add-on skill export). The server installs
    [publication_observer ~base_path ~invalidate_full_health] there: it drops
    the full-health snapshot, then sends {!Skill_catalog_published_event} to
    [base_path]'s observers. A failed broadcast is counted on
    [keeper_sse_broadcast_failures] and logged at WARN; [Cancelled] is raised
    again, and the service's observer guard reports it. *)

val publication_observer :
  base_path:string -> invalidate_full_health:(unit -> unit) -> unit -> unit
