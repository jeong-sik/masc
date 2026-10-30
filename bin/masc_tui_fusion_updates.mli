(** Apply Fusion responses on the UI state owner fiber. These operations mutate
    state and invoke caller-supplied reporting and follow-up refresh callbacks.
    Transport and scheduling remain caller-owned; these operations perform no
    terminal output or clock reads themselves. *)

val runs_loaded :
  Masc_tui_types.state -> unit Masc_tui_fetched.request ->
  (Masc.Tui_decode_fusion.fusion_snapshot, string) result -> unit
(** Drop an obsolete list request before reconciling either surface cursor.
    A failed current refresh retains the previous snapshot as stale. *)

val detail_loaded :
  Masc_tui_types.state -> generation:int -> run_id:string ->
  (Masc.Tui_decode_fusion.fusion_detail, string) result -> unit
(** Clear only the matching in-flight request. Apply the result only when its
    generation and run identity still match the detail being read. *)

val historical_detail_loaded :
  Masc_tui_types.state -> generation:int ->
  reference:Masc.Tui_decode_fusion.fusion_historical_evidence ->
  (Masc.Tui_decode_fusion.fusion_historical_detail, string) result -> unit
(** The matching in-flight request settles even if navigation moved on;
    the displayed result changes only for the still-current reference. *)

val launch_options_loaded :
  Masc_tui_types.state -> generation:int -> report:(string -> unit) ->
  (Masc.Tui_decode_fusion.fusion_launch_options, string) result -> unit
(** Only the form waiting for this generation consumes the response.
    [report] records a refusal after the form state has been updated. *)

val launched :
  Masc_tui_types.state -> generation:int -> report:(string -> unit) ->
  refresh:(unit -> unit) -> (string, string) result -> unit
(** Only the current submitting form consumes the response. Success records
    the started run, calls [report], then calls [refresh]. Refusal returns the
    existing form to editing and reports the reason. Obsolete responses invoke
    neither callback. *)
