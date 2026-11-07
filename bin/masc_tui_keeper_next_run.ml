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
                 | _ -> 2)
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

type index =
  { ind_freshness : Masc_tui_agenda.schedule_freshness
  ; ind_runner : Tui_decode.schedule_runner_status option
  ; ind_snapshot : Masc_tui_types.schedule_snapshot option
  ; ind_table : (string, t) Hashtbl.t
  }

let index_of_agenda ~freshness ?runner snapshot_opt =
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
