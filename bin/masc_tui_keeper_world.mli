(** Read-only world row and dock from existing workspace-memory inventory and
    Keeper memory-health readings (RFC-0515 W1, RFC-0511 D2c). No I/O. *)
type pulse =
  | Ledger_and_briefing
  | Fact_ages of Masc.Keeper_memory_age_bins.t option
  (** [None] means the whole fleet's ladder was not measured. *)

type row_cells = { pulse : pulse; now_cell : string; strip : string; due : string; right : string }

val row_cells :
  health_error:string option -> view:Masc_tui_keeper_list_model.view ->
  Masc.Tui_decode_memory_health.memory_health_snapshot option ->
  Masc_tui_memory_world.reading -> row_cells
(** Draw on the same grid as the Keeper rows. The caller draws [Fact_ages] with
    the Keeper row's width merging, scale and colours. Age bins count ordinary facts;
    a partial or unread fleet ladder is [?]. The inventory does not measure
    absent facts or ledger save time: those cells remain [?], not inferred.
    A failed health refresh prefixes the current cell with [mem!]; any health
    totals or bins retained beside it belong to the previous successful read.
    Failed ordinary/source snapshot reads also mark the row [mem!]; incomplete
    fact or invalidation totals are [?]. Client-refused rows leave authoritative
    server totals intact while making the age bins unknown. *)

val dock_lines :
  health_error:string option -> cells:int -> max_lines:int ->
  Masc.Tui_decode_memory_health.memory_health_snapshot option ->
  Masc_tui_memory_world.reading -> string list
(** Keeper memory, then the curator ledger, then its briefing. A retained
    inventory after a failed refresh is explicitly marked by the existing
    world's clauses, including the read failure. A health failure is also a
    priority diagnostic on the Keeper stage. Row/source read errors qualify
    partial counts. With at least three lines every stage remains visible;
    smaller docks combine the stages or explicitly say the view is partial.
    No published timestamp,
    absence count, next run time or verification verdict is invented. *)
