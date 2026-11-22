open Masc_tui_core

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
  | Interrupting
  | Delivered
  | Failed_retryable of { reason : string }

type pending_message = {
  request_id : string;
  keeper : string;
  body : string;
  mode : delivery_mode;
  operation_id : string option;
  prior_user_msg_ids : string list;
  user_persisted : bool;
  state : tx_state;
  created_at : Clock.Mono.t;
  updated_at : Clock.Mono.t;
  recheck_count : int;
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
  | Voice_speaking
  | Voice_error of string

type voice_capabilities = {
  recorder_available : bool;
  recorder_cmd : string option;
  stt_available : bool;
  tts_available : bool;
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
  | Queued, Queued
  | Sending, Sending
  | Pending_processing, Pending_processing
  | Confirming_delivery, Confirming_delivery
  | Interrupting, Interrupting
  | Delivered, Delivered ->
      true
  | Failed_retryable x, Failed_retryable y -> String.equal x.reason y.reason
  | ( Queued
    , ( Sending
      | Pending_processing
      | Confirming_delivery
      | Interrupting
      | Delivered
      | Failed_retryable _ ) )
  | ( Sending
    , ( Queued
      | Pending_processing
      | Confirming_delivery
      | Interrupting
      | Delivered
      | Failed_retryable _ ) )
  | ( Pending_processing
    , ( Queued
      | Sending
      | Confirming_delivery
      | Interrupting
      | Delivered
      | Failed_retryable _ ) )
  | ( Confirming_delivery
    , ( Queued
      | Sending
      | Pending_processing
      | Interrupting
      | Delivered
      | Failed_retryable _ ) )
  | ( Interrupting
    , ( Queued
      | Sending
      | Pending_processing
      | Confirming_delivery
      | Delivered
      | Failed_retryable _ ) )
  | ( Delivered
    , ( Queued
      | Sending
      | Pending_processing
      | Confirming_delivery
      | Interrupting
      | Failed_retryable _ ) )
  | ( Failed_retryable _
    , ( Queued
      | Sending
      | Pending_processing
      | Confirming_delivery
      | Interrupting
      | Delivered ) ) ->
      false

let tx_state_label = function
  | Queued -> Some (Say.make ~ko:"전송 대기" ~en:"Queued")
  | Sending -> Some (Say.make ~ko:"전송 중" ~en:"Sending")
  | Pending_processing -> Some (Say.make ~ko:"처리 대기" ~en:"Awaiting turn")
  | Confirming_delivery -> Some (Say.make ~ko:"전송 확인 중" ~en:"Confirming")
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
          | Some _, _ | None, _ -> t.by_keeper)
      | Some _ -> t.by_keeper
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
      if (not (String.equal k active)) && not (String.equal d.text "") then
        acc + 1
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
  let appended = txs @ [ msg ] in
  let len = List.length appended in
  if len <= max_retained_txs then appended
  else List.drop (len - max_retained_txs) appended

let enqueue_submission ~now ~keeper ~mode ?(prior_user_msg_ids = []) t =
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
        prior_user_msg_ids;
        user_persisted = false;
        state = Queued;
        created_at = now;
        updated_at = now;
        recheck_count = 0;
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
  | Queued | Sending | Pending_processing | Confirming_delivery | Interrupting
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
      if is_terminal_tx_state m.state then m
      else
        let op =
          match operation_id with Some _ as x -> x | None -> m.operation_id
        in
        { m with operation_id = op; state = Queued; updated_at = now })
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
          | Queued | Sending | Pending_processing | Confirming_delivery
          | Delivered | Failed_retryable _ ->
              Pending_processing
        in
        { m with operation_id = op; state = next_state; updated_at = now })
    t

let mark_confirming ~now ~request_id t =
  update_tx ~request_id
    (fun m ->
      if is_terminal_tx_state m.state then m
      else
        {
          m with
          state = Confirming_delivery;
          updated_at = now;
          recheck_count = m.recheck_count + 1;
        })
    t

let mark_interrupting ~now ~request_id t =
  update_tx ~request_id
    (fun m ->
      match m.state with
      | Sending | Pending_processing ->
          { m with state = Interrupting; updated_at = now }
      | Queued
      | Confirming_delivery
      | Interrupting
      | Delivered
      | Failed_retryable _ ->
          m)
    t

let clear_interrupting ~now ~request_id t =
  update_tx ~request_id
    (fun m ->
      match m.state with
      | Interrupting -> { m with state = Pending_processing; updated_at = now }
      | Queued
      | Sending
      | Pending_processing
      | Confirming_delivery
      | Delivered
      | Failed_retryable _ ->
          m)
    t

let mark_user_persisted ~request_id ?(operation_id = None) t =
  update_tx ~request_id
    (fun m ->
      let op =
        match operation_id with Some _ as x -> x | None -> m.operation_id
      in
      { m with user_persisted = true; operation_id = op })
    t

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
          && not (is_terminal_tx_state m.state)
        then { m with state = Delivered; user_persisted = true; updated_at = now }
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

let dismiss_failed_for_keeper ~keeper t =
  let removed = ref 0 in
  let pending_txs =
    List.filter
      (fun (m : pending_message) ->
        if String.equal m.keeper keeper then
          match m.state with
          | Failed_retryable _ ->
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
  | Delivered | Failed_retryable _ -> None

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
      | Failed_retryable _ ->
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
        | Failed_retryable _ ->
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
  | Voice_recording _ | Voice_transcribing | Voice_speaking -> true

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
  | Voice_off | Voice_transcribing | Voice_speaking | Voice_error _ -> t

let voice_tick_elapsed ~now t =
  match t.voice with
  | Voice_recording rec_state ->
      let elapsed_s =
        Float.max 0.0 (Clock.Mono.seconds_since now ~since:rec_state.started_at)
      in
      { t with voice = Voice_recording { rec_state with elapsed_s } }
  | Voice_off | Voice_transcribing | Voice_speaking | Voice_error _ -> t

let voice_set_transcribing t = { t with voice = Voice_transcribing }
let voice_set_speaking t = { t with voice = Voice_speaking }
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

let append_btw_delta ~request_id ~delta t =
  match t.btw with
  | Btw_sending s when String.equal s.request_id request_id ->
      {
        t with
        btw =
          Btw_streaming
            {
              request_id = s.request_id;
              keeper = s.keeper;
              prompt = s.prompt;
              buffer = delta;
            };
      }
  | Btw_streaming s when String.equal s.request_id request_id ->
      { t with btw = Btw_streaming { s with buffer = s.buffer ^ delta } }
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
