open Masc_tui_core
open Masc_tui_protocol

module String_map = Map.Make (String)

type delivery_mode =
  | Mode_direct
  | Mode_follow_up
  | Mode_steer

type tx_state =
  | Queued
  | Sending
  | Pending_processing
  | Confirming_delivery
  | No_operation_record
  | Interrupting
  | Delivered
  | Failed_retryable of { reason : string }

type pending_message = {
  request_id : string;
  keeper : string;
  body : string;
  mode : delivery_mode;
  operation_id : string option;
  state : tx_state;
  created_at : Clock.Mono.t;
  updated_at : Clock.Mono.t;
}

type keeper_draft = {
  text : string;
  cursor : int;
  preferred_mode : delivery_mode;
}

type voice_phase =
  | Voice_off
  | Voice_recording of {
      started_at : Clock.Mono.t;
      levels : float list;
      elapsed_s : float;
    }
  | Voice_transcribing
  | Voice_error of string

type voice_capabilities = {
  recorder_available : bool;
  recorder_cmd : string option;
  stt_available : bool;
}

type btw_status =
  | Btw_idle
  | Btw_sending of {
      request_id : string;
      keeper : string;
      prompt : string;
      started_at : Clock.Mono.t;
    }
  | Btw_streaming of {
      request_id : string;
      keeper : string;
      prompt : string;
      buffer : string;
      ownership : Cut_reply.ownership;
    }
  | Btw_answered of { keeper : string; prompt : string; reply : string }
  | Btw_failed of { keeper : string; prompt : string; reason : string }

type t = {
  active_keeper : string option;
  focused : bool;
  by_keeper : keeper_draft String_map.t;
  pending_txs : pending_message list;
  next_request_seq : int;
  voice : voice_phase;
  voice_caps : voice_capabilities option;
  btw : btw_status;
  popup_selected : int;
  popup_dismissed : bool;
}

let default_keeper_key = "_default"
let max_voice_levels = 32
let max_retained_txs = 64

let empty_keeper_draft =
  { text = ""; cursor = 0; preferred_mode = Mode_follow_up }

let empty =
  {
    active_keeper = None;
    focused = false;
    by_keeper = String_map.empty;
    pending_txs = [];
    next_request_seq = 1;
    voice = Voice_off;
    voice_caps = None;
    btw = Btw_idle;
    popup_selected = 0;
    popup_dismissed = false;
  }

let equal_delivery_mode a b =
  match a, b with
  | Mode_direct, Mode_direct
  | Mode_follow_up, Mode_follow_up
  | Mode_steer, Mode_steer ->
      true
  | Mode_direct, (Mode_follow_up | Mode_steer)
  | Mode_follow_up, (Mode_direct | Mode_steer)
  | Mode_steer, (Mode_direct | Mode_follow_up) ->
      false

let equal_tx_state a b =
  match a, b with
  | Queued, Queued | Sending, Sending | Pending_processing, Pending_processing
  | Confirming_delivery, Confirming_delivery | No_operation_record, No_operation_record
  | Interrupting, Interrupting | Delivered, Delivered -> true
  | Failed_retryable x, Failed_retryable y -> String.equal x.reason y.reason
  | (Queued | Sending | Pending_processing | Confirming_delivery | No_operation_record |
     Interrupting | Delivered | Failed_retryable _),
    (Queued | Sending | Pending_processing | Confirming_delivery | No_operation_record |
     Interrupting | Delivered | Failed_retryable _) -> false

let absence_notice (tx : pending_message) =
  match tx.operation_id with
  | None -> Say.make ~ko:"상태 기록 없음 · 전송 결과 미확인" ~en:"No status record · delivery unconfirmed"
  | Some _ -> Say.make ~ko:"이전에 접수됨 · 현재 상태 기록 없음" ~en:"Previously accepted · no current status record"

let tx_state_label = function
  | Queued -> Some (Say.make ~ko:"전송 대기" ~en:"Queued")
  | Sending -> Some (Say.make ~ko:"전송 중" ~en:"Sending")
  | Pending_processing -> Some (Say.make ~ko:"처리 대기" ~en:"Awaiting turn")
  | Confirming_delivery -> Some (Say.make ~ko:"전송 확인 중" ~en:"Confirming")
  | No_operation_record -> Some (Say.make ~ko:"상태 기록 없음" ~en:"No status record")
  | Interrupting -> Some (Say.make ~ko:"중단 요청 중" ~en:"Interrupting")
  | Delivered -> None
  | Failed_retryable _ -> Some (Say.make ~ko:"전송 실패" ~en:"Send failed")

let target_keeper_key t =
  match t.active_keeper with
  | Some k when not (String.equal (String.trim k) "") -> k
  | Some _ | None -> default_keeper_key

let draft_for ~keeper t =
  match String_map.find_opt keeper t.by_keeper with
  | Some d -> d
  | None -> empty_keeper_draft

let current_draft t = draft_for ~keeper:(target_keeper_key t) t

let clamp_cursor s c =
  let len = String.length s in
  if c < 0 then 0 else if c > len then len else c

let is_utf8_cont b = b land 0xC0 = 0x80

let prev_utf8_boundary s idx =
  let i = clamp_cursor s idx in
  if i <= 0 then 0
  else
    let rec step p =
      if p <= 0 then 0
      else if is_utf8_cont (Char.code s.[p]) then step (p - 1)
      else p
    in
    step (i - 1)

let next_utf8_boundary s idx =
  let len = String.length s in
  let i = clamp_cursor s idx in
  if i >= len then len
  else
    let rec step p =
      if p >= len then len
      else if is_utf8_cont (Char.code s.[p]) then step (p + 1)
      else p
    in
    step (i + 1)

let with_current_draft ?(reset_popup = true) f t =
  let key = target_keeper_key t in
  let prev = draft_for ~keeper:key t in
  let next = f prev in
  let by_keeper =
    if
      String.equal next.text ""
      && equal_delivery_mode next.preferred_mode Mode_follow_up
    then String_map.remove key t.by_keeper
    else String_map.add key next t.by_keeper
  in
  if reset_popup then
    { t with by_keeper; popup_selected = 0; popup_dismissed = false }
  else { t with by_keeper }

let set_active_keeper name t =
  let trimmed = String.trim name in
  if String.equal trimmed "" then t
  else
    let by_keeper =
      match t.active_keeper with
      | None -> (
          match
            ( String_map.find_opt default_keeper_key t.by_keeper
            , String_map.find_opt trimmed t.by_keeper )
          with
          | Some d, None when not (String.equal d.text "") ->
              t.by_keeper
              |> String_map.remove default_keeper_key
              |> String_map.add trimmed d
          | Some d, Some existing
            when String.equal existing.text "" && not (String.equal d.text "")
            ->
              t.by_keeper
              |> String_map.remove default_keeper_key
              |> String_map.add trimmed d
          | Some _, _ -> String_map.remove default_keeper_key t.by_keeper
          | None, _ -> t.by_keeper)
      | Some _ -> String_map.remove default_keeper_key t.by_keeper
    in
    {
      t with
      active_keeper = Some trimmed;
      by_keeper;
      popup_selected = 0;
      popup_dismissed = false;
    }

let set_focus focused t =
  if Bool.equal t.focused focused then t
  else { t with focused; popup_selected = 0; popup_dismissed = false }
let is_focused t = t.focused

let has_non_empty_draft t =
  not (String.equal (current_draft t).text "")

let current_draft_is_multiline t =
  String.contains (current_draft t).text '\n'

let other_keepers_draft_count t =
  let active = target_keeper_key t in
  String_map.fold
    (fun k d acc ->
      if
        (not (String.equal k active))
        && (not (String.equal k default_keeper_key))
        && not (String.equal d.text "")
      then acc + 1
      else acc)
    t.by_keeper 0

let insert_text snippet t =
  if String.equal snippet "" then t
  else
    with_current_draft
      (fun d ->
        let c = clamp_cursor d.text d.cursor in
        let before = String.sub d.text 0 c in
        let after = String.sub d.text c (String.length d.text - c) in
        {
          d with
          text = before ^ snippet ^ after;
          cursor = c + String.length snippet;
        })
      t

let set_current_text text t =
  with_current_draft
    (fun d -> { d with text; cursor = String.length text })
    t

let set_current_text_and_cursor ~text ~cursor t =
  with_current_draft
    (fun d -> { d with text; cursor = clamp_cursor text cursor })
    t

let insert_newline t = insert_text "\n" t

let backspace t =
  with_current_draft
    (fun d ->
      let c = clamp_cursor d.text d.cursor in
      if c <= 0 then d
      else
        let prev = prev_utf8_boundary d.text c in
        let before = String.sub d.text 0 prev in
        let after = String.sub d.text c (String.length d.text - c) in
        { d with text = before ^ after; cursor = prev })
    t

let delete_forward t =
  with_current_draft
    (fun d ->
      let len = String.length d.text in
      let c = clamp_cursor d.text d.cursor in
      if c >= len then d
      else
        let next = next_utf8_boundary d.text c in
        let before = String.sub d.text 0 c in
        let after = String.sub d.text next (len - next) in
        { d with text = before ^ after; cursor = c })
    t

let is_space_char = function ' ' | '\t' | '\n' | '\r' -> true | _ -> false

let kill_word t =
  with_current_draft
    (fun d ->
      let c = clamp_cursor d.text d.cursor in
      if c <= 0 then d
      else
        let rec skip_spaces i =
          if i <= 0 then 0
          else if is_space_char d.text.[i - 1] then skip_spaces (i - 1)
          else i
        in
        let rec skip_word i =
          if i <= 0 then 0
          else if is_space_char d.text.[i - 1] then i
          else skip_word (prev_utf8_boundary d.text i)
        in
        let start = skip_word (skip_spaces c) in
        let before = String.sub d.text 0 start in
        let after = String.sub d.text c (String.length d.text - c) in
        { d with text = before ^ after; cursor = start })
    t

let kill_line_start t =
  with_current_draft
    (fun d ->
      let c = clamp_cursor d.text d.cursor in
      if c <= 0 then d
      else
        let rec find_nl i =
          if i <= 0 then 0
          else if Char.equal d.text.[i - 1] '\n' then i
          else find_nl (i - 1)
        in
        let line_start = find_nl c in
        let start = if line_start = c && c > 0 then prev_utf8_boundary d.text c else line_start in
        let before = String.sub d.text 0 start in
        let after = String.sub d.text c (String.length d.text - c) in
        { d with text = before ^ after; cursor = start })
    t

let move_cursor dir t =
  with_current_draft ~reset_popup:false
    (fun d ->
      let len = String.length d.text in
      let c = clamp_cursor d.text d.cursor in
      let cursor =
        match dir with
        | `Left -> prev_utf8_boundary d.text c
        | `Right -> next_utf8_boundary d.text c
        | `Home -> 0
        | `End -> len
      in
      { d with cursor })
    t

let move_cursor_vertical dir t =
  with_current_draft ~reset_popup:false
    (fun d ->
      let s = d.text in
      let len = String.length s in
      let c = clamp_cursor s d.cursor in
      let line_start i =
        let rec scan k =
          if k <= 0 then 0
          else if Char.equal s.[k - 1] '\n' then k
          else scan (k - 1)
        in
        scan i
      in
      let line_end i =
        let rec scan k =
          if k >= len || Char.equal s.[k] '\n' then k else scan (k + 1)
        in
        scan i
      in
      let cur_start = line_start c in
      let cur_end = line_end c in
      let target_col =
        let rec count_chars i acc =
          if i >= c then acc
          else count_chars (next_utf8_boundary s i) (acc + 1)
        in
        count_chars cur_start 0
      in
      let advance_chars start limit n =
        let rec step i rem =
          if rem <= 0 || i >= limit then i
          else
            let nxt = next_utf8_boundary s i in
            if nxt > limit then i else step nxt (rem - 1)
        in
        step start n
      in
      let cursor =
        match dir with
        | `Up ->
            if cur_start = 0 then 0
            else
              let prev_end = cur_start - 1 in
              let prev_start = line_start prev_end in
              advance_chars prev_start prev_end target_col
        | `Down ->
            if cur_end >= len then len
            else
              let next_start = cur_end + 1 in
              let next_end = line_end next_start in
              advance_chars next_start next_end target_col
      in
      { d with cursor })
    t

let move_cursor_word dir t =
  with_current_draft ~reset_popup:false
    (fun d ->
      let len = String.length d.text in
      let c = clamp_cursor d.text d.cursor in
      let cursor =
        match dir with
        | `Left ->
            let rec skip_ws i =
              if i <= 0 then 0
              else if is_space_char d.text.[i - 1] then skip_ws (i - 1)
              else i
            in
            let rec skip_word i =
              if i <= 0 then 0
              else if is_space_char d.text.[i - 1] then i
              else skip_word (prev_utf8_boundary d.text i)
            in
            skip_word (skip_ws c)
        | `Right ->
            let rec skip_word i =
              if i >= len then len
              else if is_space_char d.text.[i] then i
              else skip_word (next_utf8_boundary d.text i)
            in
            let rec skip_ws i =
              if i >= len then len
              else if is_space_char d.text.[i] then skip_ws (i + 1)
              else i
            in
            skip_ws (skip_word c)
      in
      { d with cursor })
    t

let move_cursor_line dir t =
  with_current_draft ~reset_popup:false
    (fun d ->
      let len = String.length d.text in
      let c = clamp_cursor d.text d.cursor in
      let cursor =
        match dir with
        | `Start ->
            let rec scan i =
              if i <= 0 then 0
              else if Char.equal d.text.[i - 1] '\n' then i
              else scan (i - 1)
            in
            scan c
        | `End ->
            let rec scan i =
              if i >= len then len
              else if Char.equal d.text.[i] '\n' then i
              else scan (i + 1)
            in
            scan c
      in
      { d with cursor })
    t

let clear_current_draft t =
  with_current_draft (fun d -> { d with text = ""; cursor = 0 }) t

let set_preferred_mode preferred_mode t =
  with_current_draft ~reset_popup:false (fun d -> { d with preferred_mode }) t

let move_popup ~delta ~count ~wrap t =
  if count <= 0 then { t with popup_selected = 0 }
  else
    let cur = Store_scroll.clamp_index count t.popup_selected in
    let next =
      if wrap then
        let r = (cur + delta) mod count in
        if r < 0 then r + count else r
      else Store_scroll.clamp_index count (cur + delta)
    in
    { t with popup_selected = next; popup_dismissed = false }

let set_popup_selected idx t =
  { t with popup_selected = max 0 idx; popup_dismissed = false }

let dismiss_popup t = { t with popup_dismissed = true }

let process_session_nonce =
  let pid = Unix.getpid () in
  let ms = Int64.of_float (Unix.gettimeofday () *. 1000.0) in
  Printf.sprintf "%d-%Lx" pid ms

let fresh_request_id prefix seq =
  if String.equal prefix "chat" then
    Printf.sprintf "tui-%s-%d" process_session_nonce seq
  else Printf.sprintf "tui-%s-%s-%d" prefix process_session_nonce seq

let append_bounded_tx msg txs =
  (* The retention limit applies only to settled deliveries. Every outstanding
     input, including a failure awaiting operator action, keeps its identity. *)
  let _, kept =
    List.fold_left
      (fun (settled, rows) tx ->
        match tx.state with
        | Delivered when settled >= max_retained_txs -> (settled, rows)
        | Delivered -> (settled + 1, tx :: rows)
        | Queued | Sending | Pending_processing | Confirming_delivery
        | Interrupting | No_operation_record | Failed_retryable _ -> (settled, tx :: rows))
      (0, []) (List.rev txs)
  in
  kept @ [msg]

let enqueue_submission ~now ~keeper ~mode t =
  let d = draft_for ~keeper t in
  if String.equal (String.trim d.text) "" then None
  else
    let request_id = fresh_request_id "chat" t.next_request_seq in
    let next_seq =
      if t.next_request_seq = Int.max_int then 1 else t.next_request_seq + 1
    in
    let msg : pending_message =
      {
        request_id;
        keeper;
        body = d.text;
        mode;
        operation_id = None;
        state = Queued;
        created_at = now;
        updated_at = now;
      }
    in
    let by_keeper =
      if equal_delivery_mode d.preferred_mode Mode_follow_up then
        String_map.remove keeper t.by_keeper
      else
        String_map.add keeper { d with text = ""; cursor = 0 } t.by_keeper
    in
    let pending_txs = append_bounded_tx msg t.pending_txs in
    Some
      ( {
          t with
          by_keeper;
          pending_txs;
          next_request_seq = next_seq;
          popup_selected = 0;
          popup_dismissed = false;
        }
      , msg )

let is_terminal_tx_state = function
  | Delivered | Failed_retryable _ -> true
  | Queued | Sending | Pending_processing | Confirming_delivery | No_operation_record | Interrupting
    ->
      false

let update_tx ~request_id f t =
  let pending_txs =
    List.map
      (fun (m : pending_message) ->
        if String.equal m.request_id request_id then f m else m)
      t.pending_txs
  in
  { t with pending_txs }

let mark_sending ~now ~request_id t =
  update_tx ~request_id
    (fun m ->
      if is_terminal_tx_state m.state then m
      else { m with state = Sending; updated_at = now })
    t

let mark_queued ~now ~request_id ~operation_id t =
  update_tx ~request_id
    (fun m ->
      match m.state with
      | Sending | Queued | Confirming_delivery | No_operation_record ->
          let operation_id =
            match operation_id with Some _ -> operation_id | None -> m.operation_id
          in
          { m with operation_id; state = Queued; updated_at = now }
      | Pending_processing | Interrupting | Delivered | Failed_retryable _ -> m)
    t

let mark_accepted ~now ~request_id ~operation_id t =
  update_tx ~request_id
    (fun m ->
      if is_terminal_tx_state m.state then m
      else
        let op =
          match operation_id with Some _ as x -> x | None -> m.operation_id
        in
        let next_state =
          match m.state with
          | Interrupting -> Interrupting
          | Queued | Sending | Pending_processing | Confirming_delivery | No_operation_record
          | Delivered | Failed_retryable _ ->
              Pending_processing
        in
        { m with operation_id = op; state = next_state; updated_at = now })
    t

let mark_operation_absent ~now ~requested_at ~keeper ~operation_id t =
  let pending_txs = List.map (fun (m : pending_message) ->
    let id = Option.value m.operation_id ~default:m.request_id in
    if String.equal keeper m.keeper && String.equal id operation_id &&
       Clock.Mono.compare requested_at m.updated_at >= 0 && not (is_terminal_tx_state m.state)
    then { m with state = No_operation_record; updated_at = now }
    else m) t.pending_txs in
  { t with pending_txs }

let mark_confirming ~now ~request_id t =
  update_tx ~request_id
    (fun m ->
      if is_terminal_tx_state m.state || m.state = No_operation_record then m
      else
        {
          m with
          state = Confirming_delivery;
          updated_at = now;
        })
    t

let matches_operation ~keeper ~operation_id (m : pending_message) =
  String.equal m.keeper keeper
  && (String.equal m.request_id operation_id
     || Option.equal String.equal m.operation_id (Some operation_id))

let set_operation_interrupting ~now ~keeper ~operation_id ~interrupting t =
  let pending_txs =
    List.map
      (fun (m : pending_message) ->
        if matches_operation ~keeper ~operation_id m then
          match interrupting, m.state with
          | true, (Sending | Pending_processing) ->
              { m with state = Interrupting; updated_at = now }
          | false, Interrupting ->
              let state =
                if Option.is_some m.operation_id then Pending_processing
                else Sending
              in
              { m with state; updated_at = now }
          | false, (Sending | Pending_processing)
          | true, Interrupting
          | _, (Queued | Confirming_delivery | Delivered | No_operation_record | Failed_retryable _) ->
              m
        else m)
      t.pending_txs
  in
  { t with pending_txs }

let is_operation_interrupting ~keeper ~operation_id t =
  List.exists
    (fun (m : pending_message) ->
      equal_tx_state m.state Interrupting && matches_operation ~keeper ~operation_id m)
    t.pending_txs

let downgrade_mode_to_follow_up ~request_id t =
  update_tx ~request_id
    (fun m ->
      match m.mode with
      | Mode_steer -> { m with mode = Mode_follow_up }
      | Mode_direct | Mode_follow_up -> m)
    t

let mark_delivered ~now ~request_id ~keeper ~body t =
  let pending_txs =
    List.map
      (fun (m : pending_message) ->
        if
          String.equal m.request_id request_id
          && String.equal m.keeper keeper
          && String.equal m.body body
        then { m with state = Delivered; updated_at = now }
        else m)
      t.pending_txs
  in
  { t with pending_txs }

let mark_failed_retryable ~now ~request_id ~reason t =
  update_tx ~request_id
    (fun m ->
      match m.state with
      | Delivered -> m
      | Queued
      | Sending
      | Pending_processing
      | Confirming_delivery
      | Interrupting
      | No_operation_record
      | Failed_retryable _ ->
          { m with state = Failed_retryable { reason }; updated_at = now })
    t

let remove_tx ~request_id t =
  let pending_txs =
    List.filter
      (fun (m : pending_message) -> not (String.equal m.request_id request_id))
      t.pending_txs
  in
  { t with pending_txs }

let dismiss_notices_for_keeper ~keeper t =
  let removed = ref 0 in
  let pending_txs =
    List.filter
      (fun (m : pending_message) ->
        if String.equal m.keeper keeper then
          match m.state with
          | No_operation_record | Failed_retryable _ ->
              incr removed;
              false
          | Queued
          | Sending
          | Pending_processing
          | Confirming_delivery
          | Interrupting
          | Delivered ->
              true
        else true)
      t.pending_txs
  in
  ({ t with pending_txs }, !removed)

let active_tx_priority = function
  | Interrupting -> Some 0
  | Pending_processing -> Some 1
  | Sending -> Some 2
  | Confirming_delivery -> Some 3
  | Queued -> Some 4
  | Delivered | No_operation_record | Failed_retryable _ -> None

let pending_txs_for_keeper ~keeper t =
  List.filter
    (fun (m : pending_message) -> String.equal m.keeper keeper)
    t.pending_txs

let active_tx_for_keeper ~keeper t =
  let keeper_txs = pending_txs_for_keeper ~keeper t in
  List.fold_left
    (fun best (m : pending_message) ->
      match active_tx_priority m.state with
      | None -> best
      | Some prio -> (
          match best with
          | None -> Some (prio, m)
          | Some (best_prio, _) ->
              (* Strict [<] keeps the oldest tx when priorities tie. *)
              if prio < best_prio then Some (prio, m) else best))
    None keeper_txs
  |> Option.map snd

let has_active_tx_for ~keeper t =
  Option.is_some (active_tx_for_keeper ~keeper t)

let has_unreconciled_tx_for ~keeper t =
  List.exists
    (fun (m : pending_message) ->
      String.equal m.keeper keeper
      &&
      match m.state with
      | Delivered -> false
      | Queued
      | Sending
      | Pending_processing
      | Confirming_delivery
      | Interrupting
      | No_operation_record | Failed_retryable _ ->
          true)
    t.pending_txs

let queued_count_for_keeper ~keeper t =
  List.fold_left
    (fun acc (m : pending_message) ->
      if String.equal m.keeper keeper then
        match m.state with
        | Queued -> acc + 1
        | Sending
        | Pending_processing
        | Confirming_delivery
        | Interrupting
        | Delivered
        | No_operation_record | Failed_retryable _ ->
            acc
      else acc)
    0 t.pending_txs

let tx_position_for_keeper ~keeper ~request_id t =
  let keeper_txs = pending_txs_for_keeper ~keeper t in
  let rec find idx = function
    | [] -> None
    | (m : pending_message) :: rest ->
        if String.equal m.request_id request_id then Some idx
        else find (idx + 1) rest
  in
  find 0 keeper_txs

let is_voice_active t =
  match t.voice with
  | Voice_off | Voice_error _ -> false
  | Voice_recording _ | Voice_transcribing -> true

let voice_start_recording ~now t =
  {
    t with
    voice = Voice_recording { started_at = now; levels = []; elapsed_s = 0.0 };
  }

let voice_push_level level t =
  match t.voice with
  | Voice_recording rec_state ->
      let clamped = Float.max 0.0 (Float.min 1.0 level) in
      let levels = List.take max_voice_levels (clamped :: rec_state.levels) in
      { t with voice = Voice_recording { rec_state with levels } }
  | Voice_off | Voice_transcribing | Voice_error _ -> t

let voice_tick_elapsed ~now t =
  match t.voice with
  | Voice_recording rec_state ->
      let elapsed_s =
        Float.max 0.0 (Clock.Mono.seconds_since now ~since:rec_state.started_at)
      in
      { t with voice = Voice_recording { rec_state with elapsed_s } }
  | Voice_off | Voice_transcribing | Voice_error _ -> t

let voice_set_transcribing t = { t with voice = Voice_transcribing }
let voice_set_off t = { t with voice = Voice_off }
let voice_set_error msg t = { t with voice = Voice_error msg }

let voice_apply_transcript text t =
  let trimmed = String.trim text in
  let t' = { t with voice = Voice_off } in
  if String.equal trimmed "" then t'
  else
    let current = current_draft t' in
    let prefix =
      if String.equal (String.trim current.text) "" then "" else " "
    in
    insert_text (prefix ^ trimmed) t'

let set_voice_capabilities caps t = { t with voice_caps = Some caps }

let start_btw ~now ~keeper ~prompt t =
  let request_id = fresh_request_id "btw" t.next_request_seq in
  let next_seq =
    if t.next_request_seq = Int.max_int then 1 else t.next_request_seq + 1
  in
  let btw = Btw_sending { request_id; keeper; prompt; started_at = now } in
  ({ t with btw; next_request_seq = next_seq }, request_id)

let reset_btw_run ~request_id t =
  match t.btw with
  | Btw_streaming s when String.equal s.request_id request_id ->
      {
        t with
        btw =
          Btw_streaming
            { s with buffer = ""; ownership = Cut_reply.fresh_ownership };
      }
  | Btw_sending _ | Btw_streaming _ | Btw_idle | Btw_answered _ | Btw_failed _
    ->
      t

let retire_btw_attempt ~request_id t =
  match t.btw with
  | Btw_streaming s when String.equal s.request_id request_id ->
      {
        t with
        btw =
          Btw_streaming
            {
              s with
              buffer = "";
              ownership = Cut_reply.retire_attempt s.ownership;
            };
      }
  | Btw_sending _ | Btw_streaming _ | Btw_idle | Btw_answered _ | Btw_failed _
    ->
      t

let append_btw_delta ?(owner = Wire_chat_journal.Unobserved_scope None)
    ~request_id ~delta t =
  match t.btw with
  | Btw_sending s when String.equal s.request_id request_id -> (
      match Cut_reply.admit Cut_reply.fresh_ownership owner with
      | Cut_reply.Append ownership ->
          {
            t with
            btw =
              Btw_streaming
                {
                  request_id = s.request_id;
                  keeper = s.keeper;
                  prompt = s.prompt;
                  buffer = delta;
                  ownership;
                };
          }
      | Cut_reply.Drop -> t)
  | Btw_streaming s when String.equal s.request_id request_id -> (
      match Cut_reply.admit s.ownership owner with
      | Cut_reply.Append ownership ->
          {
            t with
            btw = Btw_streaming { s with buffer = s.buffer ^ delta; ownership };
          }
      | Cut_reply.Drop -> t)
  | Btw_sending _ | Btw_streaming _ | Btw_idle | Btw_answered _ | Btw_failed _
    ->
      t

let finish_btw ~request_id ~reply t =
  match t.btw with
  | Btw_sending s when String.equal s.request_id request_id ->
      {
        t with
        btw = Btw_answered { keeper = s.keeper; prompt = s.prompt; reply };
      }
  | Btw_streaming s when String.equal s.request_id request_id ->
      let final_reply =
        if String.equal (String.trim reply) "" then s.buffer else reply
      in
      {
        t with
        btw =
          Btw_answered
            { keeper = s.keeper; prompt = s.prompt; reply = final_reply };
      }
  | Btw_sending _ | Btw_streaming _ | Btw_idle | Btw_answered _ | Btw_failed _
    ->
      t

let finalize_btw_eof ~request_id t =
  match t.btw with
  | Btw_streaming s when String.equal s.request_id request_id ->
      if not (String.equal (String.trim s.buffer) "") then
        {
          t with
          btw =
            Btw_answered
              { keeper = s.keeper; prompt = s.prompt; reply = s.buffer };
        }
      else
        {
          t with
          btw =
            Btw_failed
              {
                keeper = s.keeper;
                prompt = s.prompt;
                reason = "Stream closed with empty response";
              };
        }
  | Btw_sending s when String.equal s.request_id request_id ->
      {
        t with
        btw =
          Btw_failed
            {
              keeper = s.keeper;
              prompt = s.prompt;
              reason = "Stream closed before any response";
            };
      }
  | Btw_sending _ | Btw_streaming _ | Btw_idle | Btw_answered _ | Btw_failed _
    ->
      t

let fail_btw ~request_id ~reason t =
  match t.btw with
  | Btw_sending s when String.equal s.request_id request_id ->
      {
        t with
        btw = Btw_failed { keeper = s.keeper; prompt = s.prompt; reason };
      }
  | Btw_streaming s when String.equal s.request_id request_id ->
      {
        t with
        btw = Btw_failed { keeper = s.keeper; prompt = s.prompt; reason };
      }
  | Btw_sending _ | Btw_streaming _ | Btw_idle | Btw_answered _ | Btw_failed _
    ->
      t

let clear_btw t = { t with btw = Btw_idle }

let detach_streams ~now t =
  let t =
    List.fold_left
      (fun acc (tx : pending_message) ->
        match tx.state with
        | Queued | Sending | Pending_processing | Interrupting ->
            mark_confirming ~now ~request_id:tx.request_id acc
        | Confirming_delivery | No_operation_record | Delivered | Failed_retryable _ -> acc)
      t t.pending_txs
  in
  match t.btw with
  | Btw_sending { request_id; _ } | Btw_streaming { request_id; _ } ->
      fail_btw ~request_id
        ~reason:"the server connection changed before the answer finished" t
  | Btw_idle | Btw_answered _ | Btw_failed _ -> t
