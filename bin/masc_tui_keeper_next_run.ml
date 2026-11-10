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

let of_snapshot ~freshness ?runner ~keeper_name (snapshot : Masc_tui_types.schedule_snapshot) : t =
  match snapshot.scs_read_error with
  | Some _ -> Unknown
  | None ->
      let resolved_runner =
        match runner with
        | Some r -> r
        | None -> snapshot.scs_runner_status
      in
      let keeper_rows =
        List.filter
          (fun (r : Masc_tui_types.schedule_row) -> r.sch_payload_keeper_name = Some keeper_name)
          snapshot.scs_rows
      in
      let active_rows = List.filter is_active keeper_rows in
      match active_rows with
      | [] ->
          if snapshot.scs_truncated then
            match List.rev snapshot.scs_rows with
            | last_row :: _ when is_active last_row ->
                (match Masc_tui_types.schedule_row_due_time last_row with
                 | Some due_at -> Not_before due_at
                 | None -> Unknown)
            | _ -> No_schedule
          else
            No_schedule
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

(* RFC-0515 §2.4.4: the wakes ahead of now, counted per half-hour slot. *)

type wake_slot =
  | Wakes of int
  | Wakes_with_unknown of int
  | Wakes_unknown

(* Every pair is written out: a known count never absorbs an unknown that
   shares its slot. [Wakes_with_unknown] keeps both facts so the summary can
   say "N known · partial" even when the overlap happens inside one slot. *)
let add_wake_slot left right =
  match left, right with
  | Wakes l, Wakes r -> Wakes (l + r)
  | Wakes l, Wakes_with_unknown k -> Wakes_with_unknown (l + k)
  | Wakes l, Wakes_unknown -> Wakes_with_unknown l
  | Wakes_with_unknown k, Wakes r -> Wakes_with_unknown (k + r)
  | Wakes_with_unknown a, Wakes_with_unknown b -> Wakes_with_unknown (a + b)
  | Wakes_with_unknown k, Wakes_unknown -> Wakes_with_unknown k
  | Wakes_unknown, Wakes k -> Wakes_with_unknown k
  | Wakes_unknown, Wakes_with_unknown k -> Wakes_with_unknown k
  | Wakes_unknown, Wakes_unknown -> Wakes_unknown
;;

let rec add_wake_strips left right =
  match left, right with
  | [], strip | strip, [] -> strip
  | l :: ls, r :: rs -> add_wake_slot l r :: add_wake_strips ls rs
;;

let sum_wake_strips strips = List.fold_left add_wake_strips [] strips

let slot_seconds = float_of_int Keeper_turn_pulse.slot_seconds

(* The now slot and the slots after it. A time before the now slot is a wake
   that came due and was not yet called late, so it counts in the now slot. *)
type window =
  { first_slot : float
  ; slots : int
  }

let slots_of ~ahead = max 0 (ahead + 1)

let window_of ~now ~ahead =
  { first_slot = float_of_int (Keeper_turn_pulse.slot_start now)
  ; slots = slots_of ~ahead
  }
;;

let slot_index window at =
  if at < window.first_slot then 0
  else int_of_float ((at -. window.first_slot) /. slot_seconds)
;;

(* What one schedule row says about the strip: the wakes it lists, the time
   after which it may wake in ways it cannot list, and its expiry, at or
   after which it never wakes ([Schedule_domain.mark_due] expires a request
   once [expires_at <= now]). *)
type row_wakes =
  { known : float list
  ; unknown_after : float option
  ; stops_at : float option
  }

let unknown_row = { known = []; unknown_after = Some Float.neg_infinity; stops_at = None }

(* What the strip makes of one row of the Keeper. *)
type strip_row =
  | Walked  (* Scheduled or running and not held: its recurrence is walked. *)
  | Closed  (* A terminal status: the row never wakes again. *)
  | Late_or_held
      (* Late ([Due]) or held by the runner. It wakes again when it fires or
         the hold ends, and a recurring row goes on after that
         ([Schedule_domain.reschedule_after_due_signal]); neither time is on
         the row. *)
  | Status_unreadable  (* A status word this build does not know. *)

let strip_row (row : Masc_tui_types.schedule_row) =
  match Schedule_domain.schedule_status_of_string row.sch_status with
  | Error _ -> Status_unreadable
  | Ok (Succeeded | Failed | Cancelled | Expired) -> Closed
  | Ok Due -> Late_or_held
  | Ok (Scheduled | Running) ->
      (match row.sch_runner_hold with
       | Some _ -> Late_or_held
       | None -> Walked)
;;

let row_expiry (row : Masc_tui_types.schedule_row) =
  match row.sch_expires_at_iso with
  | None -> Ok None
  | Some iso -> Result.map Option.some (Time_codec.parse_rfc3339 iso)
;;

(* A row that wakes at times it does not say is unknown up to its expiry. *)
let unknown_until_expiry row =
  match row_expiry row with
  | Ok stops_at -> { unknown_row with stops_at }
  | Error _ -> unknown_row
;;

(* The request's own next due. The server sends it as [next_due_at_iso]
   while the request is Scheduled or Due, and as [due_at_iso] in every status
   (Server_dashboard_schedule_projection [schedule_request_dashboard_json]).
   The strip walks the recurrence from it, not from the delivered occurrence
   that [Masc_tui_types.schedule_row_due_time] shows while that one is still
   unsettled: the runner steps from the request. *)
let request_due_time (row : Masc_tui_types.schedule_row) =
  let at =
    match row.sch_next_due_at_iso with
    | Some _ as at -> at
    | None -> row.sch_due_at_iso
  in
  Option.bind at Time_codec.parse_rfc3339_opt
;;

let row_wakes window (row : Masc_tui_types.schedule_row) =
  match request_due_time row, row_expiry row with
  | None, (Ok _ | Error _) | Some _, Error _ -> unknown_row
  | Some first, Ok stops_at ->
      let on_strip at =
        (match stops_at with
         | None -> true
         | Some stop -> at < stop)
        && slot_index window at < window.slots
      in
      let first_known = if on_strip first then [ first ] else [] in
      (* Every occurrence inside the now slot counts there, before or after
         now, so a strip depends on its window and not on the second it was
         read in. A [first] before the now slot is a missed due the runner
         fires once, so the walk skips to the slot start instead of counting
         the occurrences in between: [Float.pred] keeps an occurrence that
         falls on the slot start. A step that does not move forward leaves
         the rest unknown. *)
      let repeat step =
        let rec walk cursor known =
          match step cursor with
          | Some next when next > cursor ->
              if on_strip next then walk next (next :: known)
              else { known; unknown_after = None; stops_at }
          | Some _ | None -> { known; unknown_after = Some cursor; stops_at }
        in
        walk (Float.max first (Float.pred window.first_slot)) first_known
      in
      (match row.sch_recurrence with
       | Error _ -> { known = first_known; unknown_after = Some first; stops_at }
       | Ok Schedule_domain.One_shot ->
           { known = first_known; unknown_after = None; stops_at }
       | Ok (Schedule_domain.Interval { interval_sec }) ->
           (* The runner's own step ([Schedule_domain.next_due_after]), so the
              occurrences stay on [first + k * period]. *)
           let period = float_of_int interval_sec in
           repeat (fun cursor ->
             Schedule_domain.next_periodic_due_after ~period ~now:cursor ~anchor:first)
       | Ok ((Schedule_domain.Daily _ | Schedule_domain.Cron _) as recurrence) ->
           repeat (fun cursor -> Schedule_domain.first_due_after ~now:cursor recurrence))
;;

let strip_of_row_wakes window { known; unknown_after; stops_at } =
  List.init window.slots (fun index ->
    let start = window.first_slot +. (float_of_int index *. slot_seconds) in
    let stop = start +. slot_seconds in
    let count =
      List.fold_left
        (fun count at -> if slot_index window at = index then count + 1 else count)
        0 known
    in
    match unknown_after with
    | None -> Wakes count
    | Some after ->
        let until = Option.value stops_at ~default:Float.infinity in
        if Float.max after start < Float.min stop until
        then add_wake_slot (Wakes count) Wakes_unknown
        else Wakes count)
;;

(* The agenda is the first page of the fleet list. The server sorts it active
   first, then by [due_at], then by id, and cuts it at its limit
   (Server_dashboard_schedule_projection [compare_schedule_order] and
   [scheduled_automation_dashboard_page_json]). So a cut page whose last row
   is active left out only rows due at or after that row's [due_at_iso], and
   one whose last row is closed left out no active row. *)
let truncation_wakes (snapshot : Masc_tui_types.schedule_snapshot) =
  if not snapshot.scs_truncated then None
  else
    match List.rev snapshot.scs_rows with
    | [] -> Some unknown_row
    | last :: _ ->
        if not (is_active last) then None
        else
          (match Option.map Time_codec.parse_rfc3339 last.sch_due_at_iso with
           | Some (Ok due_at) ->
               Some { known = []; unknown_after = Some due_at; stops_at = None }
           | Some (Error _) | None -> Some unknown_row)
;;

let wake_strip_of_snapshot window ~keeper_name
    (snapshot : Masc_tui_types.schedule_snapshot) =
  match snapshot.scs_read_error with
  | Some _ -> strip_of_row_wakes window unknown_row
  | None ->
      let row_reading (row : Masc_tui_types.schedule_row) =
        match strip_row row with
        | Walked -> Some (row_wakes window row)
        | Closed -> None
        | Late_or_held | Status_unreadable -> Some (unknown_until_expiry row)
      in
      let readings =
        List.filter_map row_reading
          (List.filter
             (fun (row : Masc_tui_types.schedule_row) ->
                row.sch_payload_keeper_name = Some keeper_name)
             snapshot.scs_rows)
        @ Option.to_list (truncation_wakes snapshot)
      in
      sum_wake_strips
        (List.init window.slots (fun _ -> Wakes 0)
         :: List.map (strip_of_row_wakes window) readings)
;;

type index =
  { ind_freshness : Masc_tui_agenda.schedule_freshness
  ; ind_runner : Tui_decode.schedule_runner_status option
  ; ind_snapshot : Masc_tui_types.schedule_snapshot option
  ; ind_table : (string, t) Hashtbl.t
  ; ind_strips : (string * int, wake_slot list) Hashtbl.t
      (* Strips of the now slot in [ind_strips_slot], by Keeper and [ahead].
         The index is rebuilt when the agenda changes, so a strip is walked
         once per agenda and half hour, not once per frame. *)
  ; mutable ind_strips_slot : float option
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
  ; ind_strips_slot = None
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

let unknown_strip ~ahead = List.init (slots_of ~ahead) (fun _ -> Wakes_unknown)

let wake_strip index ~now ~ahead ~keeper_name =
  let window = window_of ~now ~ahead in
  (match index.ind_strips_slot with
   | Some slot when Float.equal slot window.first_slot -> ()
   | Some _ | None ->
       Hashtbl.reset index.ind_strips;
       index.ind_strips_slot <- Some window.first_slot);
  match Hashtbl.find_opt index.ind_strips (keeper_name, ahead) with
  | Some strip -> strip
  | None ->
      let strip =
        match index.ind_snapshot with
        | None -> strip_of_row_wakes window unknown_row
        | Some snapshot -> wake_strip_of_snapshot window ~keeper_name snapshot
      in
      Hashtbl.replace index.ind_strips (keeper_name, ahead) strip;
      strip
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
