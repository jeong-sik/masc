let default_threshold = 10

(* Step 14(b) of the bloodflow restoration plan inlined the env knob
   [MASC_STAY_SILENT_LOOP_THRESHOLD]: hyperparameters belong in code,
   not in [Sys.getenv_opt]. *)
let threshold () = default_threshold

(* Per-keeper state: current streak + latched flag so the
   detected-counter only bumps once per loop episode, not on every
   turn while the keeper is stuck. *)
type keeper_state = {
  mutable streak : int;
  mutable detected_latched : bool;
}

let state : (string, keeper_state) Hashtbl.t = Hashtbl.create 16

(* Eio.Mutex: stay-silent records originate from keeper turn fibers in a
   single domain. Stdlib.Mutex with PTHREAD_MUTEX_ERRORCHECK turns fiber
   contention into EDEADLK (memory: feedback_eio-mutex-vs-stdlib). *)
let mutex = Eio.Mutex.create ()

let with_lock f =
  Eio.Mutex.use_rw ~protect:true mutex f

let get_or_create keeper_name =
  match Hashtbl.find_opt state keeper_name with
  | Some s -> s
  | None ->
      let s = { streak = 0; detected_latched = false } in
      Hashtbl.replace state keeper_name s;
      s

let update_streak_gauge keeper_name value =
  Prometheus.set_gauge
    "masc_keeper_stay_silent_streak"
    ~labels:[ ("keeper", keeper_name) ]
    (Float.of_int value)

let record_turn ~keeper_name ~speech_act =
  with_lock (fun () ->
    let s = get_or_create keeper_name in
    if speech_act = "stay_silent" then begin
      s.streak <- s.streak + 1;
      update_streak_gauge keeper_name s.streak;
      let t = threshold () in
      if s.streak >= t && not s.detected_latched then begin
        s.detected_latched <- true;
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_stay_silent_loop_detected
          ~labels:[ ("keeper", keeper_name) ] ();
        Log.Keeper.warn
          "#9926 stay_silent loop detected keeper=%s streak=%d threshold=%d \
           — keeper is returning stay_silent repeatedly. Check preset \
           mismatch (#9926 proposal 1) or scheduler/backlog drift. \
           Counter will not re-fire until the streak resets via any \
           non-stay_silent speech act."
          keeper_name s.streak t
      end
    end else begin
      if s.streak > 0 then
        update_streak_gauge keeper_name 0;
      s.streak <- 0;
      s.detected_latched <- false
    end)

let current_streak ~keeper_name =
  with_lock (fun () ->
    match Hashtbl.find_opt state keeper_name with
    | Some s -> s.streak
    | None -> 0)

let reset ~keeper_name =
  with_lock (fun () ->
    Hashtbl.remove state keeper_name;
    update_streak_gauge keeper_name 0)

let reset_all_for_test () =
  with_lock (fun () -> Hashtbl.clear state)
