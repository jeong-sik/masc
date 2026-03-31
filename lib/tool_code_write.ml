(** Code Write Tools — File write, edit, delete, shell, git for keeper agents.

    Security model:
    - All write operations restricted to .worktrees/ directories
    - Shell commands restricted to allowlist
    - Git push to main/master blocked
    - File size limit: 1MB for writes
    - Binary file extension check inherited from Tool_code

    @since 2.128.0 *)

open Types
open Tool_args

type context = {
  config : Room.config;
  agent_name : string;
}

type result = bool * string

let max_write_size = 1024 * 1024 (* 1MB *)

(* Security: Validate path is within a .worktrees/ directory.
   Uses canonical paths from Tool_code.validate_path — already normalized. *)
let validate_writable_path config path =
  match Tool_code.validate_path config path with
  | Error e -> Error e
  | Ok canonical_path ->
    let git_root = match Room_git.git_root ~base_path:config.Room.base_path with
      | None -> Error (IoError "Not in a git repository")
      | Some root -> Ok root
    in
    match git_root with
    | Error e -> Error e
    | Ok root ->
      let worktree_prefix = Tool_code.normalize_path
        (Filename.concat root ".worktrees") in
      if String.starts_with ~prefix:(worktree_prefix ^ "/") canonical_path then
        Ok canonical_path
      else
        Error (IoError (Printf.sprintf
          "Write restricted to .worktrees/ directory (got: %s)" canonical_path))

(* Shell command allowlist *)
let allowed_shell_commands = [
  "dune"; "make"; "npm"; "npx"; "node";
  "git"; "ls"; "cat"; "head"; "tail"; "wc";
  "rg"; "find"; "diff"; "patch"; "mkdir";
  "opam"; "ocamlfind"; "tsc";
]

(* Git action allowlist *)
let allowed_git_actions = [
  "add"; "commit"; "push"; "diff"; "status";
  "log"; "branch"; "checkout"; "stash"; "fetch";
]

let max_output_bytes = 10 * 1024 (* 10KB output limit *)

let truncate_output s =
  if String.length s > max_output_bytes then
    String.sub s 0 max_output_bytes ^ "\n... (truncated)"
  else s

(* Handler: masc_code_write — Create or overwrite a file *)
let handle_code_write ctx args =
  let path = get_string args "path" "" in
  let content = get_string args "content" "" in
  let create_dirs = get_bool args "create_dirs" false in

  if path = "" then
    (false, "path parameter required")
  else if String.length content > max_write_size then
    (false, Printf.sprintf "Content too large: %d bytes (max: %d)"
       (String.length content) max_write_size)
  else if Tool_code.is_binary_file path then
    (false, "Binary file extension not allowed for write")
  else begin
    match validate_writable_path ctx.config path with
    | Error e -> (false, Types.masc_error_to_string e)
    | Ok abs_path ->
      try
        if create_dirs then begin
          let dir = Filename.dirname abs_path in
          Fs_compat.mkdir_p dir
        end;
        Fs_compat.save_file abs_path content;
        let response = `Assoc [
          ("status", `String "ok");
          ("path", `String path);
          ("bytes_written", `Int (String.length content));
          ("agent", `String ctx.agent_name);
        ] in
        (true, Yojson.Safe.pretty_to_string response)
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        (false, Printf.sprintf "Write failed: %s" (Printexc.to_string exn))
  end

(* Handler: masc_code_edit — Replace old_string with new_string in a file *)
let handle_code_edit ctx args =
  let path = get_string args "path" "" in
  let old_string = get_string args "old_string" "" in
  let new_string = get_string args "new_string" "" in
  let replace_all = get_bool args "replace_all" false in

  if path = "" then (false, "path parameter required")
  else if old_string = "" then (false, "old_string parameter required")
  else if old_string = new_string then (false, "old_string and new_string are identical")
  else begin
    match validate_writable_path ctx.config path with
    | Error e -> (false, Types.masc_error_to_string e)
    | Ok abs_path ->
      if not (Sys.file_exists abs_path) then
        (false, Printf.sprintf "File not found: %s" path)
      else begin
        try
          let content = Fs_compat.load_file abs_path in
          (* Count occurrences *)
          let count = ref 0 in
          let pos = ref 0 in
          let old_len = String.length old_string in
          while !pos <= String.length content - old_len do
            if String.sub content !pos old_len = old_string then begin
              incr count;
              pos := !pos + old_len
            end else
              incr pos
          done;

          if !count = 0 then
            (false, "old_string not found in file")
          else if !count > 1 && not replace_all then
            (false, Printf.sprintf
               "old_string found %d times. Use replace_all=true or provide more context"
               !count)
          else begin
            (* Perform replacement *)
            let new_content =
              if replace_all then begin
                let buf = Buffer.create (String.length content) in
                let i = ref 0 in
                while !i <= String.length content - old_len do
                  if String.sub content !i old_len = old_string then begin
                    Buffer.add_string buf new_string;
                    i := !i + old_len
                  end else begin
                    Buffer.add_char buf content.[!i];
                    incr i
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
                  if String.sub content !i old_len = old_string then
                    idx := !i
                  else
                    incr i
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
            let response = `Assoc [
              ("status", `String "ok");
              ("path", `String path);
              ("replacements", `Int !count);
              ("agent", `String ctx.agent_name);
            ] in
            (true, Yojson.Safe.pretty_to_string response)
          end
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          (false, Printf.sprintf "Edit failed: %s" (Printexc.to_string exn))
      end
  end

(* Handler: masc_code_delete — Delete a file *)
let handle_code_delete ctx args =
  let path = get_string args "path" "" in

  if path = "" then (false, "path parameter required")
  else begin
    match validate_writable_path ctx.config path with
    | Error e -> (false, Types.masc_error_to_string e)
    | Ok abs_path ->
      if not (Sys.file_exists abs_path) then
        (false, Printf.sprintf "File not found: %s" path)
      else if Sys.is_directory abs_path then
        (false, "Cannot delete directories, only files")
      else begin
        try
          Sys.remove abs_path;
          let response = `Assoc [
            ("status", `String "ok");
            ("path", `String path);
            ("agent", `String ctx.agent_name);
          ] in
          (true, Yojson.Safe.pretty_to_string response)
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          (false, Printf.sprintf "Delete failed: %s" (Printexc.to_string exn))
      end
  end

(* Handler: masc_code_shell — Bounded shell execution *)
let handle_code_shell ctx args =
  let command = get_string args "command" "" in
  let cwd = get_string args "cwd" "" in
  let timeout = get_int args "timeout" 30 in

  if command = "" then (false, "command parameter required")
  else begin
    (* Parse first token to check allowlist *)
    let tokens = String.split_on_char ' ' (String.trim command) in
    let executable = match tokens with
      | [] -> ""
      | exe :: _ -> Filename.basename exe
    in

    if not (List.mem executable allowed_shell_commands) then
      (false, Printf.sprintf "Command '%s' not in allowlist: %s"
         executable (String.concat ", " allowed_shell_commands))
    else begin
      (* Validate cwd if provided *)
      let cwd_result =
        if cwd = "" then Ok None
        else match validate_writable_path ctx.config cwd with
          | Ok abs_cwd -> Ok (Some abs_cwd)
          | Error e -> Error e
      in
      match cwd_result with
      | Error e -> (false, Types.masc_error_to_string e)
      | Ok cwd_opt ->
        let safe_timeout = Float.of_int (max 5 (min 120 timeout)) in
        let cmd_parts = ["sh"; "-c"; command] in
        let full_cmd = match cwd_opt with
          | None -> cmd_parts
          | Some dir -> ["sh"; "-c"; Printf.sprintf "cd %s && %s"
                           (Filename.quote dir) command]
        in
        match Process_eio.run_argv_with_status ~timeout_sec:safe_timeout full_cmd with
        | Unix.WEXITED code, output ->
          let response = `Assoc [
            ("status", `String (if code = 0 then "ok" else "error"));
            ("exit_code", `Int code);
            ("output", `String (truncate_output output));
            ("command", `String command);
            ("agent", `String ctx.agent_name);
          ] in
          (code = 0, Yojson.Safe.pretty_to_string response)
        | _, output ->
          (false, Printf.sprintf "Command failed: %s" (truncate_output output))
    end
  end

(* Handler: masc_code_git — Git operations *)
let handle_code_git ctx args =
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

  if action = "" then (false, "action parameter required")
  else if not (List.mem action allowed_git_actions) then
    (false, Printf.sprintf "Git action '%s' not allowed. Allowed: %s"
       action (String.concat ", " allowed_git_actions))
  else begin
    (* Block dangerous operations *)
    let is_dangerous =
      (action = "push" && List.mem "--force" git_args) ||
      (action = "push" && List.mem "-f" git_args) ||
      (action = "push" && List.exists (fun a ->
         a = "main" || a = "master" || a = "origin/main" || a = "origin/master"
       ) git_args) ||
      (action = "checkout" && List.mem "--" git_args &&
       List.mem "." git_args)
    in
    if is_dangerous then
      (false, "Dangerous git operation blocked (force push, main push, or checkout .)")
    else begin
      (* Validate cwd *)
      let cwd_result =
        if cwd = "" then (false, "cwd parameter required for git operations") |> fun (ok, msg) ->
          if ok then Ok None else Error (IoError msg)
        else match validate_writable_path ctx.config cwd with
          | Ok abs_cwd -> Ok (Some abs_cwd)
          | Error e -> Error e
      in
      match cwd_result with
      | Error e -> (false, Types.masc_error_to_string e)
      | Ok cwd_opt ->
        let dir = match cwd_opt with Some d -> d | None -> "." in
        let cmd = ["sh"; "-c";
                   Printf.sprintf "cd %s && git %s %s"
                     (Filename.quote dir)
                     action
                     (String.concat " " (List.map Filename.quote git_args))]
        in
        match Process_eio.run_argv_with_status ~timeout_sec:30.0 cmd with
        | Unix.WEXITED code, output ->
          let response = `Assoc [
            ("status", `String (if code = 0 then "ok" else "error"));
            ("exit_code", `Int code);
            ("output", `String (truncate_output output));
            ("action", `String action);
            ("agent", `String ctx.agent_name);
          ] in
          (code = 0, Yojson.Safe.pretty_to_string response)
        | _, output ->
          (false, Printf.sprintf "Git command failed: %s" (truncate_output output))
    end
  end

(* Dispatch *)
let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_code_write" -> Some (handle_code_write ctx args)
  | "masc_code_edit" -> Some (handle_code_edit ctx args)
  | "masc_code_delete" -> Some (handle_code_delete ctx args)
  | "masc_code_shell" -> Some (handle_code_shell ctx args)
  | "masc_code_git" -> Some (handle_code_git ctx args)
  | _ -> None

(* Tool schemas *)
let schemas : Types.tool_schema list = [
  {
    name = "masc_code_write";
    description = "Create or overwrite a file in a worktree (.worktrees/ only). \
Use to generate new source files, configs, or replace entire file contents. \
For partial edits (change a function, fix a line), use masc_code_edit instead. \
Returns bytes_written. Max 1MB. Set up a worktree first with masc_worktree_create.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("path", `Assoc [
          ("type", `String "string");
          ("description", `String "File path to write (must be within .worktrees/)");
        ]);
        ("content", `Assoc [
          ("type", `String "string");
          ("description", `String "File content to write");
        ]);
        ("create_dirs", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Create intermediate directories if needed (default: false)");
          ("default", `Bool false);
        ]);
      ]);
      ("required", `List [`String "path"; `String "content"]);
    ];
  };

  {
    name = "masc_code_edit";
    description = "Replace text in a file in a worktree (.worktrees/ only). \
Use for surgical edits: fix a bug, update a function, change a config value. \
old_string must match exactly once (unless replace_all=true). Returns replacement_count. \
For full file replacement, use masc_code_write. Read the file first with masc_code_read \
to get the exact text to replace.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("path", `Assoc [
          ("type", `String "string");
          ("description", `String "File path to edit (must be within .worktrees/)");
        ]);
        ("old_string", `Assoc [
          ("type", `String "string");
          ("description", `String "Exact string to find and replace");
        ]);
        ("new_string", `Assoc [
          ("type", `String "string");
          ("description", `String "Replacement string");
        ]);
        ("replace_all", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Replace all occurrences (default: false, requires unique match)");
          ("default", `Bool false);
        ]);
      ]);
      ("required", `List [`String "path"; `String "old_string"; `String "new_string"]);
    ];
  };

  {
    name = "masc_code_delete";
    description = "Delete a file in a worktree (.worktrees/ only). Cannot delete directories. \
Use when removing generated, obsolete, or conflicting files during code work.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("path", `Assoc [
          ("type", `String "string");
          ("description", `String "File path to delete (must be within .worktrees/)");
        ]);
      ]);
      ("required", `List [`String "path"]);
    ];
  };

  {
    name = "masc_code_shell";
    description = "Run an allowlisted command in a worktree (.worktrees/ only). \
Allowed: dune, make, npm, npx, node, git, ls, cat, head, tail, wc, rg, find, \
diff, patch, mkdir, opam, ocamlfind, tsc. Use for building and testing code \
in isolated worktrees. For unrestricted shell at project root, use keeper_bash. \
Returns exit_code and stdout (truncated at 10KB).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("command", `Assoc [
          ("type", `String "string");
          ("description", `String "Shell command to run (first token must be in allowlist)");
        ]);
        ("cwd", `Assoc [
          ("type", `String "string");
          ("description", `String "Working directory (must be within .worktrees/)");
        ]);
        ("timeout", `Assoc [
          ("type", `String "integer");
          ("description", `String "Timeout in seconds (default: 30, max: 120)");
          ("default", `Int 30);
        ]);
      ]);
      ("required", `List [`String "command"]);
    ];
  };

  {
    name = "masc_code_git";
    description = "Run git commands in a worktree (.worktrees/ only). Structured alternative \
to masc_code_shell for git operations. Supports: add, commit, push, diff, status, \
log, branch, checkout, stash, fetch. Force push and push to main/master are blocked. \
Returns git command output.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("action", `Assoc [
          ("type", `String "string");
          ("description", `String "Git action: add, commit, push, diff, status, log, branch, checkout, stash, fetch");
        ]);
        ("args", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Additional git arguments");
        ]);
        ("cwd", `Assoc [
          ("type", `String "string");
          ("description", `String "Worktree directory (must be within .worktrees/)");
        ]);
      ]);
      ("required", `List [`String "action"; `String "cwd"]);
    ];
  };
]

(** Tool names for keeper gating *)
let tool_names : string list =
  schemas |> List.map (fun (t : Types.tool_schema) -> t.name)
