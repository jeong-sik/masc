(** The operator's Lane Add-ons Inspect, compared on the server's clock
    (RFC-0480 §3.4).

    Every {!Server_lane_inventory_watch.compare_interval_s} the server reads
    {!Lane_addon_runtime.inspect_reading} and compares it with the last one:
    each instance's Inspect entry with its action receipts, and the
    declaration reading. It announces [lane_addon_instance] with the id of
    each instance that moved, appeared or left, and
    [lane_addon_configuration] when the declaration reading moved. The
    Add-ons pane reads again when told about what it shows. *)

val observe : base_path:string -> Lane_addon_runtime.inspect_reading -> unit
(** Announces what moved in [reading] since the last reading observed for
    [base_path], everything when there is none, and keeps [reading]. *)

val start : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> config:Workspace.config -> unit
(** Reads and observes now and then every interval. No manager yet is no
    reading. A read that fails is logged, and the next one waits twice as
    long as the last wait, up to thirty seconds, until one succeeds. *)
