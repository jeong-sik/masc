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

let has_mutating_side_effect_with_input ~(tool_name : string) ~(input : Yojson.Safe.t)
  : bool
  =
  not (Keeper_tool_registry.is_read_only_with_input ~tool_name ~input)
;;

type keeper_tool_call_recorder =
  tool_name:string -> success:bool -> duration_ms:int -> unit

let default_keeper_tool_call_recorder ~tool_name:_ ~success:_ ~duration_ms:_ = ()
let keeper_tool_call_recorder_mutex = Stdlib.Mutex.create ()
let keeper_tool_call_recorder = ref default_keeper_tool_call_recorder

let set_on_keeper_tool_call (f : keeper_tool_call_recorder) =
  Stdlib.Mutex.protect keeper_tool_call_recorder_mutex (fun () ->
    keeper_tool_call_recorder := f)
;;

let record_keeper_tool_call ~tool_name ~success ~duration_ms =
  let f =
    Stdlib.Mutex.protect keeper_tool_call_recorder_mutex (fun () ->
      !keeper_tool_call_recorder)
  in
  f ~tool_name ~success ~duration_ms
;;

let search_char c =
  match c with
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> c
  | _ when Char.code c > 127 -> c
  | _ -> ' '
;;

let normalize_search_text text = String.lowercase_ascii (String.map search_char text)

let contains_substring text needle =
  let text_len = String.length text in
  let needle_len = String.length needle in
  let rec loop idx =
    idx + needle_len <= text_len
    && (String.sub text idx needle_len = needle || loop (idx + 1))
  in
  needle_len = 0 || loop 0
;;

let search_terms query =
  normalize_search_text query
  |> String.split_on_char ' '
  |> List.map String.trim
  |> List.filter (fun term -> term <> "")
  |> List.sort_uniq String.compare
;;

let dedupe_tool_search_schemas schemas =
  let seen = Hashtbl.create (List.length schemas) in
  List.filter
    (fun (schema : Masc_domain.tool_schema) ->
       if Hashtbl.mem seen schema.name
       then false
       else (
         Hashtbl.replace seen schema.name ();
         true))
    schemas
;;

let default_tool_search_schemas () =
  Tool_shard.all_keeper_tool_schemas @ [ keeper_tool_search_schema ]
  |> List.filter (fun (schema : Masc_domain.tool_schema) ->
    not (String.starts_with ~prefix:"masc_autoresearch_" schema.name))
  |> List.filter (fun (schema : Masc_domain.tool_schema) ->
    not (is_keeper_denied schema.name))
  |> dedupe_tool_search_schemas
;;

let score_tool_schema terms (schema : Masc_domain.tool_schema) =
  let help = Tool_help_registry.entry_of_schema schema in
  let name_text = normalize_search_text schema.name in
  let search_text =
    normalize_search_text
      (String.concat
         " "
         [ schema.name
         ; schema.description
         ; help.Tool_help_registry.when_to_use
         ; Yojson.Safe.to_string schema.input_schema
         ])
  in
  List.fold_left
    (fun score term ->
       if contains_substring name_text term
       then score +. 2.0
       else if contains_substring search_text term
       then score +. 1.0
       else score)
    0.0
    terms
;;

let default_tool_search_fn ~query ~max_results =
  let terms = search_terms query in
  let schemas = default_tool_search_schemas () in
  let hits =
    schemas
    |> List.filter_map (fun schema ->
      let score = score_tool_schema terms schema in
      if Float.compare score 0.0 <= 0 then None else Some (schema, score))
    |> List.sort (fun (left_schema, left_score) (right_schema, right_score) ->
      let by_score = compare right_score left_score in
      if by_score <> 0
      then by_score
      else String.compare left_schema.Masc_domain.name right_schema.name)
  in
  let rec take n xs =
    if n <= 0
    then []
    else (
      match xs with
      | [] -> []
      | x :: rest -> x :: take (n - 1) rest)
  in
  let selected = take max_results hits in
  let result_json (schema, score) =
    let help = Tool_help_registry.entry_of_schema schema in
    `Assoc
      [ "name", `String schema.Masc_domain.name
      ; "score", `Float score
      ; "description", `String help.short_description
      ; "when_to_use", `String help.when_to_use
      ; "input_schema", schema.input_schema
      ; "already_visible", `Bool false
      ]
  in
  let results = List.map result_json selected in
  let hint =
    if results = []
    then
      "No tools match this static fallback query. In normal keeper turns, the \
       session-scoped BM25 index provides richer policy-aware search."
    else
      "Static fallback results from keeper schemas. Normal keeper turns use the richer \
       session-scoped BM25 index."
  in
  `Assoc
    [ "ok", `Bool true
    ; "query", `String query
    ; "results", `List results
    ; "result_count", `Int (List.length results)
    ; ( "diagnostics"
      , `Assoc
          [ "source", `String "static_schema_fallback"
          ; "candidate_count", `Int (List.length schemas)
          ] )
    ; "hint", `String hint
    ]
;;

type tool_searcher = query:string -> max_results:int -> Yojson.Safe.t

let default_tool_searcher = default_tool_search_fn
let tool_searcher_mutex = Stdlib.Mutex.create ()
let tool_searcher = ref default_tool_searcher

let set_tool_search_fn (f : tool_searcher) =
  Stdlib.Mutex.protect tool_searcher_mutex (fun () -> tool_searcher := f)
;;

let search_tools ~query ~max_results =
  let f = Stdlib.Mutex.protect tool_searcher_mutex (fun () -> !tool_searcher) in
  f ~query ~max_results
;;

type tool_result_payload =
  | Structured_success
  | Structured_error
  | Plain_text
  | Malformed_structured of string

type execution_outcome =
  [ `Success
  | `Failure
  ]

type executed_tool_result =
  { raw_output : string
  ; outcome : execution_outcome
  ; payload_shape : tool_result_payload
  }

let looks_like_structured_payload payload =
  let len = String.length payload in
  let rec find_first_nonspace i =
    if i >= len
    then None
    else (
      match payload.[i] with
      | ' ' | '\t' | '\n' | '\r' -> find_first_nonspace (i + 1)
      | c -> Some c)
  in
  match find_first_nonspace 0 with
  | Some ('{' | '[') -> true
  | Some _ | None -> false
;;

let classify_tool_result_payload payload =
  if not (looks_like_structured_payload payload)
  then Plain_text
  else (
    match
      Safe_ops.parse_json_safe
        ~context:"Keeper_exec_tools.classify_tool_result_payload"
        payload
    with
    | Error msg -> Malformed_structured msg
    | Ok (`Assoc fields) ->
      let is_error =
        match List.assoc_opt "ok" fields with
        | Some (`Bool false) -> true
        | _ -> List.mem_assoc "error" fields
      in
      if is_error then Structured_error else Structured_success
    | Ok _ -> Structured_success)
;;

let is_policy_gate_error raw_output =
  match
    Safe_ops.parse_json_safe ~context:"Keeper_exec_tools.is_policy_gate_error" raw_output
  with
  | Ok json ->
    (match Safe_ops.json_string_opt "error" json with
     | Some msg -> String.equal (String.trim msg) "tool_not_allowed"
     | None -> false)
  | Error _ -> false
;;

let inferred_outcome_of_result ~raw_output ~payload_shape =
  match payload_shape with
  | Structured_success | Plain_text -> `Success
  | Structured_error -> `Failure
  | Malformed_structured _ -> `Failure
;;

let make_executed_tool_result ?outcome raw_output =
  let payload_shape = classify_tool_result_payload raw_output in
  let outcome =
    match outcome with
    | Some explicit -> explicit
    | None -> inferred_outcome_of_result ~raw_output ~payload_shape
  in
  { raw_output; outcome; payload_shape }
;;

let success_tool_result raw_output =
  make_executed_tool_result ~outcome:`Success raw_output
;;

let failure_tool_result raw_output =
  make_executed_tool_result ~outcome:`Failure raw_output
;;

let is_keeper_board_tool_name name =
  match Tool_name.Keeper.of_string name with
  | Some tool -> Tool_name.Keeper.is_board tool
  | None -> false
;;

(* ── Tool execution dispatch ──────────────────────────────────── *)

let execute_keeper_tool_call_with_outcome
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
      ?turn_sandbox_factory
      ?turn_sandbox_factory_git
      ~(exec_cache : Masc_exec.Exec_cache.t option)
      ?search_fn
      ~(name : string)
      ~(input : Yojson.Safe.t)
      ()
  : executed_tool_result
  =
  let args = input in
  let now_ts = Time_compat.now () in
  let meta =
    match Keeper_registry.get ~base_path:config.base_path meta.name with
    | Some entry -> entry.meta
    | None -> meta
  in
  let apply_circuit_breaker (result : executed_tool_result) =
    match result.outcome, result.payload_shape with
    | `Success, _ ->
      Keeper_failure_circuit_breaker.record_success ~keeper_name:meta.name;
      result
    | `Failure, Malformed_structured parse_error ->
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_exec_tools_failures
        ~labels:[ "keeper", meta.name; "tool", name ]
        ();
      Log.Keeper.error
        "keeper:%s tool:%s produced malformed structured payload: %s"
        meta.name
        name
        parse_error;
      let breaker_msg = Printf.sprintf "malformed_tool_result: %s" parse_error in
      let raw_output =
        Keeper_failure_circuit_breaker.maybe_enrich_error
          ~keeper_name:meta.name
          ~error_msg:breaker_msg
      in
      { raw_output
      ; outcome = `Failure
      ; payload_shape = classify_tool_result_payload raw_output
      }
    | `Failure, Structured_error | `Failure, Structured_success | `Failure, Plain_text ->
      let raw_output =
        Keeper_failure_circuit_breaker.maybe_enrich_error
          ~keeper_name:meta.name
          ~error_msg:result.raw_output
      in
      { raw_output
      ; outcome = `Failure
      ; payload_shape = classify_tool_result_payload raw_output
      }
  in
  let lookup = tool_access_lookup_of_meta meta in
  apply_circuit_breaker
    (if not (can_execute ~lookup name)
     then (
       let reason, hint =
         if not (StringSet.mem name lookup.candidate_set)
         then
           ( "not_in_candidate_set"
           , Printf.sprintf
               "'%s' is not a recognized tool. Check spelling or use keeper_tools_list \
                to see available tools."
               name )
         else if StringSet.mem name lookup.deny_set
         then
           ( "denied_by_policy"
           , Printf.sprintf
               "'%s' is blocked by your current policy. Ask operator to grant access."
               name )
         else
           ( "not_in_allow_set"
           , Printf.sprintf
               "'%s' exists but your preset does not allow it. Use keeper_tools_list to \
                see available tools."
               name )
       in
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_tool_not_allowed
         ~labels:[ "keeper", meta.name; "tool", name; "reason", reason ]
         ();
       make_executed_tool_result
         (Yojson.Safe.to_string
            (`Assoc
                [ "ok", `Bool false
                ; "error", `String "tool_not_allowed"
                ; "tool", `String name
                ; "reason", `String reason
                ; "hint", `String hint
                ])))
     else (
       match name with
       | _ when is_keeper_board_tool_name name ->
         make_executed_tool_result
           (Keeper_exec_board.handle_keeper_board_tool ~meta ~name ~args)
       | "keeper_tool_search" ->
         let query = Safe_ops.json_string ~default:"" "query" args |> String.trim in
         let max_results =
           min 10 (max 1 (Safe_ops.json_int ~default:5 "max_results" args))
         in
         if query = ""
         then
           failure_tool_result
             (error_json "query is required. Good: query='read file'. Bad: query=''.")
         else (
           let fn =
             match search_fn with
             | Some f -> f
             | None -> search_tools
           in
           success_tool_result (Yojson.Safe.to_string (fn ~query ~max_results)))
       | "keeper_stay_silent" ->
         success_tool_result
           (Yojson.Safe.to_string (`Assoc [ "status", `String "silent" ]))
       | "keeper_tools_list" ->
         success_tool_result (Keeper_exec_shared.keeper_tools_list_json ~meta)
       | "keeper_time_now" ->
         success_tool_result
           (Yojson.Safe.to_string
              (`Assoc [ "now_iso", `String (now_iso ()); "now_unix", `Float now_ts ]))
       | "keeper_context_status" ->
         success_tool_result
           (Keeper_exec_memory.keeper_context_status_json ~config ~meta ~ctx_work)
       | "keeper_memory_search" ->
         success_tool_result
           (Keeper_exec_memory.keeper_memory_search_json ~config ~meta ~ctx_work ~args)
       | "keeper_memory_write" ->
         success_tool_result
           (Keeper_exec_memory.keeper_memory_write_json ~config ~meta ~args)
       | "keeper_library_search" ->
         let result =
           Tool_library.handle_search ~tool_name:"keeper_library_search" ~start_time:0.0 Tool_library.{ agent_name = meta.name } args
         in
         if result.Tool_result.success
         then success_tool_result result.Tool_result.legacy_message
         else
           failure_tool_result (Yojson.Safe.to_string (`Assoc [ "error", `String result.Tool_result.legacy_message ]))
       | "keeper_library_read" ->
         let result =
           Tool_library.handle_read ~tool_name:"keeper_library_read" ~start_time:0.0 Tool_library.{ agent_name = meta.name } args
         in
         if result.Tool_result.success then success_tool_result result.Tool_result.legacy_message else failure_tool_result (error_json result.Tool_result.legacy_message)
       | "keeper_fs_read" ->
         make_executed_tool_result
           (Keeper_exec_fs.handle_keeper_fs_read
              ~turn_sandbox_factory
              ~config
              ~keeper_name:meta.name
              ~args)
       | "keeper_fs_edit" ->
         make_executed_tool_result
           (Keeper_exec_fs.handle_keeper_fs_edit
              ~turn_sandbox_factory
              ~config
              ~keeper_name:meta.name
              ~args)
       | "keeper_bash" ->
         make_executed_tool_result
           (Keeper_exec_shell.handle_keeper_bash
              ~turn_sandbox_factory
              ~turn_sandbox_factory_git
              ~exec_cache
              ~config
              ~meta
              ~args
              ())
       | "keeper_bash_output" ->
         make_executed_tool_result
           (Keeper_exec_shell.handle_keeper_bash_output ~config ~meta ~args)
       | "keeper_bash_kill" ->
         make_executed_tool_result
           (Keeper_exec_shell.handle_keeper_bash_kill ~config ~meta ~args)
       | "keeper_shell" ->
         make_executed_tool_result
           (Keeper_exec_shell.handle_keeper_shell
              ~turn_sandbox_factory
              ~exec_cache
              ~config
              ~meta
              ~args)
       | "keeper_voice_speak"
       | "keeper_voice_listen"
       | "keeper_voice_agent"
       | "keeper_voice_sessions"
       | "keeper_voice_session_start"
       | "keeper_voice_session_end" ->
         make_executed_tool_result
           (Keeper_exec_voice.handle_keeper_voice_tool ~meta ~name ~args)
       | "keeper_preflight_check" ->
         (* A preflight can legitimately return ok=false to block a risky or
         unready workflow.  That is a successful read-only diagnostic result,
         not a tool transport/execution failure.  The keeper still sees the
         raw ok=false report and must obey it. *)
         success_tool_result
           (Keeper_exec_preflight.handle_keeper_preflight_check ~config ~meta ~args)
       | "keeper_pr_list" ->
         make_executed_tool_result
           (Keeper_tool_github_pr.handle_keeper_pr_list ~config ~meta ~args)
       | "keeper_pr_status" ->
         make_executed_tool_result
           (Keeper_tool_github_pr.handle_keeper_pr_status ~config ~meta ~args)
       | "keeper_pr_create" ->
         make_executed_tool_result
           (Keeper_tool_github_pr.handle_keeper_pr_create ~config ~meta ~args)
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
       | "keeper_task_done"
       | "keeper_task_submit_for_verification" ->
         make_executed_tool_result
           (Keeper_exec_task.handle_keeper_task_tool ~config ~meta ~name ~args)
       | other ->
         (match
            Keeper_exec_masc.handle_registered_keeper_tool ~config ~keeper_name:meta.name ~name:other ~args
          with
          | Some raw_output -> make_executed_tool_result raw_output
          | None ->
            let suggestion =
              let candidates = keeper_allowed_tool_names meta in
              let scored =
                candidates
                |> List.filter_map (fun c ->
                  if String.length c > 2 && String.length other > 2
                  then (
                    let other_lower = String.lowercase_ascii other in
                    let c_lower = String.lowercase_ascii c in
                    let contains haystack needle =
                      let nlen = String.length needle in
                      let hlen = String.length haystack in
                      if nlen = 0
                      then true
                      else if nlen > hlen
                      then false
                      else (
                        let found = ref false in
                        for i = 0 to hlen - nlen do
                          if (not !found) && String.sub haystack i nlen = needle
                          then found := true
                        done;
                        !found)
                    in
                    if contains c_lower other_lower || contains other_lower c_lower
                    then Some c
                    else None)
                  else None)
                |> List.filteri (fun i _ -> i < 3)
              in
              scored
            in
            let masc_schemas = Keeper_tool_registry.masc_schemas_snapshot () in
            let enrich_suggestion name =
              let schema_opt =
                List.find_opt
                  (fun (s : Masc_domain.tool_schema) -> s.name = name)
                  masc_schemas
              in
              match schema_opt with
              | Some s ->
                `Assoc
                  [ "name", `String name
                  ; "description", `String s.description
                  ; "input_schema", s.input_schema
                  ]
              | None -> `String name
            in
            let fields =
              [ "error", `String "unknown_tool"; "tool", `String other ]
              @
              match suggestion with
              | [] ->
                [ "hint", `String "Use keeper_tool_search to find available tools." ]
              | names ->
                [ "did_you_mean", `List (List.map enrich_suggestion names)
                ; "hint", `String "Call one of these tools with the correct parameters."
                ]
            in
            make_executed_tool_result (Yojson.Safe.to_string (`Assoc fields)))))
;;

let execute_keeper_tool_call
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
      ?turn_sandbox_factory
      ?turn_sandbox_factory_git
      ~(exec_cache : Masc_exec.Exec_cache.t option)
      ?search_fn
      ~(name : string)
      ~(input : Yojson.Safe.t)
      ()
  : string
  =
  let result =
    execute_keeper_tool_call_with_outcome
      ~config
      ~meta
      ~ctx_work
      ?turn_sandbox_factory
      ?turn_sandbox_factory_git
      ~exec_cache
      ?search_fn
      ~name
      ~input
      ()
  in
  result.raw_output
;;
