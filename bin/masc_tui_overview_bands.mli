(** btop-style unified telemetry and keeper bands for the Overview surface.

    On terminals wide and tall enough, Overview renders a compact top
    Fleet/Engine telemetry ribbon and a live Keepers mini-table directly
    above the four overview cards so operators can read fleet capacity,
    engine health, active keepers, and pending decisions in one glance
    without switching tabs. On narrower or shorter terminals, {!plan}
    returns {!Cards_only} and Overview keeps its existing card layout. *)

type plan =
  | Cards_only
  | With_bands of {
      telemetry_rows : int;
      keeper_rows : int;
      card_rows : int;
    }

val min_cols : int
(** Minimum inner width in display cells required to show the upper bands. *)

val min_rows : int
(** Minimum available body rows required to show the upper bands. *)

val plan : available:int -> cols:int -> keeper_count:int -> plan
(** Pure vertical row budget split between the top telemetry ribbon,
    the live keepers mini-table, and the lower overview cards. Independent of
    [keeper_count] so incoming keeper snapshots never shift lower cards.
    Whenever [With_bands { telemetry_rows; keeper_rows; card_rows }] is
    returned, [telemetry_rows + keeper_rows + card_rows = available],
    [telemetry_rows >= 4], [keeper_rows = 0 || keeper_rows >= 3], and
    [card_rows >= 8]. *)

type telemetry_snapshot = {
  fleet_running : int;
  fleet_bootable : int;
  capacity_avail : int;
  capacity_target : int;
  capacity_shortfall : int;
  fleet_status : Masc_tui_card.status option;
  heap_live_words : int option;
  heap_total_words : int option;
  heap_live_text : string option;
  heap_total_text : string option;
  sched_p95_ms : float option;
  sched_stalls : int option;
  tool_calls_summary : string option;
}

val render_telemetry :
  ko:bool ->
  width:int ->
  height:int ->
  telemetry_snapshot ->
  string list
(** Renders the top Fleet · Engine telemetry card to exactly [height] rows
    of display width [width]. *)

type keeper_entry = {
  name : string;
  mark : string;
  mark_tone : string;
  state_label : string;
  activity_summary : string;
      (** Overview-available activity summary (e.g. turns and tokens from the
          keeper roster snapshot), or [""] / ["—"] when unread. *)
  detail : string;
  needs_attention : bool;
}

val render_keepers :
  ko:bool ->
  width:int ->
  height:int ->
  total_keepers:int ->
  keeper_entry list ->
  string list
(** Renders the live Keepers mini-table card to exactly [height] rows of
    display width [width]. *)
