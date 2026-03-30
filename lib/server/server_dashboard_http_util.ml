(** Server dashboard HTTP utilities and diagnostics *)

open Types
open Server_utils

let contains_substring ~needle haystack =
  String_util.contains_substring haystack needle

let take n xs =
  let rec loop acc remaining xs =
    if remaining <= 0 then List.rev acc
    else
      match xs with
      | [] -> List.rev acc
      | x :: tl -> loop (x :: acc) (remaining - 1) tl
  in
  loop [] n xs

let trim_to_option raw =
  let trimmed = String.trim raw in
  if trimmed = "" then None else Some trimmed

let git_rev_parse_short path =
  match trim_to_option path with
  | None -> None
  | Some dir when not (Sys.file_exists dir) -> None
  | Some dir ->
      let channels =
        Unix.open_process_args_full "git"
          [| "git"; "-C"; dir; "rev-parse"; "--short"; "HEAD" |]
          (Unix.environment ())
      in
      let stdout, stdin, stderr = channels in
      (try
         close_out_noerr stdin;
         let output = In_channel.input_all stdout in
         ignore (In_channel.input_all stderr);
         match Unix.close_process_full channels with
         | Unix.WEXITED 0 -> trim_to_option output
         | _ -> None
       with
       | Sys_error _ | Unix.Unix_error _ ->
           ignore
             (try Unix.close_process_full channels
              with Unix.Unix_error _ -> Unix.WEXITED 1);
           None)

let path_item_json ~source path =
  `Assoc
    [
      ("path", `String path);
      ("exists", `Bool (String.trim path <> "" && Sys.file_exists path));
      ("source", `String source);
    ]

let shutdown_signal_of_message message =
  if contains_substring ~needle:"Received SIGTERM" message then Some "SIGTERM"
  else if contains_substring ~needle:"Received SIGINT" message then Some "SIGINT"
  else None

let runtime_diagnostics_json () =
  let entries = Log.Ring.recent ~limit:200 ~order:`Newest_first () in
  let diagnostics =
    entries
    |> List.filter_map (fun (entry : Log.Ring.entry) ->
           let message = entry.message in
           match shutdown_signal_of_message message with
           | Some signal ->
               Some
                 (`Assoc
                   [
                     ("ts", `String entry.ts);
                     ("kind", `String "external_signal");
                     ("signal", `String signal);
                     ("message", `String message);
                   ])
           | None when contains_substring
                           ~needle:"repairing state and rewriting canonical JSON"
                           message ->
               Some
                 (`Assoc
                   [
                     ("ts", `String entry.ts);
                     ("kind", `String "state_repair");
                     ("message", `String message);
                   ])
           | None when contains_substring ~needle:"invalid agent JSON" message
                       || contains_substring ~needle:"repaired agent JSON" message
                       || contains_substring
                            ~needle:"parse error: Types_core.agent.last_seen"
                            message ->
               Some
                 (`Assoc
                   [
                     ("ts", `String entry.ts);
                     ("kind", `String "agent_state");
                     ("message", `String message);
                   ])
           | None when contains_substring ~needle:"MaxClientsInSessionMode" message
                       || contains_substring
                            ~needle:
                              "Invalid concurrent usage of PostgreSQL connection"
                            message ->
               Some
                 (`Assoc
                   [
                     ("ts", `String entry.ts);
                     ("kind", `String "backend_pressure");
                     ("message", `String message);
                   ])
           | None -> None)
    |> take 8
  in
  let count kind =
    List.fold_left
      (fun acc json ->
        match Yojson.Safe.Util.member "kind" json with
        | `String value when String.equal value kind -> acc + 1
        | _ -> acc)
      0 diagnostics
  in
  (`List diagnostics, count "external_signal", count "state_repair",
   count "agent_state", count "backend_pressure")

let runtime_resolution_json (config : Room.config) =
  let build = Build_identity.current () in
  let runtime_commit = build.commit in
  let workspace_commit = git_rev_parse_short config.workspace_path in
  let resolved_base_commit = git_rev_parse_short config.base_path in
  let base_path_input =
    Env_config_core.base_path_opt ()
    |> Option.value ~default:config.workspace_path
  in
  let prompt_markdown_dir =
    Prompt_registry.get_markdown_dir () |> Option.value ~default:""
  in
  let prompt_outside_workspace =
    prompt_markdown_dir <> ""
    && not (String.starts_with ~prefix:config.workspace_path prompt_markdown_dir)
  in
  let source_mismatch =
    match runtime_commit, workspace_commit with
    | Some runtime, Some workspace -> not (String.equal runtime workspace)
    | _ -> false
  in
  let diagnostics, signal_count, repair_count, agent_issue_count, backend_pressure_count =
    runtime_diagnostics_json ()
  in
  let warnings =
    []
    |> fun acc ->
      if source_mismatch then
        let runtime = Option.value ~default:"unknown" runtime_commit in
        let workspace = Option.value ~default:"unknown" workspace_commit in
        (Printf.sprintf
           "Runtime build commit (%s) differs from workspace HEAD (%s). Rebuild/restart from the intended worktree."
           runtime workspace)
        :: acc
      else acc
    |> fun acc ->
      if prompt_outside_workspace then
        (Printf.sprintf
           "Prompt markdown dir resolves outside workspace path: %s"
           prompt_markdown_dir)
        :: acc
      else acc
    |> fun acc ->
      if signal_count > 0 then
        (Printf.sprintf
           "Recent external shutdown signals detected in server logs (%d). Ephemeral agents will not auto-rejoin after these restarts."
           signal_count)
        :: acc
      else acc
    |> fun acc ->
      if repair_count > 0 then
        (Printf.sprintf
           "Recent room-state repair events detected (%d)."
           repair_count)
        :: acc
      else acc
    |> fun acc ->
      if agent_issue_count > 0 then
        (Printf.sprintf
           "Recent agent-state compatibility warnings detected (%d)."
           agent_issue_count)
        :: acc
      else acc
    |> fun acc ->
      if backend_pressure_count > 0 then
        (Printf.sprintf
           "Recent PostgreSQL pressure warnings detected (%d)."
           backend_pressure_count)
        :: acc
      else acc
    |> List.rev
  in
  let status = if warnings = [] then "ready" else "warn" in
  `Assoc
    [
      ("status", `String status);
      ("warnings", `List (List.map (fun warning -> `String warning) warnings));
      ("base_path", path_item_json ~source:"input" base_path_input);
      ("workspace_path", path_item_json ~source:"workspace" config.workspace_path);
      ("resolved_base_path", path_item_json ~source:"resolved_base" config.base_path);
      ("data_root", path_item_json ~source:"runtime_data" (Room.masc_root_dir config));
      ("prompt_markdown_dir", path_item_json ~source:"prompt_registry" prompt_markdown_dir);
      ("workspace_git_commit", Option.fold ~none:`Null ~some:(fun value -> `String value) workspace_commit);
      ("resolved_base_git_commit", Option.fold ~none:`Null ~some:(fun value -> `String value) resolved_base_commit);
      ("source_mismatch", `Bool source_mismatch);
      ("diagnostics", diagnostics);
      ("build", Build_identity.to_yojson build);
    ]
