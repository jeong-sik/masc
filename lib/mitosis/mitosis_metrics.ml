(** Mitosis Prometheus Metrics

    Registers and exposes counters, gauges, and histograms for the
    mitosis (cell-division) subsystem.  All helpers are thin wrappers
    around {!Prometheus} so callers need not know metric names.

    Metrics are auto-created on first use (Prometheus auto-vivifies
    unknown keys) so no Eio runtime is needed at module load time.

    @since 0.5.0 *)

(* -- metric names (single source of truth) ---------------------- *)

let handoff_total        = "mitosis_handoff_total"
let prepare_total        = "mitosis_prepare_total"
let error_total          = "mitosis_error_total"
let current_generation   = "mitosis_current_generation"
let cooldown_remaining   = "mitosis_cooldown_remaining_seconds"
let handoff_duration     = "mitosis_handoff_duration_seconds"

(* -- convenience helpers ---------------------------------------- *)

let inc_handoff () =
  Prometheus.inc_counter handoff_total ()

let inc_prepare () =
  Prometheus.inc_counter prepare_total ()

let inc_error ?(reason="unknown") () =
  Prometheus.inc_counter error_total ~labels:[("reason", reason)] ()

let set_generation gen =
  Prometheus.set_gauge current_generation (float_of_int gen)

let set_cooldown_remaining secs =
  Prometheus.set_gauge cooldown_remaining secs

let observe_handoff_duration secs =
  Prometheus.observe_histogram handoff_duration secs
