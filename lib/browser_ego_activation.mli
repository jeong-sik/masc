(** Explicit activation of a native managed Page in the original agent-owned
    Ego Space. CDP target/window IDs are derived from that Space's current
    inventory, never from caller input. Restores only a minimized window.
    An explicitly adopted unknown-origin Page retains its origin; unmanaged
    tabs cannot be activated. Target, label, origin and URL stay bound across
    observations before and after activation.
    Native active/window state is not proof of rendered UI or OS focus. *)
val script : string
(** Fixed native TaskSpace.cdp workflow, accepting label and expectedUrl.
    Returns a before-effect refusal or an activation observation. Failures
    after a mutation remain uncertain and must never trigger replay. *)
val receipt : space_id:int -> tab_id:int -> label:string -> expected_url:string ->
  Yojson.Safe.t -> (Yojson.Safe.t, string) result
(** Validate same-Space/Page/URL, active=true and the observed window transition
    before projecting a public receipt. No pointer frame is produced. *)
