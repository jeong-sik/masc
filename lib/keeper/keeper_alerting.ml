(** Keeper_alerting — alert fanout, skill routing, path safety checks,
    and tool-call preparation helpers for keeper execution. *)

(* tla-lint: file-scope: alert score/reason accumulators are local
   refs scoped to a single compute_alert_score call; output is a
   computed score+reasons pair, not a stateful FSM transition. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
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


let alert_retryable_error (msg : string) : bool =
  let text = String.lowercase_ascii (String.trim msg) in
  text <> ""
  && (String_util.contains_substring_ci text "timeout"
      || String_util.contains_substring_ci text "timed out"
      || String_util.contains_substring_ci text "429"
      || String_util.contains_substring_ci text "502"
      || String_util.contains_substring_ci text "503"
      || String_util.contains_substring_ci text "504"
      || String_util.contains_substring_ci text "connection reset"
      || String_util.contains_substring_ci text "connection refused"
      || String_util.contains_substring_ci text "temporary"
      || String_util.contains_substring_ci text "network")

let alert_retry_delay_seconds (attempt : int) : float =
  let base_ms = max 0 Env_config.KeeperAlert.retry_base_delay_ms in
  let rec pow2 n acc =
    if n <= 0 then acc else pow2 (n - 1) (acc * 2)
  in
  let factor = pow2 (max 0 (attempt - 1)) 1 in
  float_of_int (base_ms * factor) /. 1000.0

type alert_send_result =
  | Alert_sent of string option
  | Alert_failed of string option

type alert_channel_result =
  { channel : string
  ; attempted : bool
  ; success : bool
  ; attempts : int
  ; detail : string option
  }

let alert_send_success = function
  | Alert_sent _ -> true
  | Alert_failed _ -> false

let alert_send_detail = function
  | Alert_sent detail | Alert_failed detail -> detail

let run_alert_channel_with_retry
    (ctx : _ context)
    ~(channel : string)
    ~(enabled : bool)
    ~(send_once : unit -> alert_send_result) : alert_channel_result =
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
      let send_result = send_once () in
      let ok = alert_send_success send_result in
      let detail_opt = alert_send_detail send_result in
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


(** Alert dedup: suppress identical alerts within a time window (default 60s). *)
let alert_dedup_window_sec = Env_config.AlertDedup.window_sec

let alert_dedup_table : (string, float) Hashtbl.t = Hashtbl.create 32

(** Mutex protecting [alert_dedup_table].  [is_alert_deduplicated] runs
    from every keeper's alert scoring path, and keepers execute
    concurrently in the same workspace — so the previous implementation
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

let post_keeper_alert_board
    ~(alert_text : string) : alert_send_result =
  let author = let v = String.trim Env_config.KeeperAlert.board_author in
    if v = "" then "keeper-alert-bot" else v in
  let hearth_opt = let v = String.trim Env_config.KeeperAlert.board_hearth in
    if v = "" then None else Some v in
  let visibility = let v = String.trim Env_config.KeeperAlert.board_visibility in
    if v = "" then "internal" else v in
  let visibility =
    match Board_tool.visibility_of_string visibility with
    | Some value -> value
    | None -> Board.Internal
  in
  let meta_json = Some (`Assoc [ ("source", `String "keeper_alert_board") ]) in
  (* RFC-0233 §7: stamp the typed origin so an alert board post is no longer
     origin-less. [turn_ref] is [None] here (scoped down, not fabricated):
     [post_keeper_alert_board] only receives [~alert_text], and its sole caller
     [maybe_emit_interesting_alert] runs post-turn where [meta] is no longer a
     mint-once-safe turn reference (trace_id may have rotated on handoff). Root
     fix: thread the turn's minted [turn_ref] from the turn loop into the alert
     path when alert emission is wired back into the keeper turn — same
     "mint once, thread down" pattern used for keeper_speech. *)
  let origin = Board.keeper_authored_origin ~source:"keeper_alert" () in
  match
    Board_dispatch.create_post ~author ~content:alert_text
      ~post_kind:Board.System_post ?meta_json
      ~visibility ~ttl_hours:24 ?hearth:hearth_opt ~origin ()
  with
  | Ok _ -> Alert_sent (Some "board_posted")
  | Error e -> Alert_failed (Some (Board.show_board_error e))

let post_keeper_alert_slack
    ~(alert_text : string) : alert_send_result =
  let webhook = String.trim Env_config.KeeperAlert.slack_webhook_url in
  if webhook = "" then
    Alert_failed (Some "missing_webhook")
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
      Masc_exec.Exec_gate.run_argv_with_stdin_and_status
        ~actor:`System_notify
        ~raw_source:(String.concat " " argv)
        ~summary:"keeper alert slack webhook"

        ~stdin_content:payload
        argv
    in
    match status with
    | Unix.WEXITED 0 -> Alert_sent (Some "slack_posted")
    | Unix.WEXITED n ->
        Alert_failed (Some (Printf.sprintf "curl_exit_%d: %s" n (short_preview ~max_len:200 out)))
    | Unix.WSIGNALED n ->
        Alert_failed (Some (Printf.sprintf "curl_signaled_%d" n))
    | Unix.WSTOPPED n ->
        Alert_failed (Some (Printf.sprintf "curl_stopped_%d" n))

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
    Masc_exec.Exec_gate.run_argv_with_stdin_and_status
      ~actor:`System_notify
      ~raw_source:(String.concat " " argv)
      ~summary:"keeper alert slack api post"

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
    ~(user_id : string) : alert_send_result =
  let target = String.trim user_id in
  if target = "" then
    Alert_failed (Some "missing_dm_user_id")
  else
    match slack_alert_token () with
    | None -> Alert_failed (Some "missing_slack_token")
    | Some token ->
        let open_payload = `Assoc [ ("users", `String target) ] in
        match slack_api_post_json ~token ~endpoint:"conversations.open" ~payload:open_payload with
        | Error e -> Alert_failed (Some ("dm_open_failed: " ^ e))
        | Ok open_json ->
            (match slack_ok_or_error open_json with
             | Error e -> Alert_failed (Some ("dm_open_failed: " ^ e))
             | Ok () ->
                 let channel_id =
                   match Json_util.assoc_member_opt "channel" open_json with
                   | Some channel_json -> (
                       match Json_util.assoc_member_opt "id" channel_json with
                       | Some (`String s) when String.trim s <> "" -> Some s
                       | _ -> None)
                   | None -> None
                 in
                 (match channel_id with
                  | None -> Alert_failed (Some "dm_open_failed: missing_channel_id")
                  | Some cid ->
                      let post_payload = `Assoc [
                        ("channel", `String cid);
                        ("text", `String alert_text);
                      ] in
                      (match slack_api_post_json ~token ~endpoint:"chat.postMessage" ~payload:post_payload with
                       | Error e -> Alert_failed (Some ("dm_post_failed: " ^ e))
                       | Ok post_json ->
                           (match slack_ok_or_error post_json with
                            | Ok () -> Alert_sent (Some ("dm_sent:" ^ cid))
                            | Error e -> Alert_failed (Some ("dm_post_failed: " ^ e))))))

let split_csv_nonempty (raw : string) : string list =
  raw
  |> String.split_on_char ','
  |> List.map String.trim
  |> List.filter (fun s -> s <> "")

let post_keeper_alert_github
    ~(title : string)
    ~(body : string) : alert_send_result =
  let repo = String.trim Env_config.KeeperAlert.github_repo in
  if repo = "" then
    Alert_failed (Some "missing_repo")
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
      Masc_exec.Exec_gate.run_argv_with_status
        ~actor:`Workspace_git
        ~raw_source:(String.concat " " args)
        ~summary:"keeper alert gh issue create"

        args
    in
    match status with
    | Unix.WEXITED 0 -> Alert_sent (Some (short_preview ~max_len:200 out))
    | Unix.WEXITED n ->
        Alert_failed (Some (Printf.sprintf "credential_exit_%d: %s" n (short_preview ~max_len:200 out)))
    | Unix.WSIGNALED n ->
        Alert_failed (Some (Printf.sprintf "credential_signaled_%d" n))
    | Unix.WSTOPPED n ->
        Alert_failed (Some (Printf.sprintf "credential_stopped_%d" n))

include Keeper_skill_routing
include Keeper_alerting_path
