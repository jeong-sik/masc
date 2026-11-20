module Mono = Masc_tui_wake.Mono

let nanoseconds_per_second = 1e9
let seconds_per_day = 86_400.0
let display_bar_s = 1.0
let display_bar_ns = Int64.of_float (display_bar_s *. nanoseconds_per_second)
let length_cells = 3
let width_cells = 1 + 1 + length_cells

(* The longest length the slot's three cells hold: [99d]. A read does not run
   for 100 days; the width is what the slot keeps. *)
let longest_length_s = 99.0 *. seconds_per_day

type id = int

type outcome =
  | Succeeded
  | Failed

type 'scope read = { id : id; scope : 'scope; began : Mono.t }

(* What the slot did at the last [step]. [Running]: a read past the bar was
   in flight, the oldest began at [began]. [Waiting]: the last of them
   succeeded at [since] and the slot keeps the length it had, [age_s]. *)
type phase =
  | Quiet
  | Running of { began : Mono.t }
  | Waiting of { since : Mono.t; age_s : float }

type 'scope t =
  { next_id : id
  ; reads : 'scope read list
  ; viewed : 'scope option
  ; phase : phase
  ; failed : bool
      (* A read of [viewed] did not succeed since the last [step]. *)
  }

let empty = { next_id = 0; reads = []; viewed = None; phase = Quiet; failed = false }

let started t ~scope ~now =
  let id = t.next_id in
  ({ t with next_id = id + 1; reads = { id; scope; began = now } :: t.reads }, id)

let finished t id ~outcome =
  match List.find_opt (fun read -> read.id = id) t.reads with
  | None -> t
  | Some read ->
      let failed_here =
        match outcome, t.viewed with
        | Failed, Some viewed -> viewed = read.scope
        | Failed, None | Succeeded, (Some _ | None) -> false
      in
      { t with
        reads = List.filter (fun other -> other.id <> id) t.reads;
        failed = t.failed || failed_here
      }

type length =
  | Growing of { began : Mono.t }
  | Frozen of { age_s : float }

type shown =
  | Hidden
  | Showing of length

let reached ~now at =
  Masc_tui_wake.reached_mono Masc_tui_wake.Reading_slot ~now ~at

let oldest_began reads =
  List.fold_left
    (fun oldest read ->
      match oldest with
      | Some began when Mono.compare began read.began <= 0 -> oldest
      | Some _ | None -> Some read.began)
    None reads

(* The slot keeps the length it had for one bar after the last read past the
   bar succeeded. It also stays while a read that started inside that bar is
   in flight: that read is younger than the bar when the wait ends, so it
   ends or passes the bar within one more bar. Without it the slot turns off
   between two slow reads that follow one another, because the second one
   passes the bar one bar after it began, a moment after the wait ended. A
   read that started after the wait ended is not waited for, or a screen that
   reads fast and often would never turn the slot off. *)
let waiting ~since ~age_s ~young ~now =
  let wait_ends = Mono.after since display_bar_s in
  let waited = reached ~now wait_ends in
  let started_in_wait read = Mono.compare read.began wait_ends < 0 in
  if (not waited) || List.exists started_in_wait young then
    (Waiting { since; age_s }, Showing (Frozen { age_s }))
  else (Quiet, Hidden)

let step t ~scope ~now =
  let t =
    match t.viewed with
    | Some viewed when viewed = scope -> t
    | Some _ | None -> { t with viewed = Some scope; phase = Quiet; failed = false }
  in
  let mine = List.filter (fun read -> read.scope = scope) t.reads in
  (* Asked of every read, so that each one inside the bar notes when it
     passes it. *)
  let past_bar read = reached ~now (Mono.after read.began display_bar_s) in
  let slow, young = List.partition past_bar mine in
  let phase, shown =
    match oldest_began slow, t.phase with
    | Some began, (Quiet | Running _ | Waiting _) ->
        (Running { began }, Showing (Growing { began }))
    | None, Quiet -> (Quiet, Hidden)
    | None, (Running _ | Waiting _) when t.failed -> (Quiet, Hidden)
    | None, Running { began } ->
        waiting ~since:now ~age_s:(Mono.seconds_since now ~since:began) ~young ~now
    | None, Waiting { since; age_s } -> waiting ~since ~age_s ~young ~now
  in
  ({ t with phase; failed = false }, shown)

let length_text ~now ~wall_now = function
  | Frozen { age_s } ->
      Masc_tui_value.Ongoing.Narrow.text (Float.min age_s longest_length_s)
  | Growing { began } ->
      let age_s = Float.min (Mono.seconds_since now ~since:began) longest_length_s in
      Masc_tui_value.Ongoing.Narrow.since ~now:wall_now (wall_now -. age_s)

let text ~now ~wall_now = function
  | Hidden -> String.make width_cells ' '
  | Showing length ->
      let value = length_text ~now ~wall_now length in
      let padding = String.make (max 0 (length_cells - String.length value)) ' ' in
      Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Unread ^ " " ^ padding ^ value
