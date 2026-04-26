(** Tests for Keeper_tool_alias.

    Phase A.1 of RFC-0006. The module is data-only at this point;
    these tests pin the alias table so subsequent runtime wiring
    (Phase A.2/A.3) can rely on stable contracts. *)

module Alias = Masc_mcp.Keeper_tool_alias
module Disclosure = Masc_mcp.Keeper_tool_disclosure

let test_known_aliases_resolve () =
  Alcotest.(check (option string))
    "Bash -> keeper_bash"
    (Some "keeper_bash")
    (Alias.to_internal "Bash");
  Alcotest.(check (option string))
    "Read -> keeper_fs_read"
    (Some "keeper_fs_read")
    (Alias.to_internal "Read");
  Alcotest.(check (option string))
    "Edit -> keeper_fs_edit"
    (Some "keeper_fs_edit")
    (Alias.to_internal "Edit");
  Alcotest.(check (option string))
    "Write -> keeper_fs_edit"
    (Some "keeper_fs_edit")
    (Alias.to_internal "Write");
  Alcotest.(check (option string))
    "Grep -> keeper_shell"
    (Some "keeper_shell")
    (Alias.to_internal "Grep")
;;

let test_unknown_returns_none () =
  Alcotest.(check (option string)) "Skill has no cognate" None (Alias.to_internal "Skill");
  Alcotest.(check (option string))
    "keeper_bash is internal, not public"
    None
    (Alias.to_internal "keeper_bash");
  Alcotest.(check (option string)) "empty string" None (Alias.to_internal "");
  Alcotest.(check (option string)) "case sensitive" None (Alias.to_internal "bash")
;;

let test_to_public_round_trip () =
  Alcotest.(check string) "keeper_bash -> Bash" "Bash" (Alias.to_public "keeper_bash");
  Alcotest.(check string)
    "keeper_fs_read -> Read"
    "Read"
    (Alias.to_public "keeper_fs_read");
  Alcotest.(check string) "keeper_shell -> Grep" "Grep" (Alias.to_public "keeper_shell");
  (* Edit/Write collapse: first occurrence wins for stability *)
  Alcotest.(check string)
    "keeper_fs_edit -> Edit (first wins)"
    "Edit"
    (Alias.to_public "keeper_fs_edit")
;;

let test_to_public_pass_through () =
  (* Tools without an Anthropic Code cognate should fall through verbatim. *)
  Alcotest.(check string)
    "keeper_board_post passes through"
    "keeper_board_post"
    (Alias.to_public "keeper_board_post");
  Alcotest.(check string)
    "unknown name passes through"
    "anything"
    (Alias.to_public "anything")
;;

let test_canonicalize_observed () =
  let input =
    [ "Bash"; "keeper_board_post"; "masc_board_post"; "Read"; "Skill"; "Write" ]
  in
  let expected =
    [ "keeper_bash"
    ; "keeper_board_post"
    ; "keeper_board_post"
    ; "keeper_fs_read"
    ; "Skill"
    ; "keeper_fs_edit"
    ]
  in
  Alcotest.(check (list string))
    "mixed list canonicalizes only known aliases"
    expected
    (Alias.canonicalize_observed input)
;;

let test_canonicalize_observed_with_telemetry_records_public_masc () =
  let labels =
    [ "alias_kind", "public_masc"
    ; "public_tool", "masc_board_post"
    ; "canonical_tool", "keeper_board_post"
    ]
  in
  let before =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Prometheus.metric_keeper_tool_alias_canonicalizations
      ~labels
      ()
  in
  let canonical = Alias.canonicalize_observed_with_telemetry [ "masc_board_post" ] in
  let after =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Prometheus.metric_keeper_tool_alias_canonicalizations
      ~labels
      ()
  in
  Alcotest.(check (list string))
    "public MASC tool canonicalized"
    [ "keeper_board_post" ]
    canonical;
  Alcotest.(check (float 0.001)) "telemetry counter incremented" (before +. 1.0) after
;;

let test_hallucinated_builtins () =
  Alcotest.(check bool)
    "Skill is hallucinated"
    true
    (Alias.is_hallucinated_builtin "Skill");
  Alcotest.(check bool)
    "Agent is hallucinated"
    true
    (Alias.is_hallucinated_builtin "Agent");
  Alcotest.(check bool)
    "WebSearch is hallucinated"
    true
    (Alias.is_hallucinated_builtin "WebSearch");
  Alcotest.(check bool)
    "Bash is NOT hallucinated (has cognate)"
    false
    (Alias.is_hallucinated_builtin "Bash");
  Alcotest.(check bool)
    "keeper_bash is NOT hallucinated"
    false
    (Alias.is_hallucinated_builtin "keeper_bash")
;;

let test_no_overlap_alias_and_hallucinated () =
  let aliased = List.map fst (Alias.all_aliases ()) in
  List.iter
    (fun b ->
       Alcotest.(check bool)
         (Printf.sprintf "%s must not appear in alias table" b)
         false
         (List.mem b aliased))
    Alias.hallucinated_builtins
;;

let test_alias_table_is_stable () =
  let pairs = Alias.all_aliases () in
  Alcotest.(check int) "six canonical aliases" 6 (List.length pairs);
  (* Round-trip: every alias should round-trip via to_internal then to_public,
     except where collapse happens (Write -> keeper_fs_edit -> Edit). *)
  List.iter
    (fun (public, internal) ->
       Alcotest.(check (option string))
         (Printf.sprintf "%s resolves to %s" public internal)
         (Some internal)
         (Alias.to_internal public))
    pairs
;;

(* ── Phase A.3 integration: canonicalize before the disclosure check ─── *)

(** Mirrors the call sequence in [keeper_agent_run.ml:1875] after
    canonicalization is applied. Pins the contract: a turn whose only
    tool calls are Anthropic Code aliases (Bash/Read/Edit/Grep/Write)
    must NOT produce any unexpected names. *)
let allowed_keeper_surface =
  [ "keeper_bash"
  ; "keeper_fs_read"
  ; "keeper_fs_edit"
  ; "keeper_shell"
  ; "keeper_board_post"
  ; "extend_turns"
  ]
;;

let test_pure_alias_turn_no_longer_unexpected () =
  let observed = [ "Bash" ] in
  let canonical = Alias.canonicalize_observed observed in
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
  let observed = [ "Read"; "keeper_board_post"; "Edit" ] in
  let canonical = Alias.canonicalize_observed observed in
  let unexpected =
    Disclosure.unexpected_tool_names
      ~allowed_tool_names:allowed_keeper_surface
      ~tool_names:canonical
  in
  Alcotest.(check (list string)) "mixed alias + internal -> no unexpected" [] unexpected
;;

let test_hallucinated_builtin_still_unexpected () =
  let observed = [ "Skill"; "Bash" ] in
  let canonical = Alias.canonicalize_observed observed in
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
  let canonical = Alias.canonicalize_observed observed in
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

(* ── Phase A.2 OAS dual registration ─────────────────────────────── *)

let yojson_field name j =
  match j with
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let test_oas_dual_register_subset () =
  let pairs = Alias.oas_dual_register_aliases () in
  let names = List.map fst pairs in
  Alcotest.(check (list string))
    "Phase A.4 dual-reg covers Bash/Edit/Grep/Read/Write"
    [ "Bash"; "Edit"; "Grep"; "Read"; "Write" ]
    names;
  (* Every entry must also appear in the full alias table. *)
  let full = List.map fst (Alias.all_aliases ()) in
  List.iter
    (fun (public, _) ->
       Alcotest.(check bool)
         (Printf.sprintf "%s is in all_aliases" public)
         true
         (List.mem public full))
    pairs
;;

let test_public_input_schema_present () =
  List.iter
    (fun name ->
       Alcotest.(check bool)
         (Printf.sprintf "%s has tailored schema" name)
         true
         (Option.is_some (Alias.public_input_schema name)))
    [ "Bash"; "Edit"; "Grep"; "Read"; "Write" ];
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

let test_expand_universe_adds_aliases () =
  let internal = [ "keeper_bash"; "keeper_fs_read"; "keeper_board_post" ] in
  let expanded = Alias.expand_universe internal in
  Alcotest.(check bool) "Bash appears after expansion" true (List.mem "Bash" expanded);
  Alcotest.(check bool) "Read appears after expansion" true (List.mem "Read" expanded);
  Alcotest.(check bool)
    "internal names preserved"
    true
    (List.for_all (fun n -> List.mem n expanded) internal);
  Alcotest.(check bool)
    "no duplicate Bash entries"
    true
    (List.length (List.filter (String.equal "Bash") expanded) = 1)
;;

let test_expand_universe_skips_when_internal_absent () =
  let internal = [ "keeper_board_post"; "keeper_tasks_list" ] in
  let expanded = Alias.expand_universe internal in
  Alcotest.(check bool)
    "Bash NOT added when keeper_bash absent"
    true
    (not (List.mem "Bash" expanded));
  Alcotest.(check bool)
    "Read NOT added when keeper_fs_read absent"
    true
    (not (List.mem "Read" expanded));
  Alcotest.(check int)
    "expanded length unchanged"
    (List.length internal)
    (List.length expanded)
;;

let test_expand_universe_dedup_existing_public () =
  (* If a caller already has the public name in the input list, expand
     must not duplicate it. *)
  let internal = [ "keeper_bash"; "Bash"; "keeper_fs_read" ] in
  let expanded = Alias.expand_universe internal in
  Alcotest.(check int)
    "Bash appears exactly once"
    1
    (List.length (List.filter (String.equal "Bash") expanded))
;;

let () =
  Alcotest.run
    "Keeper_tool_alias"
    [ ( "alias-table"
      , [ Alcotest.test_case "known aliases resolve" `Quick test_known_aliases_resolve
        ; Alcotest.test_case "unknown returns None" `Quick test_unknown_returns_none
        ; Alcotest.test_case "to_public round-trip" `Quick test_to_public_round_trip
        ; Alcotest.test_case "to_public pass-through" `Quick test_to_public_pass_through
        ; Alcotest.test_case "canonicalize_observed" `Quick test_canonicalize_observed
        ; Alcotest.test_case
            "canonicalize_observed telemetry"
            `Quick
            test_canonicalize_observed_with_telemetry_records_public_masc
        ; Alcotest.test_case "hallucinated builtins" `Quick test_hallucinated_builtins
        ; Alcotest.test_case "no overlap" `Quick test_no_overlap_alias_and_hallucinated
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
    ; ( "oas-dual-register"
      , [ Alcotest.test_case
            "subset is Bash + Read only"
            `Quick
            test_oas_dual_register_subset
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
            "translate unknown is identity"
            `Quick
            test_translate_unknown_is_identity
        ; Alcotest.test_case
            "translate malformed is identity"
            `Quick
            test_translate_malformed_input_is_identity
        ; Alcotest.test_case
            "expand_universe adds aliases"
            `Quick
            test_expand_universe_adds_aliases
        ; Alcotest.test_case
            "expand_universe skips when internal absent"
            `Quick
            test_expand_universe_skips_when_internal_absent
        ; Alcotest.test_case
            "expand_universe dedup existing public"
            `Quick
            test_expand_universe_dedup_existing_public
        ] )
    ]
;;
