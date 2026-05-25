module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float
module Exec_shell_gate = Masc_exec_command_gate.Shell_command_gate

(** Code Write Tools — File write, edit, delete, shell, git for keeper agents.

    Security model:
    - Write operations restricted to allowed sandboxes
      (.worktrees/ checkouts and keeper playground clones)
    - Shell commands restricted to allowlist
    - Git push to main/master blocked
    - Git clone restricted to allowed GitHub orgs (config/tool_policy.toml)
    - File size limit: 1MB for writes
    - Binary file extension check inherited from Tool_code

    @since 2.128.0 *)

include Tool_code_write_schemas
open Masc_domain
open Tool_args

type context = {
  config : Coord.config;
  agent_name : string;
}

let max_write_size = 1024 * 1024  (* 1 MiB *)

let normalize_dir_prefix path =
  Tool_code.normalize_path path ^ "/"

let first_nonempty_line output =
  output
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.find_opt (fun s -> not (String.equal s ""))

let code_shell_command_context =
  Tool_code_write_shell_validate.code_shell_command_context
let validate_code_shell_command =
  Tool_code_write_shell_validate.validate_code_shell_command

type code_shell_exit_status =
  Tool_code_write_shell_validate.code_shell_exit_status =
  | Shell_ok
  | Shell_ok_expected_nonzero of string
  | Shell_error

let classify_code_shell_exit =
  Tool_code_write_shell_validate.classify_code_shell_exit

let git_common_root path =
  try
    match
      Masc_exec.Exec_gate.run_argv_with_status ~actor:`Coord_git ~raw_source:("git -C " ^ path ^ " rev-parse --git-common-dir") ~summary:"git common root lookup"
        ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:(Unknown "misc") ())
        [ "git"; "-C"; path; "rev-parse"; "--git-common-dir" ]
    with
    | Unix.WEXITED 0, output ->
      (match first_nonempty_line output with
       | None -> None
       | Some git_common_dir ->
         let git_common_dir =
           if Filename.is_relative git_common_dir
           then Filename.concat path git_common_dir
           else git_common_dir
         in
         Some (Tool_code.normalize_path (Filename.dirname git_common_dir)))
    | _ -> None
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Unix.Unix_error _ -> None
  | Sys_error _ -> None

let allowed_worktree_prefixes config =
  [ git_common_root config.Coord.base_path;
    git_common_root (Sys.getcwd ()) ]
  |> List.filter_map (fun root -> root)
  |> Json_util.dedupe_keep_order
  |> List.map (fun root -> normalize_dir_prefix (Filename.concat root ".worktrees"))

let repo_top_relative_write_path raw =
  let rec strip_current_dir path =
    if String.starts_with ~prefix:"./" path then
      strip_current_dir (String.sub path 2 (String.length path - 2))
    else
      path
  in
  let path = raw |> String.trim |> strip_current_dir in
  if String.equal path ""
     || (not (Filename.is_relative path))
     || String.equal path "."
     || String.equal path ".."
     || String.starts_with ~prefix:"../" path
     || String.starts_with ~prefix:"repos/" path
     || String.starts_with ~prefix:"mind/" path
  then
    None
  else
    let first_segment =
      match String.split_on_char '/' path with
      | segment :: _ -> segment
      | [] -> path
    in
    if
      List.mem first_segment
        [
          "bench";
          "bin";
          "docs";
          "examples";
          "lib";
          "ops";
          "scripts";
          "src";
          "test";
          "tests";
        ]
    then
      Some path
    else
      None

let agent_repos_dir ~(agent_name : string) config =
  Filename.concat config.Coord.base_path
    (Filename.concat
       (Tool_code.agent_playground_rel ~config ~agent_name)
       "repos")

let single_agent_repo_root ~(agent_name : string) config =
  let repos_dir = agent_repos_dir ~agent_name config in
  try
    if Sys.file_exists repos_dir && Sys.is_directory repos_dir then
      Sys.readdir repos_dir
      |> Array.to_list
      |> List.filter (fun name ->
        not (String.equal name ".")
        && not (String.equal name "..")
        &&
        let path = Filename.concat repos_dir name in
        Sys.file_exists path && Sys.is_directory path)
      |> function
      | [ repo_name ] -> Some (Filename.concat repos_dir repo_name)
      | [] | _ :: _ :: _ -> None
    else
      None
  with
  | Sys_error _ | Unix.Unix_error _ -> None

let normalize_writable_path ~(agent_name : string) config path =
  let path = Tool_code.normalize_agent_relative_path ~config ~agent_name path in
  match repo_top_relative_write_path path with
  | None -> path
  | Some rel -> (
      match single_agent_repo_root ~agent_name config with
      | Some repo_root -> Filename.concat repo_root rel
      | None -> path)

(* Security: Validate path is within an allowed writable sandbox.
   Uses canonical paths from Tool_code.validate_path — already normalized.
   Worktree paths are anchored to actual git common roots so a nested
   "/.worktrees/" segment elsewhere in the tree is not accepted.

   Playground writes are gated per-agent (#6527 iter 6): the caller
   must only be allowed to write inside its own backend-scoped playground
   bundle. This prevents one agent from mutating another agent's playground
   via the shared
   `masc_code_*` dispatch. Server-wide `.worktrees/` remains allowed
   so legacy server operations that need to touch repo worktrees
   continue to work. *)
let validate_writable_path ~(agent_name : string) config path =
  let path = normalize_writable_path ~agent_name config path in
  match Tool_code.validate_path config path with
  | Error e -> Error e
  | Ok canonical_path ->
    let worktree_prefixes = allowed_worktree_prefixes config in
    let agent_playground_prefix =
      normalize_dir_prefix
        (Filename.concat config.Coord.base_path
           (Tool_code.agent_playground_rel ~config ~agent_name))
    in
    if List.exists
         (fun prefix -> String.starts_with ~prefix canonical_path)
         worktree_prefixes
       || String.starts_with ~prefix:agent_playground_prefix canonical_path then
      Ok canonical_path
    else
      Error (System (System_error.IoError (Printf.sprintf
        "path_outside_sandbox: Write restricted to allowed sandboxes for agent %s. \
         Expected path prefix: %s (or /.worktrees/ for server ops). \
         Got: %s. Cross-agent playground writes are blocked — write \
         under your own playground only. Call masc_status if you are \
         unsure of your agent_name."
        agent_name
        agent_playground_prefix
        canonical_path)))

let path_is_directory path =
  try Sys.is_directory path with
  | Sys_error _ -> false

let missing_cwd_error_json ctx ~cwd ~resolved_cwd ?command ?action () =
  let hint =
    "cwd resolved inside the agent playground but is not an existing directory. \
     If this is task work, call masc_worktree_create with the task_id first, \
     then retry with the returned repos/<repo>/.worktrees/<worktree> path. \
     Docker keepers must use the Docker playground mapping; do not guess a \
     non-docker .masc/playground/<keeper>/ path."
  in
  let fields =
    [
      ("error", `String "cwd_not_directory");
      ("cwd", `String cwd);
      ("resolved_cwd", `String resolved_cwd);
      ("agent", `String ctx.agent_name);
      ("hint", `String hint);
    ]
  in
  let fields =
    match command with
    | Some command -> ("command", `String command) :: fields
    | None -> fields
  in
  let fields =
    match action with
    | Some action -> ("action", `String action) :: fields
    | None -> fields
  in
  error_response_with (List.rev fields)

let truncate_output s =
  if String.length s > max_output_bytes then
    String.sub s 0 max_output_bytes ^ "\n... (truncated)"
  else s

let reset_policy_config_cache =
  Tool_code_write_git_policy.reset_policy_config_cache

let get_policy_config = Tool_code_write_git_policy.get_policy_config
let extract_github_org = Tool_code_write_git_policy.extract_github_org
let extract_github_org_repo = Tool_code_write_git_policy.extract_github_org_repo

let canonical_github_https_clone_url =
  Tool_code_write_git_policy.canonical_github_https_clone_url

let normalize_github_clone_url =
  Tool_code_write_git_policy.normalize_github_clone_url

let validate_clone_url = Tool_code_write_git_policy.validate_clone_url

(** Validate cwd for clone: allows .worktrees/ itself (not just subdirs)
    and THIS agent's own backend-scoped playground repos/ directory.

    #6527 iter 6 scoped this per-agent so agent A cannot drop a clone
    into agent B's playground/repos/ via masc_code_git action=clone. *)
let validate_clone_cwd ~(agent_name : string) config cwd =
  let cwd = Tool_code.normalize_agent_relative_path ~config ~agent_name cwd in
  match Tool_code.validate_path config cwd with
  | Error e -> Error e
  | Ok canonical_path ->
    match Coord_git.git_root ~base_path:config.Coord.base_path with
    | None -> Error (System (System_error.IoError "Not in a git repository"))
    | Some root ->
      let worktree_prefix = Tool_code.normalize_path
        (Filename.concat root ".worktrees") in
      let agent_playground_prefix = Tool_code.normalize_path
        (Filename.concat root
           (Tool_code.agent_playground_rel ~config ~agent_name)) in
      let in_worktrees =
        String.equal canonical_path worktree_prefix ||
        String.starts_with ~prefix:(worktree_prefix ^ "/") canonical_path
      in
      let in_agent_playground_repos =
        (* Match <agent_playground_prefix>/repos or subdirs thereof.
           [Tool_code.agent_playground_rel] already ends with "/", and the
           canonical normalisation strips trailing slashes, so we strip
           the trailing slash before prefix matching. *)
        let prefix_no_slash =
          if String.length agent_playground_prefix > 0
             && Char.equal agent_playground_prefix.[String.length agent_playground_prefix - 1] '/'
          then String.sub agent_playground_prefix 0
                 (String.length agent_playground_prefix - 1)
          else agent_playground_prefix
        in
        String.equal canonical_path (Stdlib.Filename.concat prefix_no_slash "repos")
        || String.starts_with
             ~prefix:(Filename.concat prefix_no_slash "repos/")
             canonical_path
      in
      if in_worktrees || in_agent_playground_repos then
        Ok canonical_path
      else
        Error (System (System_error.IoError (Printf.sprintf
          "Clone restricted to /.worktrees/ or this agent's own \
           %srepos/ (got: %s). Cross-agent playground clones are blocked \
           — clone into %srepos/<repo-name> instead. Call masc_status \
           if you are unsure of your agent_name (currently %s)."
          agent_playground_prefix
          canonical_path
          agent_playground_prefix
          agent_name)))

(* Handler: masc_code_write — Create or overwrite a file *)
let handle_code_write ~tool_name ~start_time ctx args =
  let path = get_string args "path" "" in
  let content = get_string args "content" "" in
  let create_dirs = get_bool args "create_dirs" false in

  if String.equal path "" then
    Tool_result.error ~tool_name ~start_time "path parameter required"
  else if String.length content > max_write_size then
    Tool_result.error ~tool_name ~start_time (Printf.sprintf "Content too large: %d bytes (max: %d)"
       (String.length content) max_write_size)
  else if Tool_code.is_binary_file path then
    Tool_result.error ~tool_name ~start_time "Binary file extension not allowed for write"
  else begin
    match validate_writable_path ~agent_name:ctx.agent_name ctx.config path with
    | Error e -> Tool_result.error ~tool_name ~start_time (Masc_domain.masc_error_to_string e)
    | Ok abs_path ->
      try
        if create_dirs then begin
          let dir = Filename.dirname abs_path in
          Fs_compat.mkdir_p dir
        end;
        Fs_compat.save_file abs_path content;
        Tool_args.ok_result ~tool_name ~start_time [
          ("path", `String path);
          ("bytes_written", `Int (String.length content));
          ("agent", `String ctx.agent_name);
        ]
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        Tool_result.error ~tool_name ~start_time (Printf.sprintf "Write failed: %s" (Tool_error.to_string (Tool_error.of_exn exn)))
  end

(* Handler: masc_code_edit — Replace old_string with new_string in a file *)
let handle_code_edit ~tool_name ~start_time ctx args =
  let path = get_string args "path" "" in
  let old_string = get_string args "old_string" "" in
  let new_string = get_string args "new_string" "" in
  let replace_all = get_bool args "replace_all" false in

  if String.equal path "" then Tool_result.error ~tool_name ~start_time "path parameter required"
  else if String.equal old_string "" then Tool_result.error ~tool_name ~start_time "old_string parameter required"
  else begin
    match validate_writable_path ~agent_name:ctx.agent_name ctx.config path with
    | Error e -> Tool_result.error ~tool_name ~start_time (Masc_domain.masc_error_to_string e)
    | Ok abs_path ->
      if not (Sys.file_exists abs_path) then
        Tool_result.error ~tool_name ~start_time (Printf.sprintf "File not found: %s" path)
      else begin
        try
          let content = Fs_compat.load_file abs_path in
          (* Count occurrences and capture byte positions of each match
             so the ambiguous-match (count > 1) branch can emit line
             numbers and snippets — mirrors the count = 0 branch which
             surfaces sample lines, giving the keeper signal for how
             to disambiguate (Evidence: 2026-05-21 60/60 "found 2
             times" errors in 3 days with no line context). *)
          let count = ref 0 in
          let pos = ref 0 in
          let old_len = String.length old_string in
          let match_positions = ref [] in
          while !pos <= String.length content - old_len do
            if String.equal (Stdlib.String.sub content !pos old_len) old_string then begin
              Stdlib.incr count;
              match_positions := !pos :: !match_positions;
              pos := !pos + old_len
            end else
              Stdlib.incr pos
          done;
          let match_positions = List.rev !match_positions in

          if String.equal old_string new_string then
            if !count > 0 then
              Tool_args.ok_result ~tool_name ~start_time [
                ("path", `String path);
                ("replacements", `Int 0);
                ("noop", `Bool true);
                ("reason", `String "old_string and new_string are identical");
                ("agent", `String ctx.agent_name);
              ]
            else
              Tool_result.error ~tool_name ~start_time
                "old_string and new_string are identical, and old_string was not found in file"
          else if !count = 0 then
            (* Exact match failed. Look for the first line of old_string
               (trimmed) inside the file and surface up to 3 matching
               lines — the LLM almost always got whitespace / indent /
               trailing newline wrong, and showing the real line(s) it
               meant to target lets the next attempt succeed without
               re-reading the whole file.

               Evidence: 2026-04-16 /loop iter 3 — 17/19 masc_code_edit
               failures are "old_string not found", single root cause. *)
            let first_line =
              match String.index_opt old_string '\n' with
              | Some i -> String.sub old_string 0 i
              | None -> old_string
            in
            let needle = String.trim first_line in
            if String.length needle < 8 then
              Tool_result.error ~tool_name ~start_time "old_string not found in file"
            else
              let matches =
                String.split_on_char '\n' content
                |> List.filter (fun line ->
                     String_util.contains_substring line needle)
                |> List.filteri (fun i _ -> i < 3)
              in
              let hint =
                match matches with
                | [] -> ""
                | samples ->
                  "\nLines in file matching the first trimmed line of \
                   old_string (check whitespace/indent):\n  "
                  ^ String.concat "\n  " samples
              in
              Tool_result.error ~tool_name ~start_time ("old_string not found in file." ^ hint)
          else if !count > 1 && not replace_all then
            (* Ambiguous match. Mirror the count = 0 branch by surfacing
               line numbers + ±2 context lines for up to 3 matches so the
               keeper can pick disambiguating context for old_string,
               instead of blindly retrying the same prompt.

               Evidence: 2026-05-21 60/60 ambiguous-match errors / 3 days
               with same prompt_fingerprint retried 5×, 3× — keeper had
               no signal for *which* occurrence to widen. *)
            let lines = Array.of_list (String.split_on_char '\n' content) in
            (* Build (start_byte_offset, end_byte_offset_exclusive) for each
               line so we can map a byte position to a 1-based line
               number. End is exclusive of the trailing '\n'. *)
            let line_offsets =
              let acc = ref [] in
              let cursor = ref 0 in
              Array.iter (fun line ->
                let len = String.length line in
                acc := (!cursor, !cursor + len) :: !acc;
                cursor := !cursor + len + 1 (* +1 for the '\n' *)
              ) lines;
              Array.of_list (List.rev !acc)
            in
            let line_of_pos p =
              (* Linear scan is fine: lines is small relative to retries
                 we are eliminating; this path is hit only on the error
                 edge. *)
              let n = Array.length line_offsets in
              let found = ref 0 in
              (try
                for i = 0 to n - 1 do
                  let (s, _) = line_offsets.(i) in
                  if s > p then begin
                    found := i - 1;
                    raise Exit
                  end
                done;
                found := n - 1
              with Exit -> ());
              if !found < 0 then 0 else !found
            in
            let sample_positions =
              List.filteri (fun i _ -> i < 3) match_positions
            in
            let format_match pos =
              let line_idx = line_of_pos pos in
              let line_num = line_idx + 1 in
              let from_idx = max 0 (line_idx - 2) in
              let to_idx =
                min (Array.length lines - 1) (line_idx + 2)
              in
              let buf = Buffer.create 128 in
              Buffer.add_string buf
                (Printf.sprintf "  match at line %d:" line_num);
              for i = from_idx to to_idx do
                let marker = if i = line_idx then ">" else " " in
                Buffer.add_string buf
                  (Printf.sprintf "\n    %s %d: %s"
                     marker (i + 1) lines.(i))
              done;
              Buffer.contents buf
            in
            let hint =
              match sample_positions with
              | [] -> ""
              | samples ->
                "\nMatches (provide more surrounding context in \
                 old_string to disambiguate, or pass replace_all=true):\n"
                ^ String.concat "\n" (List.map format_match samples)
            in
            Tool_result.error ~tool_name ~start_time (Printf.sprintf
               "old_string found %d times. Use replace_all=true or provide more context%s"
               !count hint)
          else begin
            (* Perform replacement *)
            let new_content =
              if replace_all then begin
                let buf = Buffer.create (String.length content) in
                let i = ref 0 in
                while !i <= String.length content - old_len do
                  if String.equal (Stdlib.String.sub content !i old_len) old_string then begin
                    Buffer.add_string buf new_string;
                    i := !i + old_len
                  end else begin
                    Buffer.add_char buf content.[!i];
                    Stdlib.incr i
                  end
                done;
                (* Add remaining characters *)
                if !i < String.length content then
                  Buffer.add_string buf
                    (String.sub content !i (String.length content - !i));
                Buffer.contents buf
              end else begin
                (* Replace first occurrence only *)
                let idx = ref (-1) in
                let i = ref 0 in
                while !idx = -1 && !i <= String.length content - old_len do
                  if String.equal (Stdlib.String.sub content !i old_len) old_string then
                    idx := !i
                  else
                    Stdlib.incr i
                done;
                match !idx with
                | -1 -> content (* should not happen *)
                | pos ->
                  String.sub content 0 pos
                  ^ new_string
                  ^ String.sub content (pos + old_len)
                      (String.length content - pos - old_len)
              end
            in
            Fs_compat.save_file abs_path new_content;
            Tool_args.ok_result ~tool_name ~start_time [
              ("path", `String path);
              ("replacements", `Int !count);
              ("agent", `String ctx.agent_name);
            ]
          end
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          Tool_result.error ~tool_name ~start_time (Printf.sprintf "Edit failed: %s" (Tool_error.to_string (Tool_error.of_exn exn)))
      end
  end

(* Handler: masc_code_delete — Delete a file *)
let handle_code_delete ~tool_name ~start_time ctx args =
  let path = get_string args "path" "" in

  if String.equal path "" then Tool_result.error ~tool_name ~start_time "path parameter required"
  else begin
    match validate_writable_path ~agent_name:ctx.agent_name ctx.config path with
    | Error e -> Tool_result.error ~tool_name ~start_time (Masc_domain.masc_error_to_string e)
    | Ok abs_path ->
      if not (Sys.file_exists abs_path) then
        Tool_result.error ~tool_name ~start_time (Printf.sprintf "File not found: %s" path)
      else if Sys.is_directory abs_path then
        Tool_result.error ~tool_name ~start_time "Cannot delete directories, only files"
      else begin
        try
          Sys.remove abs_path;
          Tool_args.ok_result ~tool_name ~start_time [
            ("path", `String path);
            ("agent", `String ctx.agent_name);
          ]
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          let err =
            Tool_error.of_exn
              ~detail:(Printf.sprintf "Delete failed: %s" (Stdlib.Printexc.to_string exn))
              exn
          in
          Tool_result.error ~tool_name ~start_time (Tool_error.to_string err)
      end
  end

(* Handler: masc_code_shell — Bounded shell execution *)
let handle_code_shell ~tool_name ~start_time ctx args =
  let command = get_string args "command" "" in
  let cwd = get_string args "cwd" "" in
  let timeout = get_int args "timeout" 30 in

  if String.equal command "" then Tool_result.error ~tool_name ~start_time "command parameter required"
  else
    match code_shell_command_context command with
    | Error reason_str ->
        Tool_result.error ~tool_name ~start_time
          ~failure_class:(Some Tool_result.Workflow_rejection)
          reason_str
    | Ok command_context ->
        (* Validate cwd if provided *)
        let cwd_result =
          if String.equal cwd "" then Ok None
          else
            match validate_writable_path ~agent_name:ctx.agent_name ctx.config cwd with
            | Ok abs_cwd -> Ok (Some abs_cwd)
            | Error e -> Error e
        in
        (match cwd_result with
         | Error e -> Tool_result.error ~tool_name ~start_time (Masc_domain.masc_error_to_string e)
         | Ok (Some dir) when not (path_is_directory dir) ->
             Tool_result.error ~tool_name ~start_time
               (missing_cwd_error_json ctx ~cwd ~resolved_cwd:dir
                  ~command ())
         | Ok cwd_opt ->
             let safe_timeout = Float.of_int (max 5 (min 120 timeout)) in
             let path_workdir =
               match cwd_opt with
               | Some dir -> dir
               | None -> Sys.getcwd ()
             in
             let dispatch_ir =
               Exec_shell_adapter.shell_ir_with_default_cwd
                 cwd_opt
                 command_context.Exec_shell_gate.ast
             in
             let dispatch_envelope =
               Masc_exec.Shell_ir_risk.classify
                 (Masc_exec.Shell_ir_risk.undecided dispatch_ir)
             in
             match
               Keeper_shell_ir.dispatch_classified
                 ~timeout_sec:safe_timeout
                 ~caller:Exec_shell_gate.Tool_code_write
                 ~allow_pipes:true
                 ~redirect_allowed:false
                 ~allowed_commands:Dev_exec_allowlist.code_shell
                 ~workdir:path_workdir
                 ~sandbox:(Masc_exec.Sandbox_target.host ())
                 dispatch_envelope
             with
             | Error (Keeper_shell_ir.Gate_reject diagnostic) ->
               Tool_result.error
                 ~tool_name
                 ~start_time
                 ~failure_class:(Some Tool_result.Policy_rejection)
                 diagnostic
             | Error Keeper_shell_ir.Cannot_parse ->
               Tool_result.error
                 ~tool_name
                 ~start_time
                 ~failure_class:(Some Tool_result.Workflow_rejection)
                 "Cannot parse command"
             | Error Keeper_shell_ir.Too_complex ->
               Tool_result.error
                 ~tool_name
                 ~start_time
                 ~failure_class:(Some Tool_result.Workflow_rejection)
                 "Command too complex"
             | Error (Keeper_shell_ir.Path_reject reason) ->
               Tool_result.error
                 ~tool_name
                 ~start_time
                 ~failure_class:(Some Tool_result.Policy_rejection)
                 reason
             | Ok { status = Unix.WEXITED code; stdout; stderr } ->
               let output =
                 Exec_shell_adapter.output_for_dispatch_status
                   ~status:(Unix.WEXITED code)
                   ~stdout
                   ~stderr
               in
               let exit_status =
                 classify_code_shell_exit
                   ~last_stage_bin:
                     (Exec_shell_gate.last_stage_bin command_context)
                   code
               in
               let status_text =
                 match exit_status with
                 | Shell_error -> "error"
                 | Shell_ok | Shell_ok_expected_nonzero _ -> "ok"
               in
               let exit_fields =
                 match exit_status with
                 | Shell_ok_expected_nonzero reason ->
                   [ ("exit_semantics", `String reason) ]
                 | Shell_ok | Shell_error -> []
               in
               let response_fields =
                 [
                   ("status", `String status_text);
                   ("exit_code", `Int code);
                   ("output", `String (truncate_output output));
                   ("command", `String command);
                   ("agent", `String ctx.agent_name);
                 ]
                 @ exit_fields
               in
               let response = `Assoc response_fields in
               (match exit_status with
                | Shell_ok | Shell_ok_expected_nonzero _ ->
                  fun msg -> Tool_result.ok ~tool_name ~start_time msg
                | Shell_error ->
                  fun msg -> Tool_result.error ~tool_name ~start_time msg)
                 (Yojson.Safe.pretty_to_string response)
             | Ok { status = Unix.WSIGNALED sig_num; stdout; stderr } ->
               let output =
                 Exec_shell_adapter.output_for_dispatch_status
                   ~status:(Unix.WSIGNALED sig_num)
                   ~stdout
                   ~stderr
               in
               Tool_result.error
                 ~tool_name
                 ~start_time
                 (Printf.sprintf
                    "Killed by signal %d: %s"
                    sig_num
                    (truncate_output output))
             | Ok { status = Unix.WSTOPPED sig_num; stdout; stderr } ->
               let output =
                 Exec_shell_adapter.output_for_dispatch_status
                   ~status:(Unix.WSTOPPED sig_num)
                   ~stdout
                   ~stderr
               in
               Tool_result.error
                 ~tool_name
                 ~start_time
                 (Printf.sprintf
                    "Stopped by signal %d: %s"
                    sig_num
                    (truncate_output output)))

(* Handler: masc_code_git — Git operations *)
let code_git_route_fields (ctx : context) =
  let sandbox_profile, route_via =
    match
      Keeper_sandbox.backend_of_config_agent
        ~config:ctx.config
        ~agent_name:ctx.agent_name
    with
    | Keeper_sandbox.Docker -> "docker", "brokered"
    | Keeper_sandbox.Local -> "local", "host"
  in
  [
    ("sandbox_profile", `String sandbox_profile);
    ("via", `String route_via);
    ("route_via", `String route_via);
  ]

let handle_code_git ~tool_name ~start_time ctx args =
  let action = get_string args "action" "" in
  let git_args = match args with
    | `Assoc fields ->
      (match List.assoc_opt "args" fields with
       | Some (`List l) ->
         List.filter_map (function `String s -> Some s | _ -> None) l
       | _ -> [])
    | _ -> []
  in
  let cwd = get_string args "cwd" "" in

  if String.equal action "" then Tool_result.error ~tool_name ~start_time "action parameter required"
  else if not (List.mem action allowed_git_actions) then
    Tool_result.error ~tool_name ~start_time (Printf.sprintf "Git action '%s' not allowed. Allowed: %s"
       action (String.concat ", " allowed_git_actions))
  else if String.equal action "clone" then begin
    (* Clone: validate org allowlist + cwd within .worktrees/.
       Block all flag-like args to prevent --upload-pack injection (CVE-like). *)
    let url = match git_args with url :: _ -> url | [] -> "" in
    let has_flag_args = List.exists (fun a -> String.length a > 0 && Char.equal a.[0] '-') git_args in
    if String.equal url "" then
      Tool_result.error ~tool_name ~start_time "clone requires a repository URL as first argument"
    else if has_flag_args then
      Tool_result.error ~tool_name ~start_time "clone does not accept flags (security: --upload-pack injection blocked)"
    else if String.equal cwd "" then
      Tool_result.error ~tool_name ~start_time "cwd parameter required for clone"
    else
      match validate_clone_url ~base_path:ctx.config.Coord.base_path url with
      | Error msg -> Tool_result.error ~tool_name ~start_time msg
      | Ok () ->
        match validate_clone_cwd ~agent_name:ctx.agent_name ctx.config cwd with
        | Error e -> Tool_result.error ~tool_name ~start_time (Masc_domain.masc_error_to_string e)
        | Ok abs_cwd ->
          let clone_url = normalize_github_clone_url url in
          (* Only pass the validated URL — no extra args allowed.
             Depth and timeout are config-driven via [git_clone] in tool_policy.toml. *)
          let depth = match get_policy_config ~base_path:ctx.config.Coord.base_path with
            | Some cfg -> Keeper_tool_policy_config.clone_depth cfg
            | None -> 0
          in
          let depth_args = if depth > 0 then [ "--depth"; string_of_int depth ] else [] in
          let timeout = match get_policy_config ~base_path:ctx.config.Coord.base_path with
            | Some cfg -> Keeper_tool_policy_config.clone_timeout_sec cfg
            | None -> 120.0
          in
          let cmd = [ "git"; "clone" ] @ depth_args @ [ clone_url ] in
          match
            Masc_exec.Exec_gate.run_argv_with_status
              ~actor:`Coord_git
              ~raw_source:(String.concat " " cmd)
              ~summary:"git clone"
              ~timeout_sec:timeout
              ~cwd:abs_cwd
              cmd
          with
          | Unix.WEXITED code, output ->
            let response =
              `Assoc
                ([
                   ("status", `String (if code = 0 then "ok" else "error"));
                   ("exit_code", `Int code);
                   ("output", `String (truncate_output output));
                   ("action", `String "clone");
                   ("url", `String url);
                   ("agent", `String ctx.agent_name);
                 ]
                 @ code_git_route_fields ctx)
            in
            (if code = 0
                  then fun msg -> Tool_result.ok ~tool_name ~start_time msg
                  else fun msg -> Tool_result.error ~tool_name ~start_time msg)
                   (Yojson.Safe.pretty_to_string response)
          | _, output ->
            Tool_result.error ~tool_name ~start_time (Printf.sprintf "Git clone failed: %s" (truncate_output output))
  end
  else begin
    (* Non-clone actions: existing validation *)
    let is_dangerous =
      (String.equal action "push" && List.mem "--force" git_args) ||
      (String.equal action "push" && List.mem "-f" git_args) ||
      (String.equal action "push" && List.exists (fun a ->
         String.equal a "main" || String.equal a "master" || String.equal a "origin/main" || String.equal a "origin/master"
       ) git_args) ||
      (String.equal action "checkout" && List.mem "--" git_args &&
       List.mem "." git_args)
    in
    if is_dangerous then
      Tool_result.error ~tool_name ~start_time "Dangerous git operation blocked (force push, main push, or checkout .)"
    else begin
      let cwd_result =
        if String.equal cwd "" then
          Error (System (System_error.IoError "cwd parameter required for git operations"))
        else match validate_writable_path ~agent_name:ctx.agent_name ctx.config cwd with
          | Ok abs_cwd -> Ok (Some abs_cwd)
          | Error e -> Error e
      in
      match cwd_result with
      | Error e -> Tool_result.error ~tool_name ~start_time (Masc_domain.masc_error_to_string e)
      | Ok (Some dir) when not (path_is_directory dir) ->
        Tool_result.error ~tool_name ~start_time
          (missing_cwd_error_json ctx ~cwd ~resolved_cwd:dir ~action ())
      | Ok cwd_opt ->
        let dir = match cwd_opt with Some d -> d | None -> "." in
        let cmd = "git" :: action :: git_args in
        let env_opt =
          if String.equal action "commit" then
            Some (Keeper_identity.git_env_for_keeper ~keeper_name:ctx.agent_name)
          else None
        in
        match
          Masc_exec.Exec_gate.run_argv_with_status
            ~actor:`Coord_git
            ~raw_source:(String.concat " " cmd)
            ~summary:"git action execution"
            ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Shell ())
            ?env:env_opt
            ~cwd:dir
            cmd
        with
        | Unix.WEXITED code, output ->
          let response =
            `Assoc
              ([
                 ("status", `String (if code = 0 then "ok" else "error"));
                 ("exit_code", `Int code);
                 ("output", `String (truncate_output output));
                 ("action", `String action);
                 ("agent", `String ctx.agent_name);
               ]
               @ code_git_route_fields ctx)
          in
          (if code = 0
                  then fun msg -> Tool_result.ok ~tool_name ~start_time msg
                  else fun msg -> Tool_result.error ~tool_name ~start_time msg)
                   (Yojson.Safe.pretty_to_string response)
        | _, output ->
          Tool_result.error ~tool_name ~start_time (Printf.sprintf "Git command failed: %s" (truncate_output output))
    end
  end

(* Dispatch *)
let dispatch ctx ~name ~args : Tool_result.t option =
  let start = Time_compat.now () in
  match name with
  | "masc_code_write" -> Some (handle_code_write ~tool_name:name ~start_time:start ctx args)
  | "masc_code_edit" -> Some (handle_code_edit ~tool_name:name ~start_time:start ctx args)
  | "masc_code_delete" -> Some (handle_code_delete ~tool_name:name ~start_time:start ctx args)
  | "masc_code_shell" -> Some (handle_code_shell ~tool_name:name ~start_time:start ctx args)
  | "masc_code_git" -> Some (handle_code_git ~tool_name:name ~start_time:start ctx args)
  | _ -> None
