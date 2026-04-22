(** Inference_utils — inference utility functions.

    Usage helpers, UTF-8 sanitization, token estimation, and
    concurrency diagnostics.  Extracted from the former [Cascade]
    module during the Cascade deletion refactor.

    @since 2.125.0 — extracted from Cascade *)

(* ================================================================ *)
(* Helpers                                                           *)
(* ================================================================ *)

let int_of_env_default name ~default ~min_v ~max_v =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw ->
      let v =
        Option.value ~default:default (int_of_string_opt (String.trim raw))
      in
      max min_v (min max_v v)

(* ================================================================ *)
(* Usage helpers                                                     *)
(* ================================================================ *)

(** Compute total tokens from OAS api_usage. *)
let total_tokens (u : Oas.Types.api_usage) = u.input_tokens + u.output_tokens

(** CJK-aware token estimate delegated to OAS Context_reducer. *)
let estimate_tokens (s : string) : int =
  if s = "" then 0 else Oas.Context_reducer.estimate_char_tokens s

(** Zero usage marker — delegates to OAS Types.zero_api_usage.
    @since 2.123.0 — delegated to OAS *)
let zero_usage : Oas.Types.api_usage =
  { input_tokens = 0; output_tokens = 0; cache_read_input_tokens = 0; cache_creation_input_tokens = 0; cost_usd = None }

(** Extract usage from an api_response, defaulting to zero.
    @since 2.123.0 *)
let usage_of_response (resp : Oas_response.api_response) : Oas.Types.api_usage =
  match resp.usage with Some u -> u | None -> zero_usage

(** Measure wall-clock latency of a thunk in milliseconds.
    Use at call sites that need per-call timing (keeper tool loops, etc.). *)
let timed (f : unit -> 'a) : 'a * int =
  let t0 = Time_compat.now () in
  let result = f () in
  let ms = int_of_float ((Time_compat.now () -. t0) *. 1000.0) in
  (result, ms)

(* ================================================================ *)
(* UTF-8 Sanitization                                               *)
(* ================================================================ *)

let is_disallowed_control_char (c : char) : bool =
  let code = Char.code c in
  (code < 32 && c <> '\n' && c <> '\r' && c <> '\t') || code = 127

let sanitize_text_utf8 (s : string) : string =
  let len = String.length s in
  (* Fast path: scan for invalid UTF-8 or prompt-breaking control chars
     without allocating. Keep LF/CR/TAB because prompts rely on them. *)
  let rec has_invalid_or_control i =
    if i >= len then false
    else
      let dec = String.get_utf_8_uchar s i in
      let dlen = Uchar.utf_decode_length dec in
      if dlen > 0 && Uchar.utf_decode_is_valid dec then
        if dlen = 1 && is_disallowed_control_char s.[i] then true
        else has_invalid_or_control (i + dlen)
      else true
  in
  if not (has_invalid_or_control 0) then s
  else
    let buf = Buffer.create len in
    let rec loop i =
      if i >= len then ()
      else
        let dec = String.get_utf_8_uchar s i in
        let dlen = Uchar.utf_decode_length dec in
        if dlen > 0 && Uchar.utf_decode_is_valid dec then (
          if dlen = 1 && is_disallowed_control_char s.[i] then
            Buffer.add_char buf ' '
          else
            Buffer.add_substring buf s i dlen;
          loop (i + dlen))
        else (
          Buffer.add_string buf "\xEF\xBF\xBD";
          loop (i + 1))
    in
    loop 0;
    Buffer.contents buf

let rec sanitize_json_utf8 (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `String s ->
      let sanitized = sanitize_text_utf8 s in
      if sanitized == s then json else `String sanitized
  | `Assoc fields ->
      let changed = ref false in
      let sanitized_fields =
        List.map (fun (key, value) ->
          let sanitized_key = sanitize_text_utf8 key in
          let sanitized_value = sanitize_json_utf8 value in
          if sanitized_key != key || sanitized_value != value then changed := true;
          (sanitized_key, sanitized_value)
        ) fields
      in
      if !changed then `Assoc sanitized_fields else json
  | `List items ->
      let changed = ref false in
      let sanitized_items =
        List.map (fun item ->
          let sanitized = sanitize_json_utf8 item in
          if sanitized != item then changed := true;
          sanitized
        ) items
      in
      if !changed then `List sanitized_items else json
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _) as other -> other

let rec sanitize_content_blocks_utf8
    (blocks : Oas.Types.content_block list)
  : Oas.Types.content_block list =
  match blocks with
  | [] -> blocks
  | block :: rest ->
      let sanitized_block =
        match block with
        | Oas.Types.Text s ->
            let sanitized = sanitize_text_utf8 s in
            if sanitized == s then block else Oas.Types.Text sanitized
        | Oas.Types.ToolResult { tool_use_id; content; is_error; json } ->
            let sanitized_tool_use_id = sanitize_text_utf8 tool_use_id in
            let sanitized_content = sanitize_text_utf8 content in
            let sanitized_json, json_changed =
              match json with
              | None -> (None, false)
              | Some value ->
                  let sanitized = sanitize_json_utf8 value in
                  (Some sanitized, sanitized != value)
            in
            if sanitized_tool_use_id == tool_use_id
               && sanitized_content == content
               && not json_changed
            then block
            else
              Oas.Types.ToolResult {
                tool_use_id = sanitized_tool_use_id;
                content = sanitized_content;
                is_error;
                json = sanitized_json;
              }
        | _ -> block
      in
      let sanitized_rest = sanitize_content_blocks_utf8 rest in
      if sanitized_block == block && sanitized_rest == rest then blocks
      else sanitized_block :: sanitized_rest

let sanitize_message_utf8 (m : Oas.Types.message) : Oas.Types.message =
  let sanitized_content = sanitize_content_blocks_utf8 m.content in
  if sanitized_content == m.content then m
  else { m with content = sanitized_content }

let sanitize_messages_utf8 (msgs : Oas.Types.message list) : Oas.Types.message list =
  let rec loop messages =
    match messages with
    | [] -> messages
    | msg :: rest ->
        let sanitized_msg = sanitize_message_utf8 msg in
        let sanitized_rest = loop rest in
        if sanitized_msg == msg && sanitized_rest == rest then messages
        else sanitized_msg :: sanitized_rest
  in
  loop msgs

(* ================================================================ *)
(* Concurrency diagnostics (observability only, no throttling)       *)
(* ================================================================ *)

(** Maximum concurrent model calls — retained for diagnostics/dashboard.
    No longer enforced via semaphore: llama-server handles slot-based
    parallelism internally, and cloud APIs return rate-limit errors. *)
let max_concurrent_models =
  int_of_env_default "MASC_MAX_CONCURRENT_MODELS" ~default:8 ~min_v:1 ~max_v:128

(** Atomic counter tracking in-flight model calls (observability only). *)
let inflight = Atomic.make 0

let model_permits_available () = max_concurrent_models - Atomic.get inflight
let model_permits_in_use () = Atomic.get inflight
