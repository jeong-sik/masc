(** Keeper_status_detail — single-keeper detailed status handler.
    Split from keeper_status.ml.

    Server-side response cache: keyed on (base_path, name, updated_at, args_hash).
    Avoids expensive JSONL parsing and checkpoint loading when keeper
    state has not changed between consecutive status polls. *)

open Tool_args
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

(* ── Response cache ──────────────────────────────────── *)

type cache_entry = {
  updated_at : string;
  args_hash : string;
  response : string;
}

let _cache : (string, cache_entry) Hashtbl.t = Hashtbl.create 8

type docker_preflight_status_cache_entry = {
  key : string;
  observed_at : float;
  value : Yojson.Safe.t option;
}

let docker_preflight_status_cache :
    docker_preflight_status_cache_entry option ref =
  ref None

let docker_preflight_status_cache_mu = Eio.Mutex.create ()
let docker_preflight_status_cache_ttl_sec = 60.0

(** Mutex protecting [_cache].  [handle_keeper_status] runs from an MCP
    tool-dispatch fiber, one per concurrent [masc_keeper_status]
    request, and [invalidate_status_cache_{for,all}] is called from
    keeper state-change paths on different fibers — so every access
    path competes for the same module-level [Hashtbl.t] with no
    serialisation.  The dangerous pair is [Hashtbl.filter_map_inplace]
    (eviction) interleaving with [Hashtbl.find_opt] / [Hashtbl.replace]
    from another fiber, which can segfault or return torn values: OCaml
    [Hashtbl] is explicitly unsafe for concurrent mutate-during-read. *)
let cache_mu = Eio.Mutex.create ()

let invalidate_status_cache_for name =
  Eio_guard.with_mutex cache_mu (fun () ->
    Hashtbl.filter_map_inplace
      (fun key entry ->
        match String.rindex_opt key ':' with
        | Some idx ->
            let cached_name =
              String.sub key (idx + 1) (String.length key - idx - 1)
            in
            if String.equal cached_name name then None else Some entry
        | None -> Some entry)
      _cache)

let invalidate_status_cache_all () =
  Eio_guard.with_mutex cache_mu (fun () ->
    Hashtbl.clear _cache);
  Eio_guard.with_mutex docker_preflight_status_cache_mu (fun () ->
    docker_preflight_status_cache := None)

let status_cache_key ~base_path ~name = base_path ^ ":" ^ name

let normalize_status_name = String.trim

let status_name_lookup_candidates raw_name =
  let trimmed = normalize_status_name raw_name in
  if String.equal trimmed "" then
    []
  else
    let aliases =
      match Keeper_identity.canonical_keeper_name trimmed with
      | Some candidate when not (String.equal candidate trimmed) -> [ candidate ]
      | Some _ | None -> []
    in
    trimmed :: aliases

let docker_preflight_status_cache_key ~timeout_sec =
  String.concat "|"
    [
      string_of_bool (Env_config_sandbox.Preflight.enabled ());
      Env_config_sandbox.Runtime.docker_image ();
      Env_config_sandbox.Hardening.seccomp_profile ();
      string_of_bool (Env_config_sandbox.Hardening.require_rootless ());
      string_of_bool (Env_config_sandbox.Hardening.require_userns ());
      string_of_bool
        (Env_config_sandbox.Runtime.git_dispatch ());
      Printf.sprintf "%.3f" timeout_sec;
    ]

let cached_docker_preflight_status_json ~timeout_sec =
  if not (Env_config_sandbox.Preflight.enabled ()) then
    None
  else
    let key = docker_preflight_status_cache_key ~timeout_sec in
    Eio_guard.with_mutex docker_preflight_status_cache_mu (fun () ->
      let now = Time_compat.now () in
      match !docker_preflight_status_cache with
      | Some entry
        when String.equal entry.key key
             && now -. entry.observed_at < docker_preflight_status_cache_ttl_sec ->
          entry.value
      | _ ->
          let value = Keeper_sandbox_control.preflight_status_json ~timeout_sec in
          docker_preflight_status_cache := Some { key; observed_at = now; value };
          value)

(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let effective_status_name_config ~(agent_name : string) args =
  match normalize_status_name (get_string args "name" "") with
  | "" -> normalize_status_name agent_name
  | value -> value

let effective_status_name (ctx : _ context) args =
  effective_status_name_config ~agent_name:ctx.agent_name args

type tail_order =
  | Oldest_first
  | Newest_first

let tail_order_of_args args =
  match String.lowercase_ascii (String.trim (get_string args "tail_order" "")) with
  | "newest_first" | "newest" | "latest_first" | "desc" ->
      Newest_first
  | _ ->
      Oldest_first

let tail_order_to_string = function
  | Oldest_first -> "oldest_first"
  | Newest_first -> "newest_first"

(* Issue #8486: Variant SSOT for [tail_order]. Adding a constructor
   forces [tail_order_to_string] exhaustiveness AND extends
   [valid_tail_order_strings]; the schema in [Keeper_schema] mirrors
   this list (cycle-avoidance: Keeper_schema -> Keeper_types ->
   Keeper_types_profile -> Keeper_schema, same shape as #8467). *)
let all_tail_orders = [ Oldest_first; Newest_first ]
let valid_tail_order_strings =
  List.map tail_order_to_string all_tail_orders

let apply_tail_order order items =
  match order with
  | Oldest_first -> items
  | Newest_first -> List.rev items

(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let resolve_status_target_config ~(config : Workspace.config) ~(agent_name : string) args =
  let requested_name = effective_status_name_config ~agent_name args in
  let candidates =
    status_name_lookup_candidates requested_name
    |> List.filter validate_name
  in
  if candidates = [] then
    Error
      (Printf.sprintf
         "invalid keeper name %S (must be non-empty and match \
          [A-Za-z0-9._-]+; see Keeper_config.validate_name)"
         requested_name)
  else
    let rec loop = function
      | [] -> Error (Printf.sprintf "keeper not found: %s" requested_name)
      | candidate :: rest -> (
          match read_effective_meta_resolved config candidate with
          | Error e -> Error e
          | Ok (Some (resolved_name, meta)) -> Ok (resolved_name, meta)
          | Ok None -> loop rest)
    in
    loop candidates

let resolve_status_target (ctx : _ context) args =
  resolve_status_target_config ~config:ctx.config ~agent_name:ctx.agent_name args

(** Hash the status-affecting args and the profile-overlay fields so different
    parameter combos (e.g. fast=true vs fast=false) and TOML/persona overlays
    get separate cache entries. Persisted JSON writes update [updated_at], but
    external [keepers/<name>.toml] edits do not. *)
let cache_fingerprint_field (key, value) =
  Printf.sprintf "%s=%d:%s" key (String.length value) value

let cache_fingerprint_list values = String.concat "\x1f" values

let cache_fingerprint_pairs pairs =
  pairs
  |> List.map (fun (key, value) ->
       key ^ "\x1e" ^ string_of_int (String.length value) ^ "\x1e" ^ value)
  |> String.concat "\x1f"

let effective_meta_overlay_hash (meta : keeper_meta) =
  let opt_string = function
    | Some value -> value
    | None -> ""
  in
  let opt_bool = function
    | Some true -> "true"
    | Some false -> "false"
    | None -> ""
  in
  let opt_int = Option.fold ~none:"" ~some:string_of_int in
  let fields =
    [
      ("goal", meta.goal);
      ("sandbox_profile", sandbox_profile_to_string meta.sandbox_profile);
      ("sandbox_image", opt_string meta.sandbox_image);
      ("network_mode", network_mode_to_string meta.network_mode);
      ("allowed_paths", cache_fingerprint_list meta.allowed_paths);
      ("tool_access", cache_fingerprint_list meta.tool_access);
      ("tool_denylist", cache_fingerprint_list meta.tool_denylist);
      ("mention_targets", cache_fingerprint_list meta.mention_targets);
      ("active_goal_ids", cache_fingerprint_list meta.active_goal_ids);
      ("proactive_enabled", string_of_bool meta.proactive.enabled);
      ("proactive_idle_sec", string_of_int meta.proactive.idle_sec);
      ("proactive_cooldown_sec", string_of_int meta.proactive.cooldown_sec);
      ("autoboot_enabled", string_of_bool meta.autoboot_enabled);
      ("telemetry_feedback_enabled", opt_bool meta.telemetry_feedback_enabled);
      ( "telemetry_feedback_window_hours",
        opt_int meta.telemetry_feedback_window_hours );
      ("always_approve", opt_bool meta.always_approve);
      ("oas_env", cache_fingerprint_pairs meta.oas_env);
    ]
  in
  fields
  |> List.map cache_fingerprint_field
  |> String.concat "\n"
  |> Digest.string
  |> Digest.to_hex

let hash_status_args _config resolved_name (meta : keeper_meta) args =
  let parts = [
    resolved_name;
    effective_meta_overlay_hash meta;
    (* Keeper_manual_reconcile.cache_key removed with reconcile system. *)
    string_of_bool (get_bool args "fast" false);
    string_of_bool (get_bool args "include_context" false);
    string_of_bool (get_bool args "include_metrics_overview" false);
    string_of_bool (get_bool args "include_memory_bank" false);
    string_of_bool (get_bool args "include_history_tail" false);
    string_of_bool (get_bool args "include_compaction_history" false);
    string_of_int (get_int args "tail_turns" 3);
    string_of_int (get_int args "tail_messages" 5);
    tail_order_to_string (tail_order_of_args args);
  ] in
  Digest.string (String.concat "|" parts) |> Digest.to_hex

let nonempty_trimmed = Keeper_status_detail_observability.nonempty_trimmed
let json_string_opt_member = Json_util.get_string_nonempty
let latest_metrics_json = Keeper_status_detail_observability.latest_metrics_json
let model_observability_json = Keeper_status_detail_observability.model_observability_json

(* TEL-OK: status handler — telemetry surfaces via the cache layer
   ([_cache] mutex-protected reads/writes) and Otel_metric_store counters in
   the downstream [Keeper_status_runtime]/[Keeper_status_bridge] calls. *)
let handle_keeper_status_config ~(config : Workspace.config) ~(agent_name : string) args : tool_result =
  match resolve_status_target_config ~config ~agent_name args with
  | Error err -> tool_result_error err
  | Ok (name, m) ->
      let cache_key = status_cache_key ~base_path:config.base_path ~name in
      let args_hash = hash_status_args config name m args in
      (* Cache hit: same updated_at + same args/effective-meta hash → return cached response.
         The read is taken under [cache_mu] so it cannot interleave with
         an eviction from [invalidate_status_cache_{for,all}]. *)
      (match
         Eio_guard.with_mutex_ro cache_mu (fun () ->
           Hashtbl.find_opt _cache cache_key)
       with
       | Some entry
         when entry.updated_at = m.updated_at
           && entry.args_hash = args_hash ->
         tool_result_ok entry.response
       | _ ->
      let tail_turns = max 0 (get_int args "tail_turns" 3) in
      let tail_messages = max 0 (get_int args "tail_messages" 5) in
      let tail_compactions = max 0 (get_int args "tail_compactions" 10) in
      let tail_bytes = max 1_000 (get_int args "tail_bytes" 60_000) in
      let fast = get_bool args "fast" (keeper_status_fast_default ()) in
      let tail_order = tail_order_of_args args in
      let include_context = get_bool args "include_context" (not fast) in
      let include_metrics_overview =
        get_bool args "include_metrics_overview" (not fast)
      in
      let include_memory_bank = get_bool args "include_memory_bank" (not fast) in
      let include_history_tail = get_bool args "include_history_tail" (not fast) in
      let include_compaction_history =
        get_bool args "include_compaction_history" (not fast)
      in
      let max_context_resolution =
        Keeper_context_runtime.resolve_max_context_resolution_of_meta m
      in
      let primary_max_context = max_context_resolution.effective_budget in
      let context_budget =
        Keeper_context_runtime.context_budget_json_of_resolution
          ~runtime_id:(runtime_id_of_meta m)
          max_context_resolution
      in
      let base_dir = session_base_dir config in
         let ctx_opt =
           if include_context then
             let (_session, ctx_opt) =
               load_context_from_checkpoint
                 ~max_checkpoint_messages:m.compaction.max_checkpoint_messages
                 ~trace_id:(Keeper_id.Trace_id.to_string m.runtime.trace_id)
                 ~primary_model_max_tokens:primary_max_context
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
               `Assoc [
                 ("has_checkpoint", `Bool true);
                 ("context_ratio", `Float (Keeper_context_runtime.context_ratio c));
                 ("context_tokens", `Int (Keeper_context_runtime.token_count c));
                 ("context_max", `Int (Keeper_context_runtime.max_tokens_of_context c));
                 ("message_count", `Int (Keeper_context_runtime.message_count c));
               ]
         in
         let keepalive_running = runtime_keepalive_running config m in
         let agent_status = parse_agent_status config ~agent_name:m.agent_name in
         let now_ts = Time_compat.now () in
         let created_ts =
           Workspace_resilience.Time.parse_iso8601_opt m.created_at |> Option.value ~default:0.0
         in
         let keeper_age_s = if created_ts <= 0.0 then 0.0 else now_ts -. created_ts in
         let last_turn_ago_s = if m.runtime.usage.last_turn_ts <= 0.0 then 0.0 else now_ts -. m.runtime.usage.last_turn_ts in
         let last_handoff_ago_s = if m.runtime.last_handoff_ts <= 0.0 then 0.0 else now_ts -. m.runtime.last_handoff_ts in
         let last_compaction_ago_s = if m.runtime.compaction_rt.last_ts <= 0.0 then 0.0 else now_ts -. m.runtime.compaction_rt.last_ts in
         let last_proactive_ago_s =
           if m.runtime.proactive_rt.last_ts <= 0.0 then 0.0 else now_ts -. m.runtime.proactive_rt.last_ts
         in
         let last_visible_proactive_ago_s =
           if m.runtime.proactive_rt.last_visible_ts <= 0.0 then 0.0
           else now_ts -. m.runtime.proactive_rt.last_visible_ts
         in
         let trace_history_count = List.length m.runtime.trace_history in
         let runtime_runtime_metrics = `Null in
         let last_compaction_saved_tokens =
           max 0 (m.runtime.compaction_rt.last_before_tokens - m.runtime.compaction_rt.last_after_tokens)
         in
         let (compact_ratio_gate, compact_message_gate, compact_token_gate) =
           compaction_policy_of_keeper m
         in

         let metrics_store = Keeper_types_support.keeper_metrics_store config m.name in
         let metrics_path = Keeper_types_support.keeper_metrics_path config m.name in
         let memory_bank_path =
           Keeper_types_support.keeper_memory_bank_path config m.name
         in
         let generation_index_path =
           Keeper_types_support.keeper_generation_index_path config m.name
         in
         let session_dir =
           Keeper_types_support.keeper_session_dir
             config
             (Keeper_id.Trace_id.to_string m.runtime.trace_id)
         in
         let generation_manifest_path =
           Keeper_types_support.keeper_generation_manifest_path config
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
         let generation_lineage =
           Keeper_generation_lineage.surface_json config m ~recent_limit:6
         in

         let metrics_tail =
           let lines =
             let dated = Dated_jsonl.read_recent_lines metrics_store tail_turns in
             if dated <> [] then dated
             else
               read_tail_lines_or_empty ~site:"keeper_status_detail_metrics_tail"
                 metrics_path ~max_bytes:tail_bytes ~max_lines:tail_turns
           in
           let (parsed, _) =
             Fs_compat.parse_jsonl_lines ~source:"keeper_metrics" lines
           in
           `List (apply_tail_order tail_order parsed)
         in
         let metrics_window_lines =
           if include_metrics_overview then
             let n = max tail_turns 200 in
             let dated = Dated_jsonl.read_recent_lines metrics_store n in
             if dated <> [] then dated
             else
               read_tail_lines_or_empty ~site:"keeper_status_detail_metrics_window"
                 metrics_path ~max_bytes:tail_bytes ~max_lines:n
           else
             []
         in
         let metrics_overview =
           if include_metrics_overview then
             summarize_metrics_lines
               metrics_window_lines
               ~default_generation:m.runtime.generation
           else
             empty_metrics_summary
         in
         let last_skill_route =
           if not include_metrics_overview then
             None
           else
             let rec find_latest = function
               | [] -> None
               | line :: tl ->
                 (try
                    let j = Yojson.Safe.from_string line in
                    match Safe_ops.json_string_opt "skill_primary" j with
                    | Some primary when String.trim primary <> "" ->
                      let secondary =
                        match Json_util.assoc_member_opt "skill_secondary" j with
                        | Some (`List xs) ->
                          xs
                          |> List.filter_map (fun v ->
                               match v with
                               | `String s when String.trim s <> "" -> Some s
                               | _ -> None)
                        | None | Some _ -> []
                      in
                      let reason = Safe_ops.json_string_opt "skill_reason" j in
                      Some
                        (`Assoc
                           [
                             ("primary", `String primary);
                             ( "secondary",
                               `List (List.map (fun s -> `String s) secondary) );
                             ( "reason",
                               Json_util.string_opt_to_json reason );
                           ])
                    | _ -> find_latest tl
                  with Yojson.Json_error _ -> find_latest tl)
             in
             find_latest (List.rev metrics_window_lines)
         in
         (* RFC-0149 §3.1 — typed Result resolver.  The companion
            [memory_bank_error_class] travels alongside the summary so
            the dashboard detail surface can distinguish an empty
            memory bank ([Ok summary], no recent rows) from an IO
            fault ([Error class]) instead of collapsing both into the
            same empty-shape record via the legacy silent fallback. *)
         let empty_memory_bank_summary
           : Keeper_memory_policy.keeper_memory_summary
           =
           { total_notes = 0
           ; last_ts_unix = 0.0
           ; top_kind = None
           ; kind_counts = []
           ; recent_notes = []
           }
         in
         let memory_bank_summary, memory_bank_error_class =
           if include_memory_bank then
             match
               read_keeper_memory_summary_result
                 config
                 ~name:m.name
                 ~max_bytes:tail_bytes
                 ~max_lines:(max (tail_turns * 10) 400)
                 ~recent_limit:8
             with
             | Ok summary ->
               let summary =
                 { summary with
                   recent_notes =
                     apply_tail_order tail_order summary.recent_notes
                 }
               in
               summary, None
             | Error exn_class ->
               ( empty_memory_bank_summary
               , Some (Keeper_memory_recall_exn_class.to_label exn_class) )
           else
             empty_memory_bank_summary, None
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
                     let content = Safe_ops.json_string ~default:"" "content" j in
                     let source = Safe_ops.json_string ~default:"unknown" "source" j in
                     let ts_unix =
                       let ts0 = Safe_ops.json_float ~default:0.0 "ts_unix" j in
                       if ts0 > 0.0 then ts0
                       else Safe_ops.json_float ~default:0.0 "timestamp" j
                     in
                     let age_s =
                       if ts_unix > 0.0 then Some (max 0.0 (now_ts -. ts_unix))
                       else None
                     in
                     let role_lc = String.lowercase_ascii role in
                     let is_internal =
                       ignore content;
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
         let compaction_history_tail =
           if not include_compaction_history then
             (`List [], 0)
           else
             let n = max 200 (tail_compactions * 20) in
             let lines =
               let dated = Dated_jsonl.read_recent_lines metrics_store n in
               if dated <> [] then dated
               else
                 read_tail_lines_or_empty
                   ~site:"keeper_status_detail_compaction_history" metrics_path
                   ~max_bytes:tail_bytes ~max_lines:n
             in
             let events_rev =
               List.fold_left
                 (fun acc line ->
                   try
                     let j = Yojson.Safe.from_string line in
                     let compacted = Safe_ops.json_bool ~default:false "compacted" j in
                     let memory_compaction_performed =
                       Safe_ops.json_bool ~default:false "memory_compaction_performed" j
                     in
                     if (not compacted) && (not memory_compaction_performed) then acc
                     else
                       let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
                       let age_s =
                         if ts_unix > 0.0 then Some (max 0.0 (now_ts -. ts_unix)) else None
                       in
                       let before_tokens = Safe_ops.json_int ~default:0 "compaction_before_tokens" j in
                       let after_tokens = Safe_ops.json_int ~default:0 "compaction_after_tokens" j in
                       let saved_tokens = max 0 (before_tokens - after_tokens) in
                       let memory_before_notes =
                         Safe_ops.json_int ~default:0 "memory_compaction_before_notes" j
                       in
                       let memory_after_notes =
                         Safe_ops.json_int ~default:0 "memory_compaction_after_notes" j
                       in
                       let memory_dropped_notes =
                         Safe_ops.json_int ~default:0 "memory_compaction_dropped_notes" j
                       in
                       let memory_invalid_dropped =
                         Safe_ops.json_int ~default:0 "memory_compaction_invalid_dropped" j
                       in
                       let event_kind =
                         if compacted && memory_compaction_performed then "context+memory"
                         else if compacted then "context"
                         else "memory"
                       in
                       let item =
                         `Assoc [
                           ("kind", `String event_kind);
                           ("channel", `String (Safe_ops.json_string ~default:"turn" "channel" j));
                           ("ts_unix", `Float ts_unix);
                           ("age_s", Json_util.float_opt_to_json age_s);
                           ("trace_id", `String (Safe_ops.json_string ~default:"" "trace_id" j));
                           ("generation", `Int (Safe_ops.json_int ~default:m.runtime.generation "generation" j));
                           ("context_ratio", `Float (Safe_ops.json_float ~default:0.0 "context_ratio" j));
                           ("context_before_tokens", `Int before_tokens);
                           ("context_after_tokens", `Int after_tokens);
                           ("context_saved_tokens", `Int saved_tokens);
                           ( "context_trigger",
                             match Safe_ops.json_string_opt "compaction_trigger" j with
                             | Some reason when String.trim reason <> "" -> `String reason
                             | _ -> `Null );
                           ("memory_compaction_performed", `Bool memory_compaction_performed);
                           ("memory_before_notes", `Int memory_before_notes);
                           ("memory_after_notes", `Int memory_after_notes);
                           ("memory_dropped_notes", `Int memory_dropped_notes);
                           ("memory_invalid_dropped", `Int memory_invalid_dropped);
                           ( "memory_reason",
                             match Safe_ops.json_string_opt "memory_compaction_reason" j with
                             | Some reason when String.trim reason <> "" -> `String reason
                             | _ -> `Null );
                         ]
                       in
                       item :: acc
                   with Yojson.Json_error _ -> acc)
                 [] lines
             in
             let events = List.rev events_rev in
             let total = List.length events in
             let start = max 0 (total - tail_compactions) in
             let tail = List.filteri (fun i _ -> i >= start) events in
             (`List (apply_tail_order tail_order tail), total)
        in
        let allowed_tools = keeper_allowed_tool_names m in
        let last_autonomous = String.trim m.runtime.last_autonomous_action_at in
        let tool_audit_snapshot =
          match latest_tool_audit_snapshot_from_files config ~keeper_name:m.name with
          | Some snapshot ->
              {
                snapshot with
                tool_audit_at =
                  (match snapshot.tool_audit_source, snapshot.tool_audit_at with
                   | Some _, None when last_autonomous <> "" -> Some last_autonomous
                   | Some _, None -> Some m.updated_at
                   | _ -> snapshot.tool_audit_at);
              }
          | None ->
              let has_runtime_activity =
                last_autonomous <> ""
                || m.runtime.autonomous_turn_count > 0
                || m.runtime.autonomous_action_count > 0
              in
              {
                empty_tool_audit_snapshot with
                latest_tool_call_count =
                  (if has_runtime_activity then Some 0 else None);
                latest_action_source = None;
                tool_audit_source =
                  (if has_runtime_activity then Some "keeper_runtime_meta" else None);
                tool_audit_at =
                  (if last_autonomous <> "" then Some last_autonomous
                   else if has_runtime_activity then Some m.updated_at
                   else None);
              }
        in
         let sandbox_last_error =
           match Keeper_registry.get ~base_path:config.base_path m.name with
           | Some entry -> entry.last_error
           | None -> None
         in
         let sandbox_live =
           Keeper_sandbox_control.live_status_json
             ~include_preflight:false
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
           latest_metrics_json ~metrics_store ~metrics_path ~tail_bytes
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
         let chat_queue =
           (* [Keeper_chat_queue.length] reads behind a raw [Eio.Mutex], which
              performs effects and raises [Effect.Unhandled] when no Eio scheduler
              is running.  Production dispatch runs under [Eio_main.run] with
              [Eio_guard.enable ()] (bin/main_eio.ml, bin/main_stdio_eio.ml,
              bin/masc_worker_run.ml), so the depth is read there.  Pre-Eio /
              non-Eio init paths (and unit tests that do not enable the guard)
              report [`Null] instead of probing the scheduler via a side-effecting
              [Eio.Fiber.yield] + [Effect.Unhandled] catch. *)
           let pending_messages =
             if Eio_guard.is_ready ()
             then `Int (Keeper_chat_queue.length ~keeper_name:m.name)
             else `Null
           in
           `Assoc
             [
               ("pending_messages", pending_messages);
               ("durable_replay_enabled", `Bool (Keeper_chat_queue.persistence_configured ()));
             ]
         in

         let json = `Assoc ([
           ("name", `String name);
           ("meta", Keeper_meta_json.meta_to_json m);
           ("goal", `String m.goal);
           ( "persona",
             match m.persona with
             | Some persona when String.trim persona <> "" -> `String persona
             | _ -> `Null );
           ("instructions",
            if String.trim m.instructions = "" then `Null else `String m.instructions);
           ("self_model", `Assoc [
             ( "persona",
               match m.persona with
               | Some persona when String.trim persona <> "" -> `String persona
               | _ -> `Null );
             ("instructions",
              if String.trim m.instructions = "" then `Null else `String m.instructions);
           ]);
           ("paused", `Bool m.paused);
           ("keepalive_running", `Bool keepalive_running);
           ("agent", agent_status);
           ("keeper_age_s", `Float keeper_age_s);
           ("last_turn_ago_s", `Float last_turn_ago_s);
           ("last_handoff_ago_s", `Float last_handoff_ago_s);
           ("last_compaction_ago_s", `Float last_compaction_ago_s);
           ("last_proactive_ago_s", `Float last_proactive_ago_s);
           ("last_visible_proactive_ago_s", `Float last_visible_proactive_ago_s);
           ("active_model", `Null);
           ("disposition", Json_util.string_opt_to_json disposition);
           ("disposition_reason", Json_util.string_opt_to_json disposition_reason);
           ("next_model_hint", `Null);
           ("runtime_runtime_metrics", runtime_runtime_metrics);
           ("trace_history_count", `Int trace_history_count);
           ("handoff_count_total", `Int trace_history_count);
           ("last_compaction_saved_tokens", `Int last_compaction_saved_tokens);
           ("sandbox_profile",
             `String (sandbox_profile_to_string m.sandbox_profile));
           ("network_mode",
             `String (network_mode_to_string m.network_mode));
           ("sandbox_last_error",
             Json_util.string_opt_to_json sandbox_last_error);
           ("sandbox_live", sandbox_live);
           ("tool_denylist", Json_util.json_string_list m.tool_denylist);
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
             ("uptime_hours", `Float (keeper_age_s /. Masc_time_constants.hour));
           ]);
           ("proactive", `Assoc [
             ("enabled", `Bool m.proactive.enabled);
             ("idle_sec", `Int m.proactive.idle_sec);
             ("cooldown_sec", `Int m.proactive.cooldown_sec);
             ("count_total", `Int m.runtime.proactive_rt.count_total);
             ("visible_count_total", `Int m.runtime.proactive_rt.visible_count_total);
             ("last_ts", `Float m.runtime.proactive_rt.last_ts);
             ("last_ago_s", `Float last_proactive_ago_s);
             ("last_visible_ts", `Float m.runtime.proactive_rt.last_visible_ts);
             ("last_visible_ago_s", `Float last_visible_proactive_ago_s);
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
           ("drift",
             let toml_defaults =
               Keeper_types_profile.load_keeper_profile_defaults name
             in
             drift_surface_json
               ~unknown_toml_keys:toml_defaults.unknown_toml_keys);
           ("policy", `Assoc [
             ("voice_tools_available", `Bool (List.mem "keeper_voice_speak" allowed_tools));
             ("sandbox_profile",
               `String (sandbox_profile_to_string m.sandbox_profile));
             ("network_mode",
               `String (network_mode_to_string m.network_mode));
             ("allowed_paths", Json_util.json_string_list m.allowed_paths);
           ]);
           ("auto_execution_session", auto_execution_session_surface_json ());
           ("auto_execution_session_enabled", `Bool false);
           ("autonomy", `Assoc [
             ("turn_count", `Int m.runtime.autonomous_turn_count);
             ("tool_turn_count", `Int m.runtime.autonomous_tool_turn_count);
             ("text_turn_count", `Int m.runtime.autonomous_text_turn_count);
             ("board_reactive_turn_count", `Int m.runtime.board_reactive_turn_count);
             ("mention_reactive_turn_count", `Int m.runtime.mention_reactive_turn_count);
             ("noop_turn_count", `Int m.runtime.noop_turn_count);
             ("tool_action_count", `Int m.runtime.autonomous_action_count);
           ]);
        ] @ runtime_blocker_fields @ attention_fields @ [
           ("compaction_policy", `Assoc [
             ("profile", `String m.compaction.profile);
             ("ratio_gate", `Float compact_ratio_gate);
             ("message_gate", `Int compact_message_gate);
             ("token_gate", `Int compact_token_gate);
             ("token_gate_enabled", `Bool (compact_token_gate > 0));
           ]);
           ("status_options", `Assoc [
             ("fast", `Bool fast);
             ("include_context", `Bool include_context);
             ("include_metrics_overview", `Bool include_metrics_overview);
             ("include_memory_bank", `Bool include_memory_bank);
             ("include_history_tail", `Bool include_history_tail);
             ("include_compaction_history", `Bool include_compaction_history);
             ("tail_order", `String (tail_order_to_string tail_order));
           ]);
           ("context_budget", context_budget);
           ("model_observability", model_observability);
           ("runtime_trust", runtime_trust);
           ("chat_queue", chat_queue);
           ("runtime", runtime_surface_json config m);
           ("workspace", workspace_surface_json m);
           ("sources", source_provenance_json config m);
           ("context", ctx_stats);
           ("skill_route", Json_util.option_to_yojson Fun.id last_skill_route);
           ("metrics_overview", metrics_summary_to_json metrics_overview);
           ("memory_bank", memory_summary_to_json memory_bank_summary);
           ("memory_bank_error_class",
             Json_util.string_opt_to_json memory_bank_error_class);
           ("generation_lineage", generation_lineage);
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
           ("compaction_history_tail", fst compaction_history_tail);
           ("compaction_history_count", `Int (snd compaction_history_tail));
           ("storage_paths", `Assoc [
             ("meta", `String (keeper_meta_path config m.name));
             ("metrics", `String (Dated_jsonl.base_dir metrics_store));
             ("metrics_single_file", `String metrics_path);
           ("memory_bank", `String memory_bank_path);
           ("generation_index", `String generation_index_path);
           ( "decisions"
           , `String (Keeper_types_support.keeper_decision_log_path config m.name) );
           ( "policy"
             , `String (Keeper_types_support.keeper_policy_log_path config m.name) );
             ( "feedback"
             , `String (Keeper_types_support.keeper_feedback_log_path config m.name) );
           ( "dataset_export"
           , `String
               (Keeper_types_support.keeper_dataset_export_path config m.name)
           );
           ("session_dir", `String session_dir);
             ("generation_manifest", `String generation_manifest_path);
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
             ("sandbox_repos", `String sandbox.repos_arg);
             ("sandbox_mind", `String sandbox.mind_arg);
             ("sandbox_container_root", Json_util.string_opt_to_json sandbox.container_root);
             ("default_cwd", `String keeper_visible_abs);
             ("sandbox_profile", `String (sandbox_profile_to_string m.sandbox_profile));
             ("network_mode", `String (network_mode_to_string m.network_mode));
             ("sandbox_last_error",
               Json_util.string_opt_to_json sandbox_last_error);
             ("sandbox_live", sandbox_live);
             ("allowed_paths", Json_util.json_string_list m.allowed_paths);
             ("playground_repos",
               Keeper_sandbox_control.playground_repos_json
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
         let response = Yojson.Safe.pretty_to_string json in
         Eio_guard.with_mutex cache_mu (fun () ->
           Hashtbl.replace _cache cache_key
             { updated_at = m.updated_at; args_hash; response });
         tool_result_ok response)
(* TEL-OK: 1-line delegate to ctx-free body. *)
let handle_keeper_status (ctx : _ context) args = handle_keeper_status_config ~config:ctx.config ~agent_name:ctx.agent_name args
