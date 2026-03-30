(** Decision Executor - Turn council decisions into real actions

    토론/투표 결과를 실제 시스템 변경으로 연결.

    Design: Parse, Don't Validate.
    - [action_mapping] stores a [build_action] function, not a pre-built
      action value.  Regex capture groups feed the builder directly —
      no placeholder values, no post-hoc re-extraction.
    - Regexes are compiled once at module initialisation.
    - Deterministic (build) / non-deterministic (execute) boundary is
      explicit: [build_action] is pure, [execute_action] is effectful.

    @since MASC v2.7.0
*)

(** {1 Types} *)

(** Action types that can be executed *)
type action_kind =
  | ExecCommand of string list       (** Run a command with argv (no shell) *)
  | ConfigChange of string * string  (** key, value *)
  | Notification of string * string  (** target, message *)
  | GitHubAction of github_action    (** GitHub CLI action *)
  | Custom of string                 (** Custom action identifier *)

and github_action =
  | MergePR of int                   (** PR number *)
  | ClosePR of int
  | ApproveReview of int
  | CreateIssue of string * string   (** title, body *)

(** Execution result *)
type exec_result = {
  success: bool;
  stdout: string;
  stderr: string;
  output: string;
  timestamp: float;
}

(** Decision to action mapping.

    [build_action] receives the regex match group from [compiled_re] and
    returns either a validated [action_kind] or an error message.
    This eliminates placeholder values and post-hoc re-extraction. *)
type action_mapping = {
  compiled_re : Re.re;
  pattern_source : string;
  build_action : Re.Group.t -> (action_kind, string) result;
  describe : string -> string;
  requires_unanimous : bool;
  min_threshold : float;
}

(** {1 Helpers — pure, deterministic} *)

(** Extract the first integer from a regex group's first capture.
    Returns [Error] if no integer can be parsed. *)
let int_of_group_1 (group : Re.Group.t) ~(context : string) : (int, string) result =
  match Re.Group.get_opt group 1 with
  | Some s -> (
      match int_of_string_opt s with
      | Some n -> Ok n
      | None -> Error (Printf.sprintf "%s: capture %S is not an integer" context s))
  | None -> Error (Printf.sprintf "%s: no capture group 1 in match" context)

let compile pat = Re.compile (Re.Pcre.re ~flags:[`CASELESS] pat)

(** {1 Built-in Patterns — compiled once at module init} *)

let default_mappings : action_mapping list =
  let merge_re = compile "merge pr #?([0-9]+)" in
  let close_re = compile "close pr #?([0-9]+)" in
  let deploy_re = compile "deploy (v?[0-9.]+)" in
  [
    { compiled_re = merge_re;
      pattern_source = "merge pr #?([0-9]+)";
      build_action = (fun group ->
        int_of_group_1 group ~context:"MergePR"
        |> Result.map (fun n -> GitHubAction (MergePR n)));
      describe = (fun topic ->
        match Re.exec_opt merge_re (String.lowercase_ascii topic) with
        | Some g -> (
            match int_of_group_1 g ~context:"MergePR" with
            | Ok n -> Printf.sprintf "gh pr merge %d" n
            | Error _ -> "gh pr merge ?")
        | None -> "gh pr merge ?");
      requires_unanimous = false;
      min_threshold = 0.6;
    };
    { compiled_re = close_re;
      pattern_source = "close pr #?([0-9]+)";
      build_action = (fun group ->
        int_of_group_1 group ~context:"ClosePR"
        |> Result.map (fun n -> GitHubAction (ClosePR n)));
      describe = (fun topic ->
        match Re.exec_opt close_re (String.lowercase_ascii topic) with
        | Some g -> (
            match int_of_group_1 g ~context:"ClosePR" with
            | Ok n -> Printf.sprintf "gh pr close %d" n
            | Error _ -> "gh pr close ?")
        | None -> "gh pr close ?");
      requires_unanimous = false;
      min_threshold = 0.5;
    };
    { compiled_re = deploy_re;
      pattern_source = "deploy (v?[0-9.]+)";
      build_action = (fun group ->
        let version = match Re.Group.get_opt group 1 with
          | Some v -> v
          | None -> "unknown"
        in
        Error (Printf.sprintf
          "deploy action not implemented for version %S — \
           requires deployment pipeline integration" version));
      describe = (fun _topic -> "deploy (not implemented)");
      requires_unanimous = true;
      min_threshold = 1.0;
    };
  ]

(** {1 Pattern Matching — deterministic} *)

(** Match a topic against a mapping's pre-compiled regex. *)
let match_mapping (mapping : action_mapping) topic : Re.Group.t option =
  let text_lower = String.lowercase_ascii topic in
  Re.exec_opt mapping.compiled_re text_lower

(** Find the first matching mapping for a topic. *)
let find_action topic =
  List.find_opt (fun m -> match_mapping m topic <> None) default_mappings

(** {1 Action Execution — non-deterministic, effectful} *)

let read_all_from_ic ic =
  let buf = Buffer.create 4096 in
  (try
     while true do
       Buffer.add_char buf (input_char ic)
     done
   with End_of_file -> ());
  Buffer.contents buf

let combine_output ~stdout ~stderr =
  let stdout = String.trim stdout in
  let stderr = String.trim stderr in
  match stdout, stderr with
  | "", "" -> ""
  | s, "" -> s
  | "", e -> e
  | s, e ->
      Printf.sprintf {|[stdout]
%s

[stderr]
%s|} s e

let execute_argv argv =
  let timestamp () = Time_compat.now () in
  let do_exec () =
    match argv with
    | [] ->
        { success = false;
          stdout = "";
          stderr = "Empty argv";
          output = "Empty argv";
          timestamp = timestamp () }
    | prog :: _ ->
        try
          let stdout_ic, stdin_oc, stderr_ic =
            Unix.open_process_args_full prog (Array.of_list argv) (Unix.environment ())
          in
          let stdout = (try read_all_from_ic stdout_ic with Sys_error _ -> "") in
          let stderr = (try read_all_from_ic stderr_ic with Sys_error _ -> "") in
          let status = Unix.close_process_full (stdout_ic, stdin_oc, stderr_ic) in
          let success = match status with Unix.WEXITED 0 -> true | _ -> false in
          let output = combine_output ~stdout ~stderr in
          { success; stdout; stderr; output; timestamp = timestamp () }
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | e ->
          let err = Printexc.to_string e in
          { success = false;
            stdout = "";
            stderr = err;
            output = err;
            timestamp = timestamp () }
  in
  Eio_guard.run_in_systhread do_exec

let github_argv action =
  match action with
  | MergePR pr_num ->
      ["gh"; "pr"; "merge"; string_of_int pr_num; "--auto"; "--merge"]
  | ClosePR pr_num ->
      ["gh"; "pr"; "close"; string_of_int pr_num]
  | ApproveReview pr_num ->
      ["gh"; "pr"; "review"; string_of_int pr_num; "--approve"]
  | CreateIssue (title, body) ->
      ["gh"; "issue"; "create"; "--title"; title; "--body"; body]

let execute_github action =
  execute_argv (github_argv action)

let rec ensure_dir path =
  if not (Sys.file_exists path) then begin
    let parent = Filename.dirname path in
    if parent <> path && not (Sys.file_exists parent) then
      ensure_dir parent;
    try Unix.mkdir path 0o755
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let execute_config_change key value =
  let config_dir = ".masc/config" in
  let config_file = Filename.concat config_dir (key ^ ".json") in
  try
    ensure_dir config_dir;
    let json = `Assoc [("key", `String key); ("value", `String value);
                       ("updated_at", `Float (Time_compat.now ()))] in
    Fs_compat.save_file config_file (Yojson.Safe.pretty_to_string json);
    let msg = Printf.sprintf "Config written: %s = %s → %s" key value config_file in
    { success = true;
      stdout = msg;
      stderr = "";
      output = msg;
      timestamp = Time_compat.now () }
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    let msg = Printf.sprintf "Config error: %s" (Printexc.to_string exn) in
    { success = false;
      stdout = "";
      stderr = msg;
      output = msg;
      timestamp = Time_compat.now () }

let execute_notification target message =
  let notify_file = ".masc/notifications.jsonl" in
  try
    let json = `Assoc [
      ("target", `String target);
      ("message", `String message);
      ("timestamp", `Float (Time_compat.now ()))
    ] in
    Fs_compat.append_file notify_file (Yojson.Safe.to_string json ^ "\n");
    Log.Misc.info "[Council] %s: %s" target message;
    let msg = Printf.sprintf "Notified %s: %s" target message in
    { success = true;
      stdout = msg;
      stderr = "";
      output = msg;
      timestamp = Time_compat.now () }
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    let msg = Printf.sprintf "Notification error: %s" (Printexc.to_string exn) in
    { success = false;
      stdout = "";
      stderr = msg;
      output = msg;
      timestamp = Time_compat.now () }

let execute_action action =
  match action with
  | ExecCommand argv -> execute_argv argv
  | ConfigChange (key, value) -> execute_config_change key value
  | Notification (target, message) -> execute_notification target message
  | GitHubAction gh -> execute_github gh
  | Custom id ->
    let msg = Printf.sprintf "Unknown custom action: %s" id in
    { success = false;
      stdout = "";
      stderr = msg;
      output = msg;
      timestamp = Time_compat.now () }

(** {1 Decision Processing} *)

let check_threshold result mapping =
  match result with
  | Consensus.Unanimous Consensus.Approve -> true
  | Consensus.Majority n ->
    not mapping.requires_unanimous &&
    (float_of_int n >= mapping.min_threshold *. 100.0)
  | _ -> false

(** Execute decision based on voting result.

    Flow: topic -> [find_action] -> [build_action group] -> [execute_action].
    The build step is deterministic; the execute step is effectful. *)
let execute_decision ~topic ~result : exec_result option =
  match find_action topic with
  | None ->
    Log.Misc.warn "Executor: no action mapping for topic: %s" topic;
    None
  | Some mapping ->
    if check_threshold result mapping then begin
      Log.Misc.info "Executor: executing action for: %s" topic;
      match match_mapping mapping topic with
      | None ->
        Log.Misc.error "Executor: pattern matched in find but not in execute for: %s" topic;
        None
      | Some group ->
        match mapping.build_action group with
        | Ok action -> Some (execute_action action)
        | Error msg ->
          Log.Misc.error "Executor: %s" msg;
          Some { success = false;
                 stdout = "";
                 stderr = msg;
                 output = msg;
                 timestamp = Time_compat.now () }
    end else begin
      Log.Misc.info "Executor: threshold not met for: %s" topic;
      None
    end

(** {1 Dry Run} *)

let dry_run ~topic ~result : string =
  match find_action topic with
  | None -> "No action would be taken (no matching pattern)"
  | Some mapping ->
    if check_threshold result mapping then
      Printf.sprintf "Would execute: %s" (mapping.describe topic)
    else
      Printf.sprintf "Would NOT execute (threshold: %.0f%%, requires_unanimous: %b)"
        (mapping.min_threshold *. 100.0) mapping.requires_unanimous
