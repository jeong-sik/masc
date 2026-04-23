(** Keeper_exec_tools — keeper tool execution and tool-loop helpers.

    Split into multiple layers:
    - [Keeper_tool_registry]: declarative tool name lists (data)
    - [Keeper_tool_policy]: access control, presets, allowed-tool resolution (logic)
    - [Keeper_exec_*]: dedicated modules for tool categories
    - This module: execution dispatch + shared helpers (side-effects) *)

open Keeper_types
open Keeper_exec_shared

include Keeper_tool_registry
include Keeper_tool_policy

let has_mutating_side_effect_with_input ~(tool_name : string)
    ~(input : Yojson.Safe.t) : bool =
  not (Keeper_tool_registry.is_read_only_with_input ~tool_name ~input)

let on_keeper_tool_call
  : (tool_name:string -> success:bool -> duration_ms:int -> unit) ref
  =
  ref (fun ~tool_name:_ ~success:_ ~duration_ms:_ -> ())

let tool_search_fn
  : (query:string -> max_results:int -> Yojson.Safe.t) ref
  =
  ref (fun ~query:_ ~max_results:_ ->
    `Assoc [ ("results", `List []) ])

type tool_result_payload =
  | Structured_success
  | Structured_error
  | Plain_text
  | Malformed_structured of string

type execution_outcome = [ `Success | `Failure ]

type executed_tool_result = {
  raw_output : string;
  outcome : execution_outcome;
  payload_shape : tool_result_payload;
}

let looks_like_structured_payload payload =
  let len = String.length payload in
  let rec find_first_nonspace i =
    if i >= len then None
    else
      match payload.[i] with
      | ' ' | '\t' | '\n' | '\r' -> find_first_nonspace (i + 1)
      | c -> Some c
  in
  match find_first_nonspace 0 with
  | Some ('{' | '[') -> true
  | Some _ | None -> false

let classify_tool_result_payload payload =
  if not (looks_like_structured_payload payload) then Plain_text
  else
    match Safe_ops.parse_json_safe ~context:"Keeper_exec_tools.classify_tool_result_payload" payload with
    | Error msg -> Malformed_structured msg
    | Ok (`Assoc fields) ->
      let is_error =
        match List.assoc_opt "ok" fields with
        | Some (`Bool false) -> true
        | _ -> List.mem_assoc "error" fields
      in
      if is_error then Structured_error else Structured_success
    | Ok _ -> Structured_success

let is_policy_gate_error raw_output =
  match Safe_ops.parse_json_safe
          ~context:"Keeper_exec_tools.is_policy_gate_error"
          raw_output
  with
  | Ok json ->
      (match Safe_ops.json_string_opt "error" json with
       | Some msg -> String.equal (String.trim msg) "tool_not_allowed"
       | None -> false)
  | Error _ -> false

let inferred_outcome_of_result ~raw_output ~payload_shape =
  match payload_shape with
  | Structured_success
  | Plain_text ->
      `Success
  | Structured_error ->
      if is_policy_gate_error raw_output then `Success else `Failure
  | Malformed_structured _ ->
      `Failure

let make_executed_tool_result ?outcome raw_output =
  let payload_shape = classify_tool_result_payload raw_output in
  let outcome =
    match outcome with
    | Some explicit -> explicit
    | None -> inferred_outcome_of_result ~raw_output ~payload_shape
  in
  { raw_output; outcome; payload_shape }

let success_tool_result raw_output =
  make_executed_tool_result ~outcome:`Success raw_output

let failure_tool_result raw_output =
  make_executed_tool_result ~outcome:`Failure raw_output



(* ── Tool execution dispatch ──────────────────────────────────── *)

let execute_keeper_tool_call_with_outcome
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
      ?turn_sandbox_runtime
      ?turn_sandbox_runtime_git
      ?search_fn
      ~(name : string)
      ~(input : Yojson.Safe.t)
      ()
  : executed_tool_result
  =
  let args = input in
  let now_ts = Time_compat.now () in
  let apply_circuit_breaker (result : executed_tool_result) =
    match result.outcome, result.payload_shape with
    | `Success, _ ->
      Keeper_failure_circuit_breaker.record_success ~keeper_name:meta.name;
      result
    | `Failure, Malformed_structured parse_error ->
      Log.Keeper.error
        "keeper:%s tool:%s produced malformed structured payload: %s"
        meta.name name parse_error;
      let breaker_msg =
        Printf.sprintf "malformed_tool_result: %s" parse_error
      in
      let raw_output =
        Keeper_failure_circuit_breaker.maybe_enrich_error
          ~keeper_name:meta.name ~error_msg:breaker_msg
      in
      { raw_output; outcome = `Failure;
        payload_shape = classify_tool_result_payload raw_output; }
    | `Failure, Structured_error
    | `Failure, Structured_success
    | `Failure, Plain_text ->
      let raw_output =
        Keeper_failure_circuit_breaker.maybe_enrich_error
          ~keeper_name:meta.name ~error_msg:result.raw_output
      in
      { raw_output; outcome = `Failure;
        payload_shape = classify_tool_result_payload raw_output; }
  in
  let lookup = tool_access_lookup_of_meta meta in
  apply_circuit_breaker (
  if not (can_execute ~lookup name)
  then
    let reason, hint =
      if not (StringSet.mem name lookup.candidate_set)
      then
        ( "tool does not exist or is not available to your preset"
        , Printf.sprintf
            "'%s' is not a recognized tool. Check spelling or use keeper_tools_list to see available tools." name )
      else if StringSet.mem name lookup.deny_set
      then
        ( "denied_by_policy"
        , Printf.sprintf
            "'%s' is blocked by your current policy. Ask operator to grant access." name )
      else
        ( "not_in_allow_set"
        , Printf.sprintf
            "'%s' exists but your preset does not allow it. Use keeper_tools_list to see available tools." name )
    in
    make_executed_tool_result
      (Yojson.Safe.to_string
         (`Assoc [
           ("ok", `Bool false);
           ("error", `String "tool_not_allowed");
           ("tool", `String name);
           ("reason", `String reason);
           ("hint", `String hint);
         ]))
  else (
    match name with
    | "keeper_tool_search" ->
      let query =
        Safe_ops.json_string ~default:"" "query" args |> String.trim
      in
      let max_results =
        min 10 (max 1 (Safe_ops.json_int ~default:5 "max_results" args))
      in
      if query = "" then
        failure_tool_result
          (error_json
             "query is required. Good: query='read file'. Bad: query=''.")

      else
        let fn = match search_fn with
          | Some f -> f
          | None -> !tool_search_fn
        in
        success_tool_result (Yojson.Safe.to_string (fn ~query ~max_results))
    | "keeper_stay_silent" ->
      success_tool_result
        (Yojson.Safe.to_string (`Assoc [ "status", `String "silent" ]))
    | "keeper_tools_list" ->
      success_tool_result (Keeper_exec_shared.keeper_tools_list_json ~meta)
    | "keeper_time_now" ->
      success_tool_result
        (Yojson.Safe.to_string
           (`Assoc [ "now_iso", `String (now_iso ());
                     "now_unix", `Float now_ts ]))
    | "keeper_context_status" ->
      success_tool_result
        (Keeper_exec_memory.keeper_context_status_json ~config ~meta ~ctx_work)
    | "keeper_memory_search" ->
      success_tool_result
        (Keeper_exec_memory.keeper_memory_search_json ~config ~meta ~ctx_work ~args)
    | "keeper_library_search" ->
      let ok, msg =
        Tool_library.handle_search Tool_library.{ agent_name = meta.name } args
      in
      if ok then success_tool_result msg
      else failure_tool_result
             (Yojson.Safe.to_string (`Assoc [ "error", `String msg ]))
    | "keeper_library_read" ->
      let ok, msg =
        Tool_library.handle_read Tool_library.{ agent_name = meta.name } args
      in
      if ok then success_tool_result msg
      else failure_tool_result (error_json msg)
    | "keeper_board_post"
    | "keeper_board_list"
    | "keeper_board_get"
    | "keeper_board_comment"
    | "keeper_board_vote"
    | "keeper_board_stats"
    | "keeper_board_search"
    | "keeper_board_delete"
    | "keeper_board_cleanup" ->
      make_executed_tool_result
        (Keeper_exec_board.handle_keeper_board_tool ~meta ~name ~args)
    | "keeper_fs_read" ->
      make_executed_tool_result
        (Keeper_exec_fs.handle_keeper_fs_read ~turn_sandbox_runtime ~config ~meta ~args)
    | "keeper_fs_edit" ->
      make_executed_tool_result
        (Keeper_exec_fs.handle_keeper_fs_edit ~turn_sandbox_runtime ~config ~meta ~args)
    | "keeper_bash" ->
      make_executed_tool_result
        (Keeper_exec_shell.handle_keeper_bash
           ~turn_sandbox_runtime ~turn_sandbox_runtime_git ~config ~meta ~args)
    | "keeper_bash_output" ->
      make_executed_tool_result
        (Keeper_exec_shell.handle_keeper_bash_output ~config ~meta ~args)
    | "keeper_bash_kill" ->
      make_executed_tool_result
        (Keeper_exec_shell.handle_keeper_bash_kill ~config ~meta ~args)
    | "keeper_shell" ->
      make_executed_tool_result
        (Keeper_exec_shell.handle_keeper_shell ~turn_sandbox_runtime ~config ~meta ~args)
    | "keeper_voice_speak"
    | "keeper_voice_listen"
    | "keeper_voice_agent"
    | "keeper_voice_sessions"
    | "keeper_voice_session_start"
    | "keeper_voice_session_end" ->
      make_executed_tool_result
        (Keeper_exec_voice.handle_keeper_voice_tool ~meta ~name ~args)
    | "keeper_preflight_check" ->
      make_executed_tool_result
        (Keeper_exec_preflight.handle_keeper_preflight_check ~config ~meta ~args)
    | "keeper_pr_review_read" ->
      make_executed_tool_result
        (Keeper_tool_pr_review.handle_keeper_pr_review_read ~config ~meta ~args)
    | "keeper_pr_review_comment" ->
      make_executed_tool_result
        (Keeper_tool_pr_review.handle_keeper_pr_review_comment ~config ~meta ~args)
    | "keeper_pr_review_reply" ->
      make_executed_tool_result
        (Keeper_tool_pr_review.handle_keeper_pr_review_reply ~config ~meta ~args)
    | "keeper_tasks_list"
    | "keeper_tasks_audit"
    | "keeper_task_force_release"
    | "keeper_task_force_done"
    | "keeper_broadcast"
    | "keeper_task_claim"
    | "keeper_task_create"
    | "keeper_task_done" ->
      make_executed_tool_result
        (Keeper_exec_task.handle_keeper_task_tool ~config ~meta ~name ~args)
    | n when String.starts_with ~prefix:"masc_autoresearch_" n ->
      make_executed_tool_result
        (Keeper_exec_masc.handle_keeper_autoresearch_tool ~config ~meta ~name ~args)
    | n when String.starts_with ~prefix:"masc_" n ->
      make_executed_tool_result
        (Keeper_exec_masc.handle_keeper_masc_tool ~config ~meta ~name ~args)
    | other ->
      let suggestion =
        let candidates = keeper_allowed_tool_names meta in
        let scored =
          candidates
          |> List.filter_map (fun c ->
            if String.length c > 2 && String.length other > 2 then
              let other_lower = String.lowercase_ascii other in
              let c_lower = String.lowercase_ascii c in
              let contains haystack needle =
                let nlen = String.length needle in
                let hlen = String.length haystack in
                if nlen = 0 then true
                else if nlen > hlen then false
                else
                  let found = ref false in
                  for i = 0 to hlen - nlen do
                    if not !found
                       && String.sub haystack i nlen = needle
                    then found := true
                  done;
                  !found
              in
              if contains c_lower other_lower
                 || contains other_lower c_lower
              then Some c
              else None
            else None)
          |> List.filteri (fun i _ -> i < 3)
        in
        scored
      in
      let masc_schemas = !Keeper_tool_registry.masc_schemas_ref in
      let enrich_suggestion name =
        let schema_opt =
          List.find_opt (fun (s : Types.tool_schema) -> s.name = name) masc_schemas
        in
        match schema_opt with
        | Some s ->
          `Assoc [
            ("name", `String name);
            ("description", `String s.description);
            ("input_schema", s.input_schema);
          ]
        | None -> `String name
      in
      let fields =
        [ ("error", `String "unknown_tool"); ("tool", `String other) ]
        @ (match suggestion with
           | [] -> [("hint", `String "Use keeper_tool_search to find available tools.")]
           | names ->
             [ ("did_you_mean", `List (List.map enrich_suggestion names));
               ("hint", `String "Call one of these tools with the correct parameters.") ])
      in
      make_executed_tool_result (Yojson.Safe.to_string (`Assoc fields))))

let execute_keeper_tool_call
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
      ?turn_sandbox_runtime
      ?turn_sandbox_runtime_git
      ?search_fn
      ~(name : string)
      ~(input : Yojson.Safe.t)
      ()
  : string
  =
  let result =
    execute_keeper_tool_call_with_outcome
      ~config ~meta ~ctx_work ?turn_sandbox_runtime ?turn_sandbox_runtime_git
      ?search_fn ~name ~input ()
  in
  result.raw_output
