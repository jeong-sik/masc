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

(* The mark a running turn wears, and the only thing on a masc screen that
   moves. Motion is a claim -- it says "this is changing while you look at
   it" -- so it is spent on the one state where that is true and withheld
   everywhere else. A paused keeper, a stale heartbeat, a queued approval:
   none of those are working, and a spinner on them would say they were.

   The frames are the half-filled circles already used for a task in
   progress, so a reader who has seen the task list has seen this mark. The
   circle family is the vocabulary the rest of the marks come from too
   ([Masc_tui_keeper_mark]: filled is alive, hollow is stopped).

   [still] is the same fact without the motion, for a surface that does not
   repaint fast enough to animate. A mark that changes once every two
   seconds is not a spinner, it is a flicker. *)
let running_frames = [| "\xe2\x97\x90"; "\xe2\x97\x93"; "\xe2\x97\x91"; "\xe2\x97\x92" |]
let running_still = "\xe2\x97\x8c" (* ◌ *)

let running_glyph ~frame =
  if frame < 0 then running_still
  else running_frames.(frame mod Array.length running_frames)
;;

(* Wire spelling from [Keeper_owner.turn_lane_to_string], not a local
   re-spelling: the overlay names the lane the server named. *)
let lane_word = function
  | Tui_decode.Turn_lane_autonomous -> "autonomous"
  | Tui_decode.Turn_lane_chat_operation -> "chat_operation"
  | Tui_decode.Turn_lane_maintenance -> "maintenance"
;;

(* "2m14s" reads at a glance; a bare second count stops meaning anything past
   a minute. 41989s is a real reading a surface drew, and no operator weighs
   it -- it is eleven hours and thirty-nine minutes, which is a different
   sentence.

   Two callers, one spelling. Some know when a thing started and some are
   handed the span already measured; splitting on that rather than letting
   the second one invent its own format is what keeps "11h39m" from becoming
   "11:39" one surface over.

   Negative spans (clock skew between server and terminal) clamp to zero
   rather than counting up from the future. *)
let duration_text = Masc_tui_message_layout.span_text

let elapsed_text ~now started_at = duration_text (now -. started_at)

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

(** Carry the finish glow forward across one poll: drop entries older than
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

let overlay ?(frame = -1) ~(now : float) ~(chat_target : string option)
    ~(error : string option) ~(finishes : (string * float) list)
    (rows : Tui_decode.keeper_turn_row list) : line list =
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
  let live_finishes =
    List.filter
      (fun (_, finished_at) -> now -. finished_at <= finish_glow_ttl_seconds)
      finishes
  in
  let name_width =
    let widest =
      List.fold_left
        (fun widest (name, _, _) -> max widest (String.length name))
        0 running
    in
    List.fold_left
      (fun widest (name, _) -> max widest (String.length name))
      widest live_finishes
  in
  let error_lines =
    match error with
    | None -> []
    | Some detail ->
        [ { text = Printf.sprintf "poll failed: %s" detail
          ; tone = Unknown
          ; target = None
          }
        ; { text = "showing the last rows that arrived"
          ; tone = Quiet
          ; target = None
          }
        ]
  in
  let running_lines =
    match running with
    | [] ->
        if live_finishes = [] then
          [ { text = "nobody is answering right now"
            ; tone = Quiet
            ; target = None
            }
          ]
        else []
    | _ ->
        List.map
          (fun (name, lane, started_at) ->
            { text =
                Printf.sprintf "%s %-*s  %-14s  %s" (running_glyph ~frame)
                  name_width name
                  (lane_word lane)
                  (elapsed_text ~now started_at)
            ; tone = Running
            ; target = Some name
            })
          running
  in
  let finished_lines =
    List.map
      (fun (name, finished_at) ->
        { text =
            Printf.sprintf "\xe2\x9c\x93 %-*s  answered %s ago" name_width
              name
              (elapsed_text ~now finished_at)
        ; tone = Done
        ; target = Some name
        })
      live_finishes
  in
  let unavailable_lines =
    List.map
      (fun (name, detail) ->
        { text = Printf.sprintf "? %s \xe2\x80\x94 %s" name detail
        ; tone = Unknown
        ; target = None
        })
      unavailable
  in
  let idle_line =
    if idle_count = 0 then []
    else
      [ { text = Printf.sprintf "%d idle" idle_count
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
