(** PR action metric helpers for [Keeper_hooks_oas]. *)

open Keeper_hooks_oas_types

open Keeper_hooks_oas_output_json

let pr_review_action_metric_event_of_tool_io
    ~route_via_fallback
    ~(tool_name : string)
    ~(input : Yojson.Safe.t)
    ~(output_text : string)
    ~(transport_success : bool) =
  if String.equal tool_name "keeper_pr_review_comment"
  then
    let output_json = output_json_opt ~surface:"pr_review_action" output_text in
    let route_via =
      first_some (Option.bind output_json route_via_of_json)
        route_via_fallback
    in
    let action =
      match output_json with
      | Some json -> Safe_ops.json_string_opt "event" json
      | None -> None
    in
    let action =
      match action with
      | Some value -> Some value
      | None -> Safe_ops.json_string_opt "event" input
    in
    let success =
      output_success ~transport_success output_json
    in
    let credential = Option.bind output_json (assoc_json_opt "credential") in
    let identity_attestation =
      Option.bind output_json (assoc_json_opt "identity_attestation")
    in
    Option.map
      (fun action ->
         {
           action;
           pr_number =
             first_some
               (match output_json with
                | Some json -> json_int_opt "pr_number" json
                | None -> None)
               (json_int_opt "pr_number" input);
           comment_id = None;
           success;
           route_via;
           credential;
           identity_attestation;
         })
      (Option.bind action normalize_pr_review_action)
  else if String.equal tool_name "keeper_pr_review_reply"
  then
    let output_json = output_json_opt ~surface:"pr_review_action" output_text in
    let route_via =
      first_some (Option.bind output_json route_via_of_json)
        route_via_fallback
    in
    let success =
      output_success ~transport_success output_json
    in
    let credential = Option.bind output_json (assoc_json_opt "credential") in
    let identity_attestation =
      Option.bind output_json (assoc_json_opt "identity_attestation")
    in
    Some
      {
        action = "REPLY";
        pr_number =
          first_some
            (match output_json with
             | Some json -> json_int_opt "pr_number" json
             | None -> None)
            (json_int_opt "pr_number" input);
        comment_id =
          first_some
            (match output_json with
             | Some json -> json_int_opt "comment_id" json
             | None -> None)
            (json_int_opt "comment_id" input);
        success;
        route_via;
        credential;
        identity_attestation;
      }
  else if String.equal tool_name "keeper_shell"
  then
    let output_json = output_json_opt ~surface:"pr_review_action" output_text in
    let route_via =
      first_some (Option.bind output_json route_via_of_json)
        route_via_fallback
    in
    let success =
      output_success ~transport_success output_json
    in
    command_candidates_of_tool_io ~tool_name ~input ~output_json
    |> List.find_map gh_pr_review_action_of_command
    |> Option.map (fun (action, pr_number) ->
         {
           action;
           pr_number;
           comment_id = None;
           success;
           route_via;
           credential = None;
           identity_attestation = None;
         })
  else None

let pr_work_action_of_git_action raw =
  let lower = String.trim raw |> String.lowercase_ascii in
  if String.equal lower "add" then Some "GIT_ADD"
  else if String.equal lower "commit" then Some "GIT_COMMIT"
  else if String.equal lower "push" then Some "GIT_PUSH"
  else None

let pr_work_actions_of_git_segment segment =
  match Exec_policy_mutation_classifier.argv_words_of_string segment with
  | Some ("git" :: action :: _) ->
      pr_work_action_of_git_action action |> Option.to_list
  | Some ("git" :: []) -> []
  | Some _ -> []
  | None ->
      let lower = String.trim segment |> String.lowercase_ascii in
      let starts_with_word prefix =
        String.equal lower prefix
        || (String.length lower > String.length prefix
            && String.starts_with ~prefix:(prefix ^ " ") lower)
      in
      if starts_with_word "git push" then [ "GIT_PUSH" ]
      else if starts_with_word "git commit" then [ "GIT_COMMIT" ]
      else if starts_with_word "git add" then [ "GIT_ADD" ]
      else []

let pr_work_actions_of_gh_segment segment =
  match gh_argv_of_segment segment with
  | Some (subcommand :: action :: _)
    when String.equal (String.lowercase_ascii subcommand) "pr"
         && String.equal (String.lowercase_ascii action) "create" ->
      [ "PR_CREATE" ]
  | Some [] | Some [ _ ] | Some (_ :: _ :: _) | None -> []

let pr_work_actions_of_command command =
  Masc_exec_bash_parser.Bash_words.top_level_command_segments command
  |> List.concat_map (fun (unconditional, segment) ->
       (* Shell conditionals can skip later segments at runtime.  Without
          per-segment exit data, count only top-level segments that are
          unconditionally reached. *)
       if not unconditional then []
       else
         match pr_work_actions_of_gh_segment segment with
         | [] -> pr_work_actions_of_git_segment segment
         | actions -> actions)

let is_pr_work_action_tool_name tool_name =
  List.mem tool_name [ "masc_code_git"; "keeper_shell"; "keeper_bash"; "masc_code_shell" ]

let pr_work_action_metric_events_of_tool_io
    ~route_via_fallback
    ~(tool_name : string)
    ~(input : Yojson.Safe.t)
    ~(output_text : string)
    ~(transport_success : bool) =
  if not (is_pr_work_action_tool_name tool_name) then []
  else
  let observe_json_failure =
    not (List.mem tool_name [ "keeper_shell"; "keeper_bash"; "masc_code_shell" ])
  in
  let output_json =
    output_json_opt ~observe_failure:observe_json_failure
      ~surface:"pr_work_action" output_text
  in
  let route_via =
    first_some (Option.bind output_json route_via_of_json)
      route_via_fallback
  in
  let success = output_success ~transport_success output_json in
  if String.equal tool_name "masc_code_git"
  then
    let action =
      match output_json with
      | Some json -> Safe_ops.json_string_opt "action" json
      | None -> None
    in
    let action =
      match action with
      | Some value -> Some value
      | None -> Safe_ops.json_string_opt "action" input
    in
    (match Option.bind action pr_work_action_of_git_action with
     | None -> []
     | Some work_action ->
         [
           {
             work_action;
             work_source = "masc_code_git";
             work_ref = None;
             pr_url = None;
             command = None;
             success;
             route_via;
           };
         ])
  else if List.mem tool_name [ "keeper_shell"; "keeper_bash"; "masc_code_shell" ]
  then
    command_candidates_of_tool_io ~tool_name ~input ~output_json
    |> List.concat_map (fun command ->
         pr_work_actions_of_command command
         |> List.map (fun work_action ->
              ( command,
                {
                  work_action;
                  work_source = tool_name;
                  work_ref = None;
                  pr_url = None;
                  command = Some command;
                  success;
                  route_via;
                } )))
    |> List.fold_left
         (fun (seen, events) (_command, event) ->
            let key = event.work_action in
            if List.mem key seen then (seen, events)
            else (key :: seen, events @ [ event ]))
         ([], [])
    |> snd
  else []

let append_pr_review_action_metric
    ~(config : Coord.config)
    ~(meta : Keeper_types.keeper_meta)
    ~(generation : int)
    ~(tool_name : string)
    ~(input : Yojson.Safe.t)
    ~(output_text : string)
    ~(transport_success : bool)
    ~(duration_ms : float)
    () =
  let route_via_fallback =
    if meta.sandbox_profile = Docker then
      if List.mem tool_name ["keeper_pr_review_comment"; "keeper_pr_review_reply"] then Some "brokered"
      else if String.equal tool_name "keeper_shell" then Some "docker"
      else None
    else None
  in
  match
    pr_review_action_metric_event_of_tool_io
      ~route_via_fallback ~tool_name ~input ~output_text ~transport_success
  with
  | None -> ()
  | Some event ->
      let now = Time_compat.now () in
      let store = Keeper_types.keeper_pr_action_metrics_store config meta.name in
      let route_fields =
        match event.route_via with
        | None -> []
        | Some via -> [(key_via, `String via); (key_route_via, `String via)]
      in
      let identity_fields =
        []
        |> (fun fields ->
             match event.credential with
             | None -> fields
             | Some credential -> ("credential", credential) :: fields)
        |> (fun fields ->
             match event.identity_attestation with
             | None -> fields
             | Some attestation -> ("identity_attestation", attestation) :: fields)
        |> List.rev
      in
      let snapshot =
        `Assoc
          ([
             (key_ts, `String (Masc_domain.iso8601_of_unix_seconds now));
             (key_ts_unix, `Float now);
             (key_channel, `String "tool_event");
             (key_metric_event, `String "keeper_pr_review_action");
             (key_name, `String meta.name);
             (key_agent_name, `String meta.agent_name);
             ( "trace_id",
               `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id) );
             (key_generation, `Int generation);
             (key_tool_name, `String tool_name);
             (key_pr_review_action, `String event.action);
             (key_pr_review_action_success, `Bool event.success);
             (key_tool_call_count, `Int 0);
             (key_tools_used, `List []);
             ("pr_number", Json_util.int_opt_to_json event.pr_number);
             ("comment_id", Json_util.int_opt_to_json event.comment_id);
             (key_duration_ms, `Float duration_ms);
           ]
           @ route_fields
           @ identity_fields)
      in
      Dated_jsonl.append store (Inference_utils.sanitize_json_utf8 snapshot)

let append_pr_work_action_metrics
    ~(config : Coord.config)
    ~(meta : Keeper_types.keeper_meta)
    ~(generation : int)
    ~(tool_name : string)
    ~(input : Yojson.Safe.t)
    ~(output_text : string)
    ~(transport_success : bool)
    ~(duration_ms : float)
    () =
  let route_via_fallback =
    if meta.sandbox_profile = Docker
       && List.mem tool_name ["keeper_shell"; "keeper_bash"; "masc_code_shell"; "masc_code_git"]
    then Some "docker"
    else None
  in
  let events =
    pr_work_action_metric_events_of_tool_io
      ~route_via_fallback ~tool_name ~input ~output_text ~transport_success
  in
  match events with
  | [] -> ()
  | _ ->
      let store = Keeper_types.keeper_pr_action_metrics_store config meta.name in
      List.iter
        (fun event ->
           let now = Time_compat.now () in
           let route_fields =
             match event.route_via with
             | None -> []
             | Some via -> [(key_via, `String via); (key_route_via, `String via)]
           in
           let snapshot =
             `Assoc
               ([
                  (key_ts, `String (Masc_domain.iso8601_of_unix_seconds now));
                  (key_ts_unix, `Float now);
                  (key_channel, `String "tool_event");
                  (key_metric_event, `String "keeper_pr_work_action");
                  (key_name, `String meta.name);
                  (key_agent_name, `String meta.agent_name);
                  ( "trace_id",
                    `String
                      (Keeper_id.Trace_id.to_string meta.runtime.trace_id) );
                  (key_generation, `Int generation);
                  (key_tool_name, `String tool_name);
                  (key_pr_work_action, `String event.work_action);
                  (key_pr_work_action_source, `String event.work_source);
                  (key_pr_work_action_success, `Bool event.success);
                  ( "pr_work_ref",
                    Json_util.string_opt_to_json event.work_ref );
                  ("pr_url", Json_util.string_opt_to_json event.pr_url);
                  ( "pr_work_command",
                    Json_util.string_opt_to_json event.command );
                  (key_tool_call_count, `Int 0);
                  (key_tools_used, `List []);
                  (key_duration_ms, `Float duration_ms);
                ]
                @ route_fields)
           in
           Dated_jsonl.append store
             (Inference_utils.sanitize_json_utf8 snapshot))
        events
