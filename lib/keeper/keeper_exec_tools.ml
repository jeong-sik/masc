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

let tool_call_observers
  : (keeper_name:string ->
     tool_name:string ->
     input:Yojson.Safe.t ->
     success:bool ->
     unit) list ref
  = ref []

let add_tool_call_observer fn =
  tool_call_observers := fn :: !tool_call_observers

let remove_tool_call_observer fn =
  tool_call_observers := List.filter (fun f -> f != fn) !tool_call_observers

let notify_tool_call_observers ~keeper_name ~tool_name ~input ~success =
  List.iter
    (fun f -> f ~keeper_name ~tool_name ~input ~success)
    !tool_call_observers

let tool_search_fn
  : (query:string -> max_results:int -> Yojson.Safe.t) ref
  =
  ref (fun ~query:_ ~max_results:_ ->
    `Assoc [ ("results", `List []) ])



(* ── Tool execution dispatch ──────────────────────────────────── *)

let execute_keeper_tool_call
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
      ?search_fn
      ~(name : string)
      ~(input : Yojson.Safe.t)
      ()
  : string
  =
  let args = input in
  let now_ts = Time_compat.now () in
  let apply_circuit_breaker result =
    (* Detect error in JSON result and enrich with corrective hint
       if the same error class has repeated [threshold] times. *)
    let is_error =
      try
        match Yojson.Safe.from_string result with
        | `Assoc fields ->
          (match List.assoc_opt "ok" fields with
           | Some (`Bool false) -> true
           | _ -> List.mem_assoc "error" fields)
        | _ -> false
      with _ -> false
    in
    if is_error then
      Keeper_failure_circuit_breaker.maybe_enrich_error
        ~keeper_name:meta.name ~error_msg:result
    else begin
      Keeper_failure_circuit_breaker.record_success ~keeper_name:meta.name;
      result
    end
  in
  let lookup = tool_access_lookup_of_meta meta in
  apply_circuit_breaker (
  if not (can_execute ~lookup name)
  then
    let reason, hint =
      if not (Hashtbl.mem lookup.candidate_set name)
      then
        ( "tool does not exist or is not available to your preset"
        , Printf.sprintf
            "'%s' is not a recognized tool. Check spelling or use keeper_tools_list to see available tools." name )
      else if Hashtbl.mem lookup.deny_set name
      then
        ( "denied_by_policy"
        , Printf.sprintf
            "'%s' is blocked by your current policy. Ask operator to grant access." name )
      else
        ( "not_in_allow_set"
        , Printf.sprintf
            "'%s' exists but your preset does not allow it. Use keeper_tools_list to see available tools." name )
    in
    Yojson.Safe.to_string
      (`Assoc [
        ("ok", `Bool false);
        ("error", `String "tool_not_allowed");
        ("tool", `String name);
        ("reason", `String reason);
        ("hint", `String hint);
      ])
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
        error_json "query is required. Good: query='read file'. Bad: query=''."

      else
        let fn = match search_fn with
          | Some f -> f
          | None -> !tool_search_fn
        in
        Yojson.Safe.to_string (fn ~query ~max_results)
    | "keeper_stay_silent" ->
      Yojson.Safe.to_string (`Assoc [ "status", `String "silent" ])
    | "keeper_tools_list" -> Keeper_exec_shared.keeper_tools_list_json ~meta
    | "keeper_time_now" ->
      Yojson.Safe.to_string
        (`Assoc [ "now_iso", `String (now_iso ()); "now_unix", `Float now_ts ])
    | "keeper_context_status" -> Keeper_exec_memory.keeper_context_status_json ~meta ~ctx_work
    | "keeper_memory_search" -> Keeper_exec_memory.keeper_memory_search_json ~config ~meta ~ctx_work ~args
    | "keeper_library_search" ->
      let ok, msg =
        Tool_library.handle_search Tool_library.{ agent_name = meta.name } args
      in
      if ok then msg else Yojson.Safe.to_string (`Assoc [ "error", `String msg ])
    | "keeper_library_read" ->
      let ok, msg =
        Tool_library.handle_read Tool_library.{ agent_name = meta.name } args
      in
      tool_result_or_error (ok, msg)
    | "keeper_board_post"
    | "keeper_board_list"
    | "keeper_board_get"
    | "keeper_board_comment"
    | "keeper_board_vote"
    | "keeper_board_stats"
    | "keeper_board_search"
    | "keeper_board_delete"
    | "keeper_board_cleanup" -> Keeper_exec_board.handle_keeper_board_tool ~meta ~name ~args
    | "keeper_fs_read" -> Keeper_exec_fs.handle_keeper_fs_read ~config ~meta ~args
    | "keeper_fs_edit" -> Keeper_exec_fs.handle_keeper_fs_edit ~config ~meta ~args
    | "keeper_bash" -> Keeper_exec_shell.handle_keeper_bash ~config ~meta ~args
    | "keeper_shell" -> Keeper_exec_shell.handle_keeper_shell ~config ~meta ~args
    | "keeper_voice_speak"
    | "keeper_voice_listen"
    | "keeper_voice_agent"
    | "keeper_voice_sessions"
    | "keeper_voice_session_start"
    | "keeper_voice_session_end" -> Keeper_exec_voice.handle_keeper_voice_tool ~meta ~name ~args
    | "keeper_github" -> Keeper_exec_github.handle_keeper_github ~config ~meta ~args
    | "keeper_pr_workflow" -> Keeper_tool_pr_workflow.handle_keeper_pr_workflow ~config ~meta ~args
    | "keeper_pr_submit" -> Keeper_exec_github.handle_keeper_pr_submit ~config ~meta ~args
    | "keeper_preflight_check" -> Keeper_exec_preflight.handle_keeper_preflight_check ~config ~meta ~args
    | "keeper_pr_review_read" -> Keeper_exec_github.handle_keeper_pr_review_read ~config ~meta ~args
    | "keeper_pr_review_comment" -> Keeper_exec_github.handle_keeper_pr_review_comment ~config ~meta ~args
    | "keeper_pr_review_reply" -> Keeper_exec_github.handle_keeper_pr_review_reply ~config ~meta ~args
    | "keeper_tasks_list"
    | "keeper_tasks_audit"
    | "keeper_task_force_release"
    | "keeper_task_force_done"
    | "keeper_broadcast"
    | "keeper_task_claim"
    | "keeper_task_create"
    | "keeper_task_done" -> Keeper_exec_task.handle_keeper_task_tool ~config ~meta ~name ~args
    | n when String.starts_with ~prefix:"masc_autoresearch_" n ->
      Keeper_exec_masc.handle_keeper_autoresearch_tool ~config ~meta ~name ~args
    | n when String.starts_with ~prefix:"masc_" n ->
      Keeper_exec_masc.handle_keeper_masc_tool ~config ~meta ~name ~args
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
      Yojson.Safe.to_string (`Assoc fields)))
