(** Tests for Keeper_tool_alias.

    RFC-0064: two-surface routing table. Public names (Execute, ReadFile, …)
    map to internal handler names (tool_execute, tool_read_file, …)
    via a single [route] type. No reverse lookup or tier classification. *)

module Alias = Masc_mcp.Keeper_tool_alias
module Descriptor = Masc_mcp.Agent_tool_descriptor
module Observation = Masc_mcp.Keeper_tool_observation
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
  Alcotest.(check bool)
    "unaliased keeper tool has no agent descriptor"
    true
    (Option.is_none (Runtime.descriptor_for_internal "keeper_board_post"))
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
    (Option.is_none (yojson_field "path" props))
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
  let input =
    `Assoc [ "file_path", `String "/tmp/foo"; "limit", `Int 4096; "offset", `Int 100 ]
  in
  let translated = Alias.translate_input ~public:"ReadFile" input in
  let path = yojson_field "path" translated in
  let max_bytes = yojson_field "max_bytes" translated in
  let offset = yojson_field "offset" translated in
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
       | _ -> None));
  Alcotest.(check bool)
    "offset is dropped (tool_read_file does not support it)"
    true
    (Option.is_none offset)
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
    (Option.is_none (yojson_field "op" props))
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
      ; "-n", `Bool true
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
    "-i shim dropped"
    true
    (Option.is_none (yojson_field "-i" translated));
  Alcotest.(check bool)
    "-n shim dropped"
    true
    (Option.is_none (yojson_field "-n" translated))
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
