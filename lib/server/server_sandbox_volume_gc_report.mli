(** The server's periodic [masc_sandbox_volume_gc] report. One maintenance
    pulse after the server starts, and every {!report_interval_sec} after
    that, the server judges this workspace's Keeper volumes without
    [execute] ({!Keeper_volume_gc_periodic.observe}) and keeps the last pass
    in process memory for the dashboard tools envelope. Each pass writes one
    server log line. Nothing here deletes a volume: deleting stays the
    operator's two presses of [V] in the TUI. *)

(** Six hours. A pass checks the host and Apple Container, lists the
    volumes once, reads the container inventory once per Keeper with a
    volume, and starts one claims-read helper microVM per unregistered,
    unreferenced work volume: about 6-8 s for 29 Keepers and 3 helpers on
    2026-11-06. Reclaim candidates appear only when a Keeper retires, so four
    passes a day, plus one after each restart, keep the count current
    without starting helper microVMs every pulse. *)
val report_interval_sec : float

(** This workspace's last pass, or [`Null] when no matching pass is retained.
    Installing a pass announces its Tools source after the value is visible. *)
val envelope_json : base_path:string -> unit -> Yojson.Safe.t

val start :
  sw:Eio.Switch.t
  -> clock:float Eio.Time.clock_ty Eio.Resource.t
  -> config:Workspace.config
  -> unit
