(** Tests for Keeper_tool_alias.

    RFC-0064: two-surface routing table. Public names (Bash, Read, …)
    map to internal handler names (keeper_bash, keeper_fs_read, …)
    via a single [route] type. No reverse lookup or tier classification. *)

module Alias = Masc_mcp.Keeper_tool_alias
module Disclosure = Masc_mcp.Keeper_tool_disclosure

let route_internal name =
  match Alias.route name with
  | Some r -> Some r.internal_name
  | None -> None
;;

let test_known_aliases_resolve () =
  Alcotest.(check (option string))
    "Bash -> keeper_bash"
    (Some "keeper_bash")
    (route_internal "Bash");
  Alcotest.(check (option string))
    "Read -> keeper_fs_read"
    (Some "keeper_fs_read")
    (route_internal "Read");
  Alcotest.(check (option string))
    "Edit -> keeper_fs_edit"
    (Some "keeper_fs_edit")
    (route_internal "Edit");
  Alcotest.(check (option string))
    "Write -> keeper_fs_edit"
    (Some "keeper_fs_edit")
    (route_internal "Write");
  Alcotest.(check (option string))
    "Grep -> keeper_shell"
    (Some "keeper_shell")
    (route_internal "Grep");
  Alcotest.(check (option string))
    "WebSearch -> masc_web_search"
    (Some "masc_web_search")
    (route_internal "WebSearch")
;;

let test_unknown_returns_none () =
  Alcotest.(check (option string)) "Skill has no cognate" None (route_internal "Skill");
  Alcotest.(check (option string))
    "keeper_bash is internal, not public"
    None
    (route_internal "keeper_bash");
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
  (* Edit and Write both route to keeper_fs_edit. *)
  Alcotest.(check (option string))
    "Edit -> keeper_fs_edit"
    (Some "keeper_fs_edit")
    (route_internal "Edit");
  Alcotest.(check (option string))
    "Write -> keeper_fs_edit"
    (Some "keeper_fs_edit")
    (route_internal "Write")
;;

let test_route_unknown_returns_none () =
  Alcotest.(check (option string))
    "internal name has no route"
    None
    (route_internal "keeper_bash");
  Alcotest.(check (option string))
    "arbitrary name has no route"
    None
    (route_internal "anything");
  Alcotest.(check (option string)) "empty string has no route" None (route_internal "")
;;

let test_route_or_miss_records_ok () =
  let labels = [ "tool", "Bash"; "routed_to", "keeper_bash"; "result", "ok" ] in
  let before =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_tool_call_total
      ~labels
      ()
  in
  let _ = Alias.route_or_miss "Bash" in
  let after =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_tool_call_total
      ~labels
      ()
  in
  Alcotest.(check (float 0.001))
    "telemetry counter incremented for ok route"
    (before +. 1.0)
    after
;;

let test_route_or_miss_records_miss () =
  (* Cardinality bound (RFC-0064 PR #14574 review #4): a miss for a
     hallucinated name like "Skill" is recorded against the
     [tool="unknown"] / [routed_to="none"] bucket — never against the
     raw observed string, otherwise each unique hallucination would
     allocate its own Prometheus time series. *)
  let labels = [ "tool", "unknown"; "routed_to", "none"; "result", "miss" ] in
  let before =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_tool_call_total
      ~labels
      ()
  in
  let _ = Alias.route_or_miss "Skill" in
  let after =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_tool_call_total
      ~labels
      ()
  in
  Alcotest.(check (float 0.001))
    "telemetry counter incremented for miss (unknown bucket)"
    (before +. 1.0)
    after
;;

let test_known_public_names () =
  (* Names with a route entry are known public names. *)
  Alcotest.(check bool) "Bash is known public" true (Alias.is_known_public "Bash");
  Alcotest.(check bool) "Read is known public" true (Alias.is_known_public "Read");
  Alcotest.(check bool)
    "WebSearch is known public"
    true
    (Alias.is_known_public "WebSearch");
  Alcotest.(check bool) "WebFetch is known public" true (Alias.is_known_public "WebFetch");
  (* Internal names and arbitrary names are NOT public surface names. *)
  Alcotest.(check bool) "Skill is NOT known public" false (Alias.is_known_public "Skill");
  Alcotest.(check bool) "Agent is NOT known public" false (Alias.is_known_public "Agent");
  Alcotest.(check bool)
    "keeper_bash is NOT known public (it's internal)"
    false
    (Alias.is_known_public "keeper_bash")
;;

let test_alias_table_is_stable () =
  let names = Alias.public_names () in
  Alcotest.(check int) "seven public names" 7 (List.length names);
  List.iter
    (fun public ->
       Alcotest.(check bool)
         (Printf.sprintf "%s has a route" public)
         true
         (Alias.is_known_public public))
    names
;;

(* ── Phase A.3 integration: canonicalize before the disclosure check ─── *)

(** Mirrors the call sequence in [keeper_agent_run.ml:1875] after
    canonicalization is applied. Pins the contract: a turn whose only
    tool calls are Anthropic Code aliases (Bash/Read/Edit/Grep/WebSearch/Write)
    must NOT produce any unexpected names. *)
let allowed_keeper_surface =
  [ "keeper_bash"
  ; "keeper_fs_read"
  ; "keeper_fs_edit"
  ; "keeper_shell"
  ; "keeper_board_post"
  ; "masc_web_search"
  ; "masc_web_fetch"
  ; "extend_turns"
  ]
;;

let test_pure_alias_turn_no_longer_unexpected () =
  let observed = [ "Bash" ] in
  let canonical = List.map Disclosure.canonical_tool_name observed in
  let unexpected =
    Disclosure.unexpected_tool_names
      ~allowed_tool_names:allowed_keeper_surface
      ~tool_names:canonical
  in
  Alcotest.(check (list string))
    "[Bash] only -> no unexpected (was the 18% nuke source)"
    []
    unexpected
;;

let test_mixed_alias_and_internal_no_unexpected () =
  let observed = [ "Read"; "keeper_board_post"; "Edit"; "WebSearch" ] in
  let canonical = List.map Disclosure.canonical_tool_name observed in
  let unexpected =
    Disclosure.unexpected_tool_names
      ~allowed_tool_names:allowed_keeper_surface
      ~tool_names:canonical
  in
  Alcotest.(check (list string)) "mixed alias + internal -> no unexpected" [] unexpected
;;

let test_hallucinated_builtin_still_unexpected () =
  let observed = [ "Skill"; "Bash" ] in
  let canonical = List.map Disclosure.canonical_tool_name observed in
  let unexpected =
    Disclosure.unexpected_tool_names
      ~allowed_tool_names:allowed_keeper_surface
      ~tool_names:canonical
  in
  Alcotest.(check (list string))
    "Skill remains unexpected (no cognate); Bash resolved"
    [ "Skill" ]
    unexpected
;;

let test_partial_tolerance_still_works () =
  let observed = [ "Skill"; "Bash" ] in
  let canonical = List.map Disclosure.canonical_tool_name observed in
  let unexpected =
    Disclosure.unexpected_tool_names
      ~allowed_tool_names:allowed_keeper_surface
      ~tool_names:canonical
  in
  let has_valid =
    Disclosure.has_valid_tool_call ~unexpected_tool_names:unexpected ~tool_names:canonical
  in
  Alcotest.(check bool)
    "Bash counts as valid -> partial tolerance kicks in"
    true
    has_valid
;;

(* ── Routing table and schemas ─────────────────────────────── *)

let yojson_field name j =
  match j with
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let test_public_names_stable_order () =
  (* public_names returns all LLM-native surface names in stable order. *)
  let names = Alias.public_names () in
  Alcotest.(check (list string))
    "stable public name order"
    [ "Bash"; "Edit"; "Grep"; "Read"; "WebFetch"; "WebSearch"; "Write" ]
    names
;;

let test_public_input_schema_present () =
  List.iter
    (fun name ->
       Alcotest.(check bool)
         (Printf.sprintf "%s has tailored schema" name)
         true
         (Option.is_some (Alias.public_input_schema name)))
    [ "Bash"; "Edit"; "Grep"; "Read"; "WebSearch"; "Write" ];
  Alcotest.(check bool)
    "unknown public name has no schema"
    true
    (Option.is_none (Alias.public_input_schema "Nope"))
;;

let test_bash_schema_uses_command_field () =
  let schema = Option.get (Alias.public_input_schema "Bash") in
  let props = Option.get (yojson_field "properties" schema) in
  Alcotest.(check bool)
    "Bash schema exposes 'command' (not 'cmd')"
    true
    (Option.is_some (yojson_field "command" props));
  Alcotest.(check bool)
    "Bash schema does not expose 'cmd' directly"
    true
    (Option.is_none (yojson_field "cmd" props));
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
  Alcotest.(check (list string)) "Bash requires 'command'" [ "command" ] required
;;

let test_read_schema_uses_file_path () =
  let schema = Option.get (Alias.public_input_schema "Read") in
  let props = Option.get (yojson_field "properties" schema) in
  Alcotest.(check bool)
    "Read schema exposes 'file_path' (not 'path')"
    true
    (Option.is_some (yojson_field "file_path" props));
  Alcotest.(check bool)
    "Read schema does not expose 'path' directly"
    true
    (Option.is_none (yojson_field "path" props))
;;

let test_translate_bash_input () =
  let input =
    `Assoc
      [ "command", `String "ls -la"
      ; "timeout", `Int 60
      ; "description", `String "list files"
      ; "run_in_background", `Bool false
      ]
  in
  let translated = Alias.translate_input ~public:"Bash" input in
  let cmd = yojson_field "cmd" translated in
  let timeout_sec = yojson_field "timeout_sec" translated in
  let bg = yojson_field "run_in_background" translated in
  let desc = yojson_field "description" translated in
  Alcotest.(check (option string))
    "command -> cmd"
    (Some "ls -la")
    (Option.bind cmd (function
       | `String s -> Some s
       | _ -> None));
  Alcotest.(check (option int))
    "timeout -> timeout_sec"
    (Some 60)
    (Option.bind timeout_sec (function
       | `Int i -> Some i
       | _ -> None));
  Alcotest.(check bool) "run_in_background passes through" true (Option.is_some bg);
  Alcotest.(check bool) "description is dropped" true (Option.is_none desc)
;;

let test_translate_read_input () =
  let input =
    `Assoc [ "file_path", `String "/tmp/foo"; "limit", `Int 4096; "offset", `Int 100 ]
  in
  let translated = Alias.translate_input ~public:"Read" input in
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
    "offset is dropped (keeper_fs_read does not support it)"
    true
    (Option.is_none offset)
;;

let test_edit_schema_uses_anthropic_fields () =
  let schema = Option.get (Alias.public_input_schema "Edit") in
  let props = Option.get (yojson_field "properties" schema) in
  List.iter
    (fun field ->
       Alcotest.(check bool)
         (Printf.sprintf "Edit schema exposes %S" field)
         true
         (Option.is_some (yojson_field field props)))
    [ "file_path"; "old_string"; "new_string"; "replace_all" ];
  Alcotest.(check bool)
    "Edit schema does not expose internal 'mode' to LLM"
    true
    (Option.is_none (yojson_field "mode" props))
;;

let test_write_schema_uses_anthropic_fields () =
  let schema = Option.get (Alias.public_input_schema "Write") in
  let props = Option.get (yojson_field "properties" schema) in
  List.iter
    (fun field ->
       Alcotest.(check bool)
         (Printf.sprintf "Write schema exposes %S" field)
         true
         (Option.is_some (yojson_field field props)))
    [ "file_path"; "content" ];
  Alcotest.(check bool)
    "Write schema does not expose internal 'mode' to LLM"
    true
    (Option.is_none (yojson_field "mode" props))
;;

let test_grep_schema_uses_anthropic_fields () =
  let schema = Option.get (Alias.public_input_schema "Grep") in
  let props = Option.get (yojson_field "properties" schema) in
  Alcotest.(check bool)
    "Grep schema exposes 'pattern'"
    true
    (Option.is_some (yojson_field "pattern" props));
  Alcotest.(check bool)
    "Grep schema does not expose internal 'op' to LLM"
    true
    (Option.is_none (yojson_field "op" props))
;;

let test_web_search_schema_uses_public_fields () =
  let schema = Option.get (Alias.public_input_schema "WebSearch") in
  let props = Option.get (yojson_field "properties" schema) in
  Alcotest.(check bool)
    "WebSearch schema exposes 'query'"
    true
    (Option.is_some (yojson_field "query" props));
  Alcotest.(check bool)
    "WebSearch schema exposes 'limit'"
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
  Alcotest.(check (list string)) "WebSearch requires 'query'" [ "query" ] required
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
  let translated = Alias.translate_input ~public:"Edit" input in
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
  (* Defense-in-depth: if the LLM tries to write via Edit by providing 'content',
     fallback to mode=overwrite instead of silently dropping it. *)
  let input =
    `Assoc
      [ "file_path", `String "/tmp/x"
      ; "mode", `String "patch"
      ; "content", `String "fallback"
      ]
  in
  let translated = Alias.translate_input ~public:"Edit" input in
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
  let translated = Alias.translate_input ~public:"Write" input in
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

let test_translate_grep_input () =
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
  let translated = Alias.translate_input ~public:"Grep" input in
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
  let translated = Alias.translate_input ~public:"WebSearch" input in
  Alcotest.(check string)
    "WebSearch payload already matches masc_web_search"
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
  let translated = Alias.translate_input ~public:"Bash" input in
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
  Alcotest.(check bool) "Bash is in public_names" true (List.mem "Bash" names);
  Alcotest.(check bool) "Read is in public_names" true (List.mem "Read" names);
  Alcotest.(check bool) "WebSearch is in public_names" true (List.mem "WebSearch" names);
  (* Internal names are NOT in public_names. *)
  Alcotest.(check bool)
    "keeper_bash is NOT in public_names"
    false
    (List.mem "keeper_bash" names)
;;

let () =
  Alcotest.run
    "Keeper_tool_alias"
    [ ( "routing-table"
      , [ Alcotest.test_case "known aliases resolve" `Quick test_known_aliases_resolve
        ; Alcotest.test_case "unknown returns None" `Quick test_unknown_returns_none
        ; Alcotest.test_case "route round-trip" `Quick test_route_round_trip
        ; Alcotest.test_case
            "route unknown returns None"
            `Quick
            test_route_unknown_returns_none
        ; Alcotest.test_case
            "route_or_miss records ok"
            `Quick
            test_route_or_miss_records_ok
        ; Alcotest.test_case
            "route_or_miss records miss"
            `Quick
            test_route_or_miss_records_miss
        ; Alcotest.test_case "known public names" `Quick test_known_public_names
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
            "partial tolerance still works"
            `Quick
            test_partial_tolerance_still_works
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
            "Bash schema uses 'command' field"
            `Quick
            test_bash_schema_uses_command_field
        ; Alcotest.test_case
            "Read schema uses 'file_path' field"
            `Quick
            test_read_schema_uses_file_path
        ; Alcotest.test_case
            "Edit schema uses Anthropic field names"
            `Quick
            test_edit_schema_uses_anthropic_fields
        ; Alcotest.test_case
            "Write schema uses Anthropic field names"
            `Quick
            test_write_schema_uses_anthropic_fields
        ; Alcotest.test_case
            "Grep schema uses Anthropic field names"
            `Quick
            test_grep_schema_uses_anthropic_fields
        ; Alcotest.test_case
            "WebSearch schema uses public field names"
            `Quick
            test_web_search_schema_uses_public_fields
        ; Alcotest.test_case "translate Bash input shape" `Quick test_translate_bash_input
        ; Alcotest.test_case "translate Read input shape" `Quick test_translate_read_input
        ; Alcotest.test_case "translate Edit input shape" `Quick test_translate_edit_input
        ; Alcotest.test_case
            "translate Edit drops caller mode"
            `Quick
            test_translate_edit_drops_caller_supplied_mode
        ; Alcotest.test_case
            "translate Write input shape"
            `Quick
            test_translate_write_input
        ; Alcotest.test_case "translate Grep input shape" `Quick test_translate_grep_input
        ; Alcotest.test_case
            "translate WebSearch input shape"
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
