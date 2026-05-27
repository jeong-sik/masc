(** PR action metric helpers for [Keeper_hooks_oas]. *)

open Keeper_hooks_oas_types

open Keeper_hooks_oas_output_json

let pr_work_action_of_git_action raw =
  let lower = String.trim raw |> String.lowercase_ascii in
  if String.equal lower "add" then Some "GIT_ADD"
  else if String.equal lower "commit" then Some "GIT_COMMIT"
  else if String.equal lower "push" then Some "GIT_PUSH"
  else None

let pr_work_actions_of_git_segment segment =
  let fallback () =
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
  in
  match Agent_tool_execute_command_semantics.effective_stages_of_cmd segment with
  | [ { bin = "git"; args = action :: _ } ] ->
    pr_work_action_of_git_action action |> Option.to_list
  | [ { bin = "git"; args = [] } ] -> []
  | [] -> fallback ()
  | _ -> []

let pr_work_actions_of_repo_hosting_cli_segment segment =
  match repo_hosting_cli_argv_of_segment segment with
  | Some (_bin :: subcommand :: action :: _)
    when String.equal (String.lowercase_ascii subcommand) "pr"
         && String.equal (String.lowercase_ascii action) "create" ->
      [ "PR_CREATE" ]
  | Some _ | None -> []

let pr_work_actions_of_command command =
  Masc_exec_bash_parser.Bash_words.top_level_command_segments command
  |> List.concat_map (fun (unconditional, segment) ->
       (* Shell conditionals can skip later segments at runtime.  Without
          per-segment exit data, count only top-level segments that are
          unconditionally reached. *)
       if not unconditional then []
       else
         match pr_work_actions_of_repo_hosting_cli_segment segment with
         | [] -> pr_work_actions_of_git_segment segment
         | actions -> actions)

(* STR-OK: tool_name is the external MCP tool-name boundary for telemetry. *)
let is_pr_work_action_tool_name tool_name =
  Keeper_tool_capability_axis.supports Pr_work_action tool_name

let pr_work_action_metric_events_of_tool_io
    ~route_via_fallback
    ~(tool_name : string)
    ~(input : Yojson.Safe.t)
    ~(output_text : string)
    ~(transport_success : bool) =
  if not (is_pr_work_action_tool_name tool_name) then []
  else
  let normalized_tool_name = Keeper_tool_capability_axis.canonical_tool_name tool_name in
  let observe_json_failure =
    Keeper_tool_capability_axis.supports Pr_work_git_action tool_name
    || not
         (Keeper_tool_capability_axis.supports Pr_work_shell_command tool_name)
  in
  let output_json =
    output_json_opt ~observe_failure:observe_json_failure
      ~surface:"pr_work_action" output_text
  in
  let route_via =
    Dashboard_utils.first_some (Option.bind output_json route_via_of_json)
      route_via_fallback
  in
  let success = output_success ~transport_success output_json in
  let event ?command work_action =
    {
      work_action;
      work_source = normalized_tool_name;
      work_ref = None;
      pr_url = None;
      command;
      success;
      route_via;
    }
  in
  let action_events =
    if not (Keeper_tool_capability_axis.supports Pr_work_git_action tool_name)
    then []
    else
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
     | Some work_action -> [ event work_action ])
  in
  let command_events =
    if not (Keeper_tool_capability_axis.supports Pr_work_shell_command tool_name)
    then []
    else
    command_candidates_of_tool_io ~tool_name ~input ~output_json
    |> List.concat_map (fun command ->
         pr_work_actions_of_command command
         |> List.map (fun work_action ->
              event ~command work_action))
  in
  action_events @ command_events
    |> List.fold_left
         (fun (seen, events) event ->
            let key = event.work_action in
            if List.mem key seen then (seen, events)
            else (key :: seen, events @ [ event ]))
         ([], [])
    |> snd

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
       && Keeper_tool_capability_axis.supports
            Docker_route_pr_work_action
            tool_name
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
      let store =
        Keeper_types_support.github_pr_action_metrics_store config meta.name
      in
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
                  (key_metric_event, `String "github_pr_work_action");
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
