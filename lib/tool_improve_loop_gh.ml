(** Tool_improve_loop_gh — GitHub CLI interaction for the improve-loop. *)

open Tool_improve_loop_types

let run_process argv =
  match argv with
  | [] -> { exit_code = 127; stdout = ""; stderr = "empty argv" }
  | prog :: _ ->
      let result =
        Tool_command_plane_support.run_process ~prog ~argv
          ~env:(Unix.environment ())
      in
      { exit_code = result.exit_code; stdout = result.stdout; stderr = result.stderr }

let parse_check_state json =
  let label =
    option_or_else (string_member "name" json)
      (fun () -> string_member "context" json)
    |> Option.value ~default:"unnamed-check"
  in
  let state =
    option_or_else (string_member "conclusion" json)
      (fun () -> string_member "status" json)
    |> fun value ->
    option_or_else value
      (fun () -> string_member "state" json)
    |> Option.map String.uppercase_ascii
    |> Option.value ~default:"UNKNOWN"
  in
  (label, state)

let failing_check_states =
  [ "FAILURE"; "FAILED"; "ERROR"; "TIMED_OUT"; "CANCELLED"; "ACTION_REQUIRED";
    "STARTUP_FAILURE"; "STALE" ]

let pending_check_states =
  [ "PENDING"; "QUEUED"; "IN_PROGRESS"; "EXPECTED"; "WAITING" ]

let parse_pr json =
  let check_rows =
    match U.member "statusCheckRollup" json with
    | `List rows -> rows |> List.filter_map (function `Assoc _ as row -> Some row | _ -> None)
    | _ -> []
  in
  let failing_checks, pending_checks =
    List.fold_left
      (fun (failing, pending) row ->
        let label, state = parse_check_state row in
        if List.mem state failing_check_states then
          (label :: failing, pending)
        else if List.mem state pending_check_states then
          (failing, label :: pending)
        else
          (failing, pending))
      ([], []) check_rows
  in
  {
    number = int_member "number" json |> Option.value ~default:0;
    title = string_member "title" json |> Option.value ~default:"";
    url = string_member "url" json;
    head_ref_name = string_member "headRefName" json |> Option.value ~default:"";
    base_ref_name = string_member "baseRefName" json;
    mergeable = string_member "mergeable" json;
    merge_state_status = string_member "mergeStateStatus" json;
    is_draft = bool_member "isDraft" json |> Option.value ~default:false;
    failing_checks = List.rev failing_checks;
    pending_checks = List.rev pending_checks;
  }

let parse_issue json =
  let labels =
    match U.member "labels" json with
    | `List rows ->
        rows
        |> List.filter_map (function
             | `Assoc _ as row ->
                 string_member "name" row
             | `String label ->
                 let trimmed = String.trim label in
                 if trimmed = "" then None else Some trimmed
             | _ -> None)
        |> List.sort_uniq String.compare
    | _ -> []
  in
  {
    number = int_member "number" json |> Option.value ~default:0;
    title = string_member "title" json |> Option.value ~default:"";
    url = string_member "url" json;
    labels;
  }

let default_driver =
  let gh_json argv parse_item =
    let result = run_process argv in
    if result.exit_code <> 0 then
      Error
        (String.trim
           (if String.trim result.stderr <> "" then result.stderr else result.stdout))
    else
      try
        match Yojson.Safe.from_string result.stdout with
        | `List rows -> Ok (rows |> List.filter_map (function `Assoc _ as row -> Some (parse_item row) | _ -> None))
        | _ -> Error "gh returned non-list JSON"
      with Yojson.Json_error msg ->
        Error ("failed to parse gh JSON: " ^ msg)
  in
  {
    list_prs =
      (fun ~repo ->
        gh_json
          [
            "gh"; "pr"; "list"; "--repo"; repo; "--state"; "open";
            "--json";
            "number,title,url,headRefName,baseRefName,isDraft,mergeable,mergeStateStatus,statusCheckRollup";
          ]
          parse_pr);
    list_issues =
      (fun ~repo ->
        gh_json
          [
            "gh"; "issue"; "list"; "--repo"; repo; "--state"; "open";
            "--json"; "number,title,url,labels";
          ]
          parse_issue);
    run_command = run_process;
    now = Time_compat.now;
  }
