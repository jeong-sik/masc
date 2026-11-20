(** The Answering overlay: who is mid-turn right now, in one keypress.

    The footer badge compresses the same fact to "◌ answering echo +2";
    this overlay is the "+2" unfolded — every running keeper with its lane
    and how long the turn has been going, the pane's last chat target first,
    because that is the answer the operator who pressed the key is waiting
    on. Keepers that just finished stay listed for a while (see
    {!finish_glow_ttl_seconds}): "it is done" is the other half of the
    question the operator walked away holding. Pure projection over the
    polled rows so the shape is testable without a terminal. *)

open Masc

type tone =
  | Heading
  | Running
  | Done
  | Unknown
  | Quiet

type line =
  { text : string
  ; tone : tone
  ; target : string option
        (** The keeper this row names, when Enter can open its chat:
            running and just-finished rows carry it, prose rows do not. *)
  }

(* How long a finished turn keeps its ✓ row (and its footer glow) before the
   fact goes quiet. Long enough to survive a glance away, short enough that
   the overlay stays "right now", not a log. *)
let finish_glow_ttl_seconds = 60.

(* The mark a running turn wears. It does not move (RFC tui-one-screen-grammar
   §7.2): the growing length beside it is what says the turn is still going,
   and a screen with no new data redraws only when that length changes (§8).
   The mark comes from the state dictionary, so a running turn reads the same
   as any other work under way. *)
let running_mark = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way

(* The turn's lane in the screen's words. The server spells the chat lane
   [chat_operation]; the screen calls it a chat. *)
let lane_word ~ko = function
  | Tui_decode.Turn_lane_autonomous -> if ko then "자율" else "autonomous"
  | Tui_decode.Turn_lane_chat_operation -> if ko then "채팅" else "chat"
  | Tui_decode.Turn_lane_maintenance -> if ko then "정비" else "maintenance"
;;

(* One row of the chat pane's status band. [lead] is what the eye lands on
   -- the mark, the lane, the age -- and the renderer paints it in the
   status colour; [rest] is the detail after it, receded. The band used to
   be drawn in the status colour whole, five rows of it, and a screen where
   every word is the colour of a warning has no warning on it. *)
type chat_activity_row =
  { lead : string
  ; rest : string
  ; keys : string
        (** What a key does about this row -- " · Esc stops it · /queue" on
            the row of a turn Esc can stop, empty elsewhere. Apart from
            [rest] because [rest] carries the preview's status, whose length
            is the server's: appended after it, the keys were the cells a
            100-column pane cut first. The renderer fits [rest] to what the
            lead and the keys leave. *)
  }

let chat_activity_row_text row = row.lead ^ row.rest ^ row.keys

(* Why the turn rows are not current: the read failed, or the workspace guard
   stopped the read before it left, which the caller has worded as a
   kept-back notice and which is drawn as it is (RFC §2). *)
type read_error = Read_failed of string | Read_kept_back of string

(* The same running turn must remain visible while a submitted chat waits
   behind it. No ETA can be inferred from the turn's elapsed age.

   Reply text belongs to the scrollable conversation; this band carries only
   activity and the keys that act on it. *)
let chat_activity ?(stop_keys = "") ?(show_timing = true)
    ~ko ~now ~keeper_name ~error rows =
  let say korean english = if ko then korean else english in
  let plain text = { lead = text; rest = ""; keys = "" } in
  let stale = match error with
    | None -> []
    | Some (Read_failed detail) -> [plain (say "활동 조회 실패: " "Activity unavailable: " ^ detail)]
    | Some (Read_kept_back notice) -> [plain notice] in
  match List.find_opt (fun (row : Tui_decode.keeper_turn_row) ->
    String.equal row.ktr_keeper_name keeper_name) rows with
  | None -> stale
  | Some { ktr_state = Tui_decode.Keeper_turn_idle; _ } -> stale
  | Some { ktr_state = Tui_decode.Keeper_turn_unavailable detail; _ } ->
    stale @ [plain (say "현재 턴 조회 실패: " "Current turn unavailable: " ^ detail)]
  | Some { ktr_state = Tui_decode.Keeper_turn_running { lane; started_at_unix; preview }; _ } ->
    let status = match preview with
      | None -> say "진행 보고 없음" "progress has not been reported"
      | Some preview when not show_timing -> preview.Tui_decode.ktp_status_text
      | Some preview ->
        Printf.sprintf (if ko then "%s · 마지막 활동 %s 전" else "%s · last activity %s ago")
          preview.Tui_decode.ktp_status_text
          (Masc_tui_value.Ongoing.since ~now preview.ktp_updated_at_unix)
    in
    (* "Current chat_operation turn · 14m43s · …" went: the mark says a turn
       is running, and the lane and the age are the facts; "current" and
       "turn" were the sentence around them. A stale reading keeps its word,
       because a number from a read that is failing is a different fact. The
       mark is the same either way: the word, not the mark, says the reading
       is an earlier one (RFC §6.4 keeps [◌] for a value not read yet). *)
    let observed =
      match error with
      | None -> ""
      | Some _ -> say "이전 관측 " "last observed "
    in
    stale
    @ [ { lead = Printf.sprintf "%s %s%s%s" running_mark observed (lane_word ~ko lane)
                   (if show_timing then " · " ^ Masc_tui_value.Ongoing.since ~now started_at_unix else "")
        ; rest = " · " ^ Masc.Tui_terminal_text.sanitize_terminal_text status
        ; keys = stop_keys
        } ]
;;

let is_running (row : Tui_decode.keeper_turn_row) =
  match row.ktr_state with
  | Tui_decode.Keeper_turn_running _ -> true
  | Tui_decode.Keeper_turn_idle | Tui_decode.Keeper_turn_unavailable _ ->
      false
;;

(** Names that were mid-turn in [previous] and are idle in [current] — the
    turns that finished between two polls. A keeper that went unavailable is
    not finished (the owner lookup failing says nothing about its turn), and
    a keeper missing from [current] is not finished either (it was removed,
    not answered). *)
let newly_finished ~previous ~current =
  List.filter_map
    (fun (row : Tui_decode.keeper_turn_row) ->
      if not (is_running row) then None
      else
        List.find_map
          (fun (next : Tui_decode.keeper_turn_row) ->
            if
              String.equal next.ktr_keeper_name row.ktr_keeper_name
              && next.ktr_state = Tui_decode.Keeper_turn_idle
            then Some row.ktr_keeper_name
            else None)
          current)
    previous
;;

(** Carry the finish glow forward across one read: drop entries older than
    the TTL, drop a keeper that started running again (the badge takes over),
    and put the turns that just finished in front. *)
let advance_finishes ~now ~previous_rows ~current_rows finishes =
  let fresh =
    List.map (fun name -> (name, now))
      (newly_finished ~previous:previous_rows ~current:current_rows)
  in
  let running_again name =
    List.exists
      (fun (row : Tui_decode.keeper_turn_row) ->
        String.equal row.ktr_keeper_name name && is_running row)
      current_rows
  in
  let kept =
    List.filter
      (fun (name, finished_at) ->
        now -. finished_at <= finish_glow_ttl_seconds
        && (not (running_again name))
        && not (List.mem_assoc name fresh))
      finishes
  in
  fresh @ kept
;;

let overlay ?width ~ko ~(now : float) ~(chat_target : string option)
    ~(error : read_error option) ~(observed_at : float option)
    ~(finishes : (string * float) list)
    (rows : Tui_decode.keeper_turn_row list) : line list =
  let say korean english = if ko then korean else english in
  let poll_error_text = function
    | Read_failed detail -> Printf.sprintf (if ko then "조회 실패: %s" else "read failed: %s") detail
    | Read_kept_back notice -> notice in
  let answered elapsed =
    if ko then elapsed ^ " 전에 끝남" else "answered " ^ elapsed ^ " ago" in
  let running, unavailable, idle_count =
    List.fold_left
      (fun (running, unavailable, idle) (row : Tui_decode.keeper_turn_row) ->
        match row.ktr_state with
        | Tui_decode.Keeper_turn_running { lane; started_at_unix } ->
            ((row.ktr_keeper_name, lane, started_at_unix) :: running,
             unavailable, idle)
        | Tui_decode.Keeper_turn_unavailable detail ->
            (running, (row.ktr_keeper_name, detail) :: unavailable, idle)
        | Tui_decode.Keeper_turn_idle -> (running, unavailable, idle + 1))
      ([], [], 0) rows
  in
  let running = List.rev running in
  let unavailable = List.rev unavailable in
  (* The pane's last chat target leads; the rest keep server order, which is
     sorted by name. Same rule as the footer badge, so the overlay opens on
     the keeper the badge was naming. *)
  let running =
    match chat_target with
    | Some target ->
        let mine, others =
          List.partition (fun (name, _, _) -> String.equal name target) running
        in
        mine @ others
    | None -> running
  in
  (* A finished row leaves when its glow runs out, with no new data, so that
     is a time the overlay next changes (RFC tui-one-screen-grammar §8). *)
  let live_finishes =
    List.filter
      (fun (_, finished_at) ->
        Masc_tui_value.Redraw.holds ~now ~until:(finished_at +. finish_glow_ttl_seconds))
      finishes
  in
  let name_width =
    let widest =
      List.fold_left
        (fun widest (name, _, _) -> max widest (Masc_tui_message_layout.display_width name))
        0 running
    in
    List.fold_left
      (fun widest (name, _) -> max widest (Masc_tui_message_layout.display_width name))
      widest live_finishes
  in
  let lane_cell lane =
    Masc_tui_message_layout.fit_width (lane_word ~ko lane)
      (if ko then 6 else 12)
  in
  let suffix_width =
    let running_width = List.fold_left
      (fun widest (_, lane, started_at) ->
        max widest (Masc_tui_message_layout.display_width
          (Printf.sprintf "  %s  %s" (lane_cell lane)
            (Masc_tui_value.Ongoing.since ~now started_at)))) 0 running
    in
    List.fold_left
      (fun widest (_, finished_at) ->
        max widest (Masc_tui_message_layout.display_width
          ("  " ^ answered (Masc_tui_value.Ongoing.since ~now finished_at))))
      running_width live_finishes
  in
  (* Reserve the lane and age first: one long fleet name must not push every
     other keeper's status outside the viewport. Widths are terminal cells. *)
  let name_width = match width with
    | None -> name_width
    | Some width -> min name_width (max 0 (width - 2 - suffix_width))
  in
  let fitted_name name =
    Masc_tui_message_layout.fit_width
      (Masc.Tui_terminal_text.sanitize_terminal_text name) name_width
  in
  (* What the rows below are a reading of. [observed_at] is when a read last
     answered; without one there are no rows at all, so "showing the last rows
     that arrived" and "nobody is answering right now" were both said about a
     list no read had brought back. *)
  let error_lines =
    match error, observed_at with
    | None, _ -> []
    | Some error, None ->
        [ { text = poll_error_text error
          ; tone = Unknown
          ; target = None
          }
        ]
    | Some error, Some read_at ->
        [ { text = poll_error_text error
          ; tone = Unknown
          ; target = None
          }
        ; { text =
              Printf.sprintf (if ko then "%s 전에 읽은 목록" else "showing the rows read %s ago")
                (Masc_tui_value.Ongoing.since ~now read_at)
          ; tone = Quiet
          ; target = None
          }
        ]
  in
  let running_lines =
    match running, observed_at, error with
    | [], Some _, _ ->
        if live_finishes = [] then
          [ { text = say "지금 응답 중인 키퍼 없음" "nobody is answering right now"
            ; tone = Quiet
            ; target = None
            }
          ]
        else []
    | [], None, None ->
        [ { text = say "미조회" "not loaded yet"; tone = Quiet; target = None } ]
    (* The failed read above is the whole answer; there is no list to
       describe. *)
    | [], None, Some _ -> []
    | _ :: _, _, _ ->
        List.map
          (fun (name, lane, started_at) ->
            { text =
                Printf.sprintf "%s %s  %s  %s" running_mark
                  (fitted_name name)
                  (lane_cell lane)
                  (Masc_tui_value.Ongoing.since ~now started_at)
            ; tone = Running
            ; target = Some name
            })
          running
  in
  let finished_lines =
    List.map
      (fun (name, finished_at) ->
        { text =
            Printf.sprintf "%s %s  %s"
              (Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Settled)
              (fitted_name name)
              (answered (Masc_tui_value.Ongoing.since ~now finished_at))
        ; tone = Done
        ; target = Some name
        })
      live_finishes
  in
  let unavailable_lines =
    List.map
      (fun (name, detail) ->
        { text = Printf.sprintf "? %s \xc2\xb7 %s" name detail
        ; tone = Unknown
        ; target = None
        })
      unavailable
  in
  let idle_line =
    if idle_count = 0 then []
    else
      [ { text = Printf.sprintf (if ko then "쉬는 키퍼 %d" else "%d idle") idle_count
        ; tone = Quiet
        ; target = None
        }
      ]
  in
  error_lines @ running_lines @ finished_lines @ unavailable_lines @ idle_line
;;

(** Indexes of the rows Enter can act on, in display order. The cursor moves
    over these, not over prose. *)
let target_indexes lines =
  let rec loop index acc = function
    | [] -> List.rev acc
    | line :: rest ->
        loop (index + 1)
          (if Option.is_some line.target then index :: acc else acc)
          rest
  in
  loop 0 [] lines
;;
