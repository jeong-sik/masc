val json
  :  ?actor:string
  -> ?fixture:string
  -> ?light:bool
  -> config:Coord.config
  -> sw:Eio.Switch.t
  -> clock:'a Eio.Time.clock
  -> proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option
  -> unit
  -> Yojson.Safe.t

(** #9766: per-render phase timing surfaced in the [slow render] WARN.
    Pure value type so unit tests can pin the formatter without
    booting Eio. *)
type render_phase_timings_ms =
  { total_ms : float
  ; snapshot_ms : float
  ; operations_ms : float
  ; enrich_ms : float
  ; data_load_ms : float
  ; assemble_ms : float
  ; n_keepers : int
  }

(** Average enrich-phase ms per keeper.  Returns [0.0] when
    [n_keepers = 0] to avoid divide-by-zero in startup races. *)
val per_keeper_enrich_ms : render_phase_timings_ms -> float

(** Render the breakdown into the WARN suffix.  Stable format so
    log scrapers can parse it. *)
val format_slow_render_timings : render_phase_timings_ms -> string
