(** Llm_utils — LLM utility functions.

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
        try int_of_string (String.trim raw)
        with Failure _ -> default
      in
      max min_v (min max_v v)

(* ================================================================ *)
(* Usage helpers                                                     *)
(* ================================================================ *)

(** Compute total tokens from OAS api_usage. *)
let total_tokens (u : Agent_sdk.Types.api_usage) = u.input_tokens + u.output_tokens

(** Zero usage sentinel. *)
let zero_usage : Agent_sdk.Types.api_usage =
  { Agent_sdk.Types.input_tokens = 0;
    output_tokens = 0;
    cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0 }

(** Extract usage from an api_response, defaulting to zero. *)
let usage_of_response (resp : Llm_provider.Types.api_response) : Agent_sdk.Types.api_usage =
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

let sanitize_text_utf8 (s : string) : string =
  let len = String.length s in
  (* Fast path: scan for invalid UTF-8 without allocating *)
  let rec has_invalid i =
    if i >= len then false
    else
      let dec = String.get_utf_8_uchar s i in
      let dlen = Uchar.utf_decode_length dec in
      if dlen > 0 && Uchar.utf_decode_is_valid dec then has_invalid (i + dlen)
      else true
  in
  if not (has_invalid 0) then s
  else
    let buf = Buffer.create len in
    let rec loop i =
      if i >= len then ()
      else
        let dec = String.get_utf_8_uchar s i in
        let dlen = Uchar.utf_decode_length dec in
        if dlen > 0 && Uchar.utf_decode_is_valid dec then (
          Buffer.add_substring buf s i dlen;
          loop (i + dlen))
        else (
          Buffer.add_string buf "\xEF\xBF\xBD";
          loop (i + 1))
    in
    loop 0;
    Buffer.contents buf

let sanitize_message_utf8 (m : Agent_sdk.Types.message) : Agent_sdk.Types.message =
  { m with
    content = List.map (fun block ->
      match block with
      | Agent_sdk.Types.Text s -> Agent_sdk.Types.Text (sanitize_text_utf8 s)
      | Agent_sdk.Types.ToolResult { tool_use_id; content; is_error } ->
          Agent_sdk.Types.ToolResult {
            tool_use_id = sanitize_text_utf8 tool_use_id;
            content = sanitize_text_utf8 content;
            is_error }
      | other -> other
    ) m.content;
  }

let sanitize_messages_utf8 (msgs : Agent_sdk.Types.message list) : Agent_sdk.Types.message list =
  List.map sanitize_message_utf8 msgs

(** Heuristic: ~4 characters per token (conservative estimate). *)
let estimate_tokens (msgs : Agent_sdk.Types.message list) =
  List.fold_left (fun acc (m : Agent_sdk.Types.message) -> acc + (String.length (Agent_sdk.Types.text_of_message m) / 4) + 4) 0 msgs

(* ================================================================ *)
(* Concurrency diagnostics (observability only, no throttling)       *)
(* ================================================================ *)

(** Maximum concurrent LLM calls — retained for diagnostics/dashboard.
    No longer enforced via semaphore: llama-server handles slot-based
    parallelism internally, and cloud APIs return rate-limit errors. *)
let max_concurrent_llm =
  int_of_env_default "MASC_MAX_CONCURRENT_LLM" ~default:8 ~min_v:1 ~max_v:128

(** Atomic counter tracking in-flight LLM calls (observability only). *)
let inflight = Atomic.make 0

let llm_semaphore_available () = max_concurrent_llm - Atomic.get inflight
let llm_permits_in_use () = Atomic.get inflight
