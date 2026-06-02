(** Prometheus bridge for backend filesystem mutex contention metrics. *)

val install : unit -> unit
(** Install Prometheus-backed observers for {!Backend.FileSystem} write
    mutex acquire/held timings.

    The backend sub-library intentionally has no dependency on Prometheus.
    Calling [install] from the top-level runtime wires that dependency from
    [masc_mcp], where both modules are already available. *)
