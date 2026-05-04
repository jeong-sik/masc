(** Keeper_alerting — alert fanout, skill routing, path safety checks,
    and tool-call preparation helpers for keeper execution. *)

(* tla-lint: file-scope: alert score/reason accumulators are local
   refs scoped to a single compute_alert_score call; output is a
   computed score+reasons pair, not a stateful FSM transition. *)

open Keeper_types
open Keeper_memory

let keeper_model_tools = Tool_shard.keeper_model_tools

let merge_usage
    (a : Agent_sdk.Types.api_usage)
    (b : Agent_sdk.Types.api_usage) : Agent_sdk.Types.api_usage =
  { Agent_sdk.Types.input_tokens = a.input_tokens + b.input_tokens;
    output_tokens = a.output_tokens + b.output_tokens;
    cache_creation_input_tokens =
      a.cache_creation_input_tokens + b.cache_creation_input_tokens;
    cache_read_input_tokens =
      a.cache_read_input_tokens + b.cache_read_input_tokens;
    cost_usd =
      (match a.cost_usd, b.cost_usd with
       | Some x, Some y -> Some (x +. y)
       | Some x, None | None, Some x -> Some x
       | None, None -> None) }

let contains_ci = String_util.contains_substring_ci

let alert_retryable_error (msg : string) : bool =
  let text = String.lowercase_ascii (String.trim msg) in
  text <> ""
  && (contains_ci text "timeout"
      || contains_ci text "timed out"
      || contains_ci text "429"
      || contains_ci text "502"
      || contains_ci text "503"
      || contains_ci text "504"
      || contains_ci text "connection reset"
      || contains_ci text "connection refused"
      || contains_ci text "temporary"
      || contains_ci text "network")

let alert_retry_delay_seconds (attempt : int) : float =
  let base_ms = max 0 Env_config.KeeperAlert.retry_base_delay_ms in
  let rec pow2 n acc =
    if n <= 0 then acc else pow2 (n - 1) (acc * 2)
  in
  let factor = pow2 (max 0 (attempt - 1)) 1 in
  float_of_int (base_ms * factor) /. 1000.0

let run_alert_channel_with_retry
    (ctx : _ context)
    ~(channel : string)
    ~(enabled : bool)
    ~(send_once : unit -> bool * string option) : alert_channel_result =
  if not enabled then
    {
      channel;
      attempted = false;
      success = false;
      attempts = 0;
      detail = Some "disabled";
    }
  else
    let max_attempts = 1 + max 0 Env_config.KeeperAlert.max_retries in
    let rec loop attempt last_error =
      let (ok, detail_opt) = send_once () in
      let detail =
        match detail_opt with
        | Some s when String.trim s <> "" -> Some (short_preview ~max_len:Keeper_config.alert_error_detail_max_chars s)
        | _ -> last_error
      in
      if ok then
        { channel; attempted = true; success = true; attempts = attempt; detail }
      else if attempt >= max_attempts then
        {
          channel;
          attempted = true;
          success = false;
          attempts = attempt;
          detail =
            (match detail with
             | Some _ -> detail
             | None -> Some "fanout failed");
        }
      else
        let err_msg = Option.value ~default:"fanout failed" detail in
        if not (alert_retryable_error err_msg) then
          {
            channel;
            attempted = true;
            success = false;
            attempts = attempt;
            detail = Some err_msg;
          }
        else (
          Eio.Time.sleep ctx.clock (alert_retry_delay_seconds attempt);
          loop (attempt + 1) (Some err_msg))
    in
    loop 1 None

let dedup_strings = Dashboard_utils.dedup_strings

(** Alert dedup: suppress identical alerts within a time window (default 60s). *)
let alert_dedup_window_sec = Env_config.AlertDedup.window_sec

let alert_dedup_table : (string, float) Hashtbl.t = Hashtbl.create 32

(** Mutex protecting [alert_dedup_table].  [is_alert_deduplicated] runs
    from every keeper's alert scoring path, and keepers execute
    concurrently in the same room — so the previous implementation
    interleaved [Hashtbl.length] / [Hashtbl.filter_map_inplace] /
    [Hashtbl.find_opt] / [Hashtbl.replace] from multiple fibers with
    no serialisation.  The [find_opt + replace] pair is a TOCTOU that
    can let the same alert fire twice even within the dedup window,
    and [filter_map_inplace] concurrent with [find_opt] invalidates
    the iteration (OCaml [Hashtbl] does not support mutate-during-
    fold). *)
let alert_dedup_mu = Eio.Mutex.create ()

let alert_dedup_key ~(keeper_name : string) ~(reasons : string list) : string =
  let sorted = List.sort String.compare reasons in
  keeper_name ^ ":" ^ String.concat "," sorted

let is_alert_deduplicated ~(keeper_name : string) ~(reasons : string list) : bool =
  let key = alert_dedup_key ~keeper_name ~reasons in
  let now = Time_compat.now () in
  Eio_guard.with_mutex alert_dedup_mu (fun () ->
    if Hashtbl.length alert_dedup_table > 64 then begin
      let stale_threshold = alert_dedup_window_sec *. 2.0 in
      Hashtbl.filter_map_inplace (fun _k ts ->
        if now -. ts > stale_threshold then None else Some ts
      ) alert_dedup_table
    end;
    match Hashtbl.find_opt alert_dedup_table key with
    | Some last_ts when now -. last_ts < alert_dedup_window_sec -> true
    | _ ->
      Hashtbl.replace alert_dedup_table key now;
      false)

(** {1 Alert Signal Weights}

    Keyword weights and signal bonuses for keeper alert scoring.
    These are heuristic values — not empirically calibrated.

    Keyword weights represent severity estimates for each term.
    Higher weight = stronger indicator of an incident requiring escalation.
    The score is the sum of matched weights, capped at 1.0.

    Signal bonuses are additive modifiers for structural indicators
    (guardrail stops, context pressure, alignment drops, tool usage).

    TODO(RFC-0001 Phase 3): Register in Runtime_params for runtime tuning. *)

let alert_keyword_weights : (string * float) list = [
  ("장애",     0.35);  (* Korean: outage/failure *)
  ("사고",     0.30);  (* Korean: incident *)
  ("롤백",     0.30);  (* Korean: rollback *)
  ("긴급",     0.25);  (* Korean: urgent *)
  ("critical", 0.30);
  ("urgent",   0.22);
  ("incident", 0.25);
  ("outage",   0.38);
  ("oncall",   0.18);
  ("p0",       0.32);
  ("sev1",     0.32);
  ("security", 0.35);
  ("breach",   0.45);
  ("data loss", 0.45);
  ("failover", 0.22);
  ("hotfix",   0.20);
  ("downtime", 0.28);
]

(** Additive bonus when a guardrail stop was triggered. *)
let signal_bonus_guardrail_stop = 0.45
(** Additive bonus when handoff is active and context is near limit. *)
let signal_bonus_handoff_pressure = 0.16
(** Additive bonus when both goal and response alignment are low. *)
let signal_bonus_low_alignment = 0.12
(** Additive bonus when multiple tool calls occurred. *)
let signal_bonus_multi_tool = 0.06

(** Context ratio above which handoff pressure is flagged. *)
let handoff_pressure_threshold () =
  Runtime_params.get Governance_registry.keeper_handoff_pressure_threshold
(** Goal alignment below which low-alignment signal fires. *)
let goal_alignment_floor = 0.05
(** Response alignment below which low-alignment signal fires. *)
let response_alignment_floor = 0.16
(** Minimum tool call count to trigger multi-tool signal. *)
let multi_tool_min_count = 2

let alert_emit_threshold () =
  max 0.0 (min 1.0 Env_config.KeeperAlert.min_score)

let keeper_alert_signal
    ~(message : string)
    ~(reply : string)
    ~(context_ratio : float)
    ~(goal_alignment : float)
    ~(response_alignment : float)
    ~(tool_call_count : int)
    ~(auto_rules : keeper_auto_rule_eval) : float * string list * string list =
  let corpus = String.lowercase_ascii (message ^ "\n" ^ reply) in
  let keyword_hits =
    alert_keyword_weights
    |> List.filter_map (fun (kw, w) ->
         if contains_ci corpus kw then Some (kw, w) else None)
  in
  let keyword_score =
    keyword_hits
    |> List.fold_left (fun acc (_, w) -> acc +. w) 0.0
    |> min 1.0
  in
  let score = ref keyword_score in
  let reasons = ref [] in
  if keyword_hits <> [] then
    reasons := "critical_keywords" :: !reasons;
  if auto_rules.guardrail_stop then begin
    score := !score +. signal_bonus_guardrail_stop;
    reasons := "guardrail_stop" :: !reasons
  end;
  if auto_rules.handoff && context_ratio >= handoff_pressure_threshold () then begin
    score := !score +. signal_bonus_handoff_pressure;
    reasons := "handoff_pressure" :: !reasons
  end;
  if goal_alignment < goal_alignment_floor && response_alignment < response_alignment_floor then begin
    score := !score +. signal_bonus_low_alignment;
    reasons := "low_alignment" :: !reasons
  end;
  if tool_call_count >= multi_tool_min_count then begin
    score := !score +. signal_bonus_multi_tool;
    reasons := "multi_tool_action" :: !reasons
  end;
  let score = max 0.0 (min 1.0 !score) in
  let keywords = keyword_hits |> List.map fst |> dedup_strings in
  (score, List.rev !reasons, keywords)

let keeper_alert_text
    ~(meta : keeper_meta)
    ~(score : float)
    ~(reasons : string list)
    ~(keywords : string list)
    ~(message : string)
    ~(reply : string)
    ~(work_kind : string)
    ~(context_ratio : float)
    ~(goal_alignment : float)
    ~(response_alignment : float) : string =
  let reason_text = if reasons = [] then "-" else String.concat ", " reasons in
  let keyword_text = if keywords = [] then "-" else String.concat ", " keywords in
  let excerpt_cap = max Keeper_config.alert_excerpt_min_chars Env_config.KeeperAlert.max_body_chars in
  let message_preview = short_preview ~max_len:(min excerpt_cap Keeper_config.alert_message_preview_max_chars) message in
  let reply_preview = short_preview ~max_len:(min excerpt_cap Keeper_config.alert_reply_preview_max_chars) reply in
  Printf.sprintf
    "[keeper-alert] %s score=%.2f\n\
     - trace: %s\n\
     - generation: %d\n\
     - work_kind: %s\n\
     - reasons: %s\n\
     - keywords: %s\n\
     - context_ratio: %.2f\n\
     - goal_alignment: %.2f\n\
     - response_alignment: %.2f\n\
     - user: %s\n\
     - reply: %s"
    meta.name score (Keeper_id.Trace_id.to_string meta.runtime.trace_id) meta.runtime.generation work_kind
    reason_text keyword_text context_ratio goal_alignment response_alignment
    message_preview reply_preview

let post_keeper_alert_board
    ~(alert_text : string) : bool * string option =
  let author = let v = String.trim Env_config.KeeperAlert.board_author in
    if v = "" then "keeper-alert-bot" else v in
  let hearth_opt = let v = String.trim Env_config.KeeperAlert.board_hearth in
    if v = "" then None else Some v in
  let visibility = let v = String.trim Env_config.KeeperAlert.board_visibility in
    if v = "" then "internal" else v in
  let visibility =
    match Tool_board.visibility_of_string visibility with
    | Some value -> value
    | None -> Board.Internal
  in
  let meta_json = Some (`Assoc [ ("source", `String "keeper_alert_board") ]) in
  match
    Board_dispatch.create_post ~author ~content:alert_text
      ~post_kind:Board.System_post ?meta_json
      ~visibility ~ttl_hours:24 ?hearth:hearth_opt ()
  with
  | Ok _ -> (true, Some "board_posted")
  | Error e -> (false, Some (Board.show_board_error e))

let post_keeper_alert_slack
    ~(alert_text : string) : bool * string option =
  let webhook = String.trim Env_config.KeeperAlert.slack_webhook_url in
  if webhook = "" then
    (false, Some "missing_webhook")
  else
    let payload = `Assoc [ ("text", `String alert_text) ] |> Yojson.Safe.to_string in
    let argv = [
      "curl";
      "-sS";
      "--fail";
      "--max-time"; "10";
      "-X"; "POST";
      "-H"; "Content-Type: application/json";
      "--data-binary"; "@-";
      webhook;
    ] in
    let (status, out) =
      Process_eio.run_argv_with_stdin_and_status
        ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Alerting ())
        ~stdin_content:payload
        argv
    in
    match status with
    | Unix.WEXITED 0 -> (true, Some "slack_posted")
    | Unix.WEXITED n ->
        (false, Some (Printf.sprintf "curl_exit_%d: %s" n (short_preview ~max_len:200 out)))
    | Unix.WSIGNALED n ->
        (false, Some (Printf.sprintf "curl_signaled_%d" n))
    | Unix.WSTOPPED n ->
        (false, Some (Printf.sprintf "curl_stopped_%d" n))

let slack_alert_token () : string option =
  let pick name =
    match Sys.getenv_opt name with
    | Some v ->
        let trimmed = String.trim v in
        if trimmed <> "" then Some trimmed else None
    | None -> None
  in
  match pick "SLACK_BOT_TOKEN" with
  | Some _ as tok -> tok
  | None ->
      (match pick "SLACK_USER_TOKEN" with
       | Some _ as tok -> tok
       | None -> pick "SLACK_TOKEN")

let slack_api_post_json
    ~(token : string)
    ~(endpoint : string)
    ~(payload : Yojson.Safe.t) : (Yojson.Safe.t, string) result =
  let url = Printf.sprintf "https://slack.com/api/%s" endpoint in
  let body = Yojson.Safe.to_string payload in
  let argv = [
    "curl";
    "-sS";
    "--fail";
    "--max-time"; "12";
    "-X"; "POST";
    "-H"; "Content-Type: application/json; charset=utf-8";
    "-H"; ("Authorization: Bearer " ^ token);
    "--data-binary"; "@-";
    url;
  ] in
  let (status, out) =
    Process_eio.run_argv_with_stdin_and_status
      ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Alerting ())
      ~stdin_content:body
      argv
  in
  match status with
  | Unix.WEXITED 0 ->
      (try
         Ok (Yojson.Safe.from_string out)
       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
         Error (Printf.sprintf "json_parse_failed: %s" (Printexc.to_string exn)))
  | Unix.WEXITED n ->
      Error (Printf.sprintf "curl_exit_%d: %s" n (short_preview ~max_len:220 out))
  | Unix.WSIGNALED n ->
      Error (Printf.sprintf "curl_signaled_%d" n)
  | Unix.WSTOPPED n ->
      Error (Printf.sprintf "curl_stopped_%d" n)

let slack_ok_or_error (json : Yojson.Safe.t) : (unit, string) result =
  let ok = Safe_ops.json_bool ~default:false "ok" json in
  if ok then Ok ()
  else
    let err =
      match Safe_ops.json_string_opt "error" json with
      | Some e when String.trim e <> "" -> e
      | _ -> "slack_api_error"
    in
    Error err

let post_keeper_alert_slack_dm
    ~(alert_text : string)
    ~(user_id : string) : bool * string option =
  let target = String.trim user_id in
  if target = "" then
    (false, Some "missing_dm_user_id")
  else
    match slack_alert_token () with
    | None -> (false, Some "missing_slack_token")
    | Some token ->
        let open_payload = `Assoc [ ("users", `String target) ] in
        match slack_api_post_json ~token ~endpoint:"conversations.open" ~payload:open_payload with
        | Error e -> (false, Some ("dm_open_failed: " ^ e))
        | Ok open_json ->
            (match slack_ok_or_error open_json with
             | Error e -> (false, Some ("dm_open_failed: " ^ e))
             | Ok () ->
                 let channel_id =
                   let open Yojson.Safe.Util in
                   match open_json |> member "channel" |> member "id" with
                   | `String s when String.trim s <> "" -> Some s
                   | _ -> None
                 in
                 (match channel_id with
                  | None -> (false, Some "dm_open_failed: missing_channel_id")
                  | Some cid ->
                      let post_payload = `Assoc [
                        ("channel", `String cid);
                        ("text", `String alert_text);
                      ] in
                      (match slack_api_post_json ~token ~endpoint:"chat.postMessage" ~payload:post_payload with
                       | Error e -> (false, Some ("dm_post_failed: " ^ e))
                       | Ok post_json ->
                           (match slack_ok_or_error post_json with
                            | Ok () -> (true, Some ("dm_sent:" ^ cid))
                            | Error e -> (false, Some ("dm_post_failed: " ^ e))))))

let split_csv_nonempty (raw : string) : string list =
  raw
  |> String.split_on_char ','
  |> List.map String.trim
  |> List.filter (fun s -> s <> "")

let post_keeper_alert_github
    ~(title : string)
    ~(body : string) : bool * string option =
  let repo = String.trim Env_config.KeeperAlert.github_repo in
  if repo = "" then
    (false, Some "missing_repo")
  else
    let labels = split_csv_nonempty Env_config.KeeperAlert.github_label in
    let args = [
      "gh"; "issue"; "create";
      "--repo"; repo;
      "--title"; title;
      "--body"; body;
    ]
    @ List.concat_map (fun label -> [ "--label"; label ]) labels
    in
    let (status, out) =
      Process_eio.run_argv_with_status
        ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Alerting ())
        args
    in
    match status with
    | Unix.WEXITED 0 -> (true, Some (short_preview ~max_len:200 out))
    | Unix.WEXITED n ->
        (false, Some (Printf.sprintf "gh_exit_%d: %s" n (short_preview ~max_len:200 out)))
    | Unix.WSIGNALED n ->
        (false, Some (Printf.sprintf "gh_signaled_%d" n))
    | Unix.WSTOPPED n ->
        (false, Some (Printf.sprintf "gh_stopped_%d" n))

let maybe_emit_interesting_alert
    (ctx : _ context)
    ~(meta : keeper_meta)
    ~(message : string)
    ~(reply : string)
    ~(work_kind : string)
    ~(tool_call_count : int)
    ~(context_ratio : float)
    ~(goal_alignment : float)
    ~(response_alignment : float)
    ~(auto_rules : keeper_auto_rule_eval) : interesting_alert_result =
  let enabled = Env_config.KeeperAlert.enabled in
  let threshold = alert_emit_threshold () in
  if not enabled then
    { empty_interesting_alert_result with enabled = false; threshold }
  else
    let (score, reasons, keywords) =
      keeper_alert_signal
        ~message
        ~reply
        ~context_ratio
        ~goal_alignment
        ~response_alignment
        ~tool_call_count
        ~auto_rules
    in
    if score < threshold then
      {
        empty_interesting_alert_result with
        enabled = true;
        threshold;
        score;
        reasons;
        keywords;
      }
    else if is_alert_deduplicated ~keeper_name:meta.name ~reasons then
      {
        empty_interesting_alert_result with
        enabled = true;
        threshold;
        score;
        reasons;
        keywords;
      }
    else
      let now_ts = Time_compat.now () in
      let alert_id = Printf.sprintf "%s-%d" (Keeper_id.Trace_id.to_string meta.runtime.trace_id) (int_of_float (now_ts *. 1000.0)) in
      let alert_text =
        keeper_alert_text
          ~meta
          ~score
          ~reasons
          ~keywords
          ~message
          ~reply
          ~work_kind
          ~context_ratio
          ~goal_alignment
          ~response_alignment
      in
      let alert_json =
        `Assoc [
          ("ts", `String (now_iso ()));
          ("ts_unix", `Float now_ts);
          ("alert_id", `String alert_id);
          ("name", `String meta.name);
          ("agent_name", `String meta.agent_name);
          ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
          ("generation", `Int meta.runtime.generation);
          ("score", `Float score);
          ("threshold", `Float threshold);
          ("reasons", `List (List.map (fun s -> `String s) reasons));
          ("keywords", `List (List.map (fun s -> `String s) keywords));
          ("work_kind", `String work_kind);
          ("tool_call_count", `Int tool_call_count);
          ("context_ratio", `Float context_ratio);
          ("goal_alignment", `Float goal_alignment);
          ("response_alignment", `Float response_alignment);
          ("message_preview", `String (short_preview ~max_len:260 message));
          ("reply_preview", `String (short_preview ~max_len:360 reply));
        ]
      in
      (try append_jsonl_line (keeper_alerts_path ctx.config) alert_json with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Log.Keeper.error "alert JSONL write failed: %s" (Printexc.to_string exn));
      Prometheus.inc_counter Prometheus.metric_keeper_alert_persist_failures ~labels:[("kind", "alert")] ();
      let board_result =
        run_alert_channel_with_retry ctx
          ~channel:"board"
          ~enabled:Env_config.KeeperAlert.board_enabled
          ~send_once:(fun () -> post_keeper_alert_board ~alert_text)
      in
      let slack_enabled =
        Env_config.KeeperAlert.slack_enabled
        && String.trim Env_config.KeeperAlert.slack_webhook_url <> ""
      in
      let slack_result =
        run_alert_channel_with_retry ctx
          ~channel:"slack"
          ~enabled:slack_enabled
          ~send_once:(fun () -> post_keeper_alert_slack ~alert_text)
      in
      let slack_dm_target = String.trim Env_config.KeeperAlert.slack_dm_user_id in
      let slack_dm_enabled =
        Env_config.KeeperAlert.slack_dm_enabled
        && slack_dm_target <> ""
      in
      let slack_dm_result =
        run_alert_channel_with_retry ctx
          ~channel:"slack_dm"
          ~enabled:slack_dm_enabled
          ~send_once:(fun () -> post_keeper_alert_slack_dm ~alert_text ~user_id:slack_dm_target)
      in
      let github_enabled =
        Env_config.KeeperAlert.github_enabled
        && String.trim Env_config.KeeperAlert.github_repo <> ""
        && score >= Env_config.KeeperAlert.github_min_score
      in
      let gh_title =
        Printf.sprintf "[keeper-alert] %s score %.2f (%s)"
          meta.name score (String.concat "," (if reasons = [] then [ "signal" ] else reasons))
      in
      let gh_body =
        utf8_safe_prefix_bytes
          (alert_text ^ "\n\n---\n\nraw alert json:\n" ^ Yojson.Safe.pretty_to_string alert_json)
          ~max_bytes:(max 800 Env_config.KeeperAlert.max_body_chars)
      in
      let github_result =
        run_alert_channel_with_retry ctx
          ~channel:"github"
          ~enabled:github_enabled
          ~send_once:(fun () -> post_keeper_alert_github ~title:gh_title ~body:gh_body)
      in
      let channels = [ board_result; slack_result; slack_dm_result; github_result ] in
      let attempted_failures =
        channels
        |> List.filter (fun r -> r.attempted && not r.success)
      in
      let attempted_success =
        channels
        |> List.exists (fun r -> r.attempted && r.success)
      in
      let retry_queued = attempted_failures <> [] in
      let deadlettered = attempted_failures <> [] && not attempted_success in
      if retry_queued then
        (try
           append_jsonl_line
             (keeper_alert_retry_path ctx.config)
             (`Assoc [
                ("ts", `String (now_iso ()));
                ("ts_unix", `Float now_ts);
                ("alert_id", `String alert_id);
                ("alert", alert_json);
                ("failed_channels",
                  `List (List.map alert_channel_result_to_json attempted_failures));
              ])
         with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
           Log.Keeper.error "failed-channels JSONL write failed: %s" (Printexc.to_string exn));
           Prometheus.inc_counter Prometheus.metric_keeper_alert_persist_failures ~labels:[("kind", "failed_channels")] ();
      if deadlettered then
        (try
           append_jsonl_line
             (keeper_alert_deadletter_path ctx.config)
             (`Assoc [
                ("ts", `String (now_iso ()));
                ("ts_unix", `Float now_ts);
                ("alert_id", `String alert_id);
                ("alert", alert_json);
                ("channels",
                  `List (List.map alert_channel_result_to_json channels));
              ])
         with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
           Log.Keeper.error "deadletter JSONL write failed: %s" (Printexc.to_string exn));
           Prometheus.inc_counter Prometheus.metric_keeper_alert_persist_failures ~labels:[("kind", "deadletter")] ();
      {
        enabled = true;
        triggered = true;
        score;
        threshold;
        reasons;
        keywords;
        alert_id = Some alert_id;
        channels;
        retry_queued;
        deadlettered;
      }

include Keeper_skill_routing
include Keeper_alerting_path
