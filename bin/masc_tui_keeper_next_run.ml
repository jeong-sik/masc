open Masc

type t =
  | No_schedule
  | Scheduled_at of float
  | Late_since of float
  | Held_current of float
  | Held_as_of of float
  | Not_before of float
  | Unknown

let is_active (row : Masc_tui_types.schedule_row) =
  match Schedule_domain.schedule_status_of_string row.sch_status with
  | Ok (Scheduled | Due | Running) -> true
  | Ok (Succeeded | Failed | Cancelled | Expired) -> false
  | Error _ -> true
;;

let freshness_wire = function
  | Masc_tui_agenda.Last_read -> Tui_decode.List_latest
  | Masc_tui_agenda.Refresh_needed -> Tui_decode.List_kept
;;

let reduce_active_row ~freshness ~runner (row : Masc_tui_types.schedule_row) =
  match row.sch_runner_hold with
  | Some hold ->
      (match Tui_decode.schedule_hold_reading ~freshness:(freshness_wire freshness) ~runner hold with
       | Hold_current -> Held_current hold.srh_observed_at
       | Hold_as_of at -> Held_as_of at)
  | None ->
      (match Schedule_domain.schedule_status_of_string row.sch_status with
       | Ok Due ->
           (match Masc_tui_types.schedule_row_due_time row with
            | Some due_at -> Late_since due_at
            | None -> Unknown)
       | Ok (Scheduled | Running) | Error _ ->
           (match Masc_tui_types.schedule_row_due_time row with
            | Some due_at -> Scheduled_at due_at
            | None -> Unknown)
       | Ok (Succeeded | Failed | Cancelled | Expired) ->
           No_schedule)
;;

(* What a cut page leaves out. The server sends active rows first, earliest
   due first, so the rows past the page include an active one only when the
   page's last row is active, and then each of them is due no earlier than
   that row. Its due time here is the one {!Masc_tui_types.schedule_row_due_time}
   reads, never later than the stored due the server sorts by. *)
type sight =
  | Whole_agenda
  | Unseen_from of float
  | Unseen_from_unread
      (** The page is cut after an active row whose due time did not read. *)

let sight_of_snapshot (snapshot : Masc_tui_types.schedule_snapshot) =
  if not snapshot.scs_truncated then Whole_agenda
  else
    match List.rev snapshot.scs_rows with
    | last_row :: _ when is_active last_row ->
        (match Masc_tui_types.schedule_row_due_time last_row with
         | Some due_at -> Unseen_from due_at
         | None -> Unseen_from_unread)
    | _ :: _ | [] -> Whole_agenda
;;

let keeper_active_rows ~keeper_name (snapshot : Masc_tui_types.schedule_snapshot) =
  List.filter
    (fun (r : Masc_tui_types.schedule_row) ->
      r.sch_payload_keeper_name = Some keeper_name && is_active r)
    snapshot.scs_rows
;;

let of_snapshot ~freshness ?runner ~keeper_name (snapshot : Masc_tui_types.schedule_snapshot) : t =
  match snapshot.scs_read_error with
  | Some _ -> Unknown
  | None ->
      let resolved_runner =
        match runner with
        | Some r -> r
        | None -> snapshot.scs_runner_status
      in
      let active_rows = keeper_active_rows ~keeper_name snapshot in
      match active_rows with
      | [] ->
          (match sight_of_snapshot snapshot with
           | Whole_agenda -> No_schedule
           | Unseen_from due_at -> Not_before due_at
           | Unseen_from_unread -> Unknown)
      | first_active :: other_active ->
          let due_order (r1 : Masc_tui_types.schedule_row) (r2 : Masc_tui_types.schedule_row) =
            match Masc_tui_types.schedule_row_due_time r1, Masc_tui_types.schedule_row_due_time r2 with
            | Some d1, Some d2 -> Float.compare d1 d2
            | Some _, None -> -1
            | None, Some _ -> 1
            | None, None -> 0
          in
          let priority_val (r : Masc_tui_types.schedule_row) =
            match r.sch_runner_hold with
            | Some _ -> 0
            | None ->
                (match Schedule_domain.schedule_status_of_string r.sch_status with
                 | Ok Due -> 1
                 | Ok (Scheduled | Running | Succeeded | Failed | Cancelled | Expired) | Error _ -> 2)
          in
          let compare_priority r1 r2 =
            let p1 = priority_val r1 in
            let p2 = priority_val r2 in
            if p1 <> p2 then Int.compare p1 p2
            else due_order r1 r2
          in
          let sorted = List.sort compare_priority (first_active :: other_active) in
          (match sorted with
           | target :: _ -> reduce_active_row ~freshness ~runner:resolved_runner target
           | [] -> No_schedule)
;;

(* {1 The strip ahead} (RFC-0515 V7) *)

type hour =
  | Hour_quiet
  | Hour_wakes of int
  | Hour_wakes_at_least of int
  | Hour_unknown

module Mark = Masc_tui_keeper_mark

let seconds_per_hour = Float.of_int Masc_tui_keeper_pulse.seconds_per_hour

(* The start of the hour that holds [now]: the pulse's newest hour, which is
   the strip's first. [None] for a [now] that is not a clock reading. *)
let strip_start now =
  if Float.is_finite now then
    Some (Float.of_int (Masc_tui_keeper_pulse.hour_start (Float.to_int (Float.floor now))))
  else None
;;

(* When one schedule row wakes its keeper. [Wakes_every] is counted by
   arithmetic, so a short interval is not spelled out wake by wake. *)
type wakes =
  | Wakes_at of float list
  | Wakes_every of { first : float; period : float }

(* One row's wakes over the strip. [expires]: nothing wakes at or after it.
   [unseen_from]: the row cannot say what wakes at or after it, up to
   [expires]. *)
type row_wakes =
  { wakes : wakes
  ; expires : float option
  ; unseen_from : float option
  }

type strip =
  | Strip_none
  | Strip_unread
  | Strip_rows of { start : float; rows : row_wakes list }

let unseen_everywhere = Some Float.neg_infinity
let all_unknown = List.init Mark.pulse_hours (fun _ -> Hour_unknown)

(* Daily and cron wakes from [after] up to [limit], each found by the store's
   own calendar function. It returns a time strictly after the one it is
   given; a time that is not later ends the walk, and the rest of the strip is
   unseen rather than quiet. *)
let calendar_wakes recurrence ~after ~limit =
  let rec walk previous found =
    if previous >= limit then List.rev found, None
    else
      match Schedule_domain.first_due_after ~now:previous recurrence with
      | None -> List.rev found, Some previous
      | Some next when next <= previous -> List.rev found, Some previous
      | Some next when next >= limit -> List.rev found, None
      | Some next -> walk next (next :: found)
  in
  walk after []
;;

let row_wakes ~start ~limit (row : Masc_tui_types.schedule_row) =
  let expires_read =
    match row.sch_expires_at_iso with
    | None -> Ok None
    | Some iso ->
        (match Time_codec.parse_rfc3339_opt iso with
         | Some at -> Ok (Some at)
         | None -> Error ())
  in
  match expires_read, Masc_tui_types.schedule_row_due_time row with
  | Error (), _ ->
      { wakes = Wakes_at []; expires = None; unseen_from = unseen_everywhere }
  | Ok expires, None -> { wakes = Wakes_at []; expires; unseen_from = unseen_everywhere }
  | Ok expires, Some first ->
      let limit = Option.fold ~none:limit ~some:(Float.min limit) expires in
      (match row.sch_recurrence with
       | Error _ -> { wakes = Wakes_at [ first ]; expires; unseen_from = Some first }
       | Ok Schedule_domain.One_shot -> { wakes = Wakes_at [ first ]; expires; unseen_from = None }
       | Ok (Schedule_domain.Interval { interval_sec }) ->
           { wakes = Wakes_every { first; period = Float.of_int interval_sec }
           ; expires
           ; unseen_from = None
           }
       | Ok ((Schedule_domain.Daily _ | Schedule_domain.Cron _) as recurrence) ->
           (* A wake before the strip does not matter, so a first due long
              past is not walked forward one slot at a time: the walk starts
              at the strip, and [Float.pred] keeps a slot that falls exactly
              on its start. *)
           let later, unseen_from =
             if first >= start then calendar_wakes recurrence ~after:first ~limit
             else calendar_wakes recurrence ~after:(Float.pred start) ~limit
           in
           let first_in_strip = if first >= start && first < limit then [ first ] else [] in
           { wakes = Wakes_at (first_in_strip @ later); expires; unseen_from })
;;

let strip_of_snapshot ~start ~keeper_name = function
  | None -> Strip_unread
  | Some (snapshot : Masc_tui_types.schedule_snapshot) ->
      (match snapshot.scs_read_error with
       | Some _ -> Strip_unread
       | None ->
           let limit = start +. (Float.of_int Mark.pulse_hours *. seconds_per_hour) in
           let active = keeper_active_rows ~keeper_name snapshot in
           (* A held run is not drawn: the next cell already says it is held,
              and when it runs is the runner's call. *)
           let rows =
             active
             |> List.filter (fun (r : Masc_tui_types.schedule_row) -> Option.is_none r.sch_runner_hold)
             |> List.map (row_wakes ~start ~limit)
           in
           (* The same rule as {!of_snapshot}: no active row and nothing cut
              off is a keeper with no schedule. *)
           let cut_off unseen_from = { wakes = Wakes_at []; expires = None; unseen_from } in
           (match active, sight_of_snapshot snapshot with
            | [], Whole_agenda -> Strip_none
            | _ :: _, Whole_agenda -> Strip_rows { start; rows }
            | _, Unseen_from at -> Strip_rows { start; rows = cut_off (Some at) :: rows }
            | _, Unseen_from_unread -> Strip_rows { start; rows = cut_off unseen_everywhere :: rows }))
;;

(* How many of the row's wakes fall in [[low, high)]. *)
let count_wakes ~low ~high { wakes; expires; unseen_from = _ } =
  let high = Option.fold ~none:high ~some:(Float.min high) expires in
  if high <= low then 0
  else
    match wakes with
    | Wakes_at times -> List.length (List.filter (fun at -> at >= low && at < high) times)
    | Wakes_every { first; period } ->
        let index_from at = Float.to_int (Float.ceil ((at -. first) /. period)) in
        max 0 (index_from high - max 0 (index_from low))
;;

let unseen_in ~low ~high { wakes = _; expires; unseen_from } =
  match unseen_from with
  | None -> false
  | Some from ->
      let high = Option.fold ~none:high ~some:(Float.min high) expires in
      Float.max from low < high
;;

let hours_of_strip ~now = function
  | Strip_none -> None
  | Strip_unread -> Some all_unknown
  | Strip_rows { start; rows } ->
      Some
        (List.init Mark.pulse_hours (fun position ->
             let opens = start +. (Float.of_int position *. seconds_per_hour) in
             let high = opens +. seconds_per_hour in
             let low = Float.max opens now in
             let count = List.fold_left (fun total row -> total + count_wakes ~low ~high row) 0 rows in
             let seen = not (List.exists (unseen_in ~low ~high) rows) in
             match count, seen with
             | 0, true -> Hour_quiet
             | 0, false -> Hour_unknown
             | n, true -> Hour_wakes n
             | n, false -> Hour_wakes_at_least n))
;;

let hours_of_snapshot ~now ~keeper_name snapshot =
  match strip_start now with
  | None -> Some all_unknown
  | Some start -> hours_of_strip ~now (strip_of_snapshot ~start ~keeper_name snapshot)
;;

type index =
  { ind_freshness : Masc_tui_agenda.schedule_freshness
  ; ind_runner : Tui_decode.schedule_runner_status option
  ; ind_snapshot : Masc_tui_types.schedule_snapshot option
  ; ind_table : (string, t) Hashtbl.t
  ; ind_strips : (string, strip) Hashtbl.t
        (** Each keeper's wakes over the strip that starts at [ind_strip_start],
            so a cron is walked once an hour, not once a frame. *)
  ; mutable ind_strip_start : float option
  }

let index_of_agenda ~freshness ?runner (snapshot_opt : Masc_tui_types.schedule_snapshot option) =
  let table = Hashtbl.create 16 in
  (match snapshot_opt with
   | Some snapshot when Option.is_none snapshot.scs_read_error ->
       List.iter
         (fun (row : Masc_tui_types.schedule_row) ->
            match row.sch_payload_keeper_name with
            | Some name when not (Hashtbl.mem table name) ->
                let t = of_snapshot ~freshness ?runner ~keeper_name:name snapshot in
                Hashtbl.add table name t
            | _ -> ())
         snapshot.scs_rows
   | _ -> ());
  { ind_freshness = freshness
  ; ind_runner = runner
  ; ind_snapshot = snapshot_opt
  ; ind_table = table
  ; ind_strips = Hashtbl.create 16
  ; ind_strip_start = None
  }
;;

let find index ~keeper_name =
  match Hashtbl.find_opt index.ind_table keeper_name with
  | Some t -> t
  | None ->
      (match index.ind_snapshot with
       | None -> Unknown
       | Some snapshot ->
           let t =
             of_snapshot
               ~freshness:index.ind_freshness
               ?runner:index.ind_runner
               ~keeper_name
               snapshot
           in
           Hashtbl.add index.ind_table keeper_name t;
           t)
;;

let find_hours index ~now ~keeper_name =
  match strip_start now with
  | None -> Some all_unknown
  | Some start ->
      if index.ind_strip_start <> Some start then begin
        Hashtbl.reset index.ind_strips;
        index.ind_strip_start <- Some start
      end;
      let strip =
        match Hashtbl.find_opt index.ind_strips keeper_name with
        | Some strip -> strip
        | None ->
            let strip = strip_of_snapshot ~start ~keeper_name index.ind_snapshot in
            Hashtbl.add index.ind_strips keeper_name strip;
            strip
      in
      hours_of_strip ~now strip
;;

let hour_mark = function
  | Hour_quiet -> Mark.schedule_strip_quiet_mark
  | Hour_wakes _ | Hour_wakes_at_least _ -> Mark.schedule_strip_wake_mark
  | Hour_unknown -> Mark.unknown_mark
;;

let hours_cell hours =
  { Masc_tui_keeper_axis_cell.text = String.concat "" (List.map hour_mark hours)
  ; tone = Masc_tui_keeper_axis_cell.Quiet
  }
;;

let cell ~now = function
  | No_schedule -> None
  | Scheduled_at at ->
      let text =
        if at >= now then
          Printf.sprintf "◷ %s" (Masc_tui_message_layout.span_text (at -. now))
        else
          "◷ 곧"
      in
      Some { Masc_tui_keeper_axis_cell.text; tone = Quiet }
  | Late_since at ->
      let text =
        if now > at then
          Printf.sprintf "◷ 늦음 +%s" (Masc_tui_message_layout.span_text (now -. at))
        else
          "◷ 늦음"
      in
      Some { Masc_tui_keeper_axis_cell.text; tone = Attention }
  | Held_current _ ->
      Some { Masc_tui_keeper_axis_cell.text = "◷ 보류"; tone = Attention }
  | Held_as_of at ->
      let text =
        if now > at then
          Printf.sprintf "◷ 보류 (%s 전)" (Masc_tui_message_layout.span_text (now -. at))
        else
          "◷ 보류 (확인 전)"
      in
      Some { Masc_tui_keeper_axis_cell.text; tone = Quiet }
  | Not_before at ->
      let text =
        if at >= now then
          Printf.sprintf "◷ >%s" (Masc_tui_message_layout.span_text (at -. now))
        else
          "◷ 확인 중"
      in
      Some { Masc_tui_keeper_axis_cell.text; tone = Quiet }
  | Unknown ->
      Some { Masc_tui_keeper_axis_cell.text = "◷ ?"; tone = Quiet }
;;
