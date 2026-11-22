open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

let layout_breakpoint_of_model = function
  | Model.Wide -> Layout.Wide
  | Model.Standard -> Layout.Standard
  | Model.Compact -> Layout.Compact
  | Model.Micro -> Layout.Micro

let target_keeper_of_model (m : Model.t) =
  match m.drafts.active_keeper with
  | Some k when not (String.equal (String.trim k) "") -> String.trim k
  | Some _ | None -> (
      match Fleet_store.selected_keeper_summary m.fleet with
      | Some k -> k.name
      | None -> Drafts.target_keeper_key m.drafts)

let display_target_keeper_of_model (m : Model.t) =
  match m.drafts.active_keeper with
  | Some k when not (String.equal (String.trim k) "") -> String.trim k
  | Some _ | None -> (
      match Fleet_store.selected_keeper_summary m.fleet with
      | Some k -> k.name
      | None -> Say.resolve m.lang (Say.make ~ko:"미선택" ~en:"none"))

let pending_tx_of_drafts ~keeper (drafts : Drafts.t) =
  match Drafts.active_tx_for_keeper ~keeper drafts with
  | None -> Composer.Tx_idle
  | Some tx -> (
      match tx.state with
      | Drafts.Queued -> Composer.Tx_queued
      | Drafts.Sending -> Composer.Tx_sending
      | Drafts.Pending_processing -> Composer.Tx_awaiting_turn
      | Drafts.Confirming_delivery -> Composer.Tx_confirming
      | Drafts.Delivered | Drafts.Failed_retryable _ -> Composer.Tx_idle)

let voice_state_of_drafts (drafts : Drafts.t) =
  match drafts.voice with
  | Drafts.Voice_off | Drafts.Voice_speaking | Drafts.Voice_error _ ->
      Composer.Voice_off
  | Drafts.Voice_recording { levels; elapsed_s; _ } ->
      Composer.Voice_recording { levels = Array.of_list levels; elapsed_s }
  | Drafts.Voice_transcribing -> Composer.Voice_transcribing

let contains_ci ~needle haystack =
  let n_len = String.length needle in
  if n_len = 0 then true
  else
    let h_len = String.length haystack in
    if n_len > h_len then false
    else
      let n_low = String.lowercase_ascii needle in
      let h_low = String.lowercase_ascii haystack in
      let limit = h_len - n_len in
      let rec scan i =
        if i > limit then false
        else if String.equal (String.sub h_low i n_len) n_low then true
        else scan (i + 1)
      in
      scan 0

let fuzzy_score ~query target =
  let q = String.lowercase_ascii (String.trim query) in
  let q_len = String.length q in
  if q_len = 0 then Some 100
  else
    let t = String.lowercase_ascii target in
    let t_len = String.length t in
    if q_len > t_len then None
    else if String.equal q t then Some 1000
    else if String.starts_with ~prefix:q t then Some (800 - (t_len - q_len))
    else if contains_ci ~needle:q t then Some (500 - (t_len - q_len))
    else
      let rec match_seq qi ti score consecutive =
        if qi >= q_len then Some (Int.max 1 score)
        else if ti >= t_len then None
        else if Char.equal q.[qi] t.[ti] then
          let bonus = if consecutive then 12 else 4 in
          let start_bonus = if ti = 0 then 10 else 0 in
          match_seq (qi + 1) (ti + 1) (score + bonus + start_bonus) true
        else match_seq qi (ti + 1) (score - 1) false
      in
      match_seq 0 0 100 false

let popup_of_draft (m : Model.t) (draft : Drafts.keeper_draft) =
  if not (Drafts.is_focused m.drafts) then Composer.Popup_none
  else
    let text = draft.text in
    let len = String.length text in
    if len > 0 && Char.equal text.[0] '/' && not (String.contains text '\n') then
      let query =
        match String.index_opt text ' ' with
        | None -> String.sub text 1 (len - 1)
        | Some _ -> ""
      in
      if String.contains text ' ' then Composer.Popup_none
      else
        let specs = Slash.filter ~query ~lang:m.lang in
        let items =
          List.map
            (fun (s : Slash.spec) ->
              {
                Composer.trigger = s.name;
                label = Say.resolve m.lang s.description;
                detail = Option.map (Say.resolve m.lang) s.arg_hint;
              })
            specs
        in
        if items = [] then Composer.Popup_none
        else Composer.Popup_slash { query; items; selected = 0 }
    else
      match String.rindex_opt text '@' with
      | Some idx
        when idx = 0
             || Char.equal text.[idx - 1] ' '
             || Char.equal text.[idx - 1] '\n' ->
          let after = String.sub text (idx + 1) (len - idx - 1) in
          if String.contains after ' ' || String.contains after '\n' then
            Composer.Popup_none
          else
            let keepers =
              Fleet_store.filtered_keepers { m.fleet with filter_query = "" }
              |> List.filter (fun (k : Wire_fleet.keeper_summary) ->
                     contains_ci ~needle:after k.name
                     || contains_ci ~needle:after k.company)
            in
            let items =
              List.map
                (fun (k : Wire_fleet.keeper_summary) ->
                  {
                    Composer.trigger = "@" ^ k.name;
                    label = k.company;
                    detail = Some k.runtime_id;
                  })
                keepers
            in
            if items = [] then Composer.Popup_none
            else Composer.Popup_mention { query = after; items; selected = 0 }
      | Some _ | None -> Composer.Popup_none

let composer_state_of_model (m : Model.t) : Composer.state =
  let lookup_keeper = target_keeper_of_model m in
  let target_keeper = display_target_keeper_of_model m in
  let draft = Drafts.current_draft m.drafts in
  {
    Composer.target_keeper;
    draft = draft.text;
    cursor = draft.cursor;
    focused = Drafts.is_focused m.drafts;
    pending_tx = pending_tx_of_drafts ~keeper:lookup_keeper m.drafts;
    voice = voice_state_of_drafts m.drafts;
    popup = popup_of_draft m draft;
    draft_count_other_keepers = Drafts.other_keepers_draft_count m.drafts;
  }

let freshness_pill ~(model : Model.t) ~compact =
  let lang = model.lang in
  let mismatch =
    match model.server_identity.mismatch_state with
    | Model.Mismatch_none -> false
    | Model.Mismatch_recovering | Model.Mismatch_halted -> true
  in
  if mismatch then
    let lbl =
      Say.resolve lang
        (if compact then Say.make ~ko:"불일치" ~en:"MISMATCH"
         else Say.make ~ko:"워크스페이스 불일치" ~en:"MISMATCH")
    in
    (Glyph.Transport_stale, lbl, Theme.Status_critical)
  else if model.freshness.server_offline then
    let lbl = Say.resolve lang (Say.make ~ko:"오프라인" ~en:"OFFLINE") in
    (Glyph.Live_idle, lbl, Theme.Status_critical)
  else
    match model.freshness.observer with
    | Health.Live _ ->
        let lbl = Say.resolve lang (Say.make ~ko:"LIVE" ~en:"LIVE") in
        (Glyph.Live_healthy, lbl, Theme.Status_ok)
    | Health.Connecting ->
        let lbl =
          Say.resolve lang
            (if compact then Say.make ~ko:"연결" ~en:"SYNC"
             else Say.make ~ko:"연결 중" ~en:"CONNECTING")
        in
        (Glyph.Transport_reconnecting, lbl, Theme.Status_active)
    | Health.Reconnecting { attempt; _ } ->
        let lbl =
          Say.resolve lang
            (if compact then Say.make ~ko:"재연결" ~en:"RECON"
             else
               Say.make
                 ~ko:(Printf.sprintf "재연결 #%d" attempt)
                 ~en:(Printf.sprintf "RECONNECTING #%d" attempt))
        in
        (Glyph.Transport_reconnecting, lbl, Theme.Status_attention)
    | Health.Stale { age_sec; _ } ->
        let lbl =
          if compact then Say.resolve lang (Say.make ~ko:"지연" ~en:"STALE")
          else
            Printf.sprintf "%s %s"
              (Say.resolve lang (Say.make ~ko:"지연" ~en:"STALE"))
              (Format_val.format_duration_s age_sec)
        in
        (Glyph.Transport_stale, lbl, Theme.Status_attention)
    | Health.Disconnected _ ->
        let lbl = Say.resolve lang (Say.make ~ko:"오프라인" ~en:"OFFLINE") in
        (Glyph.Live_idle, lbl, Theme.Status_critical)
    | Health.Workspace_mismatch _ ->
        let lbl = Say.resolve lang (Say.make ~ko:"불일치" ~en:"MISMATCH") in
        (Glyph.Transport_stale, lbl, Theme.Status_critical)

let attention_kind_tag = function
  | Health.Pending_ask _ -> Say.make ~ko:"질문" ~en:"ASK"
  | Health.Held_tool_approval _ -> Say.make ~ko:"도구" ~en:"TOOL"
  | Health.Goal_confirmation _ -> Say.make ~ko:"목표" ~en:"GOAL"
  | Health.Board_quarantine _ -> Say.make ~ko:"격리" ~en:"QUAR"

let attention_kind_keeper = function
  | Health.Pending_ask { keeper; _ }
  | Health.Held_tool_approval { keeper; _ }
  | Health.Board_quarantine { keeper; _ } ->
      Some keeper
  | Health.Goal_confirmation _ -> None

let keeper_health_glyph_and_tone = function
  | Wire_fleet.Keeper_healthy -> (Glyph.Live_healthy, Theme.Status_ok)
  | Wire_fleet.Keeper_working -> (Glyph.Live_working, Theme.Status_active)
  | Wire_fleet.Keeper_idle -> (Glyph.Live_idle, Theme.Status_historical)
  | Wire_fleet.Keeper_degraded -> (Glyph.Warning_triangle, Theme.Status_attention)
  | Wire_fleet.Keeper_recovering | Wire_fleet.Keeper_booting ->
      (Glyph.Transport_reconnecting, Theme.Status_active)
  | Wire_fleet.Keeper_failing | Wire_fleet.Keeper_offline ->
      (Glyph.Live_failing, Theme.Status_critical)
  | Wire_fleet.Keeper_paused -> (Glyph.Live_paused, Theme.Status_historical)

let format_hhmm_with_offset ~tz_offset_sec ts =
  if (not (Float.is_finite ts)) || ts <= 0.0 then None
  else
    let secs = Int64.add (Int64.of_float (Float.floor ts)) (Int64.of_int tz_offset_sec) in
    let day_s =
      let r = Int64.rem secs 86400L in
      Int64.to_int (if Int64.compare r 0L < 0 then Int64.add r 86400L else r)
    in
    let h = day_s / 3600 in
    let m = (day_s mod 3600) / 60 in
    Some (Printf.sprintf "%02d:%02d" h m)

let format_hhmm_utc ts = format_hhmm_with_offset ~tz_offset_sec:0 ts

let format_relative_age ~now_unix ~at_unix =
  if
    (not (Float.is_finite now_unix))
    || (not (Float.is_finite at_unix))
    || now_unix <= 0.0
    || at_unix <= 0.0
  then None
  else
    let diff = Float.max 0.0 (now_unix -. at_unix) in
    Some (Format_val.format_duration_s diff)

let format_milli_candles raw =
  let trimmed = String.trim raw in
  match float_of_string_opt trimmed with
  | Some v when Float.is_finite v ->
      Format_val.format_value Format_val.Candles (v /. 1000.0)
  | Some _ | None ->
      if String.equal trimmed "" then Glyph.to_utf8 Glyph.Missing_absent
      else trimmed ^ " C"

let draw_hline ?clip grid ~x ~y ~w ~style =
  if w > 0 then
    for dx = 0 to w - 1 do
      Cell_grid.put_glyph ?clip grid ~x:(x + dx) ~y ~style Glyph.Box_h
    done

let draw_pill ?clip grid ~x ~y ~fg ~bg ?(bold = false) text =
  if String.length text = 0 then 0
  else
    let attrs = if bold then Attr.bold else Attr.none in
    let style = Style.make ~fg ~bg ~attrs () in
    let padded = " " ^ text ^ " " in
    Cell_grid.put_text ?clip grid ~x ~y ~style padded

let dim_backdrop grid ~(rect : Rect.t) ~(theme : Theme.t) =
  let bounds = Rect.intersect rect (Cell_grid.bounds grid) in
  if not (Rect.is_empty bounds) then
    let dim_fg = Color.of_rgb theme.text_muted in
    let dim_bg = Color.of_rgb theme.surface_0 in
    for y = bounds.y to Rect.bottom bounds - 1 do
      for x = bounds.x to Rect.right bounds - 1 do
        let c = Cell_grid.get grid ~x ~y in
        match c.glyph with
        | Cell_grid.Continuation -> ()
        | Cell_grid.Empty
        | Cell_grid.Ascii _
        | Cell_grid.Braille _
        | Cell_grid.Utf8 _ ->
            let style =
              Style.make ~fg:dim_fg ~bg:dim_bg ~attrs:Attr.none ()
            in
            Cell_grid.set_cell ~clip:bounds grid ~x ~y { c with style }
      done
    done

let parse_json_struct_only s =
  match Yojson.Safe.from_string s with
  | (`Assoc _ | `List _) as json -> Some json
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ -> None
  | exception Yojson.Json_error _ -> None

let strip_trailing_colon s =
  let t = String.trim s in
  let len = String.length t in
  if len > 0 && Char.equal t.[len - 1] ':' then
    String.trim (String.sub t 0 (len - 1))
  else t

let extract_embedded_json raw =
  let trimmed = String.trim raw in
  let len = String.length trimmed in
  if len < 2 then None
  else
    let rec try_from i =
      if i >= len then None
      else if Char.equal trimmed.[i] '{' || Char.equal trimmed.[i] '[' then
        let candidate = String.sub trimmed i (len - i) in
        match parse_json_struct_only candidate with
        | Some json ->
            let prefix =
              if i = 0 then ""
              else strip_trailing_colon (String.sub trimmed 0 i)
            in
            let prefix_opt =
              if String.equal prefix "" then None else Some prefix
            in
            Some (prefix_opt, json)
        | None -> try_from (i + 1)
      else try_from (i + 1)
    in
    try_from 0

let is_ident_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
  | _ -> false

let is_ws = function ' ' | '\t' | '\n' | '\r' -> true | _ -> false

let is_value_delim = function
  | ' ' | '\t' | '\n' | '\r' | ',' | '}' | ']' | ';' | '"' | '\'' | '?' | '&' ->
      true
  | _ -> false

let redact_plain_text_secrets raw =
  let len = String.length raw in
  let buf = Buffer.create len in
  let rec skip_ws i = if i < len && is_ws raw.[i] then skip_ws (i + 1) else i in
  let rec skip_quoted_string i =
    if i >= len then len
    else if Char.equal raw.[i] '\\' && i + 1 < len then
      skip_quoted_string (i + 2)
    else if Char.equal raw.[i] '"' then i + 1
    else skip_quoted_string (i + 1)
  in
  let rec skip_unquoted_value i =
    if i >= len || is_value_delim raw.[i] then i
    else skip_unquoted_value (i + 1)
  in
  let rec find_substr ~needle from =
    let nlen = String.length needle in
    if nlen = 0 || from + nlen > len then None
    else if String.equal (String.sub raw from nlen) needle then Some from
    else find_substr ~needle (from + 1)
  in
  let rec scan i =
    if i >= len then ()
    else if
      i + 11 <= len && String.equal (String.sub raw i 11) "-----BEGIN "
      && contains_ci ~needle:"PRIVATE KEY"
           (String.sub raw i (Int.min 64 (len - i)))
    then begin
      Buffer.add_string buf "[redacted]";
      match find_substr ~needle:"-----END " (i + 11) with
      | Some end_hdr -> (
          match find_substr ~needle:"-----" (end_hdr + 9) with
          | Some close_dashes -> scan (close_dashes + 5)
          | None -> ())
      | None -> ()
    end
    else if Char.equal raw.[i] '"' then begin
      (* Check quoted key: "secret_key" : value *)
      let k_start = i + 1 in
      let rec scan_key j =
        if j < len && is_ident_char raw.[j] then scan_key (j + 1) else j
      in
      let k_end = scan_key k_start in
      if k_end > k_start && k_end < len && Char.equal raw.[k_end] '"' then
        let key = String.sub raw k_start (k_end - k_start) in
        let after_q = skip_ws (k_end + 1) in
        if
          after_q < len
          && (Char.equal raw.[after_q] ':' || Char.equal raw.[after_q] '=')
          && Json_tree.is_secret_key key
        then begin
          Buffer.add_substring buf raw i (after_q - i + 1);
          let v_start = skip_ws (after_q + 1) in
          if v_start > after_q + 1 then Buffer.add_char buf ' ';
          if v_start >= len then ()
          else if Char.equal raw.[v_start] '"' then begin
            Buffer.add_string buf "\"[redacted]\"";
            scan (skip_quoted_string (v_start + 1))
          end
          else begin
            Buffer.add_string buf "[redacted]";
            scan (skip_unquoted_value v_start)
          end
        end
        else begin
          (* Check if the quoted string itself holds a secret token value *)
          let str_end = skip_quoted_string (i + 1) in
          let inner_len =
            if str_end > i + 1 && Char.equal raw.[str_end - 1] '"' then
              str_end - i - 2
            else str_end - i - 1
          in
          let inner =
            if inner_len > 0 then String.sub raw (i + 1) inner_len else ""
          in
          if Json_tree.is_secret_value inner then begin
            Buffer.add_string buf "\"[redacted]\"";
            scan str_end
          end
          else begin
            Buffer.add_char buf '"';
            scan (i + 1)
          end
        end
      else begin
        let str_end = skip_quoted_string (i + 1) in
        let inner_len =
          if str_end > i + 1 && Char.equal raw.[str_end - 1] '"' then
            str_end - i - 2
          else str_end - i - 1
        in
        let inner =
          if inner_len > 0 then String.sub raw (i + 1) inner_len else ""
        in
        if Json_tree.is_secret_value inner then begin
          Buffer.add_string buf "\"[redacted]\"";
          scan str_end
        end
        else begin
          Buffer.add_char buf '"';
          scan (i + 1)
        end
      end
    end
    else if is_ident_char raw.[i] then begin
      let t_end = skip_unquoted_value i in
      let k_end =
        let rec go j =
          if j < len && is_ident_char raw.[j] then go (j + 1) else j
        in
        go i
      in
      let key = String.sub raw i (k_end - i) in
      let after_k = skip_ws k_end in
      if
        after_k < len
        && (Char.equal raw.[after_k] '=' || Char.equal raw.[after_k] ':')
        && Json_tree.is_secret_key key
      then begin
        Buffer.add_substring buf raw i (after_k - i + 1);
        let v_start = skip_ws (after_k + 1) in
        if v_start > after_k + 1 then Buffer.add_char buf ' ';
        if v_start >= len then ()
        else if Char.equal raw.[v_start] '"' then begin
          Buffer.add_string buf "\"[redacted]\"";
          scan (skip_quoted_string (v_start + 1))
        end
        else begin
          let v1_end = skip_unquoted_value v_start in
          let first_word =
            String.lowercase_ascii (String.sub raw v_start (v1_end - v_start))
          in
          let final_end =
            if String.equal first_word "bearer" || String.equal first_word "basic"
            then
              let v2_start = skip_ws v1_end in
              skip_unquoted_value v2_start
            else v1_end
          in
          Buffer.add_string buf "[redacted]";
          scan final_end
        end
      end
      else if
        String.equal (String.lowercase_ascii key) "bearer"
        && k_end < len && is_ws raw.[k_end]
      then begin
        let tok_start = skip_ws k_end in
        let tok_end = skip_unquoted_value tok_start in
        if tok_end > tok_start then begin
          Buffer.add_string buf "Bearer [redacted]";
          scan tok_end
        end
        else begin
          Buffer.add_substring buf raw i (k_end - i);
          scan k_end
        end
      end
      else begin
        let token = String.sub raw i (t_end - i) in
        if Json_tree.is_secret_value token then begin
          Buffer.add_string buf "[redacted]";
          scan t_end
        end
        else begin
          Buffer.add_substring buf raw i (t_end - i);
          scan t_end
        end
      end
    end
    else begin
      Buffer.add_char buf raw.[i];
      scan (i + 1)
    end
  in
  scan 0;
  Buffer.contents buf

let string_of_transport_error ~lang = function
  | Health.Connect_refused ->
      Say.resolve lang (Say.make ~ko:"연결 거부됨 (서버 중지)" ~en:"Connection refused (server stopped)")
  | Health.Timeout ->
      Say.resolve lang (Say.make ~ko:"요청 시간 초과" ~en:"Request timed out")
  | Health.Http_status code ->
      Say.resolve lang
        (Say.make
           ~ko:(Printf.sprintf "HTTP 오류 (%d)" code)
           ~en:(Printf.sprintf "HTTP error (%d)" code))
  | Health.Stream_eof ->
      Say.resolve lang (Say.make ~ko:"SSE 스트림 종료됨" ~en:"SSE stream closed (EOF)")
  | Health.Protocol_error msg ->
      Say.resolve lang
        (Say.make
           ~ko:("프로토콜 오류: " ^ msg)
           ~en:("Protocol error: " ^ msg))
  | Health.Other_io msg ->
      Say.resolve lang
        (Say.make ~ko:("I/O 오류: " ^ msg) ~en:("I/O error: " ^ msg))
