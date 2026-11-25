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

let is_horiz_ws = function ' ' | '\t' -> true | _ -> false
let is_ascii_ws = function ' ' | '\t' | '\n' | '\r' -> true | _ -> false

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

(* Horizontal whitespace plus at most one single line break (\r\n | \n | \r)
   and following horizontal whitespace. Stops before a second line break so a
   blank-line paragraph break (\n\n, \r\n\r\n, \n \n) never pulls prose on the
   next paragraph into a preceding secret key or Bearer token. *)
let scan_sep_ws s from =
  let len = String.length s in
  let j = scan_while s is_horiz_ws from in
  if j >= len then j
  else if Char.equal s.[j] '\r' then
    let after_nl =
      if j + 1 < len && Char.equal s.[j + 1] '\n' then j + 2 else j + 1
    in
    scan_while s is_horiz_ws after_nl
  else if Char.equal s.[j] '\n' then
    scan_while s is_horiz_ws (j + 1)
  else j

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
                  if
                    prev_ok
                    && starts_at_ci raw i "bearer"
                    && i + 6 < len
                    && is_ascii_ws raw.[i + 6]
                  then begin
                    let val_start = scan_sep_ws raw (i + 6) in
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
                        scan_while raw is_horiz_ws after_q
                      in
                      if
                        sep_pos < len
                        && (Char.equal raw.[sep_pos] ':'
                            || Char.equal raw.[sep_pos] '=')
                      then begin
                        let val_start = scan_sep_ws raw (sep_pos + 1) in
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
                          if val_end = val_start then loop val_start
                          else
                            let first_tok =
                              String.sub raw val_start (val_end - val_start)
                            in
                            if is_http_auth_scheme first_tok then begin
                              let ws_end = scan_sep_ws raw val_end in
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

let tool_call_tree_cache_mu = Stdlib.Mutex.create ()
let tool_call_tree_cache :
    (Wire_keeper_context.tool_call_entry
     * Wire_keeper_context.tool_result_response option
     * Json_tree.line list)
    option
    ref =
  ref None

let tool_output_display_lines_uncached ~(theme : Theme.t) ~tools_mode ~width raw =
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
    let style =
      Style.make ~fg:(Color.of_rgb theme.text_secondary)
        ~bg:(Color.of_rgb theme.surface_0) ()
    in
    let literal text =
      let text = String.concat "    " (String.split_on_char '\t' text) in
      Markdown.render_literal ~width:body_w ~base_style:style text
    in
    let artifact_lines (artifact : Tool_output.artifact_ref) =
      let preview = scrub_secrets_in_text artifact.preview in
      let reference = Tool_output.with_preview artifact "" in
      let original =
        Tool_output.encode_for_agent_core (Stored reference)
        |> scrub_secrets_in_text |> literal
      in
      let mime =
        Tool_blob_media_store.blob_mime artifact.mime |> String.lowercase_ascii
      in
      let preview_lines =
        if String.equal preview "" then []
        else if String.equal mime "text/markdown" then
          Markdown.render_lines ~theme ~width:body_w ~base_style:style preview
        else literal preview
      in
      original @ preview_lines
    in
    let all_lines =
      match Yojson.Safe.from_string trimmed with
      | json -> (
          match Tool_output.normalized_artifact_ref_of_json json with
          | Decoded_normalized_artifact_ref artifact -> artifact_lines artifact
          | Not_normalized_artifact_ref | Invalid_normalized_artifact_ref _ ->
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
                let text =
                  match ln.key with
                  | Some k -> Printf.sprintf "%s%s: %s" ind k vs
                  | None -> ind ^ vs
                in
                ({ spans = [ { text; style; hyperlink = None } ]; image_part = None } : Markdown.rendered_line))
              flat)
      | exception Yojson.Json_error _ ->
          (match Tool_output.decode_from_agent_core raw with
          | Decoded artifact -> artifact_lines artifact
          | Not_marker | Invalid_marker _ -> literal (scrub_secrets_in_text raw))
    in
    let shown = List.take max_preview all_lines in
    let hidden = List.length all_lines - List.length shown in
    (shown, hidden)

let same_tool_result_opt a b =
  match (a, b) with
  | None, None -> true
  | Some x, Some y -> x == y
  | None, Some _ | Some _, None -> false

let flattened_tool_call_lines (st : Keeper_context_store.keeper_state)
    (call : Wire_keeper_context.tool_call_entry) : Json_tree.line list =
  let res_opt = Keeper_context_store.tool_result_for_selected_call st in
  let cached =
    Stdlib.Mutex.protect tool_call_tree_cache_mu (fun () ->
        match !tool_call_tree_cache with
        | Some (prev_call, prev_res, lines)
          when prev_call == call && same_tool_result_opt prev_res res_opt ->
            Some lines
        | Some _ | None -> None)
  in
  match cached with
  | Some lines -> lines
  | None ->
      let output_json =
        match res_opt with
        | Some (Wire_keeper_context.Tool_result_page p) -> (
            match Yojson.Safe.from_string p.content with
            | j -> Wire_keeper_context.unfold_json_strings j
            | exception Yojson.Json_error _ -> `String p.content)
        | Some Wire_keeper_context.Tool_result_pending ->
            `String "(tool result pending)"
        | Some (Wire_keeper_context.Tool_result_unavailable r) ->
            `String ("(unavailable: " ^ r ^ ")")
        | None -> (
            match Yojson.Safe.from_string call.output with
            | j -> Wire_keeper_context.unfold_json_strings j
            | exception Yojson.Json_error _ -> `String call.output)
      in
      let unfolded_in = Wire_keeper_context.unfold_json_strings call.input in
      let tree_json =
        scrub_json_secrets
          (`Assoc [ ("input", unfolded_in); ("output", output_json) ])
      in
      let lines =
        Json_tree.flatten ~max_depth:5 ~redact_secrets:true tree_json
      in
      Stdlib.Mutex.protect tool_call_tree_cache_mu (fun () ->
          tool_call_tree_cache := Some (call, res_opt, lines));
      lines

let max_render_cache_entries = 512

let tool_output_cache_mu = Stdlib.Mutex.create ()
let tool_output_cache :
    (string * Theme.t * Slash.tools_mode * int,
     Markdown.rendered_line list * int) Hashtbl.t =
  Hashtbl.create 128

let tool_output_display_lines ~(theme : Theme.t) ~tools_mode ~width raw =
  let key = (raw, theme, tools_mode, width) in
  match
    Stdlib.Mutex.protect tool_output_cache_mu (fun () ->
        Hashtbl.find_opt tool_output_cache key)
  with
  | Some hit -> hit
  | None ->
      let result = tool_output_display_lines_uncached ~theme ~tools_mode ~width raw in
      Stdlib.Mutex.protect tool_output_cache_mu (fun () ->
          if String.length raw <= 524_288 then begin
            if Hashtbl.length tool_output_cache >= max_render_cache_entries then
              Hashtbl.clear tool_output_cache;
            Hashtbl.replace tool_output_cache key result
          end);
      result

(* [Markdown.render_lines] owns the bounded mutex-protected render cache so
   chat messages are not retained in two separate global tables. *)

let thinking_body_lines ~(theme : Theme.t) ~width text =
  Markdown.render_lines ~theme ~width:(Int.max 12 (width - 6))
    ~base_style:(Typography.whisper theme) text

let markdown_body_lines ~theme ~width ~rail_present ~prefix text =
  let rail_w = if rail_present then 2 else 0 in
  let body_w = Int.max 10 (width - rail_w - Grapheme.display_width prefix) in
  let rewritten = rewrite_masc_links_for_markdown text in
  Markdown.render_lines ~theme ~width:body_w ~osc8:true rewritten

let retained_image_height ~(model : Model.t) ~keeper ~width =
  let fresh =
    Fleet_store.String_map.find_opt keeper model.fleet.chat_histories
    |> Option.exists (fun history -> Observed.is_value history && not (Observed.is_stale history))
  in
  match (Probe.current_observation ()).graphics with
  | Some Graphics_supported when fresh && width >= 16 -> 6
  | Some Graphics_supported | Some (Graphics_refused _) | None -> 1

let retained_image_rows ~(theme : Theme.t) ~lang ~width ~height images =
  List.concat_map
    (fun ({ media_path; caption } : Wire_fleet.retained_image) ->
      let name = Option.value caption ~default:(Say.resolve lang (Say.make ~ko:"생성 이미지" ~en:"Generated image")) in
      let text = Grapheme.truncate_to_width ~max_width:(Int.max 1 (width - 4)) name in
      let spans = [ { Markdown.text; style = Typography.whisper theme; hyperlink = None } ] in
      let count = height - 1 in
      let rows : Cell_grid.document_image_rows = { source = Retained_png media_path; count } in
      { Markdown.spans; image_part = None }
      :: List.init count (fun index ->
             { Markdown.spans = []; image_part = Some { rows; index; left_inset = 0 } }))
    images

let stream_reply_already_persisted (hist_msgs : Wire_fleet.chat_message list)
    (buf : Fleet_store.chat_stream_buffer) =
  let buf_op_id = Option.value buf.operation_id ~default:buf.request_id in
  List.exists
    (fun row -> Option.equal String.equal (Wire_fleet.terminal_operation row) (Some buf_op_id))
    hist_msgs

type live_chat_phase =
  | Phase_idle
  | Phase_sending
  | Phase_queued of int
  | Phase_awaiting_turn
  | Phase_thinking
  | Phase_tool_running of string
  | Phase_tool_waiting of string
  | Phase_streaming
  | Phase_turn_running of {
      turn : Wire_fleet.active_turn;
      queued_count : int;
    }
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
  | Phase_tool_waiting x, Phase_tool_waiting y
  | Phase_tool_running x, Phase_tool_running y
  | Phase_failed x, Phase_failed y ->
      String.equal x y
  | Phase_turn_running x, Phase_turn_running y ->
      Wire_fleet.equal_active_turn x.turn y.turn
      && Int.equal x.queued_count y.queued_count
  | ( ( Phase_idle
      | Phase_sending
      | Phase_queued _
      | Phase_awaiting_turn
      | Phase_thinking
      | Phase_tool_running _
      | Phase_tool_waiting _
      | Phase_streaming
      | Phase_turn_running _
      | Phase_confirming
      | Phase_interrupting
      | Phase_failed _ )
    , ( Phase_idle
      | Phase_sending
      | Phase_queued _
      | Phase_awaiting_turn
      | Phase_thinking
      | Phase_tool_running _
      | Phase_tool_waiting _
      | Phase_streaming
      | Phase_turn_running _
      | Phase_confirming
      | Phase_interrupting
      | Phase_failed _ ) ) -> false

let turn_lane_label = function
  | Wire_fleet.Lane_chat -> Say.make ~ko:"대화" ~en:"chat"
  | Wire_fleet.Lane_proactive -> Say.make ~ko:"자율" ~en:"auto"
  | Wire_fleet.Lane_schedule -> Say.make ~ko:"일정" ~en:"schedule"
  | Wire_fleet.Lane_board -> Say.make ~ko:"보드" ~en:"board"
  | Wire_fleet.Lane_task -> Say.make ~ko:"작업" ~en:"task"
  | Wire_fleet.Lane_verification -> Say.make ~ko:"검증" ~en:"verify"
  | Wire_fleet.Lane_maintenance -> Say.make ~ko:"점검" ~en:"maint"
  | Wire_fleet.Lane_internal -> Say.make ~ko:"내부" ~en:"internal"

let preparation_phase_label = function
  | Wire_fleet.Prep_task -> Say.make ~ko:"작업" ~en:"task"
  | Wire_fleet.Prep_world -> Say.make ~ko:"월드" ~en:"world"
  | Wire_fleet.Prep_context -> Say.make ~ko:"컨텍스트" ~en:"context"
  | Wire_fleet.Prep_prompt -> Say.make ~ko:"프롬프트" ~en:"prompt"
  | Wire_fleet.Prep_tools -> Say.make ~ko:"도구" ~en:"tools"
  | Wire_fleet.Prep_skills -> Say.make ~ko:"스킬" ~en:"skills"
  | Wire_fleet.Prep_lane_inputs -> Say.make ~ko:"레인 입력" ~en:"lane inputs"
  | Wire_fleet.Prep_workspace_memory ->
      Say.make ~ko:"작업공간 기억" ~en:"workspace memory"
  | Wire_fleet.Prep_wiki -> Say.make ~ko:"위키" ~en:"wiki"

let preview_with_last_tool (p : Wire_fleet.turn_preview) label =
  match p.last_tool with
  | Some tool ->
      Say.concat ~sep:" · "
        [ label; Say.make ~ko:("최근 도구: " ^ tool) ~en:("Last tool: " ^ tool) ]
  | None -> label

let preview_short_activity (p : Wire_fleet.turn_preview) =
  match p.preparation with
  | Some { phase; state = Wire_fleet.Prep_active; _ } ->
      let ph = preparation_phase_label phase in
      Say.make ~ko:("준비 · " ^ ph.ko) ~en:("Prep · " ^ ph.en)
  | Some { phase; state = Wire_fleet.Prep_prepared; _ } ->
      let ph = preparation_phase_label phase in
      Say.make ~ko:(ph.ko ^ " 준비 완료") ~en:(ph.en ^ " ready")
  | Some
      {
        phase;
        state =
          ( Wire_fleet.Prep_rejected
          | Wire_fleet.Prep_raised
          | Wire_fleet.Prep_cancelled );
        _;
      } ->
      let ph = preparation_phase_label phase in
      Say.make ~ko:(ph.ko ^ " 준비 중단") ~en:(ph.en ^ " halted")
  | None -> (
      match p.activity with
      | Wire_fleet.Preview_preparing ->
          Say.make ~ko:"턴 준비 중" ~en:"Preparing"
      | Wire_fleet.Preview_waiting ->
          preview_with_last_tool p
            (Say.make ~ko:"모델 응답 대기" ~en:"Waiting for model")
      | Wire_fleet.Preview_streaming ->
          preview_with_last_tool p
            (Say.make ~ko:"응답 수신" ~en:"Response activity")
      | Wire_fleet.Preview_tool_observed -> (
          match p.last_tool with
          | Some tool ->
              Say.make ~ko:("최근 도구 · " ^ tool) ~en:("Last tool · " ^ tool)
          | None -> Say.make ~ko:"도구 활동" ~en:"Tool activity")
      | Wire_fleet.Preview_failed ->
          Say.make ~ko:"시도 실패" ~en:"Attempt failed")

let active_turn_short_activity (turn : Wire_fleet.active_turn) =
  match turn.tool_in_flight with
  | Some tool ->
      Say.make ~ko:("도구 사용 중 · " ^ tool) ~en:("Using tool · " ^ tool)
  | None -> (
      match turn.preview with
      | Some p -> preview_short_activity p
      | None -> (
          match turn.phase with
          | Some p
            when String.equal (String.lowercase_ascii (String.trim p)) "thinking"
            ->
              Say.make ~ko:"추론 중…" ~en:"Thinking…"
          | Some p -> Say.literal p
          | None -> Say.make ~ko:"진행 중" ~en:"Running"))

let fresh_turn_state ~(model : Model.t) ~keeper =
  match model.fleet.turns with
  | Observed.Value { data; stale = false; _ } ->
      List.find_map
        (fun (row : Wire_fleet.keeper_turn_row) ->
          if String.equal row.keeper_name keeper then Some row.state else None)
        data
  | Observed.Value { stale = true; _ } | Observed.Loading _
  | Observed.Absent | Observed.Unreported | Observed.Failed _ -> None

let live_turn_observed ~model ~keeper (turn : Wire_fleet.active_turn) =
  match fresh_turn_state ~model ~keeper with
  | Some (Wire_fleet.Turn_active observed) ->
      String.equal observed.interrupt_token turn.interrupt_token
  | Some (Wire_fleet.Turn_idle | Wire_fleet.Turn_unavailable _) | None -> false

let active_turn_for_progress ~(model : Model.t) ~keeper =
  match fresh_turn_state ~model ~keeper with
  | Some (Wire_fleet.Turn_active turn) -> Some turn
  | Some Wire_fleet.Turn_idle -> None
  | Some (Wire_fleet.Turn_unavailable _) | None ->
      Fleet_store.active_turn_for ~keeper model.fleet

let animation_frames_per_second = 8

let reduce_motion (model : Model.t) =
  Observed.to_option model.config.preferences
  |> Option.exists (fun (prefs : Wire_config.tui_preferences) ->
         Option.value prefs.reduce_motion ~default:false)

let progress_glyph (model : Model.t) =
  let wall = model.freshness.last_wall_unix in
  let frame =
    if reduce_motion model || not (Float.is_finite wall) then 0
    else Int.of_float (mod_float wall 1.0 *. float animation_frames_per_second)
  in
  Glyph.Live_working_frame frame

let format_elapsed seconds =
  Say.literal
    (if seconds < 60 then Printf.sprintf "%ds" seconds
     else if seconds < 3600 then Printf.sprintf "%dm %02ds" (seconds / 60) (seconds mod 60)
     else Printf.sprintf "%dh %02dm" (seconds / 3600) (seconds mod 3600 / 60))

let worked_badge ~(model : Model.t) ~keeper =
  Fleet_store.String_map.find_opt keeper model.fleet.worked
  |> Option.map (fun (_, elapsed_ms) ->
       ( Glyph.Check_mark, Theme.Status_ok,
         Say.concat ~sep:" · "
           [ Say.literal "Worked"; format_elapsed (elapsed_ms / 1000);
             Say.make ~ko:"최근 성공" ~en:"Last success" ] ))

let started_chat_wait_badge ~(model : Model.t) ~keeper =
  match Fleet_store.String_map.find_opt keeper model.fleet.chat_streams with
  | Some stream when stream.active && stream.run_started ->
      Some (progress_glyph model, Theme.Status_ai,
            Say.make ~ko:"응답 대기" ~en:"Waiting for response")
  | Some _ | None -> None

let active_turn_duration ~(model : Model.t) (turn : Wire_fleet.active_turn) =
  let wall = model.freshness.last_wall_unix in
  if turn.started_at_unix <= 0.0 || wall < turn.started_at_unix
     || not (Float.is_finite turn.started_at_unix && Float.is_finite wall)
  then None
  else Some (format_elapsed (Int.of_float (wall -. turn.started_at_unix)))

let observed_turn_label ~model ~live (turn : Wire_fleet.active_turn) =
  let lane =
    if Wire_fleet.equal_turn_lane turn.lane Wire_fleet.Lane_proactive
    then Say.make ~ko:"자율 실행" ~en:"Background turn"
    else turn_lane_label turn.lane
  in
  let activity = active_turn_short_activity turn in
  let parts =
    if live then
      activity :: lane :: Option.to_list (active_turn_duration ~model turn)
    else
      [ Say.make ~ko:"마지막 확인" ~en:"Last observed"; lane; activity ]
  in
  Say.concat ~sep:" · " parts

let turn_running_kind_of_turn (turn : Wire_fleet.active_turn) =
  match turn.tool_in_flight with
  | Some _ -> Composer.Turn_kind_tool
  | None -> (
      match turn.preview with
      | None -> Composer.Turn_kind_active
      | Some p -> (
          match p.preparation with
          | Some
              {
                state =
                  ( Wire_fleet.Prep_rejected
                  | Wire_fleet.Prep_raised
                  | Wire_fleet.Prep_cancelled );
                _;
              } ->
              Composer.Turn_kind_attention
          | Some { state = Wire_fleet.Prep_active | Wire_fleet.Prep_prepared; _ }
            ->
              Composer.Turn_kind_active
          | None -> (
              match p.activity with
              | Wire_fleet.Preview_tool_observed -> Composer.Turn_kind_tool
              | Wire_fleet.Preview_failed -> Composer.Turn_kind_attention
              | Wire_fleet.Preview_preparing
              | Wire_fleet.Preview_waiting
              | Wire_fleet.Preview_streaming ->
                  Composer.Turn_kind_active)))

let observed_turn_badge ~model ~keeper (turn : Wire_fleet.active_turn) =
  let live = live_turn_observed ~model ~keeper turn in
  let label = observed_turn_label ~model ~live turn in
  if Fleet_store.is_turn_interrupting ~keeper
       ~interrupt_token:turn.interrupt_token model.fleet
  then
    Glyph.Live_paused, Theme.Status_attention,
    Say.concat ~sep:" · "
      [ Say.make ~ko:"중단 요청 중" ~en:"Interrupting"; turn_lane_label turn.lane ]
  else
    match turn_running_kind_of_turn turn with
    | Composer.Turn_kind_attention -> Glyph.Action_required, Theme.Status_attention, label
    | Composer.Turn_kind_active | Composer.Turn_kind_tool ->
        if live then
          let tone =
            match turn.tool_in_flight, turn.preview with
            | None, Some { activity = Wire_fleet.Preview_waiting | Wire_fleet.Preview_preparing; _ } ->
                Theme.Status_ai
            | Some _, _
            | None, Some { activity = Wire_fleet.Preview_streaming | Wire_fleet.Preview_tool_observed
                                    | Wire_fleet.Preview_failed; _ }
            | None, None -> Theme.Status_active
          in
          progress_glyph model, tone, label
        else Glyph.Live_idle, Theme.Status_historical, label

let start_reason_label = function
  | "mention_pending" -> Say.make ~ko:"멘션 도착" ~en:"Mention received"
  | "board_event_pending" -> Say.make ~ko:"보드 이벤트" ~en:"Board event"
  | "scope_message_pending" -> Say.make ~ko:"범위 메시지" ~en:"Scope message"
  | "bootstrap_stimulus_pending" | "never_started" ->
      Say.make ~ko:"첫 실행" ~en:"First run"
  | "tool_result_ready_pending" -> Say.make ~ko:"도구 결과 도착" ~en:"Tool result ready"
  | "connector_attention_pending" -> Say.make ~ko:"연동 이벤트" ~en:"Connector event"
  | "ask_answered_pending" -> Say.make ~ko:"질문 답변 도착" ~en:"Answer received"
  | "hitl_resolved_pending" -> Say.make ~ko:"도구 승인 결정" ~en:"Tool approval decision"
  | "completion_authority_rejection_pending" ->
      Say.make ~ko:"완료 증거 반려" ~en:"Completion evidence rejected"
  | "task_outcome_pending" -> Say.make ~ko:"Task 결과 도착" ~en:"Task outcome received"
  | "task_cancellation_pending" -> Say.make ~ko:"Task 취소" ~en:"Task cancelled"
  | "workspace_message_pending" -> Say.make ~ko:"작업공간 메시지" ~en:"Workspace message"
  | "deferred_runtime_lane_pending" -> Say.make ~ko:"보류한 실행 재개" ~en:"Deferred run resumed"
  | "scheduled_autonomous_turn" -> Say.make ~ko:"자율 실행 주기" ~en:"Autonomous cadence"
  | "scheduled_automation_due" -> Say.make ~ko:"예약 작업 도래" ~en:"Scheduled work due"
  | "task_backlog" -> Say.make ~ko:"대기 중인 Task" ~en:"Task backlog"
  | reason -> Say.literal reason

type keeper_work_row =
  | Work_status of (Glyph.t * Theme.status_token * Say.t)
  | Work_detail of Say.t

let keeper_work_overview ~(model : Model.t) ~keeper =
  let labeled ~ko ~en text = Say.concat ~sep:"  " [ Say.make ~ko ~en; text ] in
  let turn = active_turn_for_progress ~model ~keeper in
  let work_context =
    Option.bind turn (fun (turn : Wire_fleet.active_turn) ->
      Option.bind turn.preview (fun preview -> preview.work_context))
  in
  let assignment =
    Option.map (fun (summary : Wire_fleet.keeper_summary) -> summary.current_task_id)
      (Fleet_store.find_keeper ~name:keeper model.fleet)
  in
  let start_task_label = Say.make ~ko:"시작 시 Task" ~en:"Task at start" in
  let observed_task =
    match assignment, work_context with
    | Some id, _ -> Some (id, Say.make ~ko:"할당 Task" ~en:"Assigned Task")
    | None, Some work -> Some (work.task_id, start_task_label)
    | None, None -> None
  in
  let task_rows =
    match observed_task with
    | None -> []
    | Some (None, label) ->
        [ Say.concat ~sep:"  " [ label; Say.make ~ko:"없음" ~en:"None" ] ]
    | Some (Some id, label) ->
        let task = List.find_opt (fun (task : Wire_work.task) -> String.equal task.id id)
            (Work_store.tasks model.work) in
        let task_text = match task with
          | Some task -> id ^ " · " ^ task.title
          | None -> id
        in
        let goal =
          match task with
          | None -> Say.make ~ko:"Task 상세 미확인" ~en:"Task details unavailable"
          | Some { goal_link = Wire_work.Unlinked; _ } ->
              Say.make ~ko:"연결 없음" ~en:"No link"
          | Some { goal_link = Wire_work.Linked id; _ } ->
              let goal = List.find_opt (fun (goal : Wire_work.goal) -> String.equal goal.id id)
                  (Work_store.goals model.work) in
              Say.literal (Option.fold ~none:id ~some:(fun (goal : Wire_work.goal) ->
                id ^ " · " ^ goal.title) goal)
        in
        [ Say.concat ~sep:"  " [ label; Say.literal task_text ];
          labeled ~ko:"연결 Goal" ~en:"Linked Goal" goal ]
  in
  let task_rows =
    match assignment, work_context with
    | Some current, Some work when not (Option.equal String.equal current work.task_id) ->
        let at_start =
          Option.fold ~none:(Say.make ~ko:"없음" ~en:"None") ~some:Say.literal work.task_id
        in
        task_rows @ [ Say.concat ~sep:"  " [ start_task_label; at_start ] ]
    | (Some _ | None), (Some _ | None) -> task_rows
  in
  match turn with
  | None ->
      let details = List.map (fun detail -> Work_detail detail) task_rows in
      let status =
        match started_chat_wait_badge ~model ~keeper with
        | Some _ as status -> status
        | None -> worked_badge ~model ~keeper
      in
      (match status with Some badge -> Work_status badge :: details | None -> details)
  | Some turn ->
      let starts =
        match work_context with
        | Some { start_reasons = first :: rest; _ } ->
            labeled ~ko:"시작 계기" ~en:"Started by" (start_reason_label first)
            :: List.map (fun reason ->
                 Say.concat ~sep:" " [ Say.literal "  ·"; start_reason_label reason ]) rest
        | Some { start_reasons = []; _ } | None ->
            let source =
              if Wire_fleet.equal_turn_lane turn.lane Wire_fleet.Lane_chat then
                Say.make ~ko:"대화 요청" ~en:"Chat request"
              else Say.make ~ko:"이 턴의 시작 이벤트 미확인" ~en:"Start event unobserved"
            in
            [ labeled ~ko:"시작 계기" ~en:"Started by" source ]
      in
      Work_status (observed_turn_badge ~model ~keeper turn)
      :: List.map (fun detail -> Work_detail detail) (starts @ task_rows)

let normalize_preview_inline s =
  String.trim
    (String.map (function '\n' | '\r' | '\t' -> ' ' | c -> c)
       (scrub_secrets_in_text s))

let extract_preview_failure_detail status_text =
  let clean = normalize_preview_inline status_text in
  let needle = "last failure: " in
  let nlen = String.length needle in
  let clen = String.length clean in
  let rec find idx =
    if idx + nlen > clen then None
    else if String.equal (String.sub clean idx nlen) needle then
      let rest =
        String.trim (String.sub clean (idx + nlen) (clen - idx - nlen))
      in
      if String.equal rest "" then None else Some rest
    else find (idx + 1)
  in
  find 0

let active_turn_detail_summary (turn : Wire_fleet.active_turn) =
  let lane_say = turn_lane_label turn.lane in
  let act_say =
    match turn.tool_in_flight with
    | Some tool ->
        Say.make ~ko:("도구 실행 · " ^ tool) ~en:("Tool · " ^ tool)
    | None -> (
        match turn.preview with
        | Some p -> (
            match p.preparation with
            | Some { phase; state = Wire_fleet.Prep_active; _ } ->
                let ph = preparation_phase_label phase in
                Say.make ~ko:("준비 중 · " ^ ph.ko) ~en:("Preparing · " ^ ph.en)
            | Some { phase; state = Wire_fleet.Prep_prepared; _ } ->
                let ph = preparation_phase_label phase in
                Say.make ~ko:(ph.ko ^ " 준비 완료") ~en:(ph.en ^ " prepared")
            | Some
                {
                  phase;
                  state =
                    ( Wire_fleet.Prep_rejected
                    | Wire_fleet.Prep_raised
                    | Wire_fleet.Prep_cancelled );
                  _;
                } ->
                let ph = preparation_phase_label phase in
                Say.make ~ko:(ph.ko ^ " 준비 중단") ~en:(ph.en ^ " prep halted")
            | None -> (
                match p.activity with
                | Wire_fleet.Preview_preparing ->
                    Say.make ~ko:"턴 준비 중" ~en:"Preparing turn"
                | Wire_fleet.Preview_waiting ->
                    preview_with_last_tool p
                      (Say.make ~ko:"응답 대기 중" ~en:"Waiting for model")
                | Wire_fleet.Preview_streaming ->
                    preview_with_last_tool p
                      (Say.make ~ko:"응답 수신" ~en:"Response activity")
                | Wire_fleet.Preview_tool_observed -> (
                    match p.last_tool with
                    | Some tool ->
                        Say.make
                          ~ko:("도구 활동 · " ^ tool)
                          ~en:("Tool activity · " ^ tool)
                    | None -> Say.make ~ko:"도구 활동 중" ~en:"Tool activity")
                | Wire_fleet.Preview_failed -> (
                    match extract_preview_failure_detail p.status_text with
                    | Some detail ->
                        Say.make
                          ~ko:("시도 실패 · " ^ detail)
                          ~en:("Attempt failed · " ^ detail)
                    | None -> (
                        match p.last_tool with
                        | Some tool ->
                            Say.make
                              ~ko:("시도 실패 · 최근 도구: " ^ tool)
                              ~en:("Attempt failed · last tool: " ^ tool)
                        | None ->
                            Say.make ~ko:"시도 실패" ~en:"Attempt failed"))))
        | None -> (
            match turn.phase with
            | Some p
              when String.equal
                     (String.lowercase_ascii (String.trim p))
                     "thinking" ->
                Say.make ~ko:"추론 중…" ~en:"Thinking…"
            | Some p -> Say.literal p
            | None -> Say.make ~ko:"진행 중" ~en:"Running"))
  in
  Say.concat ~sep:" · " [ lane_say; act_say ]

let active_turn_preview_tail (turn : Wire_fleet.active_turn) =
  match turn.preview with
  | None -> None
  | Some p ->
      let clean = normalize_preview_inline p.text_tail in
      if String.equal clean "" then None else Some clean

let turn_running_badge_label ~(turn : Wire_fleet.active_turn) ~queued_count =
  let lane_say = turn_lane_label turn.lane in
  let act_say = active_turn_short_activity turn in
  let observed = Say.make ~ko:"최근 확인" ~en:"Last observed" in
  let base = Say.concat ~sep:" · " [ observed; act_say; lane_say ] in
  if queued_count > 0 then
    Say.concat ~sep:" · "
      [
        base;
        Say.make
          ~ko:(Printf.sprintf "대기 %d" queued_count)
          ~en:(Printf.sprintf "queued %d" queued_count);
      ]
  else base

let history_msgs_for_keeper ~(model : Model.t) ~keeper =
  match Fleet_store.String_map.find_opt keeper model.fleet.chat_histories with
  | None -> []
  | Some obs -> (
      match Observed.to_option obs with
      | Some page -> page.messages
      | None -> [])

let has_persisted_failure_for_op hist_msgs op_id =
  List.exists
    (fun (row : Wire_fleet.chat_message) ->
       row.role = Wire_fleet.Role_request_failure
       && Option.equal String.equal (Wire_fleet.terminal_operation row) (Some op_id))
    hist_msgs

let has_persisted_user_for_op hist_msgs op_id ~body =
  List.exists
    (fun row -> Option.equal String.equal (Wire_fleet.accepted_input_operation row) (Some op_id)
                && String.equal row.content body)
    hist_msgs

let live_chat_phase ~(model : Model.t) ~keeper =
  let hist_msgs = history_msgs_for_keeper ~model ~keeper in
  let buf_opt = Fleet_store.String_map.find_opt keeper model.fleet.chat_streams in
  let active_tx_opt = Drafts.active_tx_for_keeper ~keeper model.drafts in
  let queued_count = Drafts.queued_count_for_keeper ~keeper model.drafts in
  let active_turn_opt = active_turn_for_progress ~model ~keeper in
  let local_interrupting =
    match buf_opt with
    | Some b when b.active -> b.interrupting
    | Some _ | None -> (
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
                | Drafts.No_operation_record
                | Drafts.Failed_retryable _ );
              _;
            }
        | None ->
            false)
  in
  let observed_interrupting =
    Option.exists
      (fun (turn : Wire_fleet.active_turn) ->
        Fleet_store.is_turn_interrupting ~keeper
          ~interrupt_token:turn.interrupt_token model.fleet)
      active_turn_opt
  in
  if local_interrupting || observed_interrupting then Phase_interrupting
  else
    match buf_opt with
    | Some b when b.active -> (
        match Fleet_store.current_tool b with
        | Some { tool_state = Tool_pending; tool_name; _ } ->
            Phase_tool_running tool_name
        | Some { tool_state = Tool_result_pending _; tool_name; _ } ->
            Phase_tool_waiting tool_name
        | Some { tool_state = (Tool_settled | Tool_unfinished); _ } | None -> (
            match Fleet_store.current_model_content b with
            | Some Wire_fleet.Content_text -> Phase_streaming
            | Some Wire_fleet.Content_thinking -> Phase_thinking
            | None when b.run_started -> Phase_awaiting_turn
            | None -> (
              match active_tx_opt with
              | Some { state = Drafts.Sending; _ } -> Phase_sending
              | Some { state = Drafts.Queued; _ } -> (
                  match active_turn_opt with
                  | Some turn ->
                      Phase_turn_running
                        { turn; queued_count = Int.max 1 queued_count }
                  | None -> Phase_queued (Int.max 1 queued_count))
              | Some { state = Drafts.Confirming_delivery; _ } ->
                  Phase_confirming
              | Some { state = Drafts.Interrupting; _ } -> Phase_interrupting
              | Some
                  {
                    state =
                      ( Drafts.Pending_processing
                      | Drafts.Delivered
                      | Drafts.No_operation_record | Drafts.Failed_retryable _ );
                    _;
                  }
              | None ->
                  Phase_awaiting_turn)))
    | Some _ | None -> (
        match active_tx_opt with
        | Some { state = Drafts.Interrupting; _ } -> Phase_interrupting
        | Some { state = Drafts.Pending_processing; _ } -> Phase_awaiting_turn
        | Some { state = Drafts.Sending; _ } -> Phase_sending
        | Some { state = Drafts.Confirming_delivery; _ } -> Phase_confirming
        | Some { state = Drafts.Queued; _ } -> (
            match active_turn_opt with
            | Some turn ->
                Phase_turn_running
                  { turn; queued_count = Int.max 1 queued_count }
            | None -> Phase_queued (Int.max 1 queued_count))
        | Some { state = Drafts.Delivered | Drafts.No_operation_record | Drafts.Failed_retryable _; _ }
        | None -> (
            match active_turn_opt with
            | Some turn -> Phase_turn_running { turn; queued_count = 0 }
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
                         | Drafts.No_operation_record | Drafts.Delivered ->
                             None)
                in
                match latest_unpersisted_failed with
                | Some reason -> Phase_failed reason
                | None -> (
                    match buf_opt with
                    | Some b
                      when (not b.active)
                           && not (List.exists (fun (tx : Drafts.pending_message) ->
                               String.equal tx.request_id b.request_id && tx.state = Drafts.No_operation_record)
                               (Drafts.pending_txs_for_keeper ~keeper model.drafts))
                           && not (stream_reply_already_persisted hist_msgs b)
                      -> (
                        match b.last_error with
                        | Some err -> Phase_failed err
                        | None -> Phase_idle)
                    | Some _ | None -> Phase_idle))))

let composer_pending_tx_of_phase = function
  | Phase_idle -> Composer.Tx_idle
  | Phase_sending -> Composer.Tx_sending
  | Phase_queued n ->
      if n > 1 then Composer.Tx_queued_count n else Composer.Tx_queued
  | Phase_awaiting_turn -> Composer.Tx_awaiting_turn
  | Phase_thinking -> Composer.Tx_thinking
  | Phase_tool_running tool -> Composer.Tx_tool_running tool
  | Phase_tool_waiting tool -> Composer.Tx_tool_waiting tool
  | Phase_streaming -> Composer.Tx_streaming
  | Phase_turn_running { turn; queued_count } ->
      Composer.Tx_turn_running
        {
          kind = turn_running_kind_of_turn turn;
          label = turn_running_badge_label ~turn ~queued_count;
        }
  | Phase_confirming -> Composer.Tx_confirming
  | Phase_interrupting -> Composer.Tx_interrupting
  | Phase_failed reason -> Composer.Tx_failed reason

let status_strip_phase ~model ~keeper =
  let phase = live_chat_phase ~model ~keeper in
  if equal_live_chat_phase phase Phase_awaiting_turn
     && not (Fleet_store.has_active_chat_stream ~keeper model.fleet)
  then
    match active_turn_for_progress ~model ~keeper with
    | Some turn ->
        let queued_count = Drafts.queued_count_for_keeper ~keeper model.drafts in
        Phase_turn_running { turn; queued_count }
    | None -> phase
  else phase

let live_chat_phase_badge ~(model : Model.t) ~keeper =
  if Option.equal Nav.equal_overlay model.nav.overlay
       (Some (Nav.Queue_context Nav.Drawer_queue))
  then
    match active_turn_for_progress ~model ~keeper with
    | Some turn -> Some (observed_turn_badge ~model ~keeper turn)
    | None -> started_chat_wait_badge ~model ~keeper
  else
      let phase = status_strip_phase ~model ~keeper in
      match phase with
      | Phase_turn_running { turn; queued_count } ->
          let glyph, tone, label = observed_turn_badge ~model ~keeper turn in
          let label =
            if queued_count = 0 then label
            else Say.concat ~sep:" · "
                [ label
                ; Say.make ~ko:(Printf.sprintf "대기 %d" queued_count)
                    ~en:(Printf.sprintf "queued %d" queued_count)
                ]
          in
          Some (glyph, tone, label)
      | Phase_thinking | Phase_tool_running _ | Phase_tool_waiting _ | Phase_streaming ->
          Composer.pending_tx_badge (composer_pending_tx_of_phase phase)
          |> Option.map (fun (_, tone, label) -> progress_glyph model, tone, label)
      | Phase_awaiting_turn ->
          (match started_chat_wait_badge ~model ~keeper with
           | Some _ as status -> status
           | None -> Composer.pending_tx_badge Composer.Tx_awaiting_turn)
      | Phase_idle -> worked_badge ~model ~keeper
      | Phase_sending | Phase_queued _
      | Phase_confirming | Phase_interrupting | Phase_failed _ ->
          Composer.pending_tx_badge (composer_pending_tx_of_phase phase)

let show_active_turn_summary ~(model : Model.t) ~keeper
    (turn : Wire_fleet.active_turn) =
  model.fleet.chat_turn_details_expanded
  || (match model.fleet.chat_origin_mode with
      | Fleet_store.Display_origin_bare -> false
      | Fleet_store.Display_origin_inline | Fleet_store.Display_origin_row -> true)
  || Option.exists
       (fun (preview : Wire_fleet.turn_preview) ->
         Wire_fleet.equal_turn_preview_activity preview.activity
           Wire_fleet.Preview_failed)
       turn.preview
  ||
  match status_strip_phase ~model ~keeper with
  | Phase_turn_running { turn = displayed; _ } ->
      not (Wire_fleet.equal_active_turn displayed turn)
  | Phase_idle | Phase_sending | Phase_queued _ | Phase_awaiting_turn
  | Phase_thinking | Phase_tool_running _ | Phase_tool_waiting _
  | Phase_streaming | Phase_confirming | Phase_interrupting | Phase_failed _ ->
      true

let is_phase_interruptible = function
  | Phase_sending
  | Phase_awaiting_turn
  | Phase_thinking
  | Phase_tool_running _
  | Phase_tool_waiting _
  | Phase_streaming ->
      true
  | Phase_turn_running { turn; queued_count } ->
      Wire_fleet.equal_turn_lane turn.lane Wire_fleet.Lane_chat
      && Int.equal queued_count 0
  | Phase_idle
  | Phase_queued _
  | Phase_confirming
  | Phase_interrupting
  | Phase_failed _ ->
      false

let interrupt_target_pending ~(model : Model.t) ~keeper = function
  | `Turn_token interrupt_token ->
      Fleet_store.is_turn_interrupting ~keeper ~interrupt_token model.fleet
  | `Operation_id operation_id ->
      Fleet_store.is_operation_interrupting ~keeper ~operation_id model.fleet
      || Drafts.is_operation_interrupting ~keeper ~operation_id model.drafts

let local_interrupt_target ~(model : Model.t) ~keeper
    : Cmd.keeper_turn_interrupt_target option =
  let operation ~request_id operation_id =
    Some (`Operation_id (Option.value operation_id ~default:request_id))
  in
  match Fleet_store.String_map.find_opt keeper model.fleet.chat_streams with
  | Some buf when buf.active -> operation ~request_id:buf.request_id buf.operation_id
  | Some _ | None -> (
      match Drafts.active_tx_for_keeper ~keeper model.drafts with
      | Some
          {
            state = (Drafts.Pending_processing | Drafts.Interrupting);
            request_id;
            operation_id;
            _;
          }
      | Some
          {
            state = Drafts.Sending;
            mode = (Drafts.Mode_direct | Drafts.Mode_steer);
            request_id;
            operation_id;
            _;
          } ->
          operation ~request_id operation_id
      | Some { state = Drafts.Sending; mode = Drafts.Mode_follow_up; _ }
      | Some
          {
            state =
              ( Drafts.Queued
              | Drafts.Confirming_delivery
              | Drafts.Delivered
              | Drafts.No_operation_record
              | Drafts.Failed_retryable _ );
            _;
          }
      | None -> None)

let escape_interrupt_already_attempted ~(model : Model.t) ~keeper = function
  | `Turn_token interrupt_token ->
      Fleet_store.is_esc_interrupt_attempted_turn ~keeper ~interrupt_token
        model.fleet
  | `Operation_id operation_id ->
      Fleet_store.is_esc_interrupt_attempted_op ~keeper ~operation_id model.fleet

let escape_interrupt_target ~(model : Model.t) ~keeper =
  match Fleet_store.active_turn_for ~keeper model.fleet with
  | Some turn when not (Wire_fleet.equal_turn_lane turn.lane Wire_fleet.Lane_chat) ->
      None
  | active_turn -> (
      match local_interrupt_target ~model ~keeper with
      | Some target
        when (not (interrupt_target_pending ~model ~keeper target))
             && not (escape_interrupt_already_attempted ~model ~keeper target) ->
          Some target
      | Some _ -> None
      | None ->
          if Drafts.has_active_tx_for ~keeper model.drafts
             || not (is_phase_interruptible (live_chat_phase ~model ~keeper))
          then None
          else
            match active_turn with
            | Some (turn : Wire_fleet.active_turn) ->
                let target = `Turn_token turn.interrupt_token in
                if escape_interrupt_already_attempted ~model ~keeper target then
                  None
                else Some target
            | None -> None)

let explicit_interrupt_target ~model ~keeper
    (active_turn : Wire_fleet.active_turn option) =
  match active_turn with
  | Some turn when Wire_fleet.equal_turn_lane turn.lane Wire_fleet.Lane_maintenance ->
      None
  | Some turn ->
      let observed_target = `Turn_token turn.interrupt_token in
      if Wire_fleet.equal_turn_lane turn.lane Wire_fleet.Lane_chat then
        Some
          (Option.value (local_interrupt_target ~model ~keeper)
             ~default:observed_target)
      else Some observed_target
  | None -> local_interrupt_target ~model ~keeper

type stream_projection = {
  buf : Fleet_store.chat_stream_buffer;
  show_runtime_meta : string option;
  show_retry : string option;
  show_checkpoint : string option;
  show_protocol_warning : string option;
  show_thinking : bool;
  show_tools : bool;
  show_text : bool;
  show_error : string option;
}

type pending_tx_projection = {
  tx : Drafts.pending_message;
  notice_only : bool;
}

type delegate_kind =
  | Delegate_invoke
  | Delegate_status
  | Delegate_cancel

type delegate_summary = {
  kind : delegate_kind;
  target_keeper : string option;
  target_keepers : string list;
  operation_count : int;
  prompt_preview : string option;
  operation_id : string option;
  artifact_count : int;
}

let sanitize_delegate_field (raw : string) : string option =
  let pass1 = scrub_secrets_in_text raw in
  let flat =
    String.trim (String.map (function '\n' | '\r' | '\t' -> ' ' | c -> c) pass1)
  in
  if String.equal flat "" then None
  else
    let pass2 = scrub_secrets_in_text flat in
    let clean =
      if Json_tree.is_secret_value pass2 then "[redacted]" else pass2
    in
    if String.equal (String.trim clean) "" then None else Some clean

let strip_leading_at s =
  let len = String.length s in
  let rec loop i =
    if i < len && Char.equal s.[i] '@' then loop (i + 1) else i
  in
  let start = loop 0 in
  if start = 0 then s else String.sub s start (len - start)

let sanitize_delegate_target (raw : string) : string option =
  match sanitize_delegate_field raw with
  | None -> None
  | Some clean ->
      let stripped = strip_leading_at clean in
      if String.equal stripped "" then None else Some stripped

let extract_delegate_summary ~tool_name ~raw_json : delegate_summary option =
  let trimmed_name = String.trim tool_name in
  let kind_opt =
    match trimmed_name with
    | "masc_keeper_delegate" -> Some Delegate_invoke
    | "masc_keeper_delegate_status" | "masc_keeper_delegate_status_many" ->
        Some Delegate_status
    | "masc_keeper_delegate_cancel" -> Some Delegate_cancel
    | _ -> None
  in
  match kind_opt with
  | None -> None
  | Some kind ->
      let str_field kvs key =
        match List.assoc_opt key kvs with
        | Some (`String s) -> sanitize_delegate_field s
        | Some _ | None -> None
      in
      let target_of_kvs kvs =
        let raw_target =
          match List.assoc_opt "target" kvs with
          | Some (`Assoc tfields) -> (
              match List.assoc_opt "name" tfields with
              | Some (`String s) -> Some s
              | Some _ | None -> None)
          | Some (`String s) -> Some s
          | Some _ | None -> (
              match List.assoc_opt "keeper_name" kvs with
              | Some (`String s) -> Some s
              | Some _ | None -> (
                  match List.assoc_opt "delegate" kvs with
                  | Some (`String s) -> Some s
                  | Some _ | None -> None))
        in
        Option.bind raw_target sanitize_delegate_target
      in
      let target_keeper, target_keepers, operation_count, prompt_preview, operation_id, artifact_count =
        match Yojson.Safe.from_string (String.trim raw_json) with
        | json -> (
            match scrub_json_secrets json with
            | `Assoc kvs ->
                let rev_targets = ref [] in
                let add_target t =
                  if not (List.exists (String.equal t) !rev_targets) then
                    rev_targets := t :: !rev_targets
                in
                Option.iter add_target (target_of_kvs kvs);
                let first_batch_op = ref None in
                let batch_count =
                  match List.assoc_opt "operations" kvs with
                  | Some (`List ops) ->
                      List.iter
                        (function
                          | `Assoc op_kvs ->
                              Option.iter add_target (target_of_kvs op_kvs);
                              if Option.is_none !first_batch_op then
                                first_batch_op :=
                                  (match str_field op_kvs "operation_id" with
                                  | Some _ as o -> o
                                  | None -> str_field op_kvs "request_id")
                          | _ -> ())
                        ops;
                      List.length ops
                  | Some _ | None -> 0
                in
                let targets = List.rev !rev_targets in
                let primary_target = List.nth_opt targets 0 in
                let prompt =
                  match str_field kvs "prompt" with
                  | Some _ as p -> p
                  | None -> str_field kvs "message"
                in
                let op_id =
                  match str_field kvs "operation_id" with
                  | Some _ as o -> o
                  | None -> (
                      match str_field kvs "request_id" with
                      | Some _ as r -> r
                      | None -> !first_batch_op)
                in
                let op_count =
                  if batch_count > 0 then batch_count
                  else if Option.is_some op_id then 1
                  else 0
                in
                let artifacts =
                  match List.assoc_opt "artifacts" kvs with
                  | Some (`List xs) -> List.length xs
                  | Some _ | None -> 0
                in
                (primary_target, targets, op_count, prompt, op_id, artifacts)
            | _ -> (None, [], 0, None, None, 0))
        | exception Yojson.Json_error _ -> (None, [], 0, None, None, 0)
      in
      Some
        {
          kind;
          target_keeper;
          target_keepers;
          operation_count;
          prompt_preview;
          operation_id;
          artifact_count;
        }

let format_short_tool_label ~(lang : Say.lang) ~tool_name ~raw_json =
  match extract_delegate_summary ~tool_name ~raw_json with
  | None -> tool_name
  | Some del -> (
      let base =
        match del.kind, lang with
        | Delegate_invoke, Say.Lang_ko -> "위임"
        | Delegate_invoke, Say.Lang_en -> "Delegate"
        | Delegate_status, Say.Lang_ko -> "위임조회"
        | Delegate_status, Say.Lang_en -> "Delegate status"
        | Delegate_cancel, Say.Lang_ko -> "위임취소"
        | Delegate_cancel, Say.Lang_en -> "Delegate cancel"
      in
      match del.target_keepers with
      | [] ->
          if del.operation_count > 1 then
            match lang with
            | Say.Lang_ko -> Printf.sprintf "%s(%d건)" base del.operation_count
            | Say.Lang_en -> Printf.sprintf "%s(%d)" base del.operation_count
          else base
      | [ single ] -> Printf.sprintf "%s(@%s)" base single
      | t1 :: t2 :: rest ->
          let shown = Printf.sprintf "@%s,@%s" t1 t2 in
          let n_rest = List.length rest in
          if n_rest > 0 then
            match lang with
            | Say.Lang_ko -> Printf.sprintf "%s(%s 외 %d)" base shown n_rest
            | Say.Lang_en -> Printf.sprintf "%s(%s +%d)" base shown n_rest
          else Printf.sprintf "%s(%s)" base shown)

let summarize_tool_histogram ~(lang : Say.lang) ?(max_unique = 4) items =
  let counts : (string * int) list ref = ref [] in
  List.iter
    (fun (tool_name, raw_json) ->
      let lbl = format_short_tool_label ~lang ~tool_name ~raw_json in
      let rec bump = function
        | [] -> [ (lbl, 1) ]
        | (k, n) :: rest when String.equal k lbl -> (k, n + 1) :: rest
        | pair :: rest -> pair :: bump rest
      in
      counts := bump !counts)
    items;
  let all = !counts in
  let shown =
    all
    |> List.take (Int.max 1 max_unique)
    |> List.map (fun (lbl, n) ->
           if n > 1 then Printf.sprintf "%s ×%d" lbl n else lbl)
  in
  let rest = List.length all - List.length shown in
  let parts =
    if rest > 0 then
      let more =
        match lang with
        | Say.Lang_ko -> Printf.sprintf "외 %d종" rest
        | Say.Lang_en -> Printf.sprintf "+%d more" rest
      in
      shown @ [ more ]
    else shown
  in
  String.concat Typography.sep_dot parts

let count_history_thinking_rows ~theme ~(mode : Fleet_store.thinking_display) ~width =
  function
  | None -> 0
  | Some thinking -> (
      match mode with
      | Fleet_store.Thinking_hidden -> 0
      | Fleet_store.Thinking_folded -> (
          match thinking with
          | Wire_fleet.Thinking_redacted | Wire_fleet.Thinking_partial _ -> 1
          | Wire_fleet.Thinking_visible text ->
              if String.equal (String.trim text) "" then 0 else 1)
      | Fleet_store.Thinking_full -> (
          match thinking with
          | Wire_fleet.Thinking_redacted -> 1
          | Wire_fleet.Thinking_visible text ->
              if String.equal (String.trim text) "" then 0
              else
                1
                + List.length
                    (thinking_body_lines ~theme ~width text)
          | Wire_fleet.Thinking_partial text ->
              if String.equal (String.trim text) "" then 1
              else
                1
                + List.length
                    (thinking_body_lines ~theme ~width text)))

type 'a tool_group = Single of 'a | Grouped of 'a * 'a list

let tools_mode (model : Model.t) =
  if model.fleet.chat_turn_details_expanded then Slash.Tools_full
  else model.fleet.chat_tools_mode

let consecutive_tool_groups ~tools_mode ~same rows =
  match tools_mode with
  | Slash.Tools_results | Slash.Tools_full -> List.map (fun row -> Single row) rows
  | Slash.Tools_compact ->
      let rec take first taken = function
        | row :: rest when same first row -> take first (row :: taken) rest
        | rest -> (List.rev taken, rest)
      in
      let rec loop groups = function
        | [] -> List.rev groups
        | row :: rest ->
            let related, remaining = take row [] rest in
            let item =
              match related with
              | [] -> Single row
              | _ :: _ -> Grouped (row, related)
            in
            loop (item :: groups) remaining
      in
      loop [] rows

let history_tool_groups ~tools_mode rows =
  let can_group (row : Wire_fleet.chat_message) =
    match row.role with
    | Wire_fleet.Role_tool -> Option.is_none row.failure_kind
    | Wire_fleet.Role_user | Wire_fleet.Role_peer _ | Wire_fleet.Role_assistant
    | Wire_fleet.Role_system | Wire_fleet.Role_request_failure -> false
  in
  let turn_ref (row : Wire_fleet.chat_message) =
    match row.turn_ref, row.provenance with
    | Some id, _ -> Some id
    | None, Some { delivery_key = Autonomous_turn id; _ } ->
        Some (Ids.Turn_ref.to_string id)
    | None, (None | Some {
        delivery_key =
          ( Operation _ | Operation_checkpoint _ | Operation_native _ | Fusion_run _
          | Workspace_message _ | Connector_message _ | Approval_lifecycle _ );
        _;
      }) -> None
  in
  let same a b =
    can_group a && can_group b
    &&
    match turn_ref a, turn_ref b with
    | Some a, Some b -> String.equal a b
    | (Some _ | None), (Some _ | None) -> false
  in
  consecutive_tool_groups ~tools_mode ~same rows

let stream_tool_groups ~tools_mode rows =
  let succeeded (call : Fleet_store.active_tool_call) =
    match call.tool_state with
    | Fleet_store.Tool_settled -> Option.equal Bool.equal call.ok (Some true)
    | Fleet_store.Tool_pending | Fleet_store.Tool_unfinished
    | Fleet_store.Tool_result_pending _ -> false
  in
  let same a b =
    succeeded a && succeeded b && Option.equal Int.equal a.stream_scope b.stream_scope
  in
  consecutive_tool_groups ~tools_mode ~same rows

type transcript_section =
  | Section_history of Wire_fleet.chat_message list
  | Section_active_turn of Wire_fleet.active_turn
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
           | Drafts.Delivered ->
               if has_persisted_user_for_op hist_msgs op_id ~body:tx.body then None
               else Some (idx, { tx; notice_only = false })
           | Drafts.No_operation_record ->
               Some (idx, { tx; notice_only = has_persisted_user_for_op hist_msgs op_id ~body:tx.body })
           | Drafts.Failed_retryable _ ->
               if has_persisted_failure_for_op hist_msgs op_id then None
               else
                 let user_in_hist =
                   has_persisted_user_for_op hist_msgs op_id ~body:tx.body
                 in
                 Some (idx, { tx; notice_only = user_in_hist })
           | Drafts.Queued
           | Drafts.Sending
           | Drafts.Pending_processing
           | Drafts.Confirming_delivery
           | Drafts.Interrupting ->
               if has_persisted_user_for_op hist_msgs op_id ~body:tx.body
               then None
               else Some (idx, { tx; notice_only = false }))
    |> List.filter_map Fun.id
  in
  let stream_opt =
    match Fleet_store.String_map.find_opt keeper model.fleet.chat_streams with
    | None -> None
    | Some buf ->
        if (not buf.active) && stream_reply_already_persisted hist_msgs buf then
          None
        else
          let show_runtime_meta =
            if not buf.active then None
            else
              match (buf.active_runtime_id, buf.attempt_index) with
              | Some rid, Some idx when idx > 1 ->
                  Some (Printf.sprintf "%s (attempt #%d)" rid idx)
              | Some rid, Some _ | Some rid, None -> Some rid
              | None, Some idx when idx > 1 ->
                  Some (Printf.sprintf "attempt #%d" idx)
              | None, (Some _ | None) -> None
          in
          let show_retry = if buf.active then buf.retry_notice else None in
          let show_checkpoint = buf.checkpoint_notice in
          let show_protocol_warning = buf.protocol_warning in
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
                      | Drafts.No_operation_record | Drafts.Failed_retryable _ -> true
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
            Option.is_none show_retry && Option.is_none show_checkpoint
            && Option.is_none show_protocol_warning
            && (not show_thinking) && (not show_tools) && (not show_text)
            && Option.is_none show_error
          then None
          else
            Some
              {
                buf;
                show_runtime_meta;
                show_retry;
                show_checkpoint;
                show_protocol_warning;
                show_thinking;
                show_tools;
                show_text;
                show_error;
              }
  in
  let add_if_nonempty sec acc =
    match sec with
    | Section_history [] | Section_pending [] -> acc
    | Section_history (_ :: _)
    | Section_active_turn _
    | Section_pending (_ :: _)
    | Section_stream _ ->
        sec :: acc
  in
  let active_turn_opt = active_turn_for_progress ~model ~keeper in
  let is_waiting_behind_turn (p : pending_tx_projection) =
    match p.tx.state with
    | Drafts.Queued -> true
    | Drafts.Sending ->
        Drafts.equal_delivery_mode p.tx.mode Drafts.Mode_follow_up
    | Drafts.Pending_processing
    | Drafts.Confirming_delivery
    | Drafts.Interrupting
    | Drafts.Delivered
    | Drafts.No_operation_record
    | Drafts.Failed_retryable _ ->
        false
  in
  let add_pending_with_turn acc indexed =
    match active_turn_opt with
    | None -> acc |> add_if_nonempty (Section_pending (List.map snd indexed))
    | Some turn ->
        let before_turn, after_turn =
          List.partition
            (fun (_, p) -> not (is_waiting_behind_turn p))
            indexed
        in
        acc
        |> add_if_nonempty (Section_pending (List.map snd before_turn))
        |> add_if_nonempty (Section_active_turn turn)
        |> add_if_nonempty (Section_pending (List.map snd after_turn))
  in
  let sections_rev =
    match stream_opt with
    | None ->
        []
        |> add_if_nonempty (Section_history hist_msgs)
        |> fun acc -> add_pending_with_turn acc visible_indexed
    | Some sp ->
        let buf_idx_opt =
          Drafts.tx_position_for_keeper ~keeper ~request_id:sp.buf.request_id
            model.drafts
        in
        let before_stream, after_stream_indexed =
          match buf_idx_opt with
          | Some buf_idx ->
              let b, a =
                List.partition (fun (idx, _) -> idx <= buf_idx) visible_indexed
              in
              (List.map snd b, a)
          | None -> ([], visible_indexed)
        in
        let base =
          []
          |> add_if_nonempty (Section_history hist_msgs)
          |> add_if_nonempty (Section_pending before_stream)
          |> add_if_nonempty (Section_stream sp)
        in
        if sp.buf.active then
          base
          |> add_if_nonempty
               (Section_pending (List.map snd after_stream_indexed))
        else add_pending_with_turn base after_stream_indexed
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
  let full_body =
    Layout.inset_body breakpoint
      (Rect.make ~x:0 ~y:top_h ~w:cols ~h:body_outer_h)
  in
  let body_outer =
    if
      Model.sidebar_docked sized_model
      && full_body.w >= Model.sidebar_width + 20
    then
      let sw = Model.sidebar_width in
      let gap = Model.sidebar_gap in
      Rect.make ~x:(full_body.x + sw + gap) ~y:full_body.y
        ~w:(Int.max 0 (full_body.w - sw - gap))
        ~h:full_body.h
    else full_body
  in
  let target_rect =
    if
      embedded && Model.uses_keeper_split ~width:body_outer.w sized_model
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
  let raw_content_h =
    if not embedded then card_inner_h
    else
      let has_keeper =
        Option.is_some (Fleet_store.selected_keeper_summary model.fleet)
      in
      let after_hero_h =
        if has_keeper && card_inner_h >= 16 then card_inner_h - 5
        else card_inner_h
      in
      if after_hero_h >= 3 then
        let body_h1 = after_hero_h - 1 in
        if body_h1 >= 6 then body_h1 - 1 else body_h1
      else after_hero_h
  in
  let active_name_opt =
    if embedded then
      Option.map
        (fun (k : Wire_fleet.keeper_summary) -> k.name)
        (Fleet_store.selected_keeper_summary model.fleet)
    else
      match Model.active_dive model with
      | Some (Nav.Dive_keeper { name; _ }) -> Some name
      | Some
          ( Nav.Dive_work _
          | Nav.Dive_knowledge _
          | Nav.Dive_runtime _
          | Nav.Dive_infra _ )
      | None ->
          Option.map
            (fun (k : Wire_fleet.keeper_summary) -> k.name)
            (Fleet_store.selected_keeper_summary model.fleet)
  in
  let banner_h =
    match active_name_opt with
    | Some name ->
        Model.keeper_diagnostic_banner_height ~name ~avail_h:raw_content_h model
    | None -> 0
  in
  (card_inner_w, Int.max 0 (raw_content_h - banner_h))

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

let count_tool_output_rows ~theme ~tools_mode ~width raw =
  let shown, hidden = tool_output_display_lines ~theme ~tools_mode ~width raw in
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
  let tools_mode = tools_mode model in
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
  let retained_height = retained_image_height ~model ~keeper ~width in
  let count_history hist_msgs =
    let _, total =
      List.fold_left
        (fun (first, acc) item ->
          let spacing = if first then 0 else 1 in
          match item with
          | Grouped _ -> (false, acc + spacing + 1)
          | Single (msg : Wire_fleet.chat_message) ->
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
                let think_r =
                  count_history_thinking_rows ~theme
                    ~mode:model.fleet.chat_thinking_mode ~width msg.thinking
                in
                think_r + hdr
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
                  count_tool_output_rows ~theme ~tools_mode ~width msg.content
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
          let media_r = retained_height * List.length msg.retained_images in
          (false, acc + spacing + msg_r + media_r))
        (true, 0) (history_tool_groups ~tools_mode hist_msgs)
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
                (thinking_body_lines ~theme ~width buf.thinking)
    in
    let tools_r =
      if not sp.show_tools then 0
      else
        List.fold_left
          (fun acc -> function
            | Grouped _ -> acc + 1
            | Single (tc : Fleet_store.active_tool_call) ->
            let det =
              match expanded_tools, tc.output_preview with
              | true, Some out -> count_tool_output_rows ~theme ~tools_mode ~width out
              | false, _ | true, None -> 0
            in
            acc + 1 + det)
          0 (stream_tool_groups ~tools_mode buf.tools)
    in
    let text_r =
      if not sp.show_text then 0
      else
        1
        + count_markdown_rows ~theme ~width ~rail_present:false ~prefix:"  "
            buf.text
    in
    let retry_r = match sp.show_retry with Some _ -> 1 | None -> 0 in
    let ckpt_r = match sp.show_checkpoint with Some _ -> 1 | None -> 0 in
    let proto_r = match sp.show_protocol_warning with Some _ -> 1 | None -> 0 in
    let err_r = match sp.show_error with Some _ -> 1 | None -> 0 in
    retry_r + ckpt_r + proto_r + think_r + tools_r + text_r + err_r
  in
  let sections = project_transcript ~model ~keeper in
  let _, total =
    List.fold_left
      (fun (first, acc) sec ->
        let rows =
          match sec with
          | Section_history msgs -> count_history msgs
          | Section_active_turn turn ->
              let summary =
                if show_active_turn_summary ~model ~keeper turn then 1 else 0
              in
              summary
              + if Option.is_some (active_turn_preview_tail turn) then 1 else 0
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
