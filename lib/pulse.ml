(** Pulse — the beating heart of any Space.

    Implementation notes:
    - [Eio.Fiber.first] races timer vs nudge-wait. First to complete wins.
    - Nudge signaling: [Eio.Stream] (capacity 1) — cancellation-safe, no mutex.
    - Shutdown signaling: [Eio.Promise] — one-shot, non-blocking resolve.
    - Quiet hours stretch the interval by 3x (configurable via rhythm).
    - Consumer errors are logged but never crash the pulse.
*)

(* ── Types ───────────────────────────────────────────────────── *)

type trigger =
  | Rhythm
  | Nudge of string
  | Demand

type beat = {
  seq     : int;
  ts      : float;
  trigger : trigger;
}

type rhythm = {
  base_s  : float;
  min_s   : float;
  max_s   : float;
  quiet   : int * int;
}

type lifecycle =
  | Perpetual
  | Bounded of (beat -> bool)

type stats = {
  total_beats   : int;
  total_nudges  : int;
  uptime_s      : float;
  avg_interval  : float;
}

module type Consumer = sig
  val name       : string
  val should_act : beat -> bool
  val on_beat    : beat -> (unit, string) result
end

(* ── Internal state ──────────────────────────────────────────── *)

type any_clock = Clock : _ Eio.Time.clock -> any_clock

type t = {
  clock      : any_clock;
  rhythm     : rhythm;
  lifecycle  : lifecycle;
  mutable consumers : (module Consumer) list;
  (* nudge signaling — Stream is cancellation-safe under Fiber.first *)
  nudge_stream : string Eio.Stream.t;
  (* shutdown signaling — Promise is one-shot and non-blocking *)
  shutdown_p   : unit Eio.Promise.t;
  shutdown_r   : unit Eio.Promise.u;
  (* engine state *)
  mutable seq         : int;
  mutable last_beat_v : beat option;
  mutable alive       : bool;
  mutable total_nudges: int;
  mutable start_ts    : float;
}

(* ── Defaults ────────────────────────────────────────────────── *)

let default_rhythm = {
  base_s = 60.0;
  min_s  = 30.0;
  max_s  = 300.0;
  quiet  = (1, 6);
}

(* ── Helpers ─────────────────────────────────────────────────── *)

let now (Clock c) = Eio.Time.now c
let sleep (Clock c) s = Eio.Time.sleep c s

(** Current KST hour (UTC+9). *)
let kst_hour clock =
  let t = Unix.gmtime (now clock) in
  (t.tm_hour + 9) mod 24

(** Is the current hour within the quiet window? *)
let is_quiet_hour clock rhythm =
  let h = kst_hour clock in
  let (qs, qe) = rhythm.quiet in
  if qs <= qe then
    (* e.g., 1..6 *)
    h >= qs && h < qe
  else
    (* wrap-around, e.g., 22..6 *)
    h >= qs || h < qe

(** Compute the effective interval for the next beat.
    Quiet hours stretch the base interval by 3x, clamped to [min, max]. *)
let effective_interval clock rhythm =
  let base =
    if is_quiet_hour clock rhythm then
      rhythm.base_s *. 3.0
    else
      rhythm.base_s
  in
  Float.max rhythm.min_s (Float.min rhythm.max_s base)

(* ── Consumer dispatch ───────────────────────────────────────── *)

let trigger_to_string = function
  | Rhythm    -> "rhythm"
  | Nudge r   -> Printf.sprintf "nudge(%s)" r
  | Demand    -> "demand"

let dispatch_consumers consumers beat =
  List.iter (fun (module C : Consumer) ->
    if C.should_act beat then begin
      match C.on_beat beat with
      | Ok () -> ()
      | Error msg ->
        Eio.traceln "[pulse] consumer %s error on beat #%d: %s"
          C.name beat.seq msg
    end
  ) consumers

(* ── Core loop ───────────────────────────────────────────────── *)

(** Is shutdown requested? Non-blocking check. *)
let is_shutdown t =
  match Eio.Promise.peek t.shutdown_p with
  | Some () -> true
  | None -> false

(** One tick: determine trigger, make beat, dispatch consumers, check lifecycle. *)
let tick t trigger =
  t.seq <- t.seq + 1;
  let beat = {
    seq     = t.seq;
    ts      = now t.clock;
    trigger;
  } in
  t.last_beat_v <- Some beat;
  (match trigger with Nudge _ -> t.total_nudges <- t.total_nudges + 1 | _ -> ());
  Eio.traceln "[pulse] beat #%d trigger=%s" beat.seq (trigger_to_string trigger);
  dispatch_consumers t.consumers beat;
  (* Check bounded lifecycle *)
  (match t.lifecycle with
   | Perpetual -> ()
   | Bounded pred ->
     if pred beat && not (is_shutdown t) then begin
       Eio.traceln "[pulse] bounded lifecycle condition met at beat #%d" beat.seq;
       Eio.Promise.resolve t.shutdown_r ()
     end);
  beat

(** The main pulse loop. Races timer vs nudge vs shutdown on each iteration.

    The three-way race uses nested [Eio.Fiber.first]:
    - Outer: timer vs (nudge | shutdown)
    - Inner: nudge (Stream.take) vs shutdown (Promise.await)

    All three blocking primitives (sleep, Stream.take, Promise.await) are
    cleanly cancellable — no Mutex involvement, no Poisoned risk. *)
let loop t =
  (* Beat 0: startup demand *)
  let _startup_beat = tick t Demand in
  while not (is_shutdown t) do
    let interval = effective_interval t.clock t.rhythm in
    (* Non-blocking drain: if a nudge arrived between beats, handle it now *)
    match Eio.Stream.take_nonblocking t.nudge_stream with
    | Some reason ->
      let _b = tick t (Nudge reason) in ()
    | None ->
      (* Three-way race: timer vs (nudge | shutdown) *)
      let trigger =
        Eio.Fiber.first
          (fun () ->
             sleep t.clock interval;
             Rhythm)
          (fun () ->
             Eio.Fiber.first
               (fun () ->
                  let reason = Eio.Stream.take t.nudge_stream in
                  Nudge reason)
               (fun () ->
                  Eio.Promise.await t.shutdown_p;
                  Demand))
      in
      if not (is_shutdown t) then
        let _b = tick t trigger in ()
  done;
  (* Final beat: shutdown demand *)
  let _shutdown_beat = tick t Demand in
  t.alive <- false;
  Eio.traceln "[pulse] stopped after %d beats" t.seq

(* ── Public API ──────────────────────────────────────────────── *)

let create ~clock ~rhythm ~lifecycle ~consumers =
  let ac = Clock clock in
  let (shutdown_p, shutdown_r) = Eio.Promise.create () in
  {
    clock = ac;
    rhythm;
    lifecycle;
    consumers;
    nudge_stream = Eio.Stream.create 1;
    shutdown_p;
    shutdown_r;
    seq         = 0;
    last_beat_v = None;
    alive       = false;
    total_nudges= 0;
    start_ts    = now ac;
  }

let run ~sw t =
  t.alive    <- true;
  t.start_ts <- now t.clock;
  Eio.Fiber.fork ~sw (fun () ->
    Fun.protect
      (fun () -> loop t)
      ~finally:(fun () -> t.alive <- false)
  )

let nudge t ~reason =
  if t.alive && Eio.Stream.is_empty t.nudge_stream then
    (* Capacity-1 mailbox: buffer one nudge. If already pending, coalesce
       (skip the new one — the loop will fire a Nudge beat soon anyway).
       The is_empty guard avoids blocking on a full stream. *)
    Eio.Stream.add t.nudge_stream reason

let shutdown t =
  if not (is_shutdown t) then
    Eio.Promise.resolve t.shutdown_r ()

let stats t =
  let uptime = (now t.clock) -. t.start_ts in
  let avg =
    if t.seq > 0 then uptime /. (Float.of_int t.seq)
    else 0.0
  in
  {
    total_beats  = t.seq;
    total_nudges = t.total_nudges;
    uptime_s     = uptime;
    avg_interval = avg;
  }

let last_beat t = t.last_beat_v
let is_alive t  = t.alive

let add_consumer t consumer =
  t.consumers <- t.consumers @ [consumer]

let remove_consumer t name =
  let before = List.length t.consumers in
  t.consumers <- List.filter (fun (module C : Consumer) -> C.name <> name) t.consumers;
  List.length t.consumers < before
