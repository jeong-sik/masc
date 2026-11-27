open Masc_tui_core
open Masc_tui_protocol

type ephemeral_turn = {
  keeper_id : string;
  message : string;
  answer : Wire_personal_keepers.turn_answer;
}

type t = {
  keepers : Wire_personal_keepers.personal_keeper list Observed.t;
  own_keeper_forbidden : string option;
  selected_keeper_idx : int;
  selected_keeper_id : string option;
  conversation : (string * Wire_personal_keepers.conversation_snapshot) Observed.t;
  requested_conversation_id : string option;
  selected_conv_idx : int;
  conversation_forbidden : string option;
  ephemeral_turns : ephemeral_turn list;
  turn_in_flight : (string * string) option;
  last_turn_error : (string * string) option;
  delete_armed_conv_id : string option;
  last_delete_notice : string option;
  transcript_scroll : int;
}

let empty =
  {
    keepers = Observed.unreported;
    own_keeper_forbidden = None;
    selected_keeper_idx = 0;
    selected_keeper_id = None;
    conversation = Observed.unreported;
    requested_conversation_id = None;
    selected_conv_idx = 0;
    conversation_forbidden = None;
    ephemeral_turns = [];
    turn_in_flight = None;
    last_turn_error = None;
    delete_armed_conv_id = None;
    last_delete_notice = None;
    transcript_scroll = 0;
  }

let purge _t = empty

let mark_stale t =
  {
    t with
    keepers = Observed.mark_stale t.keepers;
    conversation = Observed.mark_stale t.conversation;
  }

let clamp_idx count idx =
  if count <= 0 then 0 else Int.max 0 (Int.min (count - 1) idx)

let keepers_list t =
  match Observed.to_option t.keepers with
  | Some rows -> rows
  | None -> []

let selected_keeper t =
  let rows = keepers_list t in
  match rows with
  | [] -> None
  | _ -> (
      match t.selected_keeper_id with
      | Some kid -> (
          match
            List.find_opt
              (fun (k : Wire_personal_keepers.personal_keeper) ->
                String.equal k.keeper_id kid)
              rows
          with
          | Some k -> Some k
          | None -> List.nth_opt rows (clamp_idx (List.length rows) t.selected_keeper_idx))
      | None ->
          List.nth_opt rows (clamp_idx (List.length rows) t.selected_keeper_idx))

let selected_keeper_id t =
  match selected_keeper t with
  | Some k -> Some k.keeper_id
  | None -> t.selected_keeper_id

let conversation_for_selected t =
  match (selected_keeper_id t, Observed.to_option t.conversation) with
  | Some kid, Some (ckid, snap) when String.equal kid ckid -> Some snap
  | Some _, Some _ | Some _, None | None, _ -> None

let selected_conversation_summary t =
  match conversation_for_selected t with
  | None -> None
  | Some snap ->
      let n = List.length snap.conversations in
      if n <= 0 then None
      else List.nth_opt snap.conversations (clamp_idx n t.selected_conv_idx)

let delete_target_conversation_id t =
  match selected_conversation_summary t with
  | Some c -> Some c.conversation_id
  | None -> (
      match conversation_for_selected t with
      | Some snap -> (
          match snap.conversation_id with
          | Some _ as id -> id
          | None -> snap.current_conversation_id)
      | None -> None)

let ephemeral_turns_for ~keeper_id t =
  List.filter
    (fun (e : ephemeral_turn) -> String.equal e.keeper_id keeper_id)
    t.ephemeral_turns

let index_of_keeper_id kid rows =
  let rec loop i = function
    | [] -> None
    | (k : Wire_personal_keepers.personal_keeper) :: rest ->
        if String.equal k.keeper_id kid then Some i else loop (i + 1) rest
  in
  loop 0 rows

let index_of_conv_id cid (rows : Wire_personal_keepers.conversation_summary list) =
  let rec loop i = function
    | [] -> None
    | (c : Wire_personal_keepers.conversation_summary) :: rest ->
        if String.equal c.conversation_id cid then Some i else loop (i + 1) rest
  in
  loop 0 rows

let apply_keepers ~observed_at (rows : Wire_personal_keepers.personal_keeper list) t =
  let count = List.length rows in
  let next_idx, next_id =
    if count = 0 then (0, None)
    else
      match Option.bind t.selected_keeper_id (fun kid -> index_of_keeper_id kid rows) with
      | Some idx -> (idx, t.selected_keeper_id)
      | None ->
          let idx = clamp_idx count t.selected_keeper_idx in
          let kid =
            Option.map
              (fun (k : Wire_personal_keepers.personal_keeper) -> k.keeper_id)
              (List.nth_opt rows idx)
          in
          (idx, kid)
  in
  let keeper_changed =
    not (Option.equal String.equal t.selected_keeper_id next_id)
  in
  {
    t with
    keepers = Observed.value ~observed_at rows;
    own_keeper_forbidden = None;
    selected_keeper_idx = next_idx;
    selected_keeper_id = next_id;
    requested_conversation_id =
      if keeper_changed then None else t.requested_conversation_id;
    conversation_forbidden =
      if keeper_changed then None else t.conversation_forbidden;
    delete_armed_conv_id =
      if keeper_changed then None else t.delete_armed_conv_id;
    transcript_scroll = if keeper_changed then 0 else t.transcript_scroll;
  }

let apply_conversation ~observed_at ~keeper_id
    (snap : Wire_personal_keepers.conversation_snapshot) t =
  let n = List.length snap.conversations in
  let target_cid =
    match snap.conversation_id with
    | Some _ as id -> id
    | None -> snap.current_conversation_id
  in
  let next_conv_idx =
    match Option.bind target_cid (fun cid -> index_of_conv_id cid snap.conversations) with
    | Some idx -> idx
    | None -> clamp_idx n t.selected_conv_idx
  in
  {
    t with
    conversation = Observed.value ~observed_at (keeper_id, snap);
    conversation_forbidden = None;
    selected_conv_idx = next_conv_idx;
    delete_armed_conv_id =
      (match t.delete_armed_conv_id with
      | Some cid
        when List.exists
               (fun (c : Wire_personal_keepers.conversation_summary) ->
                 String.equal c.conversation_id cid)
               snap.conversations ->
          Some cid
      | Some _ | None -> None);
  }

let mark_own_keeper_forbidden ~at ~reason t =
  {
    t with
    keepers = Observed.failed ~reason ~retryable:false ~at;
    conversation = Observed.failed ~reason ~retryable:false ~at;
    own_keeper_forbidden = Some reason;
    delete_armed_conv_id = None;
    turn_in_flight = None;
  }

let mark_conversation_forbidden ~at ~reason t =
  {
    t with
    conversation = Observed.failed ~reason ~retryable:false ~at;
    conversation_forbidden = Some reason;
    delete_armed_conv_id = None;
  }

let clear_forbidden t =
  {
    t with
    own_keeper_forbidden = None;
    conversation_forbidden = None;
  }

let select_keeper_by_id kid t =
  let rows = keepers_list t in
  let next_idx =
    Option.value ~default:t.selected_keeper_idx (index_of_keeper_id kid rows)
  in
  let changed = not (Option.equal String.equal t.selected_keeper_id (Some kid)) in
  {
    t with
    selected_keeper_idx = next_idx;
    selected_keeper_id = Some kid;
    requested_conversation_id =
      if changed then None else t.requested_conversation_id;
    selected_conv_idx = if changed then 0 else t.selected_conv_idx;
    conversation_forbidden = if changed then None else t.conversation_forbidden;
    delete_armed_conv_id = if changed then None else t.delete_armed_conv_id;
    last_delete_notice = if changed then None else t.last_delete_notice;
    transcript_scroll = if changed then 0 else t.transcript_scroll;
  }

let move_keeper_selection ~delta t =
  let rows = keepers_list t in
  let count = List.length rows in
  if count <= 0 then
    { t with selected_keeper_idx = 0; selected_keeper_id = None }
  else
    let next_idx = clamp_idx count (t.selected_keeper_idx + delta) in
    match List.nth_opt rows next_idx with
    | Some k -> select_keeper_by_id k.keeper_id t
    | None -> t

type conv_fetch_target =
  | Fetch_none
  | Fetch_current
  | Fetch_conversation of string

let select_conversation_by_delta ~delta t =
  match conversation_for_selected t with
  | None -> (t, Fetch_none)
  | Some snap ->
      let count = List.length snap.conversations in
      if count <= 0 then ({ t with selected_conv_idx = 0 }, Fetch_none)
      else
        let next_idx = clamp_idx count (t.selected_conv_idx + delta) in
        let chosen = List.nth_opt snap.conversations next_idx in
        let next_req, fetch_target =
          match chosen with
          | None -> (t.requested_conversation_id, Fetch_none)
          | Some c -> (
              match c.deletion with
              | Wire_personal_keepers.Deletion_failed ->
                  (* Never fetch ?conversation_id=<failed_id> (server returns 404). *)
                  (None, Fetch_none)
              | Wire_personal_keepers.Deletion_kept ->
                  let is_current =
                    Option.equal String.equal snap.current_conversation_id
                      (Some c.conversation_id)
                  in
                  if is_current then (None, Fetch_current)
                  else (Some c.conversation_id, Fetch_conversation c.conversation_id))
        in
        ( {
            t with
            selected_conv_idx = next_idx;
            requested_conversation_id = next_req;
            delete_armed_conv_id = None;
            transcript_scroll = 0;
          }
        , fetch_target )

let set_requested_conversation cid t =
  { t with requested_conversation_id = cid; transcript_scroll = 0 }

let wrapped_line_count ~avail text =
  let avail = Int.max 8 avail in
  let lines = String.split_on_char '\n' text in
  List.fold_left
    (fun acc line ->
      let w = Masc_tui_term.Grapheme.display_width line in
      acc + Int.max 1 ((w + avail - 1) / avail))
    0 lines

let max_transcript_scroll ~pane_w ~pane_h t =
  let inner_w = Int.max 0 (pane_w - 2) in
  let pad_x = if inner_w >= 40 then 1 else 0 in
  let cw = Int.max 12 (inner_w - (2 * pad_x)) in
  let inner_h = Int.max 0 (pane_h - 2) in
  let footer_h = if inner_h >= 6 then 1 else 0 in
  let snap_opt = conversation_for_selected t in
  let ephemeral =
    match selected_keeper_id t with
    | Some keeper_id -> ephemeral_turns_for ~keeper_id t
    | None -> []
  in
  let conv_rows =
    match snap_opt with
    | Some s -> Int.min 4 (List.length s.conversations)
    | None -> 0
  in
  let banner_rows =
    let count_opt = function Some _ -> 1 | None -> 0 in
    let matches_sel = function
      | Some (tk, _) ->
          Option.equal String.equal (selected_keeper_id t) (Some tk)
      | None -> false
    in
    count_opt t.delete_armed_conv_id
    + count_opt t.last_delete_notice
    + count_opt t.conversation_forbidden
    + (if matches_sel t.turn_in_flight then 1 else 0)
    + if matches_sel t.last_turn_error then 1 else 0
  in
  (* Header line (Keeper/Runtime) + conv list + Turns hairline + banners. *)
  let used_top = 1 + conv_rows + 1 + banner_rows in
  let avail = Int.max 1 (inner_h - footer_h - used_top) in
  let total_lines =
    let snap_lines =
      match snap_opt with
      | None -> 0
      | Some s ->
          if s.turns = [] && ephemeral = [] then 1
          else
            List.fold_left
              (fun acc (turn : Wire_personal_keepers.conversation_turn) ->
                let user_lines =
                  wrapped_line_count ~avail:(Int.max 8 (cw - 5)) turn.message
                in
                let reply_lines =
                  match turn.outcome with
                  | Wire_personal_keepers.Turn_answered { text; model; _ } ->
                      let pfx_w = String.length model + 10 in
                      wrapped_line_count ~avail:(Int.max 8 (cw - pfx_w)) text
                  | Wire_personal_keepers.Turn_failed _
                  | Wire_personal_keepers.Turn_unrecorded _ ->
                      1
                in
                acc + user_lines + reply_lines + 1)
              0 s.turns
    in
    let eph_lines =
      List.fold_left
        (fun acc (ep : ephemeral_turn) ->
          let user_lines =
            wrapped_line_count ~avail:(Int.max 8 (cw - 5)) ep.message
          in
          let ans_lines =
            wrapped_line_count ~avail:(Int.max 8 (cw - 2)) ep.answer.text
          in
          acc + user_lines + 1 + ans_lines + 1)
        0 ephemeral
    in
    snap_lines + eph_lines
  in
  Int.max 0 (total_lines - avail)

let scroll_transcript ?max_scroll ~delta t =
  let base =
    match max_scroll with
    | Some ms -> Int.min (Int.max 0 ms) t.transcript_scroll
    | None -> t.transcript_scroll
  in
  let next = Int.max 0 (base + delta) in
  let clamped =
    match max_scroll with
    | Some ms -> Int.min (Int.max 0 ms) next
    | None -> next
  in
  { t with transcript_scroll = clamped }

let start_turn_in_flight ~keeper_id ~preview t =
  {
    t with
    turn_in_flight = Some (keeper_id, preview);
    last_turn_error = None;
    delete_armed_conv_id = None;
  }

let finish_turn_ok ~keeper_id ~message (answer : Wire_personal_keepers.turn_answer) t =
  let ephemeral_turns =
    match answer.recording with
    | Wire_personal_keepers.Turn_recorded _ -> t.ephemeral_turns
    | Wire_personal_keepers.Turn_ephemeral ->
        t.ephemeral_turns @ [ { keeper_id; message; answer } ]
  in
  let requested_conversation_id =
    match answer.recording with
    | Wire_personal_keepers.Turn_recorded _ -> None
    | Wire_personal_keepers.Turn_ephemeral -> t.requested_conversation_id
  in
  {
    t with
    turn_in_flight = None;
    last_turn_error = None;
    ephemeral_turns;
    requested_conversation_id;
  }

let finish_turn_error ~keeper_id ~reason t =
  {
    t with
    turn_in_flight = None;
    last_turn_error = Some (keeper_id, reason);
  }

let arm_delete ~conversation_id t =
  { t with delete_armed_conv_id = Some conversation_id }

let disarm_delete t = { t with delete_armed_conv_id = None }

let set_delete_notice notice t = { t with last_delete_notice = notice }
