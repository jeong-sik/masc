(** Cascade — MASC LLM call module.

    Cascade profile defaults and {!complete} which delegates to
    OAS [Cascade_config.complete_named].

    Model types and spec parsing live in {!Model_spec}.

    Public entry points:
    - {!complete} — messages + cascade_name, returns api_response or error

    Response helpers ([text_of_response], [has_tool_use], [tool_msg])
    removed — use {!Llm_provider.Types} directly.
    [get_cascade] inlined into {!Oas_worker}.

    @since 2.114.0 — original
    @since 2.115.0 — delegated to OAS Cascade_config
    @since 2.116.0 — call_raw, call_with_tools added
    @since 2.117.0 — model types extracted to Model_spec
    @since 2.123.0 — OAS-duplicate helpers removed *)

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
(* Usage helpers (no OAS equivalent — kept here)                     *)
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

(* ================================================================ *)
(* Cascade profile defaults                                          *)
(* ================================================================ *)

(** Locate config/cascade.json via CWD or ME_ROOT.
    Falls back to legacy config/llm_cascade.json if new name not found.
    Returns [Some path] when the file exists on disk. *)
let default_config_path () : string option =
  let base dir name = Filename.concat (Filename.concat dir "config") name in
  let cwd = Sys.getcwd () in
  let me_root =
    Sys.getenv_opt "ME_ROOT"
    |> Option.value
         ~default:(Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp")
  in
  let masc_root = Filename.concat me_root "workspace/yousleepwhen/masc-mcp" in
  let candidates =
    [ base cwd "cascade.json";
      base masc_root "cascade.json";
      base cwd "llm_cascade.json";
      base masc_root "llm_cascade.json" ]
  in
  List.find_opt Sys.file_exists candidates

(** Build a provider:model label, filtering out empty models. *)
let label provider model =
  if model = "" then None
  else Some (Printf.sprintf "%s:%s" provider model)

(** Build a label list, discarding entries with empty models. *)
let labels_of pairs =
  List.filter_map (fun (p, m) -> label p m) pairs

let default_model_strings ~cascade_name =
  let llama_model = Env_config.Llama.default_model in
  let glm_model = Env_config.Llm.default_model in
  let glm_flash = Env_config.Llm.flash_model in
  (* llama + glm:auto — GLM provider selects model at runtime *)
  let llama_glm =
    (if llama_model <> "" then [ Printf.sprintf "llama:%s" llama_model ] else [])
    @ [ "glm:auto" ]
  in
  match cascade_name with
  (* heartbeat — llama first, glm fallback *)
  | "heartbeat_action" | "heartbeat_wake" -> llama_glm
  (* sentinel — llama first, glm fallback *)
  | "sentinel_board" | "sentinel_task" | "sentinel_keeper" -> llama_glm
  (* lodge subsystems — llama first, glm fallback *)
  | "lodge_direct" | "lodge_context_rewrite" | "lodge_trait_gen"
  | "lodge_comment" | "lodge_agent_match" ->
      llama_glm
  (* gardener — llama first, glm fallback *)
  | "gardener_spawn" | "gardener_retire" -> llama_glm
  (* classification — local llama, glm fallback *)
  | "classification" | "context_router" | "capability_match" -> llama_glm
  (* theory of mind — local llama, glm fallback *)
  | "tom" -> llama_glm
  (* verifier — local llama, glm fallback *)
  | "verifier" | "code_swarm_verify" | "code_swarm" -> llama_glm
  (* keeper — local llama, glm fallback *)
  | "keeper_autonomy" | "keeper_proactive" | "keeper_deliberation"
  | "keeper_reply" | "keeper_social" | "keeper_turn" -> llama_glm
  (* routing — local llama, glm fallback *)
  | "routing_judge" | "team_router" -> llama_glm
  (* chain — local llama, glm fallback *)
  | "chain_llm" -> llama_glm
  (* autoresearch — local llama, glm fallback *)
  | "autoresearch" -> llama_glm
  (* trpg — local llama, glm fallback *)
  | "trpg_intent" -> llama_glm
  (* briefing — llama first, flash-tier cloud chain, glm fallback *)
  | "briefing" ->
      (if llama_model <> "" then [ Printf.sprintf "llama:%s" llama_model ] else [])
      @ labels_of [ ("glm", glm_flash); ("gemini", Env_config.Gemini.flash_model) ]
      @ [ "glm:auto" ]
  | "governance_judge" | "operator_judge" -> llama_glm
  (* walph — default execution models *)
  | "walph" -> llama_glm
  (* auto_responder — agent_type-specific cascades *)
  | "auto_responder_claude" ->
      labels_of [ ("claude", Env_config.Claude.default_model) ]
      @ [ "glm:auto" ]
  | "auto_responder_gemini" ->
      labels_of [ ("gemini", Env_config.Gemini.flash_model) ]
      @ [ "glm:auto" ]
  | "auto_responder_glm" ->
      labels_of [ ("glm", glm_model) ]
      @ [ "glm:auto" ]
  | "auto_responder" -> llama_glm
  (* spawn glm — cloud-only cascade *)
  | "spawn_glm" ->
      labels_of [ ("glm", glm_model); ("glm", glm_flash) ]
      @ [ "glm:auto" ]
  (* mitosis — cell division / handoff *)
  | "mitosis" -> llama_glm
  (* topic extraction — fast local model, glm fallback *)
  | "topic_extraction" -> llama_glm
  (* unregistered cascade: llama + glm as safety net *)
  | _ -> llama_glm

(* ================================================================ *)
(* Cascade orchestration                                             *)
(* ================================================================ *)

(** Format OAS http_error as cascade error string. *)
let format_cascade_error ~cascade_name = function
  | Llm_provider.Http_client.HttpError { code; body } ->
    Printf.sprintf "[cascade] %s: HTTP %d: %s" cascade_name code
      (if String.length body > 200
       then String.sub body 0 200 ^ "..."
       else body)
  | Llm_provider.Http_client.NetworkError { message } ->
    Printf.sprintf "[cascade] %s: %s" cascade_name message

(** Direct OAS bridge — single entry point for all LLM cascade calls.
    Returns OAS [api_response] directly; error formatted as string. *)
let complete ~cascade_name ~messages
    ?(config_path = "") ?(temperature = 0.3) ?(timeout_sec = 30)
    ?(max_tokens = 500) ?(accept = fun _ -> true) ?tools () =
  let env = Masc_eio_env.get () in
  let defaults = default_model_strings ~cascade_name in
  let config_path_opt =
    if String.length config_path > 0 then Some config_path
    else default_config_path ()
  in
  match
    Llm_provider.Cascade_config.complete_named
      ~sw:env.sw ~net:env.net ?clock:env.clock
      ?config_path:config_path_opt
      ~name:cascade_name ~defaults ~messages
      ?tools ~temperature ~max_tokens ~accept ~timeout_sec ()
  with
  | Ok resp -> Ok resp
  | Error err -> Error (format_cascade_error ~cascade_name err)

(* call, call_raw, call_with_tools removed — use {!complete} directly.
   Callers build messages and handle api_response/errors themselves. *)
