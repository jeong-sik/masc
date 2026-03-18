(** Keeper_alerting — alert fanout, skill routing, path safety checks,
    and tool-call preparation helpers for keeper execution. *)

open Keeper_types
open Keeper_memory

let keeper_llm_tools = Tool_shard.keeper_llm_tools

let merge_usage
    (a : Llm.token_usage)
    (b : Llm.token_usage) : Llm.token_usage =
  { Agent_sdk.Types.input_tokens = a.input_tokens + b.input_tokens;
    output_tokens = a.output_tokens + b.output_tokens;
    cache_creation_input_tokens =
      a.cache_creation_input_tokens + b.cache_creation_input_tokens;
    cache_read_input_tokens =
      a.cache_read_input_tokens + b.cache_read_input_tokens }

let contains_ci (haystack : string) (needle : string) : bool =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  if n = "" then false
  else
    try
      let _ = Str.search_forward (Str.regexp_string n) h 0 in
      true
    with Not_found -> false

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
        | Some s when String.trim s <> "" -> Some (short_preview ~max_len:280 s)
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
let alert_dedup_window_sec =
  match Sys.getenv_opt "MASC_ALERT_DEDUP_WINDOW_SEC" with
  | Some s -> (try max 5.0 (float_of_string (String.trim s)) with Failure _ -> 60.0)
  | None -> 60.0

let alert_dedup_table : (string, float) Hashtbl.t = Hashtbl.create 32
let alert_dedup_mutex = Eio.Mutex.create ()

let alert_dedup_key ~(keeper_name : string) ~(reasons : string list) : string =
  let sorted = List.sort String.compare reasons in
  keeper_name ^ ":" ^ String.concat "," sorted

let is_alert_deduplicated ~(keeper_name : string) ~(reasons : string list) : bool =
  Eio.Mutex.use_rw ~protect:true alert_dedup_mutex (fun () ->
    let key = alert_dedup_key ~keeper_name ~reasons in
    let now = Time_compat.now () in
    match Hashtbl.find_opt alert_dedup_table key with
    | Some last_ts when now -. last_ts < alert_dedup_window_sec -> true
    | _ ->
      Hashtbl.replace alert_dedup_table key now;
      false)

let keeper_alert_signal
    ~(message : string)
    ~(reply : string)
    ~(context_ratio : float)
    ~(goal_alignment : float)
    ~(response_alignment : float)
    ~(tool_call_count : int)
    ~(auto_rules : keeper_auto_rule_eval) : float * string list * string list =
  let corpus = String.lowercase_ascii (message ^ "\n" ^ reply) in
  let keyword_weights = [
    ("장애", 0.35);
    ("사고", 0.30);
    ("롤백", 0.30);
    ("긴급", 0.25);
    ("critical", 0.30);
    ("urgent", 0.22);
    ("incident", 0.25);
    ("outage", 0.38);
    ("oncall", 0.18);
    ("p0", 0.32);
    ("sev1", 0.32);
    ("security", 0.35);
    ("breach", 0.45);
    ("data loss", 0.45);
    ("failover", 0.22);
    ("hotfix", 0.20);
    ("downtime", 0.28);
  ] in
  let keyword_hits =
    keyword_weights
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
    score := !score +. 0.45;
    reasons := "guardrail_stop" :: !reasons
  end;
  if auto_rules.handoff && context_ratio >= 0.88 then begin
    score := !score +. 0.16;
    reasons := "handoff_pressure" :: !reasons
  end;
  if goal_alignment < 0.20 && response_alignment < 0.16 then begin
    score := !score +. 0.12;
    reasons := "low_alignment" :: !reasons
  end;
  if tool_call_count >= 2 then begin
    score := !score +. 0.06;
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
  let excerpt_cap = max 240 Env_config.KeeperAlert.max_body_chars in
  let message_preview = short_preview ~max_len:(min excerpt_cap 300) message in
  let reply_preview = short_preview ~max_len:(min excerpt_cap 420) reply in
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
    meta.name score meta.trace_id meta.generation work_kind
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
  let fields = ref [
    ("author", `String author);
    ("content", `String alert_text);
    ("visibility", `String visibility);
  ] in
  (match hearth_opt with
   | Some h -> fields := ("hearth", `String h) :: !fields
   | None -> ());
  let (ok, res) = Tool_board.handle_tool "masc_board_post" (`Assoc (List.rev !fields)) in
  if ok then (true, Some "board_posted") else (false, Some res)

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
        ~timeout_sec:15.0
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
    | Some v when String.trim v <> "" -> Some (String.trim v)
    | _ -> None
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
      ~timeout_sec:15.0
      ~stdin_content:body
      argv
  in
  match status with
  | Unix.WEXITED 0 ->
      (try
         Ok (Yojson.Safe.from_string out)
       with exn ->
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
    let (status, out) = Process_eio.run_argv_with_status ~timeout_sec:20.0 args in
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
  let threshold = max 0.0 (min 1.0 Env_config.KeeperAlert.min_score) in
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
      let alert_id = Printf.sprintf "%s-%d" meta.trace_id (int_of_float (now_ts *. 1000.0)) in
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
          ("trace_id", `String meta.trace_id);
          ("generation", `Int meta.generation);
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
      (try append_jsonl_line (keeper_alerts_path ctx.config) alert_json with exn ->
      Log.Keeper.error "alert JSONL write failed: %s" (Printexc.to_string exn));
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
         with exn ->
           Log.Keeper.error "failed-channels JSONL write failed: %s" (Printexc.to_string exn));
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
         with exn ->
           Log.Keeper.error "deadletter JSONL write failed: %s" (Printexc.to_string exn));
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

type keeper_skill_route = {
  primary_skill: string;
  secondary_skills: string list;
  reason: string;
}

type keeper_skill_selection_mode =
  | SkillSelectHeuristic
  | SkillSelectAgent

type keeper_skill_route_resolution = {
  route: keeper_skill_route;
  selection_mode: string;
  provenance: string;
}

let keeper_skill_selection_mode () : keeper_skill_selection_mode =
  match Sys.getenv_opt "MASC_KEEPER_SKILL_SELECTION" with
  | None -> SkillSelectAgent
  | Some raw ->
      let v = String.lowercase_ascii (String.trim raw) in
      if v = "" || v = "agent" || v = "llm" || v = "auto"
      then SkillSelectAgent
      else SkillSelectHeuristic

let keeper_allowed_skills = [
  "masc-heartbeat";
  "lodge-social";
  "masc-keeper-autonomy";
  "trpg-roleplay";
]

let canonical_keeper_skill_token (raw : string) : string option =
  match String.lowercase_ascii (String.trim raw) with
  | "masc-heartbeat" | "masc_heartbeat" | "heartbeat" -> Some "masc-heartbeat"
  | "lodge-social" | "lodge_social" | "lodge" | "social" -> Some "lodge-social"
  | "masc-keeper-autonomy"
  | "masc_keeper_autonomy"
  | "keeper-autonomy"
  | "keeper"
  | "autonomy" ->
      Some "masc-keeper-autonomy"
  | "trpg-roleplay" | "trpg_roleplay" | "trpg" | "roleplay" | "rp" ->
      Some "trpg-roleplay"
  | _ -> None

let unique_skills_preserve_order (xs : string list) : string list =
  List.fold_left
    (fun acc x -> if List.mem x acc then acc else acc @ [x])
    []
    xs

let skill_match_count_ci ~(text : string) ~(keywords : string list) : int =
  List.fold_left
    (fun acc keyword -> if contains_ci text keyword then acc + 1 else acc)
    0 keywords

let keeper_skill_priority ~(soul_profile : string) (skill : string) : int =
  let profile =
    canonical_soul_profile soul_profile |> Option.value ~default:default_soul_profile
  in
  match profile, skill with
  | "safety", "masc-heartbeat" -> 0
  | "safety", "masc-keeper-autonomy" -> 1
  | "safety", "lodge-social" -> 2
  | "delivery", "masc-keeper-autonomy" -> 0
  | "delivery", "masc-heartbeat" -> 1
  | "delivery", "lodge-social" -> 2
  | "research", "lodge-social" -> 0
  | "research", "masc-keeper-autonomy" -> 1
  | "research", "masc-heartbeat" -> 2
  | _, "masc-keeper-autonomy" -> 0
  | _, "masc-heartbeat" -> 1
  | _, "lodge-social" -> 2
  | _ -> 9

let route_keeper_skill ~(soul_profile : string) ~(message : string) : keeper_skill_route =
  let heartbeat_keywords = [
    "heartbeat"; "alive"; "status"; "health"; "diagnose"; "liveness";
    "하트비트"; "살아"; "상태"; "진단"; "헬스";
  ] in
  let lodge_keywords = [
    "board"; "post"; "comment"; "feed"; "social"; "lodge"; "k2k";
    "보드"; "포스트"; "댓글"; "피드"; "활동"; "소셜";
  ] in
  let keeper_keywords = [
    "keeper"; "handoff"; "compaction"; "context"; "generation"; "trace"; "memory";
    "키퍼"; "승계"; "핸드오프"; "컴팩팅"; "컨텍스트"; "세대"; "메모리";
  ] in
  let profile =
    canonical_soul_profile soul_profile |> Option.value ~default:default_soul_profile
  in
  let heartbeat_score = skill_match_count_ci ~text:message ~keywords:heartbeat_keywords in
  let lodge_score = skill_match_count_ci ~text:message ~keywords:lodge_keywords in
  let keeper_score = skill_match_count_ci ~text:message ~keywords:keeper_keywords in
  let heartbeat_bonus, lodge_bonus, keeper_bonus =
    match profile with
    | "safety" -> (1, 0, 1)
    | "delivery" -> (0, 0, 1)
    | "research" -> (0, 1, 1)
    | "relationship" -> (0, 1, 1)
    | _ -> (0, 0, 1)
  in
  let scored = [
    ("masc-heartbeat", heartbeat_score + heartbeat_bonus);
    ("lodge-social", lodge_score + lodge_bonus);
    ("masc-keeper-autonomy", keeper_score + keeper_bonus);
  ] in
  let sorted =
    List.sort
      (fun (sa, score_a) (sb, score_b) ->
         let c = compare score_b score_a in
         if c <> 0 then c
         else
           compare
             (keeper_skill_priority ~soul_profile:profile sa)
             (keeper_skill_priority ~soul_profile:profile sb))
      scored
  in
  let primary_skill =
    match sorted with
    | (name, _) :: _ -> name
    | [] -> "masc-keeper-autonomy"
  in
  let secondary_skills =
    sorted
    |> List.filter_map (fun (name, score) ->
           if name = primary_skill || score <= 0 then None else Some name)
    |> take 1
  in
  let reason =
    Printf.sprintf
      "profile=%s; scores{heartbeat=%d,lodge=%d,keeper=%d}"
      profile
      (heartbeat_score + heartbeat_bonus)
      (lodge_score + lodge_bonus)
      (keeper_score + keeper_bonus)
  in
  { primary_skill; secondary_skills; reason }

let skill_route_header (route : keeper_skill_route) : string =
  match route.secondary_skills with
  | [] -> Printf.sprintf "SKILL: %s" route.primary_skill
  | secs ->
      Printf.sprintf
        "SKILL: %s (+%s)"
        route.primary_skill
        (String.concat ", " secs)

let ensure_skill_route_header ~(route : keeper_skill_route) (raw : string) : string =
  let trimmed = String.trim raw in
  if trimmed = "" then
    skill_route_header route
  else
    let first_line =
      match String.split_on_char '\n' trimmed with
      | head :: _ -> String.trim head
      | [] -> ""
    in
    let already_tagged =
      match strip_prefix_ci ~prefix:"SKILL:" first_line with
      | Some _ -> true
      | None -> false
    in
    if already_tagged then raw
    else Printf.sprintf "%s\n%s" (skill_route_header route) raw

let strip_skill_route_lines (raw : string) : string =
  let lines = String.split_on_char '\n' raw in
  let keep line =
    let trimmed = String.trim line in
    if trimmed = "" then true
    else
      match strip_prefix_ci ~prefix:"SKILL:" trimmed with
      | Some _ -> false
      | None -> (
          match strip_prefix_ci ~prefix:"SKILL_REASON:" trimmed with
          | Some _ -> false
          | None -> true)
  in
  lines |> List.filter keep |> String.concat "\n"

let parse_skill_line (line : string) : (string * string list) option =
  match strip_prefix_ci ~prefix:"SKILL:" line with
  | None -> None
  | Some payload ->
      let payload = String.trim payload in
      if payload = "" then None
      else
        let payload_len = String.length payload in
        let rec first_sep i =
          if i >= payload_len then payload_len
          else
            match payload.[i] with
            | ' ' | '\t' | '(' -> i
            | _ -> first_sep (i + 1)
        in
        let primary_end = first_sep 0 in
        let primary_raw = String.sub payload 0 primary_end |> String.trim in
        let rest =
          if primary_end >= payload_len then ""
          else String.sub payload primary_end (payload_len - primary_end) |> String.trim
        in
        let secondary_raw_opt =
          if String.length rest >= 2 && String.sub rest 0 2 = "(+" then
            try
              let close_idx = Str.search_forward (Str.regexp_string ")") rest 2 in
              let inside = String.sub rest 2 (close_idx - 2) |> String.trim in
              if inside = "" then None else Some inside
            with Not_found ->
              None
          else
            None
        in
        match canonical_keeper_skill_token primary_raw with
        | None -> None
        | Some primary ->
            let secondary =
              match secondary_raw_opt with
              | None -> []
              | Some raw ->
                  raw
                  |> String.split_on_char ','
                  |> List.filter_map canonical_keeper_skill_token
                  |> unique_skills_preserve_order
                  |> List.filter (fun s -> s <> primary)
                  |> take 1
            in
            Some (primary, secondary)

let parse_skill_reason_line (line : string) : string option =
  match strip_prefix_ci ~prefix:"SKILL_REASON:" line with
  | Some v -> trim_nonempty v
  | None -> None

let agent_selected_skill_route_from_reply (raw : string) : keeper_skill_route option =
  let lines =
    raw
    |> String.split_on_char '\n'
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
  in
  match lines with
  | [] -> None
  | first :: tail ->
      (match parse_skill_line first with
       | None -> None
       | Some (primary, secondary) ->
           let reason =
             tail
             |> take 3
             |> List.find_map parse_skill_reason_line
             |> Option.value ~default:"agent-selected"
           in
           Some { primary_skill = primary; secondary_skills = secondary; reason })

let resolved_keeper_skill_route
    ~(selection_mode : keeper_skill_selection_mode)
    ~(fallback_route : keeper_skill_route)
    ~(reply_raw : string) : keeper_skill_route_resolution =
  match selection_mode with
  | SkillSelectHeuristic ->
      { route = fallback_route; selection_mode = "heuristic"; provenance = "fallback" }
  | SkillSelectAgent ->
      (match agent_selected_skill_route_from_reply reply_raw with
       | Some route ->
           { route; selection_mode = "agent"; provenance = "judgment" }
       | None ->
           { route = fallback_route; selection_mode = "heuristic"; provenance = "fallback" })

let skill_route_system_prompt_heuristic
    ~(base_system_prompt : string)
    ~(route : keeper_skill_route) : string =
  Printf.sprintf
    "%s\n\n\
     Skill routing policy (strict):\n\
     - Selected primary skill: %s\n\
     - Secondary skill(s): %s\n\
     - Selection reason: %s\n\
     - First line of assistant output MUST be exactly `%s`.\n\
     - After the first line, answer normally and concretely.\n\
     - Do not fabricate capabilities beyond the selected skills."
    base_system_prompt
    route.primary_skill
    (if route.secondary_skills = [] then "none" else String.concat ", " route.secondary_skills)
    route.reason
    (skill_route_header route)

let skill_route_system_prompt_agent
    ~(base_system_prompt : string)
    ~(fallback_route : keeper_skill_route)
    ~(soul_profile : string) : string =
  Printf.sprintf
    "%s\n\n\
     Skill routing policy (agent-selected):\n\
     - Available skills: %s\n\
     - SOUL profile: %s\n\
     - You MUST choose exactly one primary skill from the list above.\n\
     - You MAY add at most one secondary skill.\n\
     - First line MUST be: SKILL: <primary> (+<secondary>)\n\
     - Second line SHOULD be: SKILL_REASON: <short reason>\n\
     - If uncertain, default to `%s`.\n\
     - After those lines, answer normally and concretely.\n\
     - Do not fabricate capabilities beyond chosen skills."
    base_system_prompt
    (String.concat ", " keeper_allowed_skills)
    soul_profile
    fallback_route.primary_skill

include Keeper_alerting_path
