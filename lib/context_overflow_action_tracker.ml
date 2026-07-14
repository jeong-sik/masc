let default_grace_window_sec = 60.0

let grace_window_seconds () =
  match Sys.getenv_opt "MASC_CONTEXT_OVERFLOW_GRACE_SEC" with
  | Some v when v <> "" ->
    (match float_of_string_opt v with
     | Some f when f > 0.0 -> f
     | _ -> default_grace_window_sec)
  | _ -> default_grace_window_sec

(* Per-keeper state.

   [pending_since]: timestamp of the current unanswered imminent,
   or None if no imminent is pending (either never happened or the
   last one was cleared by an action).

   [no_action_fired_for_pending]: latches the no_action counter
   so multiple late-arriving imminent events for the same
   unanswered episode only fire once. Resets when pending clears. *)
type keeper_state = {
  mutable pending_since : float option;
  mutable no_action_fired_for_pending : bool;
}

let state : (string, keeper_state) Hashtbl.t = Hashtbl.create 16
let mu = Stdlib.Mutex.create ()

let with_lock f = Stdlib.Mutex.protect mu f

let get_or_create keeper_name =
  match Hashtbl.find_opt state keeper_name with
  | Some s -> s
  | None ->
    let s = { pending_since = None; no_action_fired_for_pending = false } in
    Hashtbl.replace state keeper_name s;
    s

let record_imminent ~keeper_name ~ts =
  with_lock (fun () ->
    let s = get_or_create keeper_name in
    Otel_metric_store.inc_counter
      "masc_context_overflow_imminent_total"
      ~labels:[ ("keeper", keeper_name) ] ();
    let grace = grace_window_seconds () in
    match s.pending_since with
    | None ->
      (* Fresh episode — no prior pending, so the latch starts in
         the not-fired state. *)
      s.pending_since <- Some ts;
      s.no_action_fired_for_pending <- false
    | Some prior_ts
      when ts -. prior_ts > grace
        && not s.no_action_fired_for_pending ->
      (* Prior imminent went unanswered past the grace window.
         Fire no-action once per episode, latch engaged, and
         advance the pending marker so subsequent action-pairing
         still works for the same episode. Crucially, do NOT
         reset the latch — this is still the same stuck episode
         until record_action clears it. *)
      s.no_action_fired_for_pending <- true;
      s.pending_since <- Some ts;
      Otel_metric_store.inc_counter
        "masc_context_overflow_no_action_total"
        ~labels:[ ("keeper", keeper_name) ] ();
      Log.Server.warn
        "#9935 context_overflow_imminent with no reduction action \
         keeper=%s prior_imminent_age_sec=%.1f grace_sec=%.1f \
         — OAS issued context_overflow_imminent but no \
         context_compact_started / context_compacted event \
         followed within the grace window. Check compaction \
         gating (#9943), context-window resolution (#9933), or the \
         OAS compact planner." keeper_name (ts -. prior_ts) grace
    | Some _ ->
      (* Within grace, or latch already engaged. Advance the
         pending marker but preserve the latch state so we do
         not re-fire the no-action counter on every imminent. *)
      s.pending_since <- Some ts)

let record_action ~keeper_name =
  with_lock (fun () ->
    match Hashtbl.find_opt state keeper_name with
    | Some s when Option.is_some s.pending_since ->
      Otel_metric_store.inc_counter
        "masc_context_overflow_action_taken_total"
        ~labels:[ ("keeper", keeper_name) ] ();
      s.pending_since <- None;
      s.no_action_fired_for_pending <- false
    | _ -> ())

let current_pending_since ~keeper_name =
  with_lock (fun () ->
    match Hashtbl.find_opt state keeper_name with
    | Some s -> s.pending_since
    | None -> None)

let reset_all_for_test () =
  with_lock (fun () -> Hashtbl.clear state)
