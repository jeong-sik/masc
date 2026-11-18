(** The engine screen's time graphs, drawn from [/health] samples. *)

module Braille = Masc_tui_braille
module Decode = Masc.Tui_decode

type point =
  { live_heap : Braille.sample
  ; scheduler_p95 : Braille.sample
  }

type reading =
  | Answered of point
  | Failed of string

(* A time with no sample, or whose read failed: a blank in both graphs. *)
let blank = { live_heap = Braille.Absent; scheduler_p95 = Braille.Absent }

let point_of_identity (identity : Decode.server_identity) =
  { live_heap =
      (match identity.sid_gc with
       | Some gc -> Braille.of_count gc.sgc_live_words
       | None -> Braille.Absent)
  ; scheduler_p95 =
      (* A window with no latency sample reports a p95 of nothing measured,
         not a measured zero. *)
      (match identity.sid_scheduler with
       | Some scheduler when scheduler.ssch_samples > 0 ->
         Braille.of_milliseconds scheduler.ssch_p95_ms
       | Some _ | None -> Braille.Absent)
  }

let reading_of_identity = function
  | Ok identity -> Answered (point_of_identity identity)
  | Error detail -> Failed detail

let reading_of_server = function
  | Ok (Decode.Masc_server identity) -> Answered (point_of_identity identity)
  | Ok (Decode.Account_server _) -> Answered blank
  | Error detail -> Failed detail

let point_of_reading = function
  | Answered point -> point
  | Failed _ -> blank

type answer =
  { at : float
  ; reading : reading
  }

module Ring = struct
  (* Newest first, never longer than [capacity]. *)
  type 'a t =
    { capacity : int
    ; newest_first : 'a list
    }

  let keep capacity items = List.filteri (fun index _ -> index < capacity) items

  let empty ~capacity = { capacity = Stdlib.max 0 capacity; newest_first = [] }

  let push item ring = { ring with newest_first = keep ring.capacity (item :: ring.newest_first) }

  let resize ~capacity ring =
    let capacity = Stdlib.max 0 capacity in
    { capacity; newest_first = keep capacity ring.newest_first }

  let capacity ring = ring.capacity
  let to_list ring = List.rev ring.newest_first
end

let interval_s = 2.0

(* What the sampler's own reads in this view last said, so a failure is said
   once when the reads start failing rather than every two seconds. *)
type own_answer =
  | Own_unanswered
  | Own_answered
  | Own_failed

(* The samples of one opening of the view. Sample [k] is due at
   [origin + k * interval_s]. *)
type session =
  { origin : float
  ; next_slot : int
  ; ring : point Ring.t
  ; waiting : bool
        (** The due sample found no answer to take and waits for the next
            one. *)
  ; seen_until : float
        (** Answers that arrived at or before this were taken, or were
            passed over by a due sample. Neither is taken again. *)
  ; own : own_answer
  }

type t =
  { session : session option
  ; read_out : bool  (** The sampler's own read is out. *)
  }

let stopped = { session = None; read_out = false }

let open_session ~now ~capacity =
  { origin = now
  ; next_slot = 0
  ; ring = Ring.empty ~capacity
  ; waiting = false
  ; seen_until = Float.neg_infinity
  ; own = Own_unanswered
  }

let shown t ~now ~capacity =
  match t.session with
  | None -> { t with session = Some (open_session ~now ~capacity) }
  | Some session when Ring.capacity session.ring = Stdlib.max 0 capacity -> t
  | Some session ->
    { t with session = Some { session with ring = Ring.resize ~capacity session.ring } }

let hidden t =
  match t.session with
  | None -> t
  | Some _ -> { t with session = None }

let slot_time session slot = session.origin +. (Float.of_int slot *. interval_s)

(* The newest sample due at [now]. *)
let current_slot session ~now =
  if now <= session.origin then 0
  else Float.to_int (Float.floor ((now -. session.origin) /. interval_s))

(* [point] fills sample [slot]; the samples between the last one taken and
   it passed with nothing taken, and are blank. A gap longer than the ring
   leaves only blanks, so no more of them are pushed than it holds. *)
let take session ~slot ~seen_until point =
  let missed = Stdlib.min (Stdlib.max 0 (slot - session.next_slot)) (Ring.capacity session.ring) in
  let rec blanks count ring = if count <= 0 then ring else blanks (count - 1) (Ring.push blank ring) in
  { session with
    ring = Ring.push point (blanks missed session.ring)
  ; next_slot = Stdlib.max session.next_slot slot + 1
  ; waiting = false
  ; seen_until
  }

type step =
  | Nothing
  | Sampled
  | Read

let tick t ~now ~newest =
  match t.session with
  | None -> (t, Nothing)
  | Some session ->
    let fresh =
      match newest with
      | Some answer when answer.at > session.seen_until -> Some answer
      | Some _ | None -> None
    in
    let taken answer ~slot =
      ( { t with
          session =
            Some (take session ~slot ~seen_until:answer.at (point_of_reading answer.reading))
        }
      , Sampled )
    in
    if session.waiting then
      match fresh with
      | Some answer -> taken answer ~slot:(Stdlib.max session.next_slot (current_slot session ~now))
      | None -> (t, Nothing)
    else if now < slot_time session session.next_slot then (t, Nothing)
    else
      let slot = current_slot session ~now in
      match fresh with
      | Some answer when answer.at > slot_time session slot -. interval_s -> taken answer ~slot
      | Some _ | None ->
        (* Every answer up to now was considered for this sample and is too
           old; the read this asks for, or one already out, answers it. *)
        let session = { session with waiting = true; seen_until = now } in
        if t.read_out then ({ t with session = Some session }, Nothing)
        else ({ session = Some session; read_out = true }, Read)

type report =
  | Quiet
  | Failure_began of string

let answered t ~now reading =
  let t = { t with read_out = false } in
  match t.session with
  | None -> (t, Nothing, Quiet)
  | Some session ->
    let report =
      match reading, session.own with
      | Failed detail, (Own_unanswered | Own_answered) -> Failure_began detail
      | Failed _, Own_failed | Answered _, (Own_unanswered | Own_answered | Own_failed) -> Quiet
    in
    let own =
      match reading with
      | Answered _ -> Own_answered
      | Failed _ -> Own_failed
    in
    if session.waiting then
      let slot = Stdlib.max session.next_slot (current_slot session ~now) in
      let session = take session ~slot ~seen_until:now (point_of_reading reading) in
      ({ t with session = Some { session with own } }, Sampled, report)
    else ({ t with session = Some { session with own } }, Nothing, report)

type series =
  | Live_heap
  | Scheduler_p95

let pick series point =
  match series with
  | Live_heap -> point.live_heap
  | Scheduler_p95 -> point.scheduler_p95

let samples series t =
  match t.session with
  | None -> []
  | Some session -> List.map (pick series) (Ring.to_list session.ring)

let graph ~width ~axis series t =
  let samples = samples series t in
  let maximum = Braille.graph_maximum samples in
  Braille.braille_graph ~width ~rows:1 ~axis:(axis maximum) ~maximum samples
