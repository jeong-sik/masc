let default_threshold = 10

(* Step 14(b) of the bloodflow restoration plan inlined the old threshold env
   knob: hyperparameters belong in code, not in [Sys.getenv_opt]. *)
let threshold () = default_threshold

type record_outcome =
  | Normal
  | Loop_detected of { streak : int; threshold : int }
  | Loop_reset of { previous_streak : int; was_latched : bool }

type progress_identity = Keeper_tool_progress_identity.t

type no_progress_reason =
  | Empty
  | Thinking_only
  | Read_only
  | Repeated_identity
  | Surface_mismatch
  | Stale_task

let no_progress_reason_to_string = function
  | Empty -> "empty"
  | Thinking_only -> "thinking_only"
  | Read_only -> "read_only"
  | Repeated_identity -> "repeated_identity"
  | Surface_mismatch -> "surface_mismatch"
  | Stale_task -> "stale_task"
;;

let no_progress_reason_of_string value =
  match String.trim value |> String.lowercase_ascii with
  | "empty" -> Some Empty
  | "thinking_only" -> Some Thinking_only
  | "read_only" -> Some Read_only
  | "repeated_identity" -> Some Repeated_identity
  | "surface_mismatch" -> Some Surface_mismatch
  | "stale_task" -> Some Stale_task
  | _ -> None
;;

(* Per-keeper state: current streak + latched flag so the
   detected-counter only bumps once per loop episode, not on every
   turn while the keeper is stuck. *)
type keeper_state = {
  mutable streak : int;
  mutable detected_latched : bool;
  mutable last_progress_identity : progress_identity option;
  mutable last_no_progress_reason : no_progress_reason option;
}

let state : (string, keeper_state) Hashtbl.t = Hashtbl.create 16

(* Eio.Mutex: no-progress records originate from keeper turn fibers in a
   single domain. Stdlib.Mutex with PTHREAD_MUTEX_ERRORCHECK turns fiber
   contention into EDEADLK (memory: feedback_eio-mutex-vs-stdlib). *)
let mutex = Eio.Mutex.create ()

let with_lock f =
  Eio.Mutex.use_rw ~protect:true mutex f

let get_or_create keeper_name =
  match Hashtbl.find_opt state keeper_name with
  | Some s -> s
  | None ->
      let s =
        { streak = 0
        ; detected_latched = false
        ; last_progress_identity = None
        ; last_no_progress_reason = None
        }
      in
      Hashtbl.replace state keeper_name s;
      s

let update_streak_gauge keeper_name value =
  Otel_metric_store.set_gauge
    Keeper_metrics.(to_string NoProgressStreak)
    ~labels:[ ("keeper", keeper_name) ]
    (Float.of_int value)

(* RFC-0239 §3 R3: a turn makes progress when it produced durable evidence
   (substantive tool calls or validated output), or when it was delivered on a
   surface where a no-evidence turn is legitimate (a user-facing reply or a
   task claim). A turn that only broadcasts to peers (board post/comment/
   broadcast) or stays silent *without* such evidence is no-progress and
   accrues the loop streak.

   This generalises the retired self-report "stay silent" predicate, which
   reset the streak whenever a keeper *posted* its "nothing to do" conclusion
   — so the detector never fired for a cluster that thrashed by re-posting
   rather than by declaring idleness in a header. Primitive bools keep
   this module decoupled from the social-model type. *)
let turn_made_progress ~strong_evidence ~surface_requires_evidence =
  strong_evidence || not surface_requires_evidence

let repeated_progress_identity s progress_identity =
  match progress_identity with
  | None ->
    s.last_progress_identity <- None;
    false
  | Some current ->
    let repeated =
      match s.last_progress_identity with
      | Some previous -> Keeper_tool_progress_identity.equal previous current
      | None -> false
    in
    s.last_progress_identity <- Some current;
    repeated
;;

let record_turn
      ?threshold_override
      ?progress_identity
      ?no_progress_reason
      ~keeper_name
      ~made_progress
      ()
  =
  with_lock (fun () ->
    let s = get_or_create keeper_name in
    let repeated_identity = repeated_progress_identity s progress_identity in
    let made_progress = made_progress && not repeated_identity in
    if not made_progress then begin
      s.last_no_progress_reason <-
        (if repeated_identity then Some Repeated_identity else no_progress_reason);
      s.streak <- s.streak + 1;
      update_streak_gauge keeper_name s.streak;
      let t =
        match threshold_override with
        | Some n when n > 0 -> n
        | Some _ | None -> threshold ()
      in
      if s.streak >= t && not s.detected_latched then begin
        s.detected_latched <- true;
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string NoProgressLoopDetected)
          ~labels:[ ("keeper", keeper_name) ] ();
        Log.Keeper.error
          "#9926/RFC-0239 no-progress loop detected keeper=%s streak=%d \
           threshold=%d — keeper repeated no-progress turns (silent speech act \
           or board posts with no tool evidence, or identical tool-call \
           progress identity). Check effective tool surface mismatch or \
           scheduler/backlog drift. Counter will not re-fire until the streak \
           resets via a turn that makes progress."
          keeper_name s.streak t;
        Loop_detected { streak = s.streak; threshold = t }
      end else Normal
    end else begin
      let previous_streak = s.streak in
      let was_latched = s.detected_latched in
      if s.streak > 0 then
        update_streak_gauge keeper_name 0;
      s.streak <- 0;
      s.detected_latched <- false;
      s.last_no_progress_reason <- None;
      if previous_streak = 0 then Normal else Loop_reset { previous_streak; was_latched }
    end)

let current_streak ~keeper_name =
  with_lock (fun () ->
    match Hashtbl.find_opt state keeper_name with
    | Some s -> s.streak
    | None -> 0)

let current_reason ~keeper_name =
  with_lock (fun () ->
    match Hashtbl.find_opt state keeper_name with
    | Some s -> s.last_no_progress_reason
    | None -> None)

(* RFC-0246: expose latched state so the wake-tombstone gate can suppress
   automatic wake for a keeper stuck in a no-progress loop. The detector owns
   the single source of truth (streak + detected_latched); the tombstone gate
   reads it rather than duplicating state, so exactly one place decides "this
   keeper is looping". *)
let is_latched ~keeper_name =
  with_lock (fun () ->
    match Hashtbl.find_opt state keeper_name with
    | Some s -> s.detected_latched
    | None -> false)

let reset ~keeper_name =
  with_lock (fun () ->
    Hashtbl.remove state keeper_name;
    update_streak_gauge keeper_name 0)

let reset_all_for_test () =
  with_lock (fun () -> Hashtbl.clear state)
