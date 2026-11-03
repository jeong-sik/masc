(** Apply Fusion responses on the UI state owner fiber. These operations mutate
    state and invoke caller-supplied reporting and follow-up refresh callbacks.
    Transport and scheduling remain caller-owned; these operations perform no
    terminal output or clock reads themselves. *)

type demand = Share | After_change
type completion = Applied | Reread | Await_observer | Obsolete

type changed_runs = { any : bool; open_run : bool }
val no_changed_runs : changed_runs
val note_run_changed :
  open_run_id:string option -> changed_runs -> run_id:string -> changed_runs
(** Accumulate every event in a batch; a later unrelated run does not erase
    the fact that the open run changed. *)

val begin_runs :
  Masc_tui_types.state -> demand:demand -> unit Masc_tui_fetched.request option
val begin_detail :
  Masc_tui_types.state -> demand:demand -> run_id:string -> int option
val begin_historical :
  Masc_tui_types.state -> demand:demand ->
  reference:Masc.Tui_decode_fusion.fusion_historical_evidence -> int option
(** A change while the same read is in flight queues one follow-up. [Share]
    shares the active read, preserving ordinary refresh cadence behavior. *)

val revalidate_visible :
  Masc_tui_types.state -> runs:(unit -> unit) -> detail:(string -> unit) ->
  historical:(Masc.Tui_decode_fusion.fusion_historical_evidence -> unit) -> unit
(** Revalidate visible readings when the current server identity authorizes
    reads. Called after subscription, including reconnects, resets and gaps. *)

type reading = Runs | Detail | Historical

val settle_retry :
  Masc_tui_types.state -> reading ->
  failure:(Masc_tui_owed_read.t -> Masc_tui_owed_read.t) option -> unit
(** Settle the retry of an applied answer. [failure] is the transition a
    failed answer takes (the caller supplies the clock and the backoff);
    [None] is a success. A change during the read is not this value's
    business: the reading's reread flag owns it. *)

val retry_due_visible :
  Masc_tui_types.state -> now:float -> runs:(unit -> unit) -> detail:(string -> unit) ->
  historical:(Masc.Tui_decode_fusion.fusion_historical_evidence -> unit) -> unit
(** Read again each visible reading whose failed read is due a retry. Fusion
    re-reads on [fusion_run_status]; nothing else reads it on a timer. *)

val observer_failed :
  Masc_tui_types.state -> runs:(unit -> unit) -> detail:(string -> unit) ->
  historical:(Masc.Tui_decode_fusion.fusion_historical_evidence -> unit) -> unit
(** Resume only readings that settled while the failed subscription was
    opening. Existing reads and ordinary cadence are not invalidated. *)

val runs_loaded :
  Masc_tui_types.state -> unit Masc_tui_fetched.request ->
  (Masc.Tui_decode_fusion.fusion_snapshot, string) result -> completion
(** Drop an obsolete list request before reconciling either surface cursor.
    [Reread] exposes a superseded snapshot as stale while preserving an open
    run and the launch wait. [Await_observer] defers revalidation until an
    opening subscription succeeds or fails. Failed refreshes retain old data. *)

val detail_loaded :
  Masc_tui_types.state -> generation:int -> run_id:string ->
  (Masc.Tui_decode_fusion.fusion_detail, string) result -> completion
(** Clear only the matching in-flight request. Apply the result only when its
    generation and run identity still match the detail being read. *)

val historical_detail_loaded :
  Masc_tui_types.state -> generation:int ->
  reference:Masc.Tui_decode_fusion.fusion_historical_evidence ->
  (Masc.Tui_decode_fusion.fusion_historical_detail, string) result -> completion
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
