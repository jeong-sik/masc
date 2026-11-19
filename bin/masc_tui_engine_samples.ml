(** The engine screen's time graphs, drawn from [/health] samples. *)

module Braille = Masc_tui_braille
module Decode = Masc.Tui_decode
module Layout = Masc_tui_message_layout

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

type series =
  | Live_heap
  | Scheduler_p95

let pick series point =
  match series with
  | Live_heap -> point.live_heap
  | Scheduler_p95 -> point.scheduler_p95

(* The top of one graph's axis, held against single samples the way btop
   holds its network graph's (RFC tui-one-screen-grammar 5.6): a run of
   samples moves it, one sample does not, so the axis text and the dots under
   it stay still while the value wanders inside the band. *)
type held =
  { top : int
  ; above : int  (** Samples over [top], less those back under a tenth of it. *)
  ; below : int  (** Samples under a tenth of [top], less those over it. *)
  }

type scale =
  | Unscaled  (** Nothing measured since the view opened. *)
  | Scaled of held

(* btop's rescale: after five samples out of band, the average of the five
   newest samples times 1.3 going up, or times 3 going down. Kept as whole
   fractions so a top is exact, rounded up. *)
type factor =
  { times : int
  ; over : int
  }

let rescale_after = 5
let raise_factor = { times = 13; over = 10 }
let lower_factor = { times = 3; over = 1 }
let band_divisor = 10

(* The lowest top each graph takes, so a heap or a p95 near zero does not
   blow noise up to the full height. Their units are the samples': words of
   heap (8 bytes each) and microseconds. *)
let bytes_per_word = 8
let heap_floor_words = 1024 * 1024 / bytes_per_word
let p95_floor_us = 1_000

let floor_of = function
  | Live_heap -> heap_floor_words
  | Scheduler_p95 -> p95_floor_us

let measured_value = function
  | Braille.Zero -> Some 0
  | Braille.Value value -> Some (value :> int)
  | Braille.Unread | Braille.Absent -> None

(* The average of the newest [rescale_after] measured times of [series] in
   [newest_first], the time just taken among them; blanks are passed over.
   Each time is divided before it is added, the remainders averaged apart, so
   times near the integer range do not wrap the sum: the result is the exact
   floor of the mean. *)
let recent_average series newest_first ~taken =
  let values =
    List.filteri
      (fun index _ -> index < rescale_after)
      (List.filter_map (fun point -> measured_value (pick series point)) newest_first)
  in
  match values with
  | [] -> taken
  | _ :: _ ->
    let count = List.length values in
    List.fold_left (fun sum value -> sum + (value / count)) 0 values
    + (List.fold_left (fun sum value -> sum + (value mod count)) 0 values / count)

let scaled_top series ~factor average =
  let top =
    if average > (max_int - factor.over) / factor.times then max_int
    else ((average * factor.times) + factor.over - 1) / factor.over
  in
  Stdlib.max (floor_of series) top

let rescaled series ~factor newest_first ~taken =
  Scaled { top = scaled_top series ~factor (recent_average series newest_first ~taken)
         ; above = 0
         ; below = 0
         }

(* [scale] after [series] took [sample]; [newest_first] already holds it. *)
let next_scale series newest_first scale sample =
  match measured_value sample with
  | None -> scale
  | Some taken ->
    (match scale with
     | Unscaled -> rescaled series ~factor:raise_factor newest_first ~taken
     | Scaled held ->
       let held =
         if taken > held.top then
           { held with above = held.above + 1; below = Stdlib.max 0 (held.below - 1) }
         else if held.top > floor_of series && taken < held.top / band_divisor then
           { held with below = held.below + 1; above = Stdlib.max 0 (held.above - 1) }
         else held
       in
       if held.above >= rescale_after then
         rescaled series ~factor:raise_factor newest_first ~taken
       else if held.below >= rescale_after then
         rescaled series ~factor:lower_factor newest_first ~taken
       else Scaled held)

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
  ; heap_scale : scale
  ; p95_scale : scale
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
  ; heap_scale = Unscaled
  ; p95_scale = Unscaled
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
  let ring = Ring.push point (blanks missed session.ring) in
  { session with
    ring
  ; heap_scale = next_scale Live_heap ring.Ring.newest_first session.heap_scale point.live_heap
  ; p95_scale =
      next_scale Scheduler_p95 ring.Ring.newest_first session.p95_scale point.scheduler_p95
  ; next_slot = Stdlib.max session.next_slot slot + 1
  ; waiting = false
  ; seen_until
  }

type step =
  | Nothing
  | Sampled
  | Read

let tick ?(allow_read = true) t ~now ~newest =
  match t.session with
  | None -> (t, Nothing)
  | Some session ->
    (* A waiting sample has a read out ([waiting] is set only with
       [read_out]), and {!answered} hands it that read's answer. Taking
       another answer here instead would draw the graphs once for it and
       once more when that answer is applied. *)
    if session.waiting then (t, Nothing)
    else if not (Masc_tui_wake.reached Masc_tui_wake.Engine_sample ~now
                   ~at:(slot_time session session.next_slot)) then (t, Nothing)
    else
      let slot = current_slot session ~now in
      match newest with
      | Some answer
        when answer.at > session.seen_until && answer.at > slot_time session slot -. interval_s ->
        ( { t with
            session =
              Some (take session ~slot ~seen_until:answer.at (point_of_reading answer.reading))
          }
        , Sampled )
      | (Some _ | None) when not allow_read && not t.read_out ->
        ({ t with session = Some (take session ~slot ~seen_until:now blank) }, Sampled)
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

let samples series t =
  match t.session with
  | None -> []
  | Some session -> List.map (pick series) (Ring.to_list session.ring)

(* The newest [count] items, oldest first. *)
let newest count items =
  let held = List.length items in
  List.filteri (fun index _ -> index >= held - count) items

let measured sample = Option.is_some (measured_value sample)

let scale_of series session =
  match series with
  | Live_heap -> session.heap_scale
  | Scheduler_p95 -> session.p95_scale

(* The axis column is as wide as the widest top [axis] writes, whatever this
   top is, so the graph draws the same number of times at every top and the
   ring the loop sizes with {!Braille.graph_times} holds exactly those. The
   top is the held scale, not the largest time drawn, so it moves only after
   a run of samples out of its band. A graph with no time measured among
   those drawn has no top to write, and its column stays blank. *)
let held_top series t =
  match t.session with
  | None -> None
  | Some session ->
    (match scale_of series session with
     | Unscaled -> None
     | Scaled held -> Some held.top)

let graph ~tint ~width ~axis_cells ~axis series t =
  let samples = samples series t in
  let drawn = newest (Braille.graph_times ~width ~axis_cells) samples in
  let held = held_top series t in
  let top =
    match held with
    | Some top when List.exists measured drawn -> axis top
    | Some _ | None -> ""
  in
  (* With no top held, nothing was measured since the view opened, so no time
     draws a dot and the maximum only has to be a number. *)
  let maximum =
    match held with
    | Some top -> top
    | None -> 0
  in
  Braille.braille_graph ~tint ~width ~rows:1
    ~axis:(Layout.fit_width top (Stdlib.max 0 axis_cells))
    ~maximum samples
