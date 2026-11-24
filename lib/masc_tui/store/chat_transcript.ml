open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol
open Masc_tui_term
open Masc_tui_ui

let secret_token_prefixes =
  [
    "github_pat_";
    "sk_live_";
    "sk_test_";
    "rk_live_";
    "sk-";
    "ghp_";
    "gho_";
    "ghu_";
    "ghs_";
    "ghr_";
    "xoxb-";
    "xoxp-";
    "xoxa-";
    "xoxr-";
    "xoxs-";
    "AKIA";
    "ASIA";
  ]

let is_secret_token_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '.' | '/' | '+' | '=' ->
      true
  | _ -> false

let is_ident_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
  | _ -> false

let is_unquoted_val_char = function
  | ',' | '}' | ']' | '"' | '\'' | '\\' | ' ' | '\t' | '\n' | '\r' -> false
  | _ -> true

let is_http_auth_scheme s =
  match String.lowercase_ascii s with
  | "bearer" | "basic" | "token" | "digest" | "apikey" | "api-key"
  | "aws4-hmac-sha256" ->
      true
  | _ -> false

let starts_at_ci s idx prefix =
  let plen = String.length prefix in
  idx + plen <= String.length s
  &&
  let rec loop k =
    k >= plen
    || (Char.equal (Char.lowercase_ascii s.[idx + k])
          (Char.lowercase_ascii prefix.[k])
        && loop (k + 1))
  in
  loop 0

let starts_at_exact s idx prefix =
  let plen = String.length prefix in
  idx + plen <= String.length s
  &&
  let rec loop k =
    k >= plen || (Char.equal s.[idx + k] prefix.[k] && loop (k + 1))
  in
  loop 0

let match_secret_prefix s i =
  List.find_opt (fun p -> starts_at_exact s i p) secret_token_prefixes

let scan_while s pred from =
  let len = String.length s in
  let rec loop i = if i < len && pred s.[i] then loop (i + 1) else i in
  loop from

let find_pem_private_key_end s i =
  let len = String.length s in
  if not (starts_at_ci s i "-----BEGIN ") then None
  else
    let rec find_hdr_end j =
      if j + 5 > len then None
      else if Char.equal s.[j] '\n' || Char.equal s.[j] '\r' || Char.equal s.[j] '"'
      then None
      else if starts_at_exact s j "-----" then Some (j + 5)
      else find_hdr_end (j + 1)
    in
    match find_hdr_end (i + 11) with
    | None -> None
    | Some hdr_end ->
        let hdr = String.lowercase_ascii (String.sub s i (hdr_end - i)) in
        let needle = "private key" in
        let nlen = String.length needle in
        let hlen = String.length hdr in
        let rec has_priv k =
          k + nlen <= hlen
          && (String.equal (String.sub hdr k nlen) needle || has_priv (k + 1))
        in
        if not (has_priv 0) then None
        else
          let rec find_end j esc =
            if j >= len then len
            else if esc then find_end (j + 1) false
            else if Char.equal s.[j] '\\' then find_end (j + 1) true
            else if Char.equal s.[j] '"' then j
            else if starts_at_ci s j "-----END " then
              let rec close_dashes k =
                if k + 5 > len then len
                else if starts_at_exact s k "-----" then k + 5
                else if
                  Char.equal s.[k] '\n'
                  || Char.equal s.[k] '\r'
                  || Char.equal s.[k] '"'
                then k
                else close_dashes (k + 1)
              in
              close_dashes (j + 9)
            else find_end (j + 1) false
          in
          Some (find_end hdr_end false)

let find_url_cred_end s i =
  let len = String.length s in
  if not (starts_at_exact s i "://") then None
  else
    let rec scan j saw_colon =
      if j >= len then None
      else
        match s.[j] with
        | ' ' | '\t' | '\n' | '\r' | '/' | '"' | '\'' -> None
        | '@' -> if saw_colon && j > i + 3 then Some j else None
        | ':' -> scan (j + 1) true
        | _ -> scan (j + 1) saw_colon
    in
    scan (i + 3) false

let scrub_secrets_in_text raw =
  let len = String.length raw in
  let buf = Buffer.create len in
  let scan_quoted start_pos =
    let qch = raw.[start_pos] in
    Buffer.add_char buf qch;
    Buffer.add_string buf "[redacted]";
    let rec scan_q j esc =
      if j >= len then len
      else if esc then scan_q (j + 1) false
      else if Char.equal raw.[j] '\\' then scan_q (j + 1) true
      else if Char.equal raw.[j] qch then (
        Buffer.add_char buf qch;
        j + 1)
      else scan_q (j + 1) false
    in
    scan_q (start_pos + 1) false
  in
  let rec loop i =
    if i >= len then ()
    else
      match find_pem_private_key_end raw i with
      | Some pem_end ->
          Buffer.add_string buf "[redacted]";
          loop pem_end
      | None -> (
          match find_url_cred_end raw i with
          | Some at_pos ->
              Buffer.add_string buf "://[redacted]@";
              loop (at_pos + 1)
          | None -> (
              match match_secret_prefix raw i with
              | Some p ->
                  let tok_end =
                    scan_while raw is_secret_token_char (i + String.length p)
                  in
                  if tok_end > i + String.length p then begin
                    Buffer.add_string buf "[redacted]";
                    loop tok_end
                  end
                  else begin
                    Buffer.add_char buf raw.[i];
                    loop (i + 1)
                  end
              | None ->
                  let prev_ok = i = 0 || not (is_ident_char raw.[i - 1]) in
                  if prev_ok && starts_at_ci raw i "bearer " then begin
                    let val_start =
                      scan_while raw
                        (fun c -> Char.equal c ' ' || Char.equal c '\t')
                        (i + 7)
                    in
                    let val_end =
                      scan_while raw is_secret_token_char val_start
                    in
                    if val_end > val_start then begin
                      Buffer.add_string buf "Bearer [redacted]";
                      loop val_end
                    end
                    else begin
                      Buffer.add_char buf raw.[i];
                      loop (i + 1)
                    end
                  end
                  else if is_ident_char raw.[i] then begin
                    let key_end = scan_while raw is_ident_char i in
                    let key = String.sub raw i (key_end - i) in
                    if prev_ok && Json_tree.is_secret_key key then begin
                      let after_q =
                        if
                          key_end < len
                          && (Char.equal raw.[key_end] '"'
                              || Char.equal raw.[key_end] '\'')
                        then key_end + 1
                        else key_end
                      in
                      let sep_pos =
                        scan_while raw
                          (fun c -> Char.equal c ' ' || Char.equal c '\t')
                          after_q
                      in
                      if
                        sep_pos < len
                        && (Char.equal raw.[sep_pos] ':'
                            || Char.equal raw.[sep_pos] '=')
                      then begin
                        let val_start =
                          scan_while raw
                            (fun c -> Char.equal c ' ' || Char.equal c '\t')
                            (sep_pos + 1)
                        in
                        Buffer.add_substring buf raw i (val_start - i);
                        if val_start >= len then ()
                        else if
                          Char.equal raw.[val_start] '"'
                          || Char.equal raw.[val_start] '\''
                        then loop (scan_quoted val_start)
                        else begin
                          let val_end =
                            scan_while raw is_unquoted_val_char val_start
                          in
                          let first_tok =
                            String.sub raw val_start (val_end - val_start)
                          in
                          if is_http_auth_scheme first_tok then begin
                            let ws_end =
                              scan_while raw
                                (fun c -> Char.equal c ' ' || Char.equal c '\t')
                                val_end
                            in
                            if ws_end > val_end && ws_end < len then begin
                              if
                                Char.equal raw.[ws_end] '"'
                                || Char.equal raw.[ws_end] '\''
                              then begin
                                Buffer.add_string buf first_tok;
                                Buffer.add_char buf ' ';
                                loop (scan_quoted ws_end)
                              end
                              else
                                let cred_end =
                                  scan_while raw is_unquoted_val_char ws_end
                                in
                                if cred_end > ws_end then begin
                                  Buffer.add_string buf first_tok;
                                  Buffer.add_char buf ' ';
                                  Buffer.add_string buf "[redacted]";
                                  loop cred_end
                                end
                                else begin
                                  Buffer.add_string buf "[redacted]";
                                  loop val_end
                                end
                            end
                            else begin
                              Buffer.add_string buf "[redacted]";
                              loop val_end
                            end
                          end
                          else begin
                            Buffer.add_string buf "[redacted]";
                            loop val_end
                          end
                        end
                      end
                      else begin
                        Buffer.add_substring buf raw i (key_end - i);
                        loop key_end
                      end
                    end
                    else begin
                      Buffer.add_substring buf raw i (key_end - i);
                      loop key_end
                    end
                  end
                  else begin
                    Buffer.add_char buf raw.[i];
                    loop (i + 1)
                  end))
  in
  loop 0;
  Buffer.contents buf

let rec scrub_json_secrets (j : Yojson.Safe.t) : Yojson.Safe.t =
  match j with
  | `String s -> `String (scrub_secrets_in_text s)
  | `List xs -> `List (List.map scrub_json_secrets xs)
  | `Assoc kvs ->
      `Assoc
        (List.map
           (fun (k, v) ->
             if Json_tree.is_secret_key k then (k, v)
             else (k, scrub_json_secrets v))
           kvs)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _) as leaf -> leaf

let is_token_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '/' | '.' | '#' -> true
  | _ -> false

let scan_token_end s from =
  let len = String.length s in
  let rec loop i =
    if i >= len then i
    else if is_token_char s.[i] then loop (i + 1)
    else i
  in
  let raw_end = loop from in
  let rec trim_end i =
    if i <= from then from
    else
      match s.[i - 1] with
      | '.' | '/' | '-' -> trim_end (i - 1)
      | _ -> i
  in
  trim_end raw_end

let short_id id =
  let len = String.length id in
  if len <= 10 then id else String.sub id 0 10

let rewrite_masc_links_for_markdown text =
  let len = String.length text in
  let buf = Buffer.create (len + 32) in
  let rec loop i =
    if i >= len then ()
    else if Char.equal text.[i] '[' && starts_at_exact text (i + 1) "board:p-"
    then begin
      let id_start = i + 7 in
      let id_end = scan_token_end text id_start in
      if
        id_end < len
        && Char.equal text.[id_end] ']'
        && not (id_end + 1 < len && Char.equal text.[id_end + 1] '(')
      then begin
        let post_id = String.sub text id_start (id_end - id_start) in
        Buffer.add_string buf
          (Printf.sprintf "[Board %s](masc://board/%s)" (short_id post_id)
             post_id);
        loop (id_end + 1)
      end
      else begin
        Buffer.add_char buf text.[i];
        loop (i + 1)
      end
    end
    else
      let prev_is_paren = i > 0 && Char.equal text.[i - 1] '(' in
      if (not prev_is_paren) && starts_at_exact text i "board:p-" then begin
        let id_start = i + 6 in
        let id_end = scan_token_end text id_start in
        let post_id = String.sub text id_start (id_end - id_start) in
        Buffer.add_string buf
          (Printf.sprintf "[Board %s](masc://board/%s)" (short_id post_id)
             post_id);
        loop id_end
      end
      else if (not prev_is_paren) && starts_at_exact text i "github:" then begin
        let path_start = i + 7 in
        let path_end = scan_token_end text path_start in
        let gh_path = String.sub text path_start (path_end - path_start) in
        if String.length gh_path > 0 then begin
          Buffer.add_string buf
            (Printf.sprintf "[GitHub %s](https://github.com/%s)" gh_path gh_path);
          loop path_end
        end
        else begin
          Buffer.add_char buf text.[i];
          loop (i + 1)
        end
      end
      else begin
        Buffer.add_char buf text.[i];
        loop (i + 1)
      end
  in
  loop 0;
  Buffer.contents buf

let wrap_plain_lines ~width text =
  let max_w = Int.max 12 width in
  let raw_lines = String.split_on_char '\n' text in
  List.concat_map
    (fun raw ->
      let clean = String.map (function '\r' | '\t' -> ' ' | c -> c) raw in
      if Grapheme.display_width clean <= max_w then [ clean ]
      else
        let words = String.split_on_char ' ' clean in
        let rec pack cur acc = function
          | [] -> List.rev (if String.length cur > 0 then cur :: acc else acc)
          | w :: ws ->
              let cand = if String.length cur = 0 then w else cur ^ " " ^ w in
              if Grapheme.display_width cand <= max_w then pack cand acc ws
              else if String.length cur > 0 then
                pack (Grapheme.truncate_to_width ~max_width:max_w w) (cur :: acc)
                  ws
              else
                pack "" (Grapheme.truncate_to_width ~max_width:max_w w :: acc) ws
        in
        pack "" [] words)
    raw_lines

let tool_output_display_lines ~tools_mode ~width raw =
  let trimmed = String.trim raw in
  let max_preview, max_depth =
    match tools_mode with
    | Slash.Tools_compact -> (0, 2)
    | Slash.Tools_results -> (8, 2)
    | Slash.Tools_full -> (48, 4)
  in
  if String.equal trimmed "" || max_preview <= 0 then ([], 0)
  else
    let body_w = Int.max 12 (width - 6) in
    let all_lines =
      match Yojson.Safe.from_string trimmed with
      | json ->
          let scrubbed = scrub_json_secrets json in
          let flat =
            Json_tree.flatten ~max_depth ~redact_secrets:true scrubbed
          in
          let string_of_val = function
            | Json_tree.Object_node { count } -> Printf.sprintf "{%d keys}" count
            | Json_tree.Array_node { count } -> Printf.sprintf "[%d items]" count
            | Json_tree.String_val s -> s
            | Json_tree.Redacted_secret -> "[redacted]"
            | Json_tree.Int_val n -> Int.to_string n
            | Json_tree.Float_val f -> Printf.sprintf "%g" f
            | Json_tree.Bool_val b -> if b then "true" else "false"
            | Json_tree.Null_val -> "null"
          in
          List.map
            (fun (ln : Json_tree.line) ->
              let ind = String.make (ln.depth * 2) ' ' in
              let vs = string_of_val ln.value in
              match ln.key with
              | Some k -> Printf.sprintf "%s%s: %s" ind k vs
              | None -> ind ^ vs)
            flat
      | exception Yojson.Json_error _ ->
          let scrubbed = scrub_secrets_in_text trimmed in
          wrap_plain_lines ~width:body_w scrubbed
    in
    let shown = List.take max_preview all_lines in
    let hidden = List.length all_lines - List.length shown in
    (shown, hidden)

let markdown_body_lines ~theme ~width ~rail_present ~prefix text =
  let rail_w = if rail_present then 2 else 0 in
  let body_w = Int.max 10 (width - rail_w - Grapheme.display_width prefix) in
  let rewritten = rewrite_masc_links_for_markdown text in
  Markdown.render_lines ~theme ~width:body_w ~osc8:true rewritten

let stream_reply_already_persisted (hist_msgs : Wire_fleet.chat_message list)
    (buf : Fleet_store.chat_stream_buffer) =
  let buf_op_id = Option.value buf.operation_id ~default:buf.request_id in
  let op_persisted =
    List.exists
      (fun (m : Wire_fleet.chat_message) ->
        match m.operation_id with
        | Some op when String.equal op buf_op_id -> (
            match m.role with
            | Wire_fleet.Role_assistant -> (
                match m.transcript_slot with
                | None | Some "terminal_result" -> true
                | Some _ -> false)
            | Wire_fleet.Role_request_failure -> true
            | Wire_fleet.Role_user
            | Wire_fleet.Role_peer _
            | Wire_fleet.Role_system
            | Wire_fleet.Role_tool ->
                false)
        | Some _ | None -> false)
      hist_msgs
  in
  let turn_ref_persisted =
    match buf.turn_ref with
    | None -> false
    | Some tr ->
        List.exists
          (fun (m : Wire_fleet.chat_message) ->
            match m.role, m.turn_ref with
            | ( (Wire_fleet.Role_assistant | Wire_fleet.Role_request_failure)
              , Some mtr ) ->
                String.equal mtr tr
            | ( ( Wire_fleet.Role_user
                | Wire_fleet.Role_peer _
                | Wire_fleet.Role_assistant
                | Wire_fleet.Role_system
                | Wire_fleet.Role_tool
                | Wire_fleet.Role_request_failure )
              , (Some _ | None) ) ->
                false)
          hist_msgs
  in
  let legacy_text_persisted =
    match buf.last_error with
    | Some _ -> false
    | None ->
        let trimmed = String.trim buf.text in
        if String.equal trimmed "" then false
        else
          List.exists
            (fun (m : Wire_fleet.chat_message) ->
              match m.role with
              | Wire_fleet.Role_assistant ->
                  Option.is_none m.operation_id
                  && (not (Fleet_store.String_set.mem m.id buf.prior_msg_ids))
                  && String.equal (String.trim m.content) trimmed
              | Wire_fleet.Role_user
              | Wire_fleet.Role_peer _
              | Wire_fleet.Role_system
              | Wire_fleet.Role_tool
              | Wire_fleet.Role_request_failure ->
                  false)
            hist_msgs
  in
  op_persisted || turn_ref_persisted || legacy_text_persisted

type live_chat_phase =
  | Phase_idle
  | Phase_sending
  | Phase_queued of int
  | Phase_awaiting_turn
  | Phase_thinking
  | Phase_tool_running of string
  | Phase_streaming
  | Phase_confirming
  | Phase_interrupting
  | Phase_failed of string

let equal_live_chat_phase a b =
  match a, b with
  | Phase_idle, Phase_idle
  | Phase_sending, Phase_sending
  | Phase_awaiting_turn, Phase_awaiting_turn
  | Phase_thinking, Phase_thinking
  | Phase_streaming, Phase_streaming
  | Phase_confirming, Phase_confirming
  | Phase_interrupting, Phase_interrupting ->
      true
  | Phase_queued x, Phase_queued y -> Int.equal x y
  | Phase_tool_running x, Phase_tool_running y
  | Phase_failed x, Phase_failed y ->
      String.equal x y
  | ( Phase_idle
    , ( Phase_sending
      | Phase_queued _
      | Phase_awaiting_turn
      | Phase_thinking
      | Phase_tool_running _
      | Phase_streaming
      | Phase_confirming
      | Phase_interrupting
      | Phase_failed _ ) )
  | ( Phase_sending
    , ( Phase_idle
      | Phase_queued _
      | Phase_awaiting_turn
      | Phase_thinking
      | Phase_tool_running _
      | Phase_streaming
      | Phase_confirming
      | Phase_interrupting
      | Phase_failed _ ) )
  | ( Phase_queued _
    , ( Phase_idle
      | Phase_sending
      | Phase_awaiting_turn
      | Phase_thinking
      | Phase_tool_running _
      | Phase_streaming
      | Phase_confirming
      | Phase_interrupting
      | Phase_failed _ ) )
  | ( Phase_awaiting_turn
    , ( Phase_idle
      | Phase_sending
      | Phase_queued _
      | Phase_thinking
      | Phase_tool_running _
      | Phase_streaming
      | Phase_confirming
      | Phase_interrupting
      | Phase_failed _ ) )
  | ( Phase_thinking
    , ( Phase_idle
      | Phase_sending
      | Phase_queued _
      | Phase_awaiting_turn
      | Phase_tool_running _
      | Phase_streaming
      | Phase_confirming
      | Phase_interrupting
      | Phase_failed _ ) )
  | ( Phase_tool_running _
    , ( Phase_idle
      | Phase_sending
      | Phase_queued _
      | Phase_awaiting_turn
      | Phase_thinking
      | Phase_streaming
      | Phase_confirming
      | Phase_interrupting
      | Phase_failed _ ) )
  | ( Phase_streaming
    , ( Phase_idle
      | Phase_sending
      | Phase_queued _
      | Phase_awaiting_turn
      | Phase_thinking
      | Phase_tool_running _
      | Phase_confirming
      | Phase_interrupting
      | Phase_failed _ ) )
  | ( Phase_confirming
    , ( Phase_idle
      | Phase_sending
      | Phase_queued _
      | Phase_awaiting_turn
      | Phase_thinking
      | Phase_tool_running _
      | Phase_streaming
      | Phase_interrupting
      | Phase_failed _ ) )
  | ( Phase_interrupting
    , ( Phase_idle
      | Phase_sending
      | Phase_queued _
      | Phase_awaiting_turn
      | Phase_thinking
      | Phase_tool_running _
      | Phase_streaming
      | Phase_confirming
      | Phase_failed _ ) )
  | ( Phase_failed _
    , ( Phase_idle
      | Phase_sending
      | Phase_queued _
      | Phase_awaiting_turn
      | Phase_thinking
      | Phase_tool_running _
      | Phase_streaming
      | Phase_confirming
      | Phase_interrupting ) ) ->
      false

let history_msgs_for_keeper ~(model : Model.t) ~keeper =
  match Fleet_store.String_map.find_opt keeper model.fleet.chat_histories with
  | None -> []
  | Some obs -> (
      match Observed.to_option obs with
      | Some page -> page.messages
      | None -> [])

let has_persisted_failure_for_op (hist_msgs : Wire_fleet.chat_message list)
    op_id =
  List.exists
    (fun (m : Wire_fleet.chat_message) ->
      match m.role, m.operation_id with
      | Wire_fleet.Role_request_failure, Some op -> String.equal op op_id
      | ( ( Wire_fleet.Role_user
          | Wire_fleet.Role_peer _
          | Wire_fleet.Role_assistant
          | Wire_fleet.Role_system
          | Wire_fleet.Role_tool
          | Wire_fleet.Role_request_failure )
        , (Some _ | None) ) ->
          false)
    hist_msgs

let has_persisted_user_for_op (hist_msgs : Wire_fleet.chat_message list) op_id =
  List.exists
    (fun (m : Wire_fleet.chat_message) ->
      match m.role, m.operation_id with
      | (Wire_fleet.Role_user | Wire_fleet.Role_peer _), Some op ->
          String.equal op op_id
      | ( ( Wire_fleet.Role_user
          | Wire_fleet.Role_peer _
          | Wire_fleet.Role_assistant
          | Wire_fleet.Role_system
          | Wire_fleet.Role_tool
          | Wire_fleet.Role_request_failure )
        , (Some _ | None) ) ->
          false)
    hist_msgs

let live_chat_phase ~(model : Model.t) ~keeper =
  let hist_msgs = history_msgs_for_keeper ~model ~keeper in
  let buf_opt = Fleet_store.String_map.find_opt keeper model.fleet.chat_streams in
  let active_tx_opt = Drafts.active_tx_for_keeper ~keeper model.drafts in
  let queued_count = Drafts.queued_count_for_keeper ~keeper model.drafts in
  let active_turn_opt = Fleet_store.active_turn_for ~keeper model.fleet in
  let is_interrupting =
    (match buf_opt with
    | Some b -> b.active && b.interrupting
    | None -> false)
    ||
    match active_tx_opt with
    | Some { state = Drafts.Interrupting; _ } -> true
    | Some
        {
          state =
            ( Drafts.Queued
            | Drafts.Sending
            | Drafts.Pending_processing
            | Drafts.Confirming_delivery
            | Drafts.Delivered
            | Drafts.Failed_retryable _ );
          _;
        }
    | None ->
        false
  in
  if is_interrupting then Phase_interrupting
  else
    match buf_opt with
    | Some b when b.active -> (
        let running_tool =
          List.find_opt
            (fun (tc : Fleet_store.active_tool_call) -> not tc.completed)
            (List.rev b.tools)
        in
        match running_tool with
        | Some tc -> Phase_tool_running tc.tool_name
        | None ->
            if not (String.equal (String.trim b.text) "") then Phase_streaming
            else if not (String.equal (String.trim b.thinking) "") then
              Phase_thinking
            else if b.run_started then Phase_awaiting_turn
            else (
              match active_tx_opt with
              | Some { state = Drafts.Sending; _ } -> Phase_sending
              | Some { state = Drafts.Queued; _ } ->
                  Phase_queued (Int.max 1 queued_count)
              | Some { state = Drafts.Confirming_delivery; _ } ->
                  Phase_confirming
              | Some { state = Drafts.Interrupting; _ } -> Phase_interrupting
              | Some
                  {
                    state =
                      ( Drafts.Pending_processing
                      | Drafts.Delivered
                      | Drafts.Failed_retryable _ );
                    _;
                  }
              | None ->
                  Phase_awaiting_turn))
    | Some _ | None -> (
        match active_tx_opt with
        | Some { state = Drafts.Interrupting; _ } -> Phase_interrupting
        | Some { state = Drafts.Pending_processing; _ } -> Phase_awaiting_turn
        | Some { state = Drafts.Sending; _ } -> Phase_sending
        | Some { state = Drafts.Confirming_delivery; _ } -> Phase_confirming
        | Some { state = Drafts.Queued; _ } ->
            Phase_queued (Int.max 1 queued_count)
        | Some { state = Drafts.Delivered | Drafts.Failed_retryable _; _ }
        | None -> (
            match active_turn_opt with
            | Some { tool_in_flight = Some tool; _ } -> Phase_tool_running tool
            | Some { phase = Some p; _ }
              when String.equal (String.lowercase_ascii (String.trim p))
                     "thinking" ->
                Phase_thinking
            | Some _ -> Phase_awaiting_turn
            | None -> (
                let latest_unpersisted_failed =
                  Drafts.pending_txs_for_keeper ~keeper model.drafts
                  |> List.rev
                  |> List.find_map (fun (tx : Drafts.pending_message) ->
                         match tx.state with
                         | Drafts.Failed_retryable { reason } ->
                             let op =
                               Option.value tx.operation_id
                                 ~default:tx.request_id
                             in
                             if has_persisted_failure_for_op hist_msgs op then
                               None
                             else Some reason
                         | Drafts.Queued
                         | Drafts.Sending
                         | Drafts.Pending_processing
                         | Drafts.Confirming_delivery
                         | Drafts.Interrupting
                         | Drafts.Delivered ->
                             None)
                in
                match latest_unpersisted_failed with
                | Some reason -> Phase_failed reason
                | None -> (
                    match buf_opt with
                    | Some b
                      when (not b.active)
                           && not (stream_reply_already_persisted hist_msgs b)
                      -> (
                        match b.last_error with
                        | Some err -> Phase_failed err
                        | None -> Phase_idle)
                    | Some _ | None -> Phase_idle))))

let live_chat_phase_badge = function
  | Phase_idle -> None
  | Phase_sending ->
      Some
        ( Glyph.Live_working
        , Theme.Status_active
        , Say.make ~ko:"전송 중" ~en:"Sending" )
  | Phase_queued n ->
      Some
        ( Glyph.Live_working
        , Theme.Status_attention
        , Say.make
            ~ko:(if n > 1 then Printf.sprintf "대기열 %d" n else "전송 대기")
            ~en:(if n > 1 then Printf.sprintf "Queued %d" n else "Queued") )
  | Phase_awaiting_turn ->
      Some
        ( Glyph.Live_working
        , Theme.Status_active
        , Say.make ~ko:"처리 대기" ~en:"Awaiting turn" )
  | Phase_thinking ->
      Some
        ( Glyph.Ai_spark
        , Theme.Status_ai
        , Say.make ~ko:"추론 중…" ~en:"Thinking…" )
  | Phase_tool_running tool ->
      Some
        ( Glyph.Tool_square
        , Theme.Status_active
        , Say.make ~ko:("도구 실행 · " ^ tool) ~en:("Tool · " ^ tool) )
  | Phase_streaming ->
      Some
        ( Glyph.Live_working
        , Theme.Status_active
        , Say.make ~ko:"생성 중…" ~en:"Streaming…" )
  | Phase_confirming ->
      Some
        ( Glyph.Live_working
        , Theme.Status_active
        , Say.make ~ko:"전송 확인 중" ~en:"Confirming" )
  | Phase_interrupting ->
      Some
        ( Glyph.Live_paused
        , Theme.Status_attention
        , Say.make ~ko:"중단 요청 중" ~en:"Interrupting" )
  | Phase_failed _ ->
      Some
        ( Glyph.Live_failing
        , Theme.Status_critical
        , Say.make ~ko:"전송 실패" ~en:"Send failed" )

let composer_pending_tx_of_phase = function
  | Phase_idle -> Composer.Tx_idle
  | Phase_sending -> Composer.Tx_sending
  | Phase_queued n ->
      if n > 1 then Composer.Tx_queued_count n else Composer.Tx_queued
  | Phase_awaiting_turn -> Composer.Tx_awaiting_turn
  | Phase_thinking -> Composer.Tx_thinking
  | Phase_tool_running tool -> Composer.Tx_tool_running tool
  | Phase_streaming -> Composer.Tx_streaming
  | Phase_confirming -> Composer.Tx_confirming
  | Phase_interrupting -> Composer.Tx_interrupting
  | Phase_failed reason -> Composer.Tx_failed reason

let is_phase_interruptible = function
  | Phase_sending
  | Phase_awaiting_turn
  | Phase_thinking
  | Phase_tool_running _
  | Phase_streaming ->
      true
  | Phase_idle
  | Phase_queued _
  | Phase_confirming
  | Phase_interrupting
  | Phase_failed _ ->
      false

type stream_projection = {
  buf : Fleet_store.chat_stream_buffer;
  show_thinking : bool;
  show_tools : bool;
  show_text : bool;
  show_error : string option;
}

type pending_tx_projection = {
  tx : Drafts.pending_message;
  error_only : bool;
}

type transcript_section =
  | Section_history of Wire_fleet.chat_message list
  | Section_pending of pending_tx_projection list
  | Section_stream of stream_projection

let project_transcript ~(model : Model.t) ~keeper =
  let hist_msgs = history_msgs_for_keeper ~model ~keeper in
  let all_pending = Drafts.pending_txs_for_keeper ~keeper model.drafts in
  let visible_indexed =
    all_pending
    |> List.mapi (fun idx (tx : Drafts.pending_message) ->
           let op_id = Option.value tx.operation_id ~default:tx.request_id in
           match tx.state with
           | Drafts.Delivered -> None
           | Drafts.Failed_retryable _ ->
               if has_persisted_failure_for_op hist_msgs op_id then None
               else
                 let user_in_hist =
                   tx.user_persisted || has_persisted_user_for_op hist_msgs op_id
                 in
                 Some (idx, { tx; error_only = user_in_hist })
           | Drafts.Queued
           | Drafts.Sending
           | Drafts.Pending_processing
           | Drafts.Confirming_delivery
           | Drafts.Interrupting ->
               if tx.user_persisted || has_persisted_user_for_op hist_msgs op_id
               then None
               else Some (idx, { tx; error_only = false }))
    |> List.filter_map Fun.id
  in
  let stream_opt =
    match Fleet_store.String_map.find_opt keeper model.fleet.chat_streams with
    | None -> None
    | Some buf ->
        if (not buf.active) && stream_reply_already_persisted hist_msgs buf then
          None
        else
          let show_thinking =
            (not (String.equal (String.trim buf.thinking) ""))
            &&
            match model.fleet.chat_thinking_mode with
            | Fleet_store.Thinking_hidden -> false
            | Fleet_store.Thinking_folded | Fleet_store.Thinking_full -> true
          in
          let show_tools = buf.tools <> [] in
          let show_text = not (String.equal (String.trim buf.text) "") in
          let show_error =
            match buf.last_error with
            | None -> None
            | Some err ->
                let matched_by_pending =
                  List.exists
                    (fun (_, p) ->
                      String.equal p.tx.request_id buf.request_id
                      &&
                      match p.tx.state with
                      | Drafts.Failed_retryable _ -> true
                      | Drafts.Queued
                      | Drafts.Sending
                      | Drafts.Pending_processing
                      | Drafts.Confirming_delivery
                      | Drafts.Interrupting
                      | Drafts.Delivered ->
                          false)
                    visible_indexed
                in
                let superseded =
                  (not buf.active)
                  &&
                  match Drafts.active_tx_for_keeper ~keeper model.drafts with
                  | Some active_tx
                    when not (String.equal active_tx.request_id buf.request_id) ->
                      true
                  | Some _ | None -> false
                in
                if matched_by_pending || superseded then None else Some err
          in
          if
            (not show_thinking) && (not show_tools) && (not show_text)
            && Option.is_none show_error
          then None
          else Some { buf; show_thinking; show_tools; show_text; show_error }
  in
  let add_if_nonempty sec acc =
    match sec with
    | Section_history [] | Section_pending [] -> acc
    | Section_history (_ :: _) | Section_pending (_ :: _) | Section_stream _ ->
        sec :: acc
  in
  let sections_rev =
    match stream_opt with
    | None ->
        []
        |> add_if_nonempty (Section_history hist_msgs)
        |> add_if_nonempty (Section_pending (List.map snd visible_indexed))
    | Some sp ->
        let buf_idx_opt =
          Drafts.tx_position_for_keeper ~keeper ~request_id:sp.buf.request_id
            model.drafts
        in
        let before_stream, after_stream =
          match buf_idx_opt with
          | Some buf_idx ->
              let b, a =
                List.partition (fun (idx, _) -> idx <= buf_idx) visible_indexed
              in
              (List.map snd b, List.map snd a)
          | None -> ([], List.map snd visible_indexed)
        in
        []
        |> add_if_nonempty (Section_history hist_msgs)
        |> add_if_nonempty (Section_pending before_stream)
        |> add_if_nonempty (Section_stream sp)
        |> add_if_nonempty (Section_pending after_stream)
  in
  List.rev sections_rev

type viewport_geometry = {
  body_h : int;
  prose_w : int;
}

let model_breakpoint_of_layout = function
  | Layout.Wide -> Model.Wide
  | Layout.Standard -> Model.Standard
  | Layout.Compact -> Model.Compact
  | Layout.Micro -> Model.Micro

let voice_state_of_drafts (drafts : Drafts.t) =
  match drafts.voice with
  | Drafts.Voice_off | Drafts.Voice_error _ ->
      Composer.Voice_off
  | Drafts.Voice_recording { levels; elapsed_s; _ } ->
      Composer.Voice_recording { levels = Array.of_list levels; elapsed_s }
  | Drafts.Voice_transcribing -> Composer.Voice_transcribing

let keeper_content_rect_size ~embedded ~(model : Model.t) =
  let cols = Int.max 0 model.viewport.cols in
  let rows = Int.max 0 model.viewport.rows in
  let breakpoint = Layout.classify_viewport ~cols ~rows in
  let top_h = (if rows >= 1 then 1 else 0) + (if rows >= 5 then 1 else 0) in
  let footer_h = if rows >= 2 then 1 else 0 in
  let sized_model =
    {
      model with
      viewport = { cols; rows };
      breakpoint = model_breakpoint_of_layout breakpoint;
    }
  in
  let comp_mode = Model.composer_mode sized_model in
  let comp_h_raw =
    match comp_mode with
    | Model.Auto_folded_pill -> 0
    | Model.Collapsed_bar -> 1
    | Model.Expanded_multiline ->
        let max_h = Int.max 2 (Int.min 6 (rows / 4)) in
        let draft = Drafts.current_draft sized_model.drafts in
        let keeper =
          match sized_model.drafts.active_keeper with
          | Some k when not (String.equal (String.trim k) "") -> String.trim k
          | Some _ | None -> (
              match Fleet_store.selected_keeper_summary sized_model.fleet with
              | Some k -> k.name
              | None -> Drafts.target_keeper_key sized_model.drafts)
        in
        let phase = live_chat_phase ~model:sized_model ~keeper in
        let comp_st : Composer.state =
          {
            target_keeper = keeper;
            draft = draft.text;
            cursor = draft.cursor;
            focused = Drafts.is_focused sized_model.drafts;
            pending_tx = composer_pending_tx_of_phase phase;
            voice = voice_state_of_drafts sized_model.drafts;
            popup = Composer.Popup_none;
            draft_count_other_keepers =
              Drafts.other_keepers_draft_count sized_model.drafts;
          }
        in
        Composer.desired_height ~breakpoint ~max_height:max_h comp_st
  in
  let has_approval = Option.is_some (Model.fast_approval_strip_item model) in
  let avail_after_top_footer = Int.max 0 (rows - top_h - footer_h) in
  let comp_h = Int.min comp_h_raw (Int.max 0 (avail_after_top_footer - 3)) in
  let approval_h =
    if has_approval && avail_after_top_footer - comp_h >= 4 then 1 else 0
  in
  let footer_sep_h =
    if
      Layout.equal_breakpoint breakpoint Layout.Wide
      && rows >= 36
      && avail_after_top_footer - comp_h - approval_h >= 24
    then 1
    else 0
  in
  let approval_y = rows - footer_h - footer_sep_h - comp_h - approval_h in
  let body_outer_h = Int.max 0 (approval_y - top_h) in
  let body_outer =
    Layout.inset_body breakpoint
      (Rect.make ~x:0 ~y:top_h ~w:cols ~h:body_outer_h)
  in
  let target_rect =
    if
      embedded && (not model.nav.zoomed)
      && (Layout.equal_breakpoint breakpoint Layout.Wide
          || Layout.equal_breakpoint breakpoint Layout.Standard)
      && body_outer.w >= 104
    then
      let split_gap = Layout.card_gap_x breakpoint in
      let split_budget = Int.max 0 (body_outer.w - split_gap) in
      let left_w =
        Int.max 34
          (Int.min 46
             (int_of_float (Float.floor (float_of_int split_budget *. 0.36))))
      in
      match
        Layout.split_h_bp breakpoint body_outer
          [ Layout.Fixed left_w; Layout.Flex 1 ]
      with
      | [ _; right_rect ] -> right_rect
      | _ -> body_outer
    else body_outer
  in
  (* Card.draw removes 1 cell border on each side when w >= 2 && h >= 2 *)
  let card_inner_w =
    if target_rect.w >= 2 && target_rect.h >= 2 then target_rect.w - 2 else 0
  in
  let card_inner_h =
    if target_rect.w >= 2 && target_rect.h >= 2 then target_rect.h - 2 else 0
  in
  if not embedded then (card_inner_w, card_inner_h)
  else
    let has_keeper =
      Option.is_some (Fleet_store.selected_keeper_summary model.fleet)
    in
    let after_hero_h =
      if has_keeper && card_inner_h >= 16 then card_inner_h - 5
      else card_inner_h
    in
    let content_h =
      if after_hero_h >= 3 then
        let body_h1 = after_hero_h - 1 in
        if body_h1 >= 6 then body_h1 - 1 else body_h1
      else after_hero_h
    in
    (card_inner_w, Int.max 0 content_h)

let chat_viewport_geometry_for ~embedded ~(model : Model.t) =
  let cols = Int.max 0 model.viewport.cols in
  let rows = Int.max 0 model.viewport.rows in
  let breakpoint = Layout.classify_viewport ~cols ~rows in
  let card_inner_w, card_inner_h = keeper_content_rect_size ~embedded ~model in
  (* render_chat_tab reserves 1 bottom status strip when card_inner_h >= 2 *)
  let status_h = if card_inner_h >= 2 then 1 else 0 in
  let body_h = Int.max 1 (Int.max 0 (card_inner_h - status_h)) in
  let pad_x =
    if card_inner_w < 20 then 0
    else if card_inner_w < 44 then 1
    else Layout.card_pad_x breakpoint
  in
  let prose_w =
    Int.max 16 (Int.min (Int.max 16 (card_inner_w - (2 * pad_x))) 96)
  in
  { body_h; prose_w }

let chat_viewport_geometry ~(model : Model.t) =
  chat_viewport_geometry_for ~embedded:false ~model

let count_tool_output_rows ~tools_mode ~width raw =
  let shown, hidden = tool_output_display_lines ~tools_mode ~width raw in
  List.length shown + if hidden > 0 then 1 else 0

let count_markdown_rows ~theme ~width ~rail_present ~prefix text =
  let lines = markdown_body_lines ~theme ~width ~rail_present ~prefix text in
  Int.max 1 (List.length lines)

let count_transcript_rows ~(model : Model.t) ~keeper ~width =
  let theme = Theme.of_preset model.theme_preset in
  let origin_mode =
    match model.fleet.chat_origin_mode with
    | Fleet_store.Display_origin_inline ->
        if width < 56 then Fleet_store.Display_origin_row
        else Fleet_store.Display_origin_inline
    | Fleet_store.Display_origin_bare -> Fleet_store.Display_origin_bare
    | Fleet_store.Display_origin_row -> Fleet_store.Display_origin_row
  in
  let tools_mode =
    if model.fleet.chat_turn_details_expanded then Slash.Tools_full
    else model.fleet.chat_tools_mode
  in
  let expanded_tools =
    match tools_mode with
    | Slash.Tools_compact -> false
    | Slash.Tools_results | Slash.Tools_full -> true
  in
  let inline_user_prefix =
    Printf.sprintf "00:00 %s " (Glyph.to_utf8 Glyph.Prompt_caret)
  in
  let inline_asst_prefix =
    Printf.sprintf "00:00 %s " (Glyph.to_utf8 Glyph.Live_healthy)
  in
  let cut_replies = Fleet_store.cut_replies_by_row ~keeper model.fleet in
  let count_history hist_msgs =
    let _, total =
      List.fold_left
        (fun (first, acc) (msg : Wire_fleet.chat_message) ->
          let spacing = if first then 0 else 1 in
          let msg_r =
            match msg.role with
            | Wire_fleet.Role_user ->
                let hdr =
                  match origin_mode with
                  | Fleet_store.Display_origin_inline -> 0
                  | Fleet_store.Display_origin_bare
                  | Fleet_store.Display_origin_row ->
                      1
                in
                let prefix =
                  match origin_mode with
                  | Fleet_store.Display_origin_inline -> inline_user_prefix
                  | Fleet_store.Display_origin_bare
                  | Fleet_store.Display_origin_row ->
                      "  "
                in
                hdr
                + count_markdown_rows ~theme ~width ~rail_present:true ~prefix
                    msg.content
            | Wire_fleet.Role_peer _ ->
                (* Keeper_dive names the author on a header row in every
                   origin mode and draws the body with a rail and "  ". *)
                1
                + count_markdown_rows ~theme ~width ~rail_present:true
                    ~prefix:"  " msg.content
            | Wire_fleet.Role_assistant ->
                let hdr =
                  match origin_mode with
                  | Fleet_store.Display_origin_inline -> 0
                  | Fleet_store.Display_origin_bare
                  | Fleet_store.Display_origin_row ->
                      1
                in
                let prefix =
                  match origin_mode with
                  | Fleet_store.Display_origin_inline -> inline_asst_prefix
                  | Fleet_store.Display_origin_bare
                  | Fleet_store.Display_origin_row ->
                      "  "
                in
                let rail_present =
                  match origin_mode with
                  | Fleet_store.Display_origin_row -> true
                  | Fleet_store.Display_origin_bare
                  | Fleet_store.Display_origin_inline ->
                      false
                in
                hdr
                + count_markdown_rows ~theme ~width ~rail_present ~prefix
                    msg.content
            | Wire_fleet.Role_system ->
                1
                + count_markdown_rows ~theme ~width ~rail_present:true
                    ~prefix:"  " msg.content
            | Wire_fleet.Role_tool ->
                1
                +
                if expanded_tools then
                  count_tool_output_rows ~tools_mode ~width msg.content
                else 0
            | Wire_fleet.Role_request_failure ->
                let cut_reply_r =
                  match Fleet_store.String_map.find_opt msg.id cut_replies with
                  | Some text ->
                      1
                      + count_markdown_rows ~theme ~width ~rail_present:true
                          ~prefix:"  " text
                  | None -> 0
                in
                1
                + count_markdown_rows ~theme ~width ~rail_present:true
                    ~prefix:"  " msg.content
                + cut_reply_r
          in
          (false, acc + spacing + msg_r))
        (true, 0) hist_msgs
    in
    total
  in
  let count_stream (sp : stream_projection) =
    let buf = sp.buf in
    let think_r =
      if not sp.show_thinking then 0
      else
        match model.fleet.chat_thinking_mode with
        | Fleet_store.Thinking_hidden -> 0
        | Fleet_store.Thinking_folded -> 1
        | Fleet_store.Thinking_full ->
            1
            + List.length
                (wrap_plain_lines ~width:(Int.max 12 (width - 6)) buf.thinking)
    in
    let tools_r =
      if not sp.show_tools then 0
      else
        List.fold_left
          (fun acc (tc : Fleet_store.active_tool_call) ->
            let det =
              match expanded_tools, tc.output_preview with
              | true, Some out -> count_tool_output_rows ~tools_mode ~width out
              | false, _ | true, None -> 0
            in
            acc + 1 + det)
          0 buf.tools
    in
    let text_r =
      if not sp.show_text then 0
      else
        1
        + count_markdown_rows ~theme ~width ~rail_present:false ~prefix:"  "
            buf.text
    in
    let err_r = match sp.show_error with Some _ -> 1 | None -> 0 in
    think_r + tools_r + text_r + err_r
  in
  let sections = project_transcript ~model ~keeper in
  let _, total =
    List.fold_left
      (fun (first, acc) sec ->
        let rows =
          match sec with
          | Section_history msgs -> count_history msgs
          | Section_pending txs -> List.length txs
          | Section_stream sp -> count_stream sp
        in
        if rows = 0 then (first, acc)
        else
          let sep = if first then 0 else 1 in
          (false, acc + sep + rows))
      (true, 0) sections
  in
  total

let max_scroll_for_model_in ~embedded ~(model : Model.t) ~keeper =
  let { body_h; prose_w } = chat_viewport_geometry_for ~embedded ~model in
  let total = count_transcript_rows ~model ~keeper ~width:prose_w in
  Int.max 0 (total - body_h)

let max_scroll_for_model ~(model : Model.t) ~keeper =
  max_scroll_for_model_in ~embedded:false ~model ~keeper
