(** Keeper_status_detail — single-keeper detailed status handler.
    Split from keeper_status.ml. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_memory
open Keeper_alerting
open Keeper_tool_dispatch_runtime
open Keeper_execution
open Keeper_status_runtime
open Keeper_status_metrics
open Keeper_status_bridge

type tool_result = Keeper_types_profile.tool_result

let read_tail_lines_or_empty ~site path ~max_bytes ~max_lines =
  match read_file_tail_lines_result path ~max_bytes ~max_lines with
  | Ok lines -> lines
  | Error exn_class ->
      record_memory_recall_read_error ~site path exn_class;
      []

(* Status request contract. *)

type tail_order = Keeper_status_options_defaults.tail_order =
  | Oldest_first
  | Newest_first

type status_options =
  { tail_turns : int
  ; tail_messages : int
  ; tail_bytes : int
  ; tail_order : tail_order
  ; fast : bool
  ; include_context : bool
  ; include_metrics_overview : bool
  ; include_history_tail : bool
  }

let normalize_status_name = String.trim

let status_name_lookup_candidates raw_name =
  let trimmed = normalize_status_name raw_name in
  if String.equal trimmed "" then [] else [ trimmed ]

let status_argument_fields = function
  | `Assoc fields ->
      let rec collect seen = function
        | [] -> Ok (List.rev seen)
        | (key, value) :: rest ->
            if
              not
                (List.exists
                   (String.equal key)
                   Keeper_status_options_defaults.Argument.all)
            then
              Error
                (Printf.sprintf
                   "unknown keeper_status argument %S"
                   key)
            else if
              List.exists
                (fun (seen_key, _) -> String.equal key seen_key)
                seen
            then
              Error
                (Printf.sprintf
                   "keeper_status argument %S must occur at most once"
                   key)
            else collect ((key, value) :: seen) rest
      in
      collect [] fields
  | _ -> Error "keeper_status arguments must be a JSON object"

let status_argument fields key =
  List.find_map
    (fun (candidate, value) ->
      if String.equal key candidate then Some value else None)
    fields

let optional_bool_argument fields key ~default =
  match status_argument fields key with
  | None -> Ok default
  | Some (`Bool value) -> Ok value
  | Some _ ->
      Error
        (Printf.sprintf "keeper_status argument %S must be a boolean" key)

let optional_int_argument fields key ~default ~minimum ~maximum =
  let validate value =
    if value < minimum
    then
      Error
        (Printf.sprintf
           "keeper_status argument %S must be at least %d (received %d)"
           key
           minimum
           value)
    else if value > maximum
    then
      Error
        (Printf.sprintf
           "keeper_status argument %S must be at most %d (received %d)"
           key
           maximum
           value)
    else Ok value
  in
  match status_argument fields key with
  | None -> Ok default
  | Some (`Int value) -> validate value
  | Some (`Intlit literal) ->
      (match int_of_string_opt literal with
       | Some value -> validate value
       | None ->
           Error
             (Printf.sprintf
                "keeper_status argument %S is outside the supported integer range"
                key))
  | Some _ ->
      Error
        (Printf.sprintf "keeper_status argument %S must be an integer" key)

(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let effective_status_name_config ~(agent_name : string) fields =
  match
    status_argument fields Keeper_status_options_defaults.Argument.name
  with
  | None -> Ok (normalize_status_name agent_name)
  | Some (`String raw_name) ->
      (match normalize_status_name raw_name with
       | "" ->
           Error "keeper_status argument \"name\" must not be blank"
       | value -> Ok value)
  | Some _ ->
      Error "keeper_status argument \"name\" must be a string"

let tail_order_of_fields fields =
  match
    status_argument fields Keeper_status_options_defaults.Argument.tail_order
  with
  | None -> Ok Oldest_first
  | Some (`String raw_value) ->
      (match Keeper_status_options_defaults.tail_order_of_string raw_value with
       | Some order -> Ok order
       | None ->
           Error
             (Printf.sprintf
                "invalid tail_order %S (allowed: %s)"
                raw_value
                (String.concat
                   ", "
                   Keeper_status_options_defaults.valid_tail_order_strings)))
  | Some _ ->
      Error "keeper_status argument \"tail_order\" must be a string"

let tail_order_to_string = Keeper_status_options_defaults.tail_order_to_string
let valid_tail_order_strings = Keeper_status_options_defaults.valid_tail_order_strings

let status_options_of_fields fields =
  let ( let* ) = Result.bind in
  let* fast =
    optional_bool_argument
      fields
      Keeper_status_options_defaults.Argument.fast
      ~default:(keeper_status_fast_default ())
  in
  let* tail_order = tail_order_of_fields fields in
  let* tail_turns =
    optional_int_argument
      fields
      Keeper_status_options_defaults.Argument.tail_turns
      ~default:Keeper_status_options_defaults.tail_turns
      ~minimum:Keeper_status_options_defaults.min_tail_turns
      ~maximum:Keeper_status_options_defaults.max_tail_turns
  in
  let* tail_messages =
    optional_int_argument
      fields
      Keeper_status_options_defaults.Argument.tail_messages
      ~default:Keeper_status_options_defaults.tail_messages
      ~minimum:Keeper_status_options_defaults.min_tail_messages
      ~maximum:Keeper_status_options_defaults.max_tail_messages
  in
  let* tail_bytes =
    optional_int_argument
      fields
      Keeper_status_options_defaults.Argument.tail_bytes
      ~default:Keeper_status_options_defaults.tail_bytes
      ~minimum:Keeper_status_options_defaults.min_tail_bytes
      ~maximum:Keeper_status_options_defaults.max_tail_bytes
  in
  let* include_context =
    optional_bool_argument
      fields
      Keeper_status_options_defaults.Argument.include_context
      ~default:(not fast)
  in
  let* include_metrics_overview =
    optional_bool_argument
      fields
      Keeper_status_options_defaults.Argument.include_metrics_overview
      ~default:(not fast)
  in
  let* include_history_tail =
    optional_bool_argument
      fields
      Keeper_status_options_defaults.Argument.include_history_tail
      ~default:(not fast)
  in
  Ok
    { tail_turns
    ; tail_messages
    ; tail_bytes
    ; tail_order
    ; fast
    ; include_context
    ; include_metrics_overview
    ; include_history_tail
    }

let apply_tail_order order items =
  match order with
  | Oldest_first -> items
  | Newest_first -> List.rev items

(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
(* Existence, answered by the same candidate spellings and the same
   effective-meta read the status resolver uses — but as a typed bool, so
   callers stop deriving it by substring-matching "keeper not found" in a
   rendered status error (RFC-0371 B4). *)
let keeper_exists_config ~(config : Workspace.config) raw_name =
  let candidates =
    status_name_lookup_candidates raw_name |> List.filter validate_name
  in
  let rec loop = function
    | [] -> Ok false
    | candidate :: rest ->
        (match read_effective_meta_resolved config candidate with
         | Error e -> Error e
         | Ok (Some _) -> Ok true
         | Ok None -> loop rest)
  in
  loop candidates

let resolve_status_target_config ~(config : Workspace.config) ~(agent_name : string) fields =
  let ( let* ) = Result.bind in
  let* requested_name = effective_status_name_config ~agent_name fields in
  let candidates =
    status_name_lookup_candidates requested_name |> List.filter validate_name
  in
  if candidates = []
  then Error (invalid_name_error requested_name)
  else
    let rec loop = function
      | [] -> Error (Printf.sprintf "keeper not found: %s" requested_name)
      | candidate :: rest ->
          (match read_effective_meta_resolved config candidate with
           | Error e -> Error e
           | Ok (Some (resolved_name, meta)) -> Ok (resolved_name, meta)
           | Ok None -> loop rest)
    in
    loop candidates

let chat_operation_status_to_json ~base_path ~keeper_name =
  match Keeper_owner_registry.operation_projection ~base_path ~keeper_name with
  | Error error ->
    `Assoc
      [ "snapshot_available", `Bool false
      ; "read_error",
        `String (Keeper_owner_registry.lookup_error_to_string error)
      ]
  | Ok projection ->
    `Assoc
      [ "queued_count", `Int projection.queued_count
      ; ( "running_operation_id"
        , match projection.running_operation_id with
          | None -> `Null
          | Some operation_id ->
            `String
              (Keeper_chat_operation.Operation_id.to_string operation_id) )
      ; "terminal_count", `Int projection.terminal_count
      ; "snapshot_available", `Bool true
      ; "read_error", `Null
      ]
;;

let json_string_opt_member = Json_util.get_string_nonempty
let latest_metrics_json = Keeper_status_detail_observability.latest_metrics_json
let model_observability_json = Keeper_status_detail_observability.model_observability_json

(* TEL-OK: status handler — telemetry surfaces through Otel_metric_store
   counters in the downstream runtime and bridge calls. *)
let handle_keeper_status_config ~(config : Workspace.config) ~(agent_name : string) args : tool_result =
  match status_argument_fields args with
  | Error err -> tool_result_error ~class_:Tool_result.Policy_rejection err
  | Ok fields ->
      (match status_options_of_fields fields with
       | Error err -> tool_result_error ~class_:Tool_result.Policy_rejection err
       | Ok options ->
      (match resolve_status_target_config ~config ~agent_name fields with
       | Error err -> tool_result_error ~class_:Tool_result.Workflow_rejection err
       | Ok (name, m) ->
      let chat_operation_status =
        chat_operation_status_to_json
          ~base_path:config.base_path
          ~keeper_name:m.name
      in
      let
        { tail_turns
        ; tail_messages
        ; tail_bytes
        ; tail_order
        ; fast
        ; include_context
        ; include_metrics_overview
        ; include_history_tail
        }
        = options
      in
      let context_budget =
        let runtime_id = runtime_id_of_meta m in
        match
          Keeper_context_runtime.resolve_max_context_resolution_for_runtime_id
            ~requested_override:m.max_context_override
            ~runtime_id
        with
        | Ok max_context_resolution ->
            Keeper_context_runtime.context_budget_json_of_resolution
              ~runtime_id
              max_context_resolution
        | Error error ->
            `Assoc
              [ ( "runtime_id", `String runtime_id )
              ; ( "capacity_error"
                , `String
                    (Keeper_context_runtime.max_context_resolution_error_to_string
                       error) )
              ]
      in
      let base_dir = session_base_dir config in
         let ctx_opt =
           if include_context then
             let (_session, ctx_opt) =
               load_context_from_checkpoint
                 ~trace_id:(Keeper_id.Trace_id.to_string m.runtime.trace_id)
                 ~base_dir
             in
             ctx_opt
           else
             None
         in
         let ctx_stats =
           if not include_context then
             `Assoc [
               ("skipped", `Bool true);
               ("reason", `String "fast_or_disabled");
               ("has_checkpoint", `Null);
             ]
           else
             match ctx_opt with
             | None -> `Assoc [("has_checkpoint", `Bool false)]
             | Some c ->
               let checkpoint_bytes, byte_count_error =
                 match Keeper_post_turn.durable_checkpoint_bytes ~config ~meta:m with
                 | Ok bytes -> bytes, []
                 | Error detail -> None, [ ("checkpoint_bytes_error", `String detail) ]
               in
               `Assoc
                 ([ ("has_checkpoint", `Bool true);
                    ("checkpoint_bytes", Json_util.int_opt_to_json checkpoint_bytes);
                    ("message_count", `Int (Keeper_context_runtime.message_count c));
                  ]
                  @ byte_count_error)
         in
         let keepalive_running = runtime_keepalive_running config m in
         let now_ts = Time_compat.now () in
         let created_ts =
           Workspace_resilience.Time.parse_iso8601_opt m.created_at |> Option.value ~default:0.0
         in
         let keeper_age_s = Keeper_status_metrics.age_seconds_opt ~now_ts created_ts in
         let last_turn_ago_s =
           Keeper_status_metrics.age_seconds_opt ~now_ts m.runtime.usage.last_turn_ts
         in
         let last_handoff_ago_s =
           Keeper_status_metrics.age_seconds_opt ~now_ts m.runtime.last_handoff_ts
         in
         let last_proactive_ago_s =
           Keeper_status_metrics.age_seconds_opt ~now_ts m.runtime.proactive_rt.last_ts
         in
         let last_visible_proactive_ago_s =
           Keeper_status_metrics.age_seconds_opt ~now_ts m.runtime.proactive_rt.last_visible_ts
         in
         let trace_history_count = List.length m.runtime.trace_history in
         let runtime_runtime_metrics = `Null in
         let metrics_store = Keeper_types_support.keeper_metrics_store config m.name in
         let session_dir =
           Keeper_types_support.keeper_session_dir
             config
             (Keeper_id.Trace_id.to_string m.runtime.trace_id)
         in
         let history_path =
           Keeper_types_support.keeper_history_path
             config
             (Keeper_id.Trace_id.to_string m.runtime.trace_id)
         in
         let internal_history_path =
           Keeper_types_support.keeper_internal_history_path config
             (Keeper_id.Trace_id.to_string m.runtime.trace_id)
         in
         let metrics_tail =
           let lines =
             Dated_jsonl.read_recent_lines metrics_store tail_turns
           in
           let (parsed, _) =
             Fs_compat.parse_jsonl_lines ~source:"keeper_metrics" lines
           in
           let current =
             List.filter
               (fun json ->
                 Option.is_some
                   (Keeper_metrics_record.kind_of_json json))
               parsed
           in
           `List (apply_tail_order tail_order current)
         in
         let metrics_window_lines =
           if include_metrics_overview then
             let n = max tail_turns 200 in
             Dated_jsonl.read_recent_lines metrics_store n
           else
             []
         in
         let metrics_overview =
           if include_metrics_overview then
             summarize_metrics_lines metrics_window_lines
           else
             empty_metrics_summary
         in
         let history_filter_fragments =
           bool_default_true_of_env "MASC_KEEPER_HISTORY_FRAGMENT_FILTER"
         in
         let (history_tail, history_raw_count, history_fragment_count, history_fragment_filtered_count) =
           if not include_history_tail then
             (`List [], 0, 0, 0)
           else
             let lines =
               read_tail_lines_or_empty ~site:"keeper_status_detail_history"
                 history_path ~max_bytes:tail_bytes ~max_lines:tail_messages
             in
             let (items_rev, raw_count, fragment_count, filtered_count) =
               List.fold_left
                 (fun (acc, raw_count, fragment_count, filtered_count) line ->
                   try
                     let j = Yojson.Safe.from_string line in
                     let role = Safe_ops.json_string ~default:"unknown" "role" j in
                     (* History rows persist text as typed [content_blocks];
                        the flat "content" key is the pre-migration shape.
                        Reading only the flat key rendered every current
                        direct_user/direct_assistant row as "" in status
                        output. Same N-of-M reader class already fixed in
                        server_dashboard_http_keeper_api_types — use the same
                        SSOT extractor. *)
                     let content = Keeper_context_core.text_of_history_jsonl_json j in
                     let source = Safe_ops.json_string ~default:"unknown" "source" j in
                     let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
                     let age_s =
                       if ts_unix > 0.0 then Some (max 0.0 (now_ts -. ts_unix))
                       else None
                     in
                     let role_lc = String.lowercase_ascii role in
                     let is_internal =
                       Keeper_types_support.is_internal_history_source source
                     in
                     let entry_kind =
                       match source, role_lc with
                       | "direct_user", _ | "direct_assistant", _ ->
                           "direct_conversation"
                       | "world_state_prompt", _ -> "internal_prompt"
                       | "internal_assistant", _ -> "internal_reply"
                       | _, _ ->
                           (match role_lc with
                       | "assistant" -> "self_talk"
                       | "user" -> "input"
                       | "tool" -> "tool_result"
                       | "system" -> "system"
                       | _ -> "other")
                     in
                     let is_fragment =
                       role_lc = "assistant"
                       && looks_fragmentary_history_text content
                     in
                     let should_filter =
                       is_internal || (history_filter_fragments && is_fragment)
                     in
                     let preview =
                       if String.length content > 200 then
                         String_util.utf8_prefix ~max_bytes:200 content ^ "..."
                       else content
                     in
                     let item =
                       `Assoc [
                         ("role", `String role);
                         ("source", `String source);
                         ("kind", `String entry_kind);
                         ("is_fragment", `Bool is_fragment);
                         ("ts_unix", `Float ts_unix);
                         ("age_s", Json_util.float_opt_to_json age_s);
                         ("content", `String preview);
                       ]
                     in
                     let acc = if should_filter then acc else item :: acc in
                     let filtered_count =
                       filtered_count + if should_filter then 1 else 0
                     in
                     ( acc,
                       raw_count + 1,
                       fragment_count + (if is_fragment then 1 else 0),
                       filtered_count )
                   with Yojson.Json_error _ -> (acc, raw_count, fragment_count, filtered_count))
                 ([], 0, 0, 0) lines
             in
            ( `List (apply_tail_order tail_order (List.rev items_rev)),
              raw_count,
              fragment_count,
              filtered_count )
         in
        (* No tool call log for this keeper means no reading, not a reading of
           zero. The branch removed here answered "0 calls" whenever lifetime
           meta counters were non-zero, so a keeper that used a tool once and
           then had its log rotate away read as "0 calls" rather than as
           unmeasured. *)
        let tool_audit_snapshot =
          match latest_tool_audit_snapshot_from_files config ~keeper_name:m.name with
          | Some snapshot ->
              {
                snapshot with
                tool_audit_at =
                  (match snapshot.tool_audit_source, snapshot.tool_audit_at with
                   | Some _, None -> Some m.updated_at
                   | (Some _ | None), Some _ | None, None -> snapshot.tool_audit_at);
              }
          | None -> empty_tool_audit_snapshot
        in
         let keeper_last_error =
           match Keeper_registry.get ~base_path:config.base_path m.name with
           | Some entry -> entry.last_error
           | None -> None
         in
         let sandbox_live =
           Keeper_sandbox_control.live_status_json
             ~include_preflight:false
             ~include_repository_checkouts:false
             ~config:config ~meta:m
             ~timeout_sec:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ())
             ~verbose:false ()
         in
         let runtime_blocker_fields =
          runtime_blocker_fields_json config m
         in
         let attention_fields =
           attention_fields_json config m
         in
         let runtime_trust =
           Keeper_runtime_trust_snapshot.snapshot_json
             ~config:config ~meta:m
         in
         let latest_metrics =
           latest_metrics_json ~metrics_store
         in
         let model_observability =
           model_observability_json
             ~current_runtime_id:(runtime_id_of_meta m)
             ~runtime_blocker_fields
             ~runtime_trust
             latest_metrics
         in
         let attention_fields =
           attention_fields_with_runtime_trust attention_fields runtime_trust
         in
         let disposition =
           json_string_opt_member runtime_trust "disposition"
         in
         let disposition_reason =
           json_string_opt_member runtime_trust "disposition_reason"
         in
         let model_observability =
           match model_observability with
           | `Assoc fields ->
               `Assoc
                 (fields
                 @ [
                     ("disposition", Json_util.string_opt_to_json disposition);
                     ( "disposition_reason",
                       Json_util.string_opt_to_json disposition_reason );
                   ])
           | other -> other
         in
         let json = `Assoc ([
           ("name", `String name);
           ("meta", Keeper_meta_json.meta_to_json m);
           ("instructions",
            if String.trim m.instructions = "" then `Null else `String m.instructions);
           ("paused", `Bool m.paused);
           ("keepalive_running", `Bool keepalive_running);
           ("keeper_age_s", Json_util.float_opt_to_json keeper_age_s);
           ("last_turn_ago_s", Json_util.float_opt_to_json last_turn_ago_s);
           ("last_handoff_ago_s", Json_util.float_opt_to_json last_handoff_ago_s);
           ("last_proactive_ago_s", Json_util.float_opt_to_json last_proactive_ago_s);
           ("last_visible_proactive_ago_s", Json_util.float_opt_to_json last_visible_proactive_ago_s);
           ("active_model", `Null);
           ("disposition", Json_util.string_opt_to_json disposition);
           ("disposition_reason", Json_util.string_opt_to_json disposition_reason);
           ("next_model_hint", `Null);
           ("runtime_runtime_metrics", runtime_runtime_metrics);
           ("trace_history_count", `Int trace_history_count);
           ("handoff_count_total", `Int trace_history_count);
           ("sandbox_profile",
             `String (sandbox_profile_to_string m.sandbox_profile));
           ("network_mode",
             `String (network_mode_to_string m.network_mode));
           ("keeper_last_error",
             Json_util.string_opt_to_json keeper_last_error);
           ("sandbox_live", sandbox_live);
           ("latest_tool_names",
             Json_util.json_string_list tool_audit_snapshot.latest_tool_names);
           ("latest_tool_call_count",
             Json_util.int_opt_to_json tool_audit_snapshot.latest_tool_call_count);
           ("latest_action_source",
             Json_util.string_opt_to_json tool_audit_snapshot.latest_action_source);
           ("tool_audit_source",
             Json_util.string_opt_to_json tool_audit_snapshot.tool_audit_source);
           ("tool_audit_at",
             Json_util.string_opt_to_json tool_audit_snapshot.tool_audit_at);
           ("lifecycle", `Assoc [
             ("created_at", `String m.created_at);
             ("updated_at", `String m.updated_at);
             ( "uptime_hours"
             , Json_util.option_to_yojson
                 (fun age_s -> `Float (age_s /. Masc_time_constants.hour))
                 keeper_age_s );
           ]);
           ("proactive", `Assoc [
             ("enabled", `Bool m.proactive.enabled);
             ("count_total", `Int m.runtime.proactive_rt.count_total);
             ("visible_count_total", `Int m.runtime.proactive_rt.visible_count_total);
             ("last_ts", `Float m.runtime.proactive_rt.last_ts);
             ( "last_ago_s"
             , Json_util.float_opt_to_json last_proactive_ago_s );
             ("last_visible_ts", `Float m.runtime.proactive_rt.last_visible_ts);
             ( "last_visible_ago_s"
             , Json_util.float_opt_to_json last_visible_proactive_ago_s );
             ( "last_outcome"
             , `String
                 (proactive_cycle_outcome_to_string
                    m.runtime.proactive_rt.last_outcome) );
             ("last_reason",
               if String.trim m.runtime.proactive_rt.last_reason = ""
               then `Null
               else `String m.runtime.proactive_rt.last_reason);
             ("last_preview",
               if String.trim m.runtime.proactive_rt.last_preview = ""
               then `Null
               else `String m.runtime.proactive_rt.last_preview);
           ]);
           ("policy", `Assoc [
             ("sandbox_profile",
               `String (sandbox_profile_to_string m.sandbox_profile));
             ("network_mode",
               `String (network_mode_to_string m.network_mode));
           ]);
           ("auto_execution_session", auto_execution_session_surface_json ());
        ] @ runtime_blocker_fields @ attention_fields @ [
           ("status_options", `Assoc [
             ("tail_turns", `Int tail_turns);
             ("tail_messages", `Int tail_messages);
             ("tail_bytes", `Int tail_bytes);
             ("fast", `Bool fast);
             ("include_context", `Bool include_context);
             ("include_metrics_overview", `Bool include_metrics_overview);
             ("include_history_tail", `Bool include_history_tail);
             ("tail_order", `String (tail_order_to_string tail_order));
           ]);
           ("context_budget", context_budget);
           ("model_observability", model_observability);
           ("runtime_trust", runtime_trust);
           ("chat_operations", chat_operation_status);
           ("runtime", runtime_surface_json config m);
           ("workspace", workspace_surface_json m);
           ("sources", source_provenance_json config m);
           ("context", ctx_stats);
           ("metrics_overview", metrics_summary_to_json metrics_overview);
           ("metrics_tail", metrics_tail);
           ("history_tail", history_tail);
           ("history_tail_count",
             match history_tail with
             | `List xs -> `Int (List.length xs)
             | _ -> `Int 0);
           ("history_raw_count", `Int history_raw_count);
           ("history_fragment_count", `Int history_fragment_count);
           ("history_fragment_filtered_count", `Int history_fragment_filtered_count);
           ("history_fragment_filter_enabled", `Bool history_filter_fragments);
           ("storage_paths", `Assoc [
             ("meta", `String (keeper_meta_path config m.name));
             ("metrics", `String (Dated_jsonl.base_dir metrics_store));
           ( "decisions"
           , `String (Keeper_types_support.keeper_decision_log_path config m.name) );
             ( "feedback"
             , `String (Keeper_types_support.keeper_feedback_log_path config m.name) );
           ("session_dir", `String session_dir);
             ("history", `String history_path);
             ("history_internal", `String internal_history_path);
             ("evidence_dir", `String
               (Filename.concat
                 (Common.masc_dir_from_base_path ~base_path:config.base_path)
                 (Printf.sprintf "evidence/%s/%s"
                   (Workspace_utils.safe_filename m.name)
                   (Workspace_utils.safe_filename (Keeper_id.Trace_id.to_string m.runtime.trace_id)))));
           ]);
           (let sandbox = Keeper_sandbox.of_meta ~config:config ~meta:m in
           let playground_abs = sandbox.host_root_abs in
           (* #10650 + B1 follow-up: keeper-LLM-facing execution_context must
              not surface host paths.  For Docker keepers the host abs path
              does not exist inside the container, so the LLM previously
              echoed [cd <host_abs>] producing ~890/day [No such file or
              directory] errors.  default_cwd uses
              [keeper_visible_root_abs] (container path for Docker, host
              path for Local).  Host-only fields (sandbox_host_root,
              playground_path) are intentionally omitted — server-side
              file reads below still use [playground_abs] but never expose
              it through the JSON response. *)
           let keeper_visible_abs = Keeper_sandbox.keeper_visible_root_abs sandbox in
           "execution_context", `Assoc [
             ("sandbox_id", `String sandbox.sandbox_id);
             ("sandbox_backend", `String (Keeper_sandbox.backend_to_string sandbox.backend));
             ("sandbox_root", `String sandbox.root_arg);
             ("sandbox_container_root", Json_util.string_opt_to_json sandbox.container_root);
             ("default_cwd", `String keeper_visible_abs);
             ("sandbox_profile", `String (sandbox_profile_to_string m.sandbox_profile));
             ("network_mode", `String (network_mode_to_string m.network_mode));
             ("keeper_last_error",
               Json_util.string_opt_to_json keeper_last_error);
             ("sandbox_live", sandbox_live);
             ("repository_checkouts",
               Keeper_sandbox_control.repository_checkouts_json
                 ~config:config ~meta:m);
             ("pr_history",
               let pr_path = Filename.concat playground_abs
                 ".playground_pr_history.jsonl" in
               try
                 let entries = Fs_compat.load_jsonl pr_path in
                 (* Last 10 PRs, most recent first *)
                 `List (List.take 10 (List.rev entries))
               with Sys_error _ -> `List []);
           ]);
         ]) in
         tool_result_ok_data json))
(* TEL-OK: 1-line delegate to ctx-free body. *)