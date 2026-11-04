(** The Lanes inventory, compared on the server's clock (RFC-0480 §3.4).

    Every {!compare_interval_s} the server takes
    {!Server_lane_inventory.snapshot} and compares what it draws
    ({!Server_lane_inventory.drawn_json}) with the last one it took. When the
    two differ it announces [lanes]. Nothing else announces the inventory:
    its inputs are written in many places (Lane Add-on worker state, the run
    registries, the declaration directory, the binding files, runtime.toml),
    and one compare covers them all. A reader that draws the inventory reads
    it again when told. *)

val compare_interval_s : float

val observe : base_path:string -> Yojson.Safe.t -> unit
(** Announces [lanes] for [base_path] when [drawn] differs from the last value
    observed for it, or when there is none, and keeps [drawn] as the last. *)

val start : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> config:Workspace.config -> unit
(** Takes and observes a snapshot now and then every {!compare_interval_s}.
    A snapshot that raises is logged and compared again on the next turn. *)
