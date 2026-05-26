(** Tests for Keeper_tool_alias.

    RFC-0064: two-surface routing table. Public names (Execute, ReadFile, …)
    map to internal handler names (tool_execute, tool_read_file, …)
    via a single [route] type. No reverse lookup or tier classification. *)

module Alias = Masc_mcp.Keeper_tool_alias
module Descriptor = Masc_mcp.Agent_tool_descriptor
module Descriptor_resolution = Masc_mcp.Agent_tool_descriptor_resolution
module Observation = Masc_mcp.Keeper_tool_observation
module Receipt = Masc_mcp.Keeper_execution_receipt
module Resolution = Masc_mcp.Keeper_tool_resolution
module Runtime = Masc_mcp.Agent_tool_runtime

let route_internal name =
  match Alias.route name with
  | Some r -> Some r.internal_name
  | None -> None
;;

let test_known_aliases_resolve () =
  Alcotest.(check (option string))
    "Execute -> tool_execute"
    (Some "tool_execute")
    (route_internal "Execute");
  Alcotest.(check (option string))
    "ReadFile -> tool_read_file"
    (Some "tool_read_file")
    (route_internal "ReadFile");
  Alcotest.(check (option string))
    "EditFile -> tool_edit_file"
    (Some "tool_edit_file")
    (route_internal "EditFile");
  Alcotest.(check (option string))
    "WriteFile -> tool_write_file"
    (Some "tool_write_file")
    (route_internal "WriteFile");
  Alcotest.(check (option string))
    "SearchFiles -> tool_search_files"
    (Some "tool_search_files")
    (route_internal "SearchFiles");
  Alcotest.(check (option string))
    "SearchWeb -> masc_web_search"
    (Some "masc_web_search")
    (route_internal "SearchWeb")
;;

let test_internal_names_resolve_to_preferred_public_alias () =
  Alcotest.(check (option string))
    "tool_execute -> Execute"
    (Some "Execute")
    (Alias.public_name_for_internal "tool_execute");
  Alcotest.(check (option string))
    "tool_search_files -> SearchFiles"
    (Some "SearchFiles")
    (Alias.public_name_for_internal "tool_search_files");
  Alcotest.(check (option string))
    "tool_edit_file primary public alias is EditFile"
    (Some "EditFile")
    (Alias.public_name_for_internal "tool_edit_file");
  Alcotest.(check (option string))
    "unaliased internal has no public alias"
    None
    (Alias.public_name_for_internal "keeper_board_post")
;;

let test_unknown_returns_none () =
  Alcotest.(check (option string)) "Skill has no cognate" None (route_internal "Skill");
  Alcotest.(check (option string))
    "tool_execute is internal, not public"
    None
    (route_internal "tool_execute");
  Alcotest.(check (option string)) "empty string" None (route_internal "");
  Alcotest.(check (option string)) "case sensitive" None (route_internal "bash")
;;

let test_route_round_trip () =
  (* Every public name must resolve to a non-empty internal handler. *)
  List.iter
    (fun public ->
       match Alias.route public with
       | Some r ->
         Alcotest.(check bool)
           (Printf.sprintf "%s resolves to non-empty internal_name" public)
           true
           (r.internal_name <> "")
       | None ->
         Alcotest.fail (Printf.sprintf "%s should have a route but got None" public))
    (Alias.public_names ());
  (* EditFile and WriteFile now route to distinct descriptor-owned handlers. *)
  Alcotest.(check (option string))
    "EditFile -> tool_edit_file"
    (Some "tool_edit_file")
    (route_internal "EditFile");
  Alcotest.(check (option string))
    "WriteFile -> tool_write_file"
    (Some "tool_write_file")
    (route_internal "WriteFile")
;;

let test_route_unknown_returns_none () =
  Alcotest.(check (option string))
    "internal name has no route"
    None
    (route_internal "tool_execute");
  Alcotest.(check (option string))
    "arbitrary name has no route"
    None
    (route_internal "anything");
  Alcotest.(check (option string)) "empty string has no route" None (route_internal "")
;;

let test_alias_table_is_stable () =
  (* [public_names ()] is the canonical listing of LLM-native public names.
     Every entry must have a real [route] mapping; pinning length and
     route resolution catches accidental additions/deletions to the
     routing table. *)
  let names = Alias.public_names () in
  Alcotest.(check int) "seven public names" 7 (List.length names);
  List.iter
    (fun public ->
       Alcotest.(check bool)
         (Printf.sprintf "%s has a route" public)
         true
         (Option.is_some (Alias.route public)))
    names
;;

(* ── Phase A.3 integration: canonicalize before the observation check ─── *)

(** Mirrors the call sequence in [keeper_agent_run.ml:1875] after
    canonicalization is applied. Pins the contract: a turn whose only
    tool calls are Provider_a Code aliases (Execute/ReadFile/EditFile/SearchFiles/SearchWeb/WriteFile)
    must NOT produce any unexpected names. *)
let allowed_keeper_surface =
  [ "tool_execute"
  ; "tool_read_file"
  ; "tool_edit_file"
  ; "tool_search_files"
  ; "keeper_board_post"
  ; "masc_web_search"
  ; "masc_web_fetch"
  ; "extend_turns"
  ]
;;

let test_pure_alias_turn_no_longer_unexpected () =
  let observed = [ "Execute" ] in
  let canonical = List.map Resolution.canonical_tool_name observed in
  let unexpected =
    Observation.unexpected_tool_names
      ~allowed_tool_names:allowed_keeper_surface
      ~tool_names:canonical
  in
  Alcotest.(check (list string))
    "[Execute] only -> no unexpected (was the 18% nuke source)"
    []
    unexpected
;;

let test_mixed_alias_and_internal_no_unexpected () =
  let observed = [ "ReadFile"; "keeper_board_post"; "EditFile"; "SearchWeb" ] in
  let canonical = List.map Resolution.canonical_tool_name observed in
  let unexpected =
    Observation.unexpected_tool_names
      ~allowed_tool_names:allowed_keeper_surface
      ~tool_names:canonical
  in
  Alcotest.(check (list string)) "mixed alias + internal -> no unexpected" [] unexpected
;;

let test_hallucinated_builtin_still_unexpected () =
  let observed = [ "Skill"; "Execute" ] in
  let canonical = List.map Resolution.canonical_tool_name observed in
  let unexpected =
    Observation.unexpected_tool_names
      ~allowed_tool_names:allowed_keeper_surface
      ~tool_names:canonical
  in
  Alcotest.(check (list string))
    "Skill remains unexpected (no cognate); Execute resolved"
    [ "Skill" ]
    unexpected
;;

let test_mcp_prefixed_anthropic_alias_routes () =
  (* Regression guard for PR #14574 review #5: [canonical_name] must
     route ["mcp__masc__Execute"] the same way as ["Execute"]. Earlier the
     route lookup used the raw [name] instead of the stripped form,
     so MCP-prefixed Provider_a Code calls regressed into routing
     misses. *)
  let canonical = Resolution.canonical_tool_name "mcp__masc__Execute" in
  Alcotest.(check string)
    "mcp__masc__Execute routes through stripped form to tool_execute"
    "tool_execute"
    canonical
;;

let test_mcp_prefixed_anthropic_alias_telemetry_uses_stripped () =
  (* Self-review of PR #14585: in canonical_name_observed, the Route_hit
     branch (LLM-native public name reached via a stripped MCP prefix)
     must record [tool=stripped] so the label stays within
     [is_known_public]. Otherwise [safe_tool_label] collapses
     ["mcp__masc__Execute"] to ["unknown"] on a successful route. *)
  let labels = [ "tool", "Execute"; "routed_to", "tool_execute"; "result", "ok" ] in
  let before =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_tool_call_total
      ~labels
      ()
  in
  let _ = Resolution.canonical_tool_name_observed "mcp__masc__Execute" in
  let after =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_tool_call_total
      ~labels
      ()
  in
  Alcotest.(check (float 0.001))
    "MCP-prefixed Provider_a alias records tool=Execute (stripped), not raw prefixed name"
    (before +. 1.0)
    after
;;

let test_mcp_prefixed_keeper_internal_routes () =
  (* PR #14585 review: MCP transports can emit prefixed internal names
     like [mcp__masc__tool_execute]. canonicalise_outcome must check
     [is_known_internal stripped], not raw [name], so these are
     canonicalised to the stripped form instead of falling into [Miss]
     and being reported as unexpected. *)
  let canonical = Resolution.canonical_tool_name "mcp__masc__tool_execute" in
  Alcotest.(check string)
    "mcp__masc__tool_execute canonicalises to tool_execute (stripped)"
    "tool_execute"
    canonical
;;

let test_legacy_public_names_hard_cut () =
  List.iter
    (fun legacy ->
       Alcotest.(check bool)
         (Printf.sprintf "%s is no longer a public route" legacy)
         true
         (Option.is_none (Alias.route legacy));
       Alcotest.(check (option string))
         (Printf.sprintf "%s has no public schema" legacy)
         None
         (Option.map Yojson.Safe.to_string (Alias.public_input_schema legacy)))
    [ "Bash"; "Grep"; "Read"; "Edit"; "Write"; "WebSearch"; "WebFetch" ]
;;

let test_alias_canonical_internal_name_for_set_logic () =
  Alcotest.(check (option string))
    "public Execute canonicalises to tool_execute"
    (Some "tool_execute")
    (Alias.canonical_internal_name "Execute");
  Alcotest.(check (option string))
    "public SearchFiles canonicalises to tool_search_files"
    (Some "tool_search_files")
    (Alias.canonical_internal_name "SearchFiles");
  Alcotest.(check (option string))
    "MCP-prefixed public MASC name canonicalises to internal keeper tool"
    (Some "keeper_board_post")
    (Alias.canonical_internal_name "mcp__masc__masc_board_post");
  Alcotest.(check (option string))
    "known internal name stays internal"
    (Some "tool_execute")
    (Alias.canonical_internal_name "tool_execute");
  Alcotest.(check (option string))
    "unknown name stays unknown"
    None
    (Alias.canonical_internal_name "Skill")
;;

let test_mcp_prefixed_public_masc_goal_tool_routes () =
  let canonical = Resolution.canonical_tool_name "mcp__masc__masc_goal_list" in
  Alcotest.(check string)
    "mcp__masc__masc_goal_list canonicalises to masc_goal_list"
    "masc_goal_list"
    canonical;
  let unexpected =
    Observation.unexpected_tool_names
      ~allowed_tool_names:[ "masc_goal_list"; "masc_goal_verify" ]
      ~tool_names:[ canonical ]
  in
  Alcotest.(check (list string))
    "public MASC goal allowlist accepts MCP-prefixed observation"
    []
    unexpected
;;

let test_mcp_prefixed_masc_public_telemetry_preserves_label () =
  (* PR #14585 review: a successful MCP-mapped route for a name like
     [mcp__masc__masc_board_post] must record [tool=masc_board_post],
     not collapse to ["unknown"]. Verifies that
     [known_internal_names_tbl] is seeded with public MCP counterparts
     via [Tool_catalog_surfaces.keeper_internal_replacement]. *)
  let labels =
    [ "tool", "masc_board_post"; "routed_to", "keeper_board_post"; "result", "ok" ]
  in
  let before =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_tool_call_total
      ~labels
      ()
  in
  let _ = Resolution.canonical_tool_name_observed "mcp__masc__masc_board_post" in
  let after =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_tool_call_total
      ~labels
      ()
  in
  Alcotest.(check (float 0.001))
    "MCP-prefixed masc_* public name records tool=masc_board_post (not unknown)"
    (before +. 1.0)
    after
;;

let test_canonical_tool_name_pure_does_not_increment_counter () =
  (* Self-review of PR #14585 review #3: the pure variant must NOT emit
     telemetry. Otherwise set-logic call sites (required-tool
     canonicalisation, surface composition) would over-count. *)
  let labels_ok = [ "tool", "Execute"; "routed_to", "tool_execute"; "result", "ok" ] in
  let before =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_tool_call_total
      ~labels:labels_ok
      ()
  in
  let _ = Resolution.canonical_tool_name "Execute" in
  let _ = Resolution.canonical_tool_name "Execute" in
  let _ = Resolution.canonical_tool_name "Execute" in
  let after =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_tool_call_total
      ~labels:labels_ok
      ()
  in
  Alcotest.(check (float 0.001))
    "pure canonical_tool_name does not increment masc_keeper_tool_call_total"
    before
    after
;;

let test_partial_tolerance_still_works () =
  let observed = [ "Skill"; "Execute" ] in
  let canonical = List.map Resolution.canonical_tool_name observed in
  let unexpected =
    Observation.unexpected_tool_names
      ~allowed_tool_names:allowed_keeper_surface
      ~tool_names:canonical
  in
  let has_valid =
    Observation.has_valid_tool_call ~unexpected_tool_names:unexpected ~tool_names:canonical
  in
  Alcotest.(check bool)
    "Execute counts as valid -> partial tolerance kicks in"
    true
    has_valid
;;

let test_public_allowed_surface_accepts_canonical_alias () =
  let observed = [ "Execute" ] in
  let canonical = List.map Resolution.canonical_tool_name observed in
  let unexpected =
    Observation.unexpected_tool_names
      ~allowed_tool_names:[ "Execute" ]
      ~tool_names:canonical
  in
  Alcotest.(check (list string))
    "public Execute allowlist accepts canonical tool_execute observation"
    []
    unexpected;
  Alcotest.(check (list string))
    "final names keep canonical internal name"
    [ "tool_execute" ]
    (Observation.final_keeper_tool_names
       ~reported_tool_names:observed
       ~observed_tool_names:[]
       ~allowed_tool_names:[ "Execute" ])
;;

(* ── Routing table and schemas ─────────────────────────────── *)

let yojson_field name j =
  match j with
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let yojson_string_field name j =
  match yojson_field name j with
  | Some (`String s) -> Some s
  | _ -> None
;;

let yojson_bool_field name j =
  match yojson_field name j with
  | Some (`Bool b) -> Some b
  | _ -> None
;;

let yojson_int_field name j =
  match yojson_field name j with
  | Some (`Int n) -> Some n
  | Some (`Intlit s) -> (try Some (int_of_string s) with _ -> None)
  | _ -> None
;;

let count_bucket name json =
  match
    json
    |> Yojson.Safe.Util.to_list
    |> List.find_opt (fun item -> yojson_string_field "name" item = Some name)
  with
  | Some item -> yojson_int_field "count" item
  | None -> None
;;

let descriptor_id_for_tool_name name =
  Option.map
    (fun (descriptor : Descriptor.t) -> descriptor.id)
    (Descriptor_resolution.descriptor_for_tool_name name)
;;

let test_descriptor_route_evidence_names_policy_backend_sandbox_and_description () =
  let execute =
    match Descriptor.find_public "Execute" with
    | Some d -> d
    | None -> Alcotest.fail "Execute descriptor missing"
  in
  let route =
    match Alias.route "Execute" with
    | Some r -> r
    | None -> Alcotest.fail "Execute route missing"
  in
  Alcotest.(check string)
    "route carries descriptor"
    execute.Descriptor.id
    route.descriptor.id;
  let evidence = Descriptor.route_evidence_json execute in
  Alcotest.(check (option string))
    "descriptor id"
    (Some "agent.execute")
    (yojson_string_field "descriptor_id" evidence);
  Alcotest.(check (option string))
    "public name"
    (Some "Execute")
    (yojson_string_field "public_name" evidence);
  Alcotest.(check (option string))
    "canonical handler"
    (Some "tool_execute")
    (yojson_string_field "canonical_name" evidence);
  Alcotest.(check (option string))
    "executor"
    (Some "shell_ir")
    (yojson_string_field "executor" evidence);
  Alcotest.(check (option string))
    "backend"
    (Some "sandbox_process")
    (yojson_string_field "backend" evidence);
  Alcotest.(check (option string))
    "sandbox"
    (Some "backend_selected")
    (yojson_string_field "sandbox" evidence);
  Alcotest.(check (option string))
    "runtime handler"
    (Some "tool_execute")
    (yojson_string_field "runtime_handler" evidence);
  let receipt_labels = Yojson.Safe.Util.(evidence |> member "receipt_labels") in
  Alcotest.(check (option string))
    "receipt label descriptor id"
    (Some "agent.execute")
    (yojson_string_field "descriptor_id" receipt_labels);
  Alcotest.(check (option string))
    "receipt label executor"
    (Some "shell_ir")
    (yojson_string_field "executor" receipt_labels);
  Alcotest.(check (option string))
    "receipt label canonical name"
    (Some "tool_execute")
    (yojson_string_field "canonical_name" receipt_labels);
  Alcotest.(check (option string))
    "visibility"
    (Some "default")
    (yojson_string_field "visibility" evidence);
  Alcotest.(check (option string))
    "cwd scope"
    (Some "keeper_sandbox_or_allowed_path")
    (yojson_string_field "cwd_scope" evidence);
  Alcotest.(check (option bool))
    "retryable"
    (Some false)
    (yojson_bool_field "retryable" evidence);
  (match yojson_string_field "description" evidence with
   | Some description ->
     Alcotest.(check bool)
       "description names typed command"
       true
       (String.starts_with ~prefix:"Execute one typed command" description)
   | None -> Alcotest.fail "description missing")
;;

let test_descriptor_resolution_handles_public_prefixed_internal_and_dedupe () =
  Alcotest.(check (option string))
    "public ReadFile resolves"
    (Some "agent.read_file")
    (descriptor_id_for_tool_name "ReadFile");
  Alcotest.(check (option string))
    "internal tool_read_file resolves"
    (Some "agent.read_file")
    (descriptor_id_for_tool_name "tool_read_file");
  Alcotest.(check (option string))
    "internal coordination tool resolves"
    (Some "keeper.time.now")
    (descriptor_id_for_tool_name "keeper_time_now");
  Alcotest.(check (option string))
    "mcp-prefixed internal coordination tool resolves"
    (Some "keeper.time.now")
    (descriptor_id_for_tool_name "mcp__masc__keeper_time_now");
  Alcotest.(check (option string))
    "mcp-prefixed masc board tool resolves to exact masc descriptor"
    (Some "masc.board.post")
    (descriptor_id_for_tool_name "mcp__masc__masc_board_post");
  Alcotest.(check (list string))
    "descriptor list dedupes by descriptor id"
    [ "agent.read_file"; "keeper.time.now"; "agent.execute"; "masc.board.post" ]
    (Descriptor_resolution.descriptors_for_tool_names
       [ "ReadFile"
       ; "tool_read_file"
       ; "keeper_time_now"
       ; "mcp__masc__keeper_time_now"
       ; "Execute"
       ; "mcp__masc__masc_board_post"
       ; "unknown_tool"
       ]
     |> List.map (fun (descriptor : Descriptor.t) -> descriptor.id))
;;

let test_execution_receipt_descriptor_summary_projects_descriptors () =
  let receipt : Receipt.t =
    { keeper_name = "descriptor_keeper"
    ; agent_name = "descriptor_agent"
    ; trace_id = "trace-descriptor-summary"
    ; generation = 1
    ; turn_count = Some 7
    ; oas_turn_count = None
    ; oas_dispatch_mode = None
    ; oas_internal_cascade_disabled = false
    ; current_task_id = None
    ; goal_ids = []
    ; outcome = `Error
    ; terminal_reason_code = "policy_denied:approval_required"
    ; response_text_present = false
    ; model_used = None
    ; requested_tools = [ "ReadFile"; "Execute"; "keeper_time_now" ]
    ; reported_tools = [ "ReadFile" ]
    ; observed_tools = [ "tool_read_file"; "keeper_time_now" ]
    ; canonical_tools = [ "tool_read_file"; "tool_execute"; "keeper_time_now" ]
    ; unexpected_tools = []
    ; tools_used = [ "tool_execute" ]
    ; tool_contract_result = Receipt.Contract_violated
    ; tool_surface =
        { turn_lane = Masc_mcp.Keeper_agent_tool_surface.Lane_tool_required
        ; tool_surface_class = Masc_mcp.Keeper_agent_tool_surface.Surface_mixed
        ; tool_requirement = Masc_mcp.Keeper_agent_tool_surface.Required
        ; visible_tool_count = 3
        ; tool_gate_enabled = true
        ; tool_surface_fallback_used = false
        ; required_tools = [ "tool_execute" ]
        ; required_tool_candidates = [ "tool_execute" ]
        ; missing_required_tools = []
        ; materialized_tools = [ "tool_read_file"; "tool_execute"; "keeper_time_now" ]
        }
    ; sandbox_kind = Masc_mcp.Keeper_types.Local
    ; sandbox_root = None
    ; network_mode = Masc_mcp.Keeper_types.Network_none
    ; approval_profile = Some "manual"
    ; approval_profile_derived = false
    ; cascade_name = Cascade_name.of_string_exn "tier.test"
    ; cascade_selected_model = None
    ; cascade_attempt_count = 0
    ; cascade_fallback_applied = false
    ; cascade_outcome = Receipt.Cascade_not_dispatched
    ; oas_internal_cascade_allowed = false
    ; degraded_retry_applied = false
    ; degraded_retry_cascade = None
    ; fallback_reason = None
    ; cascade_rotation_attempts = []
    ; stop_reason = None
    ; error_kind = Some (Receipt.error_kind_of_string "policy")
    ; error_message = None
    ; started_at = "2026-05-26T00:00:00Z"
    ; ended_at = "2026-05-26T00:00:01Z"
    ; extra_system_context_digest = None
    ; extra_system_context_injected_size = None
    ; extra_system_context_computed_size = None
    ; pre_dispatch_compacted = false
    ; pre_dispatch_compaction_trigger = None
    ; pre_dispatch_compaction_before_tokens = None
    ; pre_dispatch_compaction_after_tokens = None
    }
  in
  let summary =
    Receipt.to_json receipt
    |> Yojson.Safe.Util.member "tool_descriptor_summary"
  in
  Alcotest.(check (option string))
    "summary source"
    (Some "receipt_tool_sets")
    (yojson_string_field "source" summary);
  Alcotest.(check (list string))
    "observed descriptor ids"
    [ "agent.read_file"; "keeper.time.now"; "agent.execute" ]
    Yojson.Safe.Util.(
      summary |> member "observed_descriptor_ids" |> to_list |> List.map to_string);
  let receipt_labels_for descriptor_id =
    Yojson.Safe.Util.(
      summary
      |> member "receipt_labels_by_descriptor"
      |> to_list
      |> List.find_opt (fun item ->
        yojson_string_field "descriptor_id" item = Some descriptor_id)
      |> Option.map (fun item -> item |> member "labels"))
  in
  (match receipt_labels_for "agent.execute" with
   | Some labels ->
     Alcotest.(check (option string))
       "execute receipt label public name"
       (Some "Execute")
       (yojson_string_field "public_name" labels);
     Alcotest.(check (option string))
       "execute receipt label backend"
       (Some "sandbox_process")
       (yojson_string_field "backend" labels)
   | None -> Alcotest.fail "missing execute receipt labels");
  (match receipt_labels_for "keeper.time.now" with
   | Some labels ->
     Alcotest.(check (option string))
       "time receipt label runtime handler"
       (Some "tool_time_now")
       (yojson_string_field "runtime_handler" labels)
   | None -> Alcotest.fail "missing time receipt labels");
  Alcotest.(check (option int))
    "descriptor count"
    (Some 3)
    (yojson_int_field "descriptor_count" summary);
  Alcotest.(check (option int))
    "filesystem executor count"
    (Some 1)
    Yojson.Safe.Util.(summary |> member "executor_counts" |> count_bucket "filesystem");
  Alcotest.(check (option int))
    "in-process executor count"
    (Some 1)
    Yojson.Safe.Util.(summary |> member "executor_counts" |> count_bucket "in_process");
  Alcotest.(check (option int))
    "shell executor count"
    (Some 1)
    Yojson.Safe.Util.(summary |> member "executor_counts" |> count_bucket "shell_ir");
  Alcotest.(check (option int))
    "sandbox backend count"
    (Some 2)
    Yojson.Safe.Util.(
      summary |> member "backend_counts" |> count_bucket "sandbox_process");
  Alcotest.(check (option int))
    "ocaml backend count"
    (Some 1)
    Yojson.Safe.Util.(summary |> member "backend_counts" |> count_bucket "ocaml_runtime");
  Alcotest.(check (option int))
    "backend-selected sandbox count"
    (Some 2)
    Yojson.Safe.Util.(
      summary |> member "sandbox_counts" |> count_bucket "backend_selected");
  Alcotest.(check (option int))
    "no sandbox count"
    (Some 1)
    Yojson.Safe.Util.(summary |> member "sandbox_counts" |> count_bucket "none");
  Alcotest.(check (option int))
    "failed policy decision count"
    (Some 1)
    (yojson_int_field "failed_policy_decision_count" summary)
;;

let test_agent_tool_runtime_resolves_descriptor_handlers () =
  let check_descriptor internal expected_id =
    match Runtime.descriptor_for_internal internal with
    | Some descriptor ->
      Alcotest.(check string) (internal ^ " descriptor id") expected_id descriptor.id
    | None -> Alcotest.failf "missing descriptor for %s" internal
  in
  check_descriptor "tool_execute" "agent.execute";
  check_descriptor "tool_search_files" "agent.search_files";
  check_descriptor "tool_read_file" "agent.read_file";
  check_descriptor "tool_edit_file" "agent.edit_file";
  check_descriptor "tool_write_file" "agent.write_file";
  check_descriptor "masc_web_search" "agent.search_web";
  check_descriptor "masc_web_fetch" "agent.fetch_web";
  (* RFC-0179 PR-3 migrated coordination tools into internal_descriptors.
     keeper_board_post now resolves to its descriptor (Tool_board_dispatch). *)
  check_descriptor "keeper_board_post" "keeper.board.post";
  check_descriptor "masc_board_post" "masc.board.post";
  check_descriptor "masc_board_list" "masc.board.list";
  check_descriptor "masc_board_sub_board_get" "masc.board.sub_board_get";
  check_descriptor "keeper_time_now" "keeper.time.now";
  check_descriptor "keeper_stay_silent" "keeper.stay_silent";
  check_descriptor "keeper_tools_list" "keeper.tools_list";
  check_descriptor "keeper_voice_speak" "keeper.voice.speak";
  check_descriptor "keeper_task_claim" "keeper.task.claim";
  Alcotest.(check bool)
    "unknown tool name still has no descriptor"
    true
    (Option.is_none (Runtime.descriptor_for_internal "totally_unknown_keeper_tool"))
;;

let string_contains ~sub text =
  let text_len = String.length text in
  let sub_len = String.length sub in
  let rec loop idx =
    if idx + sub_len > text_len
    then false
    else if String.sub text idx sub_len = sub
    then true
    else loop (idx + 1)
  in
  sub_len = 0 || loop 0
;;

let test_public_names_stable_order () =
  (* public_names returns all LLM-native surface names in stable order. *)
  let names = Alias.public_names () in
  Alcotest.(check (list string))
    "stable public name order"
    [ "Execute"; "SearchFiles"; "ReadFile"; "EditFile"; "WriteFile"; "SearchWeb"; "FetchWeb" ]
    names
;;

let test_public_input_schema_present () =
  List.iter
    (fun name ->
       Alcotest.(check bool)
         (Printf.sprintf "%s has tailored schema" name)
         true
         (Option.is_some (Alias.public_input_schema name)))
    [ "Execute"; "SearchFiles"; "ReadFile"; "EditFile"; "WriteFile"; "SearchWeb"; "FetchWeb" ];
  Alcotest.(check bool)
    "unknown public name has no schema"
    true
    (Option.is_none (Alias.public_input_schema "Nope"))
;;

let test_execute_schema_uses_typed_fields () =
  let schema = Option.get (Alias.public_input_schema "Execute") in
  let props = Option.get (yojson_field "properties" schema) in
  Alcotest.(check bool)
    "Execute schema exposes executable"
    true
    (Option.is_some (yojson_field "executable" props));
  Alcotest.(check bool)
    "Execute schema exposes argv"
    true
    (Option.is_some (yojson_field "argv" props));
  Alcotest.(check bool)
    "Execute schema exposes pipeline"
    true
    (Option.is_some (yojson_field "pipeline" props));
  Alcotest.(check bool)
    "Execute schema exposes cwd for sandbox repo disambiguation"
    true
    (Option.is_some (yojson_field "cwd" props));
  Alcotest.(check bool)
    "Execute schema does not expose 'cmd' directly"
    true
    (Option.is_none (yojson_field "cmd" props));
  Alcotest.(check bool)
    "Execute schema does not expose legacy command"
    true
    (Option.is_none (yojson_field "command" props));
  Alcotest.(check bool)
    "Execute schema does not expose background toggle"
    true
    (Option.is_none (yojson_field ("run_" ^ "in_background") props))
;;

let test_execute_schema_guides_typed_frontdoor () =
  let schema = Option.get (Alias.public_input_schema "Execute") in
  let props = Option.get (yojson_field "properties" schema) in
  let executable = Option.get (yojson_field "executable" props) in
  let description = Option.get (yojson_string_field "description" executable) in
  List.iter
    (fun (label, needle) ->
       Alcotest.(check bool)
         label
         true
         (string_contains ~sub:needle description))
    [ "Execute executable schema names typed argv", "Typed argv form"
    ; "Execute executable schema blocks combined shell syntax", "do not combine shell syntax"
    ]
;;

let test_read_schema_uses_file_path () =
  let schema = Option.get (Alias.public_input_schema "ReadFile") in
  let props = Option.get (yojson_field "properties" schema) in
  Alcotest.(check bool)
    "ReadFile schema exposes 'file_path' (not 'path')"
    true
    (Option.is_some (yojson_field "file_path" props));
  Alcotest.(check bool)
    "ReadFile schema does not expose 'path' directly"
    true
    (Option.is_none (yojson_field "path" props));
  Alcotest.(check bool)
    "ReadFile schema does not expose unsupported 'offset'"
    true
    (Option.is_none (yojson_field "offset" props))
;;

let test_translate_execute_input () =
  let input =
    `Assoc
      [ "executable", `String "ls"
      ; "argv", `List [ `String "-la" ]
      ; "cwd", `String "repos/masc-mcp"
      ; "timeout_sec", `Int 60
      ]
  in
  let translated = Alias.translate_input ~public:"Execute" input in
  let executable = yojson_field "executable" translated in
  let timeout_sec = yojson_field "timeout_sec" translated in
  let cwd = yojson_field "cwd" translated in
  Alcotest.(check (option string))
    "executable passes through"
    (Some "ls")
    (Option.bind executable (function
       | `String s -> Some s
       | _ -> None));
  Alcotest.(check (option int))
    "timeout -> timeout_sec"
    (Some 60)
    (Option.bind timeout_sec (function
       | `Int i -> Some i
       | _ -> None));
  Alcotest.(check (option string))
    "cwd passes through"
    (Some "repos/masc-mcp")
    (Option.bind cwd (function
       | `String s -> Some s
       | _ -> None));
  Alcotest.(check bool) "typed args unchanged" true (Yojson.Safe.equal input translated)
;;

let test_translate_read_input () =
  let input = `Assoc [ "file_path", `String "/tmp/foo"; "limit", `Int 4096 ] in
  let translated = Alias.translate_input ~public:"ReadFile" input in
  let path = yojson_field "path" translated in
  let max_bytes = yojson_field "max_bytes" translated in
  Alcotest.(check (option string))
    "file_path -> path"
    (Some "/tmp/foo")
    (Option.bind path (function
       | `String s -> Some s
       | _ -> None));
  Alcotest.(check (option int))
    "limit -> max_bytes"
    (Some 4096)
    (Option.bind max_bytes (function
       | `Int i -> Some i
       | _ -> None))
;;

let test_edit_schema_uses_anthropic_fields () =
  let schema = Option.get (Alias.public_input_schema "EditFile") in
  let props = Option.get (yojson_field "properties" schema) in
  List.iter
    (fun field ->
       Alcotest.(check bool)
         (Printf.sprintf "EditFile schema exposes %S" field)
         true
         (Option.is_some (yojson_field field props)))
    [ "file_path"; "old_string"; "new_string"; "replace_all" ];
  Alcotest.(check bool)
    "EditFile schema does not expose internal 'mode' to LLM"
    true
    (Option.is_none (yojson_field "mode" props))
;;

let test_write_schema_uses_anthropic_fields () =
  let schema = Option.get (Alias.public_input_schema "WriteFile") in
  let props = Option.get (yojson_field "properties" schema) in
  List.iter
    (fun field ->
       Alcotest.(check bool)
         (Printf.sprintf "WriteFile schema exposes %S" field)
         true
         (Option.is_some (yojson_field field props)))
    [ "file_path"; "content" ];
  Alcotest.(check bool)
    "WriteFile schema does not expose internal 'mode' to LLM"
    true
    (Option.is_none (yojson_field "mode" props))
;;

let test_search_files_schema_uses_public_fields () =
  let schema = Option.get (Alias.public_input_schema "SearchFiles") in
  let props = Option.get (yojson_field "properties" schema) in
  Alcotest.(check bool)
    "SearchFiles schema exposes 'pattern'"
    true
    (Option.is_some (yojson_field "pattern" props));
  Alcotest.(check bool)
    "SearchFiles schema does not expose internal 'op' to LLM"
    true
    (Option.is_none (yojson_field "op" props));
  Alcotest.(check bool)
    "SearchFiles schema does not expose unsupported '-n'"
    true
    (Option.is_none (yojson_field "-n" props))
;;

let test_web_search_schema_uses_public_fields () =
  let schema = Option.get (Alias.public_input_schema "SearchWeb") in
  let props = Option.get (yojson_field "properties" schema) in
  Alcotest.(check bool)
    "SearchWeb schema exposes 'query'"
    true
    (Option.is_some (yojson_field "query" props));
  Alcotest.(check bool)
    "SearchWeb schema exposes 'limit'"
    true
    (Option.is_some (yojson_field "limit" props));
  let required =
    match yojson_field "required" schema with
    | Some (`List items) ->
      List.filter_map
        (function
          | `String s -> Some s
          | _ -> None)
        items
    | _ -> []
  in
  Alcotest.(check (list string)) "SearchWeb requires 'query'" [ "query" ] required
;;

let test_translate_edit_input () =
  let input =
    `Assoc
      [ "file_path", `String "/tmp/foo.ml"
      ; "old_string", `String "let x = 1"
      ; "new_string", `String "let x = 2"
      ; "replace_all", `Bool true
      ]
  in
  let translated = Alias.translate_input ~public:"EditFile" input in
  Alcotest.(check (option string))
    "file_path -> path"
    (Some "/tmp/foo.ml")
    (Option.bind (yojson_field "path" translated) (function
       | `String s -> Some s
       | _ -> None));
  Alcotest.(check (option string))
    "mode injected as 'patch'"
    (Some "patch")
    (Option.bind (yojson_field "mode" translated) (function
       | `String s -> Some s
       | _ -> None));
  Alcotest.(check bool)
    "old_string preserved"
    true
    (Option.is_some (yojson_field "old_string" translated));
  Alcotest.(check bool)
    "new_string preserved"
    true
    (Option.is_some (yojson_field "new_string" translated));
  Alcotest.(check (option bool))
    "replace_all preserved"
    (Some true)
    (Option.bind (yojson_field "replace_all" translated) (function
       | `Bool b -> Some b
       | _ -> None))
;;

let test_translate_edit_drops_caller_supplied_mode () =
  (* Defense-in-depth: if the LLM tries to write via EditFile by providing 'content',
     fallback to mode=overwrite instead of silently dropping it. *)
  let input =
    `Assoc
      [ "file_path", `String "/tmp/x"
      ; "mode", `String "patch"
      ; "content", `String "fallback"
      ]
  in
  let translated = Alias.translate_input ~public:"EditFile" input in
  Alcotest.(check (option string))
    "mode is fallback to overwrite"
    (Some "overwrite")
    (Option.bind (yojson_field "mode" translated) (function
       | `String s -> Some s
       | _ -> None));
  Alcotest.(check (option string))
    "caller-supplied content preserved"
    (Some "fallback")
    (Option.bind (yojson_field "content" translated) (function
       | `String s -> Some s
       | _ -> None))
;;

let test_translate_write_input () =
  let input =
    `Assoc [ "file_path", `String "/tmp/new.txt"; "content", `String "hello world" ]
  in
  let translated = Alias.translate_input ~public:"WriteFile" input in
  Alcotest.(check (option string))
    "file_path -> path"
    (Some "/tmp/new.txt")
    (Option.bind (yojson_field "path" translated) (function
       | `String s -> Some s
       | _ -> None));
  Alcotest.(check (option string))
    "mode injected as 'overwrite'"
    (Some "overwrite")
    (Option.bind (yojson_field "mode" translated) (function
       | `String s -> Some s
       | _ -> None));
  Alcotest.(check (option string))
    "content preserved verbatim"
    (Some "hello world")
    (Option.bind (yojson_field "content" translated) (function
       | `String s -> Some s
       | _ -> None))
;;

let test_translate_search_files_input () =
  let input =
    `Assoc
      [ "pattern", `String "TODO"
      ; "path", `String "lib/"
      ; "glob", `String "*.ml"
      ; "type", `String "ml"
      ; "-i", `Bool true
      ]
  in
  let translated = Alias.translate_input ~public:"SearchFiles" input in
  Alcotest.(check (option string))
    "op injected as 'rg'"
    (Some "rg")
    (Option.bind (yojson_field "op" translated) (function
       | `String s -> Some s
       | _ -> None));
  Alcotest.(check (option string))
    "pattern preserved and prefix added"
    (Some "(?i)TODO")
    (Option.bind (yojson_field "pattern" translated) (function
       | `String s -> Some s
       | _ -> None));
  Alcotest.(check bool)
    "path preserved"
    true
    (Option.is_some (yojson_field "path" translated));
  Alcotest.(check bool)
    "glob preserved"
    true
    (Option.is_some (yojson_field "glob" translated));
  Alcotest.(check bool)
    "type preserved"
    true
    (Option.is_some (yojson_field "type" translated));
  Alcotest.(check bool)
    "-i flag translated away"
    true
    (Option.is_none (yojson_field "-i" translated))
;;

let test_translate_web_search_input_is_identity () =
  let input = `Assoc [ "query", `String "OpenAI API release notes"; "limit", `Int 5 ] in
  let translated = Alias.translate_input ~public:"SearchWeb" input in
  Alcotest.(check string)
    "SearchWeb payload already matches masc_web_search"
    (Yojson.Safe.to_string input)
    (Yojson.Safe.to_string translated)
;;

let test_translate_unknown_is_identity () =
  let input = `Assoc [ "foo", `String "bar" ] in
  let translated = Alias.translate_input ~public:"NoSuchTool" input in
  Alcotest.(check string)
    "identity for unknown public name"
    (Yojson.Safe.to_string input)
    (Yojson.Safe.to_string translated)
;;

let test_translate_malformed_input_is_identity () =
  let input = `String "not an object" in
  let translated = Alias.translate_input ~public:"Execute" input in
  Alcotest.(check string)
    "non-object payload passes through"
    (Yojson.Safe.to_string input)
    (Yojson.Safe.to_string translated)
;;

let test_public_names_adds_to_allowlist () =
  (* public_names returns LLM-native surface names that callers should
     add to their allowlists. These are the names the LLM will call,
     not the internal keeper_* names. *)
  let names = Alias.public_names () in
  Alcotest.(check bool) "Execute is in public_names" true (List.mem "Execute" names);
  Alcotest.(check bool) "ReadFile is in public_names" true (List.mem "ReadFile" names);
  Alcotest.(check bool) "SearchWeb is in public_names" true (List.mem "SearchWeb" names);
  (* Internal names are NOT in public_names. *)
  Alcotest.(check bool)
    "tool_execute is NOT in public_names"
    false
    (List.mem "tool_execute" names)
;;

let () =
  Alcotest.run
    "Keeper_tool_alias"
    [ ( "routing-table"
      , [ Alcotest.test_case "known aliases resolve" `Quick test_known_aliases_resolve
        ; Alcotest.test_case
            "internal names resolve to preferred public alias"
            `Quick
            test_internal_names_resolve_to_preferred_public_alias
        ; Alcotest.test_case "unknown returns None" `Quick test_unknown_returns_none
        ; Alcotest.test_case "route round-trip" `Quick test_route_round_trip
        ; Alcotest.test_case
            "route unknown returns None"
            `Quick
            test_route_unknown_returns_none
        ; Alcotest.test_case "table is stable" `Quick test_alias_table_is_stable
        ] )
    ; ( "disclosure-integration"
      , [ Alcotest.test_case
            "pure alias turn no longer unexpected"
            `Quick
            test_pure_alias_turn_no_longer_unexpected
        ; Alcotest.test_case
            "mixed alias + internal no unexpected"
            `Quick
            test_mixed_alias_and_internal_no_unexpected
        ; Alcotest.test_case
            "hallucinated builtin still unexpected"
            `Quick
            test_hallucinated_builtin_still_unexpected
        ; Alcotest.test_case
            "mcp-prefixed provider_a alias routes"
            `Quick
            test_mcp_prefixed_anthropic_alias_routes
        ; Alcotest.test_case
            "mcp-prefixed provider_a alias telemetry uses stripped tool label"
            `Quick
            test_mcp_prefixed_anthropic_alias_telemetry_uses_stripped
        ; Alcotest.test_case
            "mcp-prefixed keeper internal canonicalises to stripped"
            `Quick
            test_mcp_prefixed_keeper_internal_routes
        ; Alcotest.test_case
            "retired public names are hard-cut"
            `Quick
            test_legacy_public_names_hard_cut
        ; Alcotest.test_case
            "canonical internal name for set logic"
            `Quick
            test_alias_canonical_internal_name_for_set_logic
        ; Alcotest.test_case
            "mcp-prefixed public MASC goal tool canonicalises to stripped"
            `Quick
            test_mcp_prefixed_public_masc_goal_tool_routes
        ; Alcotest.test_case
            "mcp-prefixed masc public name telemetry preserves label"
            `Quick
            test_mcp_prefixed_masc_public_telemetry_preserves_label
        ; Alcotest.test_case
            "pure canonical_tool_name does not increment counter"
            `Quick
            test_canonical_tool_name_pure_does_not_increment_counter
        ; Alcotest.test_case
            "partial tolerance still works"
            `Quick
            test_partial_tolerance_still_works
        ; Alcotest.test_case
            "public allowed surface accepts canonical alias"
            `Quick
            test_public_allowed_surface_accepts_canonical_alias
        ] )
    ; ( "routing-and-schemas"
      , [ Alcotest.test_case
            "public names stable order"
            `Quick
            test_public_names_stable_order
        ; Alcotest.test_case
            "tailored input schema present"
            `Quick
            test_public_input_schema_present
        ; Alcotest.test_case
            "Execute schema uses typed fields"
            `Quick
            test_execute_schema_uses_typed_fields
        ; Alcotest.test_case
            "Execute schema guides typed front door"
            `Quick
            test_execute_schema_guides_typed_frontdoor
        ; Alcotest.test_case
            "ReadFile schema uses 'file_path' field"
            `Quick
            test_read_schema_uses_file_path
        ; Alcotest.test_case
            "EditFile schema uses Provider_a field names"
            `Quick
            test_edit_schema_uses_anthropic_fields
        ; Alcotest.test_case
            "WriteFile schema uses Provider_a field names"
            `Quick
            test_write_schema_uses_anthropic_fields
        ; Alcotest.test_case
            "SearchFiles schema uses Provider_a field names"
            `Quick
            test_search_files_schema_uses_public_fields
        ; Alcotest.test_case
            "SearchWeb schema uses public field names"
            `Quick
            test_web_search_schema_uses_public_fields
        ; Alcotest.test_case
            "descriptor evidence names policy route"
            `Quick
            test_descriptor_route_evidence_names_policy_backend_sandbox_and_description
        ; Alcotest.test_case
            "descriptor resolution handles public internal prefixed dedupe"
            `Quick
            test_descriptor_resolution_handles_public_prefixed_internal_and_dedupe
        ; Alcotest.test_case
            "execution receipt descriptor summary projects descriptors"
            `Quick
            test_execution_receipt_descriptor_summary_projects_descriptors
        ; Alcotest.test_case
            "agent tool runtime resolves descriptor handlers"
            `Quick
            test_agent_tool_runtime_resolves_descriptor_handlers
        ; Alcotest.test_case
            "translate Execute input shape"
            `Quick
            test_translate_execute_input
        ; Alcotest.test_case "translate ReadFile input shape" `Quick test_translate_read_input
        ; Alcotest.test_case "translate EditFile input shape" `Quick test_translate_edit_input
        ; Alcotest.test_case
            "translate EditFile drops caller mode"
            `Quick
            test_translate_edit_drops_caller_supplied_mode
        ; Alcotest.test_case
            "translate WriteFile input shape"
            `Quick
            test_translate_write_input
        ; Alcotest.test_case "translate SearchFiles input shape" `Quick test_translate_search_files_input
        ; Alcotest.test_case
            "translate SearchWeb input shape"
            `Quick
            test_translate_web_search_input_is_identity
        ; Alcotest.test_case
            "translate unknown is identity"
            `Quick
            test_translate_unknown_is_identity
        ; Alcotest.test_case
            "translate malformed is identity"
            `Quick
            test_translate_malformed_input_is_identity
        ; Alcotest.test_case
            "public_names adds to allowlist"
            `Quick
            test_public_names_adds_to_allowlist
        ] )
    ]
;;
