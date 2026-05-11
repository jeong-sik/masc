(** #10259 — degraded fallback for the keeper cascade-name validator.

    Pre-fix, when [Cascade_toml_materializer] hit a strict
    field-whitelist error (a single "unknown field X in profile Y"),
    [Cascade_config_loader.load_catalog] failed end-to-end and the
    keeper-name validator collapsed to the compile-time
    [reserved_cascade_names] list (5 names).  Operator-defined
    cascades like [ollama_only] were rejected fleet-wide, even though
    [cascade.toml] itself parsed fine and [ollama_only] was a
    perfectly visible top-level table.

    These tests pin that:

    1. {!Cascade_toml_materializer.toml_section_names_result} returns
       the top-level table keys when a TOML is parseable, regardless
       of whether any inner field would fail strict materialization.
    2. Meta-keys (anything starting with ['_']) are filtered.
    3. Non-table top-level keys (scalars, arrays) are filtered.
    4. {!Keeper_cascade_profile.catalog_names_with_toml_fallback}
       prefers the live catalog when available and tags the source.
    5. When a strict materializer regression is simulated by feeding
       in a JSON catalog whose contents disagree with the TOML, the
       degraded fallback still names the TOML sections and tags the
       provenance for the WARN log. *)

open Alcotest
module M = Masc_mcp.Cascade_toml_materializer
module K = Masc_mcp.Keeper_cascade_profile

let temp_dir () =
  let path = Filename.temp_file "cascade_section_fallback_10259_" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_dir f =
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if n_len = 0 then true
    else if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  loop 0

(* --- toml_section_names_result core contract ----------------------- *)

let test_section_names_basic () =
  with_temp_dir @@ fun dir ->
  let toml_path = Filename.concat dir "cascade.toml" in
  let json_path = Filename.concat dir "cascade.json" in
  write_file toml_path
    {|
[ollama_only]
strategy = "weighted_random"
keeper_assignable = true

[big_three]
strategy = "first_success"

[tool_use_strict]
strategy = "weighted_random"
|};
  match M.toml_section_names_result ~config_path:json_path with
  | Error e -> fail ("expected Ok, got Error: " ^ e)
  | Ok names ->
      let sorted = List.sort String.compare names in
      check (list string) "all top-level sections returned"
        [ "big_three"; "ollama_only"; "tool_use_strict" ]
        sorted

let test_section_names_filters_meta_keys () =
  (* Meta-keys (leading underscore) and scalar / array top-level keys
     must NOT appear as cascade section names. *)
  with_temp_dir @@ fun dir ->
  let toml_path = Filename.concat dir "cascade.toml" in
  let json_path = Filename.concat dir "cascade.json" in
  write_file toml_path
    {|
_schema = "1"
_revision = 7

allowed_environments = ["dev", "prod"]

[_comment_doc]
note = "this section is documentation"

[ollama_only]
strategy = "weighted_random"

[big_three]
strategy = "first_success"
|};
  match M.toml_section_names_result ~config_path:json_path with
  | Error e -> fail ("expected Ok, got Error: " ^ e)
  | Ok names ->
      let sorted = List.sort String.compare names in
      check (list string)
        "scalars / arrays / _-prefixed sections all filtered"
        [ "big_three"; "ollama_only" ]
        sorted

let test_section_names_survives_unknown_field () =
  (* The exact regression class from #10259: a profile that strict
     materialization would reject (unknown field) must still surface
     as a top-level section name in the lenient fallback.  This
     simulates the materializer crash root-cause without depending on
     the strict path. *)
  with_temp_dir @@ fun dir ->
  let toml_path = Filename.concat dir "cascade.toml" in
  let json_path = Filename.concat dir "cascade.json" in
  write_file toml_path
    {|
[ollama_only]
strategy = "weighted_random"
this_field_is_unknown_to_strict_pass = "irrelevant"

[big_three]
strategy = "first_success"
|};
  match M.toml_section_names_result ~config_path:json_path with
  | Error e -> fail ("expected Ok despite strict-unknown field, got: " ^ e)
  | Ok names ->
      let sorted = List.sort String.compare names in
      check (list string)
        "lenient fallback survives strict-rejected inner field"
        [ "big_three"; "ollama_only" ]
        sorted

(* --- json-only source: empty result, no error --------------------- *)

let test_json_only_source_returns_empty () =
  with_temp_dir @@ fun dir ->
  let json_path = Filename.concat dir "cascade.json" in
  write_file json_path {|{ "_schema": "1", "ollama_only_models": [] }|};
  match M.toml_section_names_result ~config_path:json_path with
  | Error e -> fail ("expected Ok [], got Error: " ^ e)
  | Ok names ->
      check (list string) "json-only source yields empty list" [] names

(* --- malformed TOML -> Error ------------------------------------- *)

let test_malformed_toml_yields_error () =
  with_temp_dir @@ fun dir ->
  let toml_path = Filename.concat dir "cascade.toml" in
  let json_path = Filename.concat dir "cascade.json" in
  write_file toml_path "[unterminated";
  match M.toml_section_names_result ~config_path:json_path with
  | Ok _ -> fail "expected Error on malformed TOML"
  | Error _ -> ()

(* --- catalog_names_with_toml_fallback live path ------------------- *)

let test_with_toml_fallback_live_path () =
  (* When the strict catalog loads fine, the helper must report
     [Live_catalog] and skip the lenient pass entirely. *)
  with_temp_dir @@ fun dir ->
  let toml_path = Filename.concat dir "cascade.toml" in
  let json_path = Filename.concat dir "cascade.json" in
  write_file toml_path
    {|
[ollama_only]
strategy = "weighted_random"
keeper_assignable = true
models = ["ollama:llama3"]
temperature = 0.7
max_tokens = 8192
|};
  (* RFC-0058 §9 Phase 9.3: the strict loader now renders TOML in
     memory via [Cascade_config_loader.load_toml_in_memory], so no
     on-disk cascade.json materialisation is needed. The [json_path]
     variable is only used as the config-path argument because
     [source_info] detects the TOML sibling automatically. *)
  match K.catalog_names_with_toml_fallback ~config_path:json_path () with
  | Error e -> fail ("expected Ok, got Error: " ^ e)
  | Ok (names, source) ->
      check bool "ollama_only in live catalog" true
        (List.mem "ollama_only" names);
      (match source with
       | K.Live_catalog -> ()
       | K.Toml_section_fallback _ ->
         fail "expected Live_catalog tag when strict catalog loads")

(* --- catalog_names_with_toml_fallback degraded path --------------- *)

let test_with_toml_fallback_degraded_path () =
  (* Simulate the #10259 condition: TOML is parseable and contains
     [ollama_only], but the strict catalog cannot be produced because
     no [cascade.json] exists at the requested path AND we point to a
     directory where strict materialization would also fail.  Use a
     TOML the lenient parser can read but with a structure shape that
     [Cascade_config_loader] won't accept (missing required scaffolding
     fields).  The lenient fallback should still name the sections. *)
  with_temp_dir @@ fun dir ->
  let toml_path = Filename.concat dir "cascade.toml" in
  let json_path = Filename.concat dir "cascade.json" in
  write_file toml_path
    {|
[ollama_only]
strategy = "weighted_random"
unknown_field_breaks_strict = "yes"

[big_three]
strategy = "first_success"
unknown_field_breaks_strict = "yes"
|};
  (* Do NOT materialize — let the strict loader fail. *)
  match K.catalog_names_with_toml_fallback ~config_path:json_path () with
  | Error e ->
      fail
        (Printf.sprintf
           "degraded fallback should succeed when TOML is parseable: %s"
           e)
  | Ok (names, source) ->
      let sorted = List.sort String.compare names in
      check (list string)
        "degraded fallback enumerates TOML sections"
        [ "big_three"; "ollama_only" ] sorted;
      (match source with
       | K.Live_catalog ->
         fail "expected Toml_section_fallback when strict load fails"
       | K.Toml_section_fallback { catalog_error } ->
           check bool
             "catalog_error message preserved for WARN logging"
             true
             (String.length catalog_error > 0))

let test_with_toml_fallback_empty_degraded_path_errors () =
  (* Strict failure plus an empty fallback name list is not a degraded
     success.  Without this guard the keeper-name validator can receive
     [Ok []] and collapse the real catalog failure into a silent
     accept-list bug. *)
  with_temp_dir @@ fun dir ->
  let json_path = Filename.concat dir "cascade.json" in
  match K.catalog_names_with_toml_fallback ~config_path:json_path () with
  | Ok (names, _) ->
      fail
        (Printf.sprintf "expected Error for empty fallback, got names: [%s]"
           (String.concat ", " names))
  | Error msg ->
      check bool "error names empty fallback" true
        (contains_substring msg "returned no cascade profile names")

let () =
  run "cascade_toml_section_fallback_10259"
    [
      ( "section-names",
        [
          test_case "basic top-level enumeration" `Quick
            test_section_names_basic;
          test_case "filters meta-keys, scalars, arrays" `Quick
            test_section_names_filters_meta_keys;
          test_case "survives strict-unknown inner field" `Quick
            test_section_names_survives_unknown_field;
          test_case "json-only source yields empty list" `Quick
            test_json_only_source_returns_empty;
          test_case "malformed toml yields error" `Quick
            test_malformed_toml_yields_error;
        ] );
      ( "validator-fallback",
        [
          test_case "live path uses Live_catalog tag" `Quick
            test_with_toml_fallback_live_path;
          test_case "degraded path uses Toml_section_fallback tag"
            `Quick test_with_toml_fallback_degraded_path;
          test_case "empty degraded fallback errors" `Quick
            test_with_toml_fallback_empty_degraded_path_errors;
        ] );
    ]
