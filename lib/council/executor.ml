(** Decision Executor - Turn council decisions into real actions

    토론/투표 결과를 실제 시스템 변경으로 연결.
    
    Example:
    - "Approve PR #123" → gh pr merge 123
    - "Use OCaml" → update config
    - "Deploy v2.0" → run deploy script
    
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

(** Decision to action mapping *)
type action_mapping = {
  pattern: string;                   (** Regex pattern to match topic *)
  action: action_kind;
  requires_unanimous: bool;          (** Only execute if unanimous *)
  min_threshold: float;              (** Minimum approval threshold *)
}

(** {1 Built-in Patterns} *)

let default_mappings : action_mapping list = [
  (* PR merge pattern - PCRE syntax *)
  {
    pattern = "merge pr #?([0-9]+)";
    action = GitHubAction (MergePR 0);  (* placeholder: actual PR# extracted at execution time *)
    requires_unanimous = false;
    min_threshold = 0.6;
  };
  (* PR close pattern *)
  {
    pattern = "close pr #?([0-9]+)";
    action = GitHubAction (ClosePR 0);  (* placeholder: actual PR# extracted at execution time *)
    requires_unanimous = false;
    min_threshold = 0.5;
  };
  (* Deploy pattern *)
  {
    pattern = "deploy (v?[0-9.]+)";
    action = ExecCommand ["echo"; "Deploy placeholder"];  (* stub: blocked at execution time *)
    requires_unanimous = true;
    min_threshold = 1.0;
  };
]

(** {1 Pattern Matching} *)

let match_pattern pattern text =
  try
    let re = Re.Pcre.re ~flags:[`CASELESS] pattern |> Re.compile in
    let text_lower = String.lowercase_ascii text in
    match Re.exec_opt re text_lower with
    | Some group -> Some (Re.Group.get group 0)
    | None -> None
  with Failure _ | Not_found -> None

let extract_number text =
  try
    let re = Re.Pcre.re "[0-9]+" |> Re.compile in
    match Re.exec_opt re text with
    | Some group -> Some (int_of_string (Re.Group.get group 0))
    | None -> None
  with Failure _ | Not_found -> None

(** {1 Action Execution} *)

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
        (* NOTE: We intentionally never write to stdin. Most commands we execute
           (e.g. gh) do not read stdin; leaving it open avoids double-closing
           issues with [close_process_full]. *)
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

(** Write config to JSON file in .masc/config/ *)
let execute_config_change key value =
  let config_dir = ".masc/config" in
  let config_file = Filename.concat config_dir (key ^ ".json") in
  try
    (* Ensure directory exists *)
    ensure_dir config_dir;
    (* Write JSON config *)
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

(** Send notification to target (file-based for now) *)
let execute_notification target message =
  let notify_file = ".masc/notifications.jsonl" in
  try
    let json = `Assoc [
      ("target", `String target);
      ("message", `String message);
      ("timestamp", `Float (Time_compat.now ()))
    ] in
    Fs_compat.append_file notify_file (Yojson.Safe.to_string json ^ "\n");
    (* Also log to stderr for visibility *)
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

(** Check if voting result meets threshold *)
let check_threshold result mapping =
  match result with
  | Consensus.Unanimous Consensus.Approve -> true
  | Consensus.Majority n -> 
    not mapping.requires_unanimous && 
    (float_of_int n >= mapping.min_threshold *. 100.0)
  | _ -> false

(** Find matching action for a topic *)
let find_action topic =
  List.find_opt (fun m -> 
    match_pattern m.pattern topic <> None
  ) default_mappings

(** Execute decision based on voting result *)
let execute_decision ~topic ~result : exec_result option =
  match find_action topic with
  | None -> 
    Log.Misc.warn "Executor: no action mapping for topic: %s" topic;
    None
  | Some mapping ->
    if check_threshold result mapping then begin
      Log.Misc.info "Executor: executing action for: %s" topic;
      (* Extract parameters from topic if needed *)
      let action = match mapping.action with
        | GitHubAction (MergePR _) ->
          (match extract_number topic with
           | Some n -> Ok (GitHubAction (MergePR n))
           | None ->
             Error (Printf.sprintf
               "Council: cannot extract PR number from topic %S — \
                MergePR requires a valid PR number" topic))
        | GitHubAction (ClosePR _) ->
          (match extract_number topic with
           | Some n -> Ok (GitHubAction (ClosePR n))
           | None ->
             Error (Printf.sprintf
               "Council: cannot extract PR number from topic %S — \
                ClosePR requires a valid PR number" topic))
        | ExecCommand ["echo"; "Deploy placeholder"] ->
          Error (Printf.sprintf
            "Council: deploy action not implemented for topic %S — \
             requires deployment pipeline integration" topic)
        | other -> Ok other
      in
      (match action with
       | Ok a -> Some (execute_action a)
       | Error msg ->
         Log.Misc.error "Executor: %s" msg;
         Some { success = false;
                stdout = "";
                stderr = msg;
                output = msg;
                timestamp = Time_compat.now () })
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
      Printf.sprintf "Would execute: %s" 
        (match mapping.action with
         | ExecCommand argv -> Printf.sprintf "exec(%s)" (String.concat " " (List.map Filename.quote argv))
         | ConfigChange (k, v) -> Printf.sprintf "config(%s=%s)" k v
         | Notification (t, m) -> Printf.sprintf "notify(%s: %s)" t m
         | GitHubAction (MergePR _) -> Printf.sprintf "gh pr merge %s" 
             (match extract_number topic with Some n -> string_of_int n | None -> "?")
         | GitHubAction (ClosePR _) -> Printf.sprintf "gh pr close %s"
             (match extract_number topic with Some n -> string_of_int n | None -> "?")
         | GitHubAction (ApproveReview n) -> Printf.sprintf "gh pr review %d --approve" n
         | GitHubAction (CreateIssue (t, _)) -> Printf.sprintf "gh issue create '%s'" t
         | Custom id -> Printf.sprintf "custom(%s)" id)
    else
      Printf.sprintf "Would NOT execute (threshold: %.0f%%, requires_unanimous: %b)"
        (mapping.min_threshold *. 100.0) mapping.requires_unanimous
