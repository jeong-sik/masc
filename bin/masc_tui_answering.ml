(** The Answering overlay: who is mid-turn right now, in one keypress.

    The footer badge compresses the same fact to "◌ answering kidsnote +2";
    this overlay is the "+2" unfolded — every running keeper with its lane
    and how long the turn has been going, the pane's last chat target first,
    because that is the answer the operator who pressed the key is waiting
    on. Pure projection over the polled rows so the shape is testable
    without a terminal. *)

open Masc

type tone =
  | Heading
  | Running
  | Unknown
  | Quiet

type line =
  { text : string
  ; tone : tone
  }

(* Wire spelling from [Keeper_owner.turn_lane_to_string], not a local
   re-spelling: the overlay names the lane the server named. *)
let lane_word = function
  | Tui_decode.Turn_lane_autonomous -> "autonomous"
  | Tui_decode.Turn_lane_chat_operation -> "chat_operation"
  | Tui_decode.Turn_lane_maintenance -> "maintenance"
;;

(* "2m14s" reads at a glance; a bare second count stops meaning anything
   past a minute. Negative deltas (clock skew between server and terminal)
   clamp to zero rather than counting up from the future. *)
let elapsed_text ~now started_at =
  let seconds = int_of_float (Float.max 0. (now -. started_at)) in
  if seconds < 60 then Printf.sprintf "%ds" seconds
  else if seconds < 3600 then
    Printf.sprintf "%dm%02ds" (seconds / 60) (seconds mod 60)
  else Printf.sprintf "%dh%02dm" (seconds / 3600) (seconds mod 3600 / 60)
;;

let overlay ~(now : float) ~(chat_target : string option)
    ~(error : string option) (rows : Tui_decode.keeper_turn_row list) :
    line list =
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
  let name_width =
    List.fold_left
      (fun widest (name, _, _) -> max widest (String.length name))
      0 running
  in
  let error_lines =
    match error with
    | None -> []
    | Some detail ->
        [ { text = Printf.sprintf "poll failed: %s" detail; tone = Unknown }
        ; { text = "showing the last rows that arrived"; tone = Quiet }
        ]
  in
  let running_lines =
    match running with
    | [] -> [ { text = "nobody is answering right now"; tone = Quiet } ]
    | _ ->
        List.map
          (fun (name, lane, started_at) ->
            { text =
                Printf.sprintf "\xe2\x97\x8c %-*s  %-14s  %s" name_width name
                  (lane_word lane)
                  (elapsed_text ~now started_at)
            ; tone = Running
            })
          running
  in
  let unavailable_lines =
    List.map
      (fun (name, detail) ->
        { text = Printf.sprintf "? %s \xe2\x80\x94 %s" name detail
        ; tone = Unknown
        })
      unavailable
  in
  let idle_line =
    if idle_count = 0 then []
    else
      [ { text = Printf.sprintf "%d idle" idle_count; tone = Quiet } ]
  in
  error_lines @ running_lines @ unavailable_lines @ idle_line
;;
