(** Env_config Module Coverage Tests

    Tests for MASC Environment Configuration:
    - get_string, get_int, get_float, get_bool: env var readers
    - Zombie, Lock, Session, Tempo, Orchestrator, Cancellation modules
*)

open Alcotest

module Env_config = Env_config

let with_env name value fn =
  let previous = Sys.getenv_opt name in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some original -> Unix.putenv name original
      | None -> Unix.putenv name "")
    (fun () ->
      Unix.putenv name value;
      fn ())

(* ============================================================
   get_string Tests
   ============================================================ *)

let test_get_string_default () =
  let result = Env_config.get_string ~default:"fallback" "NONEXISTENT_VAR_XYZ_12345" in
  check string "default" "fallback" result

let test_get_string_empty_default () =
  let result = Env_config.get_string ~default:"" "NONEXISTENT_VAR_XYZ_12345" in
  check string "empty default" "" result

(* ============================================================
   get_int Tests
   ============================================================ *)

let test_get_int_default () =
  let result = Env_config.get_int ~default:42 "NONEXISTENT_VAR_XYZ_12345" in
  check int "default" 42 result

let test_get_int_negative_default () =
  let result = Env_config.get_int ~default:(-10) "NONEXISTENT_VAR_XYZ_12345" in
  check int "negative default" (-10) result

let test_get_int_zero_default () =
  let result = Env_config.get_int ~default:0 "NONEXISTENT_VAR_XYZ_12345" in
  check int "zero default" 0 result

(* ============================================================
   get_float Tests
   ============================================================ *)

let test_get_float_default () =
  let result = Env_config.get_float ~default:3.14 "NONEXISTENT_VAR_XYZ_12345" in
  check (float 0.001) "default" 3.14 result

let test_get_float_negative_default () =
  let result = Env_config.get_float ~default:(-2.5) "NONEXISTENT_VAR_XYZ_12345" in
  check (float 0.001) "negative default" (-2.5) result

let test_get_float_zero_default () =
  let result = Env_config.get_float ~default:0.0 "NONEXISTENT_VAR_XYZ_12345" in
  check (float 0.001) "zero default" 0.0 result

(* ============================================================
   get_bool Tests
   ============================================================ *)

let test_get_bool_default_true () =
  let result = Env_config.get_bool ~default:true "NONEXISTENT_VAR_XYZ_12345" in
  check bool "default true" true result

let test_get_bool_default_false () =
  let result = Env_config.get_bool ~default:false "NONEXISTENT_VAR_XYZ_12345" in
  check bool "default false" false result

(* ============================================================
   Transport / Board Variant Parsing Tests
   ============================================================ *)

let test_transport_use_h2_parses_h2_only_variant () =
  with_env "MASC_USE_H2" " TRUE " (fun () ->
    check string "normalized h2 mode" "h2_only"
      (Env_config.Transport.use_h2 ()
       |> Env_config.Transport.h2_mode_to_string))

let test_transport_use_h2_preserves_unknown_variant_tag () =
  with_env "MASC_USE_H2" "experimental" (fun () ->
    match Env_config.Transport.use_h2 () with
    | Env_config.Transport.Unknown_h2_mode "experimental" -> ()
    | other ->
        fail
          (Printf.sprintf "expected unknown h2 mode, got %s"
             (Env_config.Transport.h2_mode_to_string other)))

let test_agent_transport_opt_parses_alias_variant () =
  with_env "MASC_AGENT_TRANSPORT" " WebSocket " (fun () ->
    match Env_config.Transport.agent_transport_opt () with
    | Some Env_config.Transport.Ws -> ()
    | Some other ->
        fail
          (Printf.sprintf "expected ws transport, got %s"
             (Env_config.Transport.agent_transport_to_string other))
    | None -> fail "expected Some transport")

let test_board_backend_opt_parses_variant () =
  with_env "MASC_BOARD_BACKEND" " PG " (fun () ->
    match Env_config.Board.backend_opt () with
    | Some Env_config.Board.Pg -> ()
    | Some other ->
        fail
          (Printf.sprintf "expected pg backend, got %s"
             (Env_config.Board.backend_to_string other))
    | None -> fail "expected Some backend")

let test_base_path_prefers_env () =
  with_env "MASC_BASE_PATH" "/tmp/masc-custom-root" (fun () ->
    check (option string) "base_path_opt" (Some "/tmp/masc-custom-root")
      (Env_config.base_path_opt ());
    check string "base_path" "/tmp/masc-custom-root" (Env_config.base_path ()))

let test_base_path_collapses_masc_dir_env () =
  with_env "MASC_BASE_PATH" "/tmp/masc-custom-root/.masc" (fun () ->
    check (option string) "raw base path keeps original env"
      (Some "/tmp/masc-custom-root/.masc")
      (Env_config.base_path_raw_opt ());
    check (option string) "base_path_opt collapses .masc leaf"
      (Some "/tmp/masc-custom-root")
      (Env_config.base_path_opt ());
    check string "base_path collapses .masc leaf"
      "/tmp/masc-custom-root" (Env_config.base_path ()))

(* ============================================================
   base_path HOME fallback Tests
   ============================================================ *)

let test_base_path_falls_back_to_home () =
  with_env "MASC_BASE_PATH" "" (fun () ->
    with_env "MASC_BASE_PATH_INPUT" "" (fun () ->
      with_env "HOME" "/home/testuser" (fun () ->
        check string "base_path falls back to HOME" "/home/testuser"
          (Env_config.base_path ()))))

let test_base_path_falls_back_to_dot_when_no_home () =
  with_env "MASC_BASE_PATH" "" (fun () ->
    with_env "MASC_BASE_PATH_INPUT" "" (fun () ->
      with_env "HOME" "" (fun () ->
        check string "base_path falls back to dot" "."
          (Env_config.base_path ()))))

let test_base_path_env_wins_over_home () =
  with_env "MASC_BASE_PATH" "/opt/masc" (fun () ->
    with_env "MASC_BASE_PATH_INPUT" "" (fun () ->
      with_env "HOME" "/home/testuser" (fun () ->
        check string "MASC_BASE_PATH wins over HOME" "/opt/masc"
          (Env_config.base_path ()))))

let test_base_path_home_with_masc_leaf_collapsed () =
  with_env "MASC_BASE_PATH" "" (fun () ->
    with_env "MASC_BASE_PATH_INPUT" "" (fun () ->
      with_env "HOME" "/home/testuser/.masc" (fun () ->
        check string "HOME .masc leaf collapsed" "/home/testuser"
          (Env_config.base_path ()))))

let test_base_path_raw_prefers_preserved_input_env () =
  with_env "MASC_BASE_PATH_INPUT" "/tmp/masc-custom-root/.masc" (fun () ->
    with_env "MASC_BASE_PATH" "/tmp/masc-custom-root" (fun () ->
      check (option string) "base_path_raw_opt prefers preserved input env"
        (Some "/tmp/masc-custom-root/.masc")
        (Env_config.base_path_raw_opt ());
      begin
        match Env_config.base_path_source_opt () with
        | Some (name, value) ->
            check string "base_path_source_opt prefers preserved input env name"
              "MASC_BASE_PATH_INPUT" name;
            check string "base_path_source_opt prefers preserved input env value"
              "/tmp/masc-custom-root/.masc" value
        | None -> fail "expected base_path_source_opt"
      end;
      check (option string) "base_path_opt still returns normalized path"
        (Some "/tmp/masc-custom-root")
        (Env_config.base_path_opt ());
      check string "base_path stays normalized"
        "/tmp/masc-custom-root" (Env_config.base_path ())))

let test_masc_http_base_url_prefers_env_and_trims () =
  with_env "MASC_HTTP_BASE_URL" "http://example.test:9911/" (fun () ->
    check (result string string) "base url result trimmed"
      (Ok "http://example.test:9911")
      (Env_config.masc_http_base_url_result ());
    check string "base url trimmed" "http://example.test:9911" (Env_config.masc_http_base_url ()))

let test_masc_http_base_url_uses_explicit_host_and_port () =
  with_env "MASC_HTTP_BASE_URL" "" (fun () ->
    with_env "MASC_HOST" "masc.example.test" (fun () ->
      with_env "MASC_HTTP_PORT" "7777" (fun () ->
        check (result string string) "base url result from host+port"
          (Ok "http://masc.example.test:7777")
          (Env_config.masc_http_base_url_result ());
        check string "base url from host+port" "http://masc.example.test:7777" (Env_config.masc_http_base_url ()))))

let test_server_bootstrap_http_sets_runtime_mcp_url () =
  with_env Env_config_core.http_base_url_env_key "https://public.example" (fun () ->
    with_env Env_config_runtime.Local_runtime.mcp_url_env_key
      "http://127.0.0.1:8935/mcp"
      (fun () ->
        ignore
          (Masc_mcp.Server_bootstrap_http.make_http_config
             ~host:"0.0.0.0" ~port:7777);
        check string "base url preserved when explicitly provided"
          "https://public.example" (Env_config.masc_http_base_url ());
        check string "runtime MCP URL updated to active bind"
          "http://127.0.0.1:7777/mcp"
          (Env_config_runtime.Local_runtime.mcp_url ())))

let test_sb_path_result_missing_is_error () =
  with_env "MASC_BASE_PATH" "" (fun () ->
    check bool "sb path result is error" true
      (match Env_config.sb_path_result () with Error _ -> true | Ok _ -> false))

let test_masc_host_prefers_primary_over_deprecated () =
  with_env "MASC_HOST" "primary.example.test" (fun () ->
    let resolved = Env_config.masc_host () in
    let explicit = Env_config.masc_host_opt () in
    check string "primary host wins" "primary.example.test" resolved;
    check (option string) "explicit host wins" (Some "primary.example.test")
      explicit)

let test_assets_dir_prefers_primary_over_deprecated () =
  with_env "MASC_ASSETS_DIR" "/tmp/assets-primary" (fun () ->
    let resolved = Env_config.assets_dir_opt () in
    check (option string) "primary assets dir wins" (Some "/tmp/assets-primary")
      resolved)

let test_cluster_name_opt_trims_empty () =
  with_env "MASC_CLUSTER_NAME" "   " (fun () ->
    check (option string) "cluster_name_opt empty -> none" None
      (Env_config.cluster_name_opt ());
    check string "cluster_name empty -> default" "default"
      (Env_config.cluster_name ()))

let find_config_entry json env_name =
  let open Yojson.Safe.Util in
  json
  |> member "categories"
  |> to_assoc
  |> List.to_seq
  |> Seq.flat_map (fun (_category, value) ->
         match value with
         | `List entries -> List.to_seq entries
         | _ -> Seq.empty)
  |> Seq.find
       (fun entry ->
         String.equal (entry |> member "env" |> to_string) env_name)
  |> function
  | Some entry -> entry
  | None -> failwith ("missing config entry: " ^ env_name)

let test_to_json_uses_canonical_introspection_shape () =
  let json = Env_config.to_json () in
  check bool "server meta omitted on config wrapper" true
    (Yojson.Safe.Util.member "server" json = `Null);
  check bool "categories exist" true
    (match Yojson.Safe.Util.member "categories" json with
    | `Assoc _ -> true
    | _ -> false)

let test_to_json_masks_sensitive_values_and_tracks_sources () =
  with_env "MASC_ADMIN_TOKEN" "super-secret-token" (fun () ->
      let json = Env_config.to_json () in
      let entry = find_config_entry json "MASC_ADMIN_TOKEN" in
      let open Yojson.Safe.Util in
      check string "source is env" "env" (entry |> member "source" |> to_string);
      check string "source detail names env" "environment variable MASC_ADMIN_TOKEN"
        (entry |> member "source_detail" |> to_string);
      check string "provenance kind is env" "env"
        (entry |> member "provenance" |> member "kind" |> to_string);
      check string "provenance env names source var" "MASC_ADMIN_TOKEN"
        (entry |> member "provenance" |> member "env" |> to_string);
      check string "provenance raw source is environment" "environment"
        (entry |> member "provenance" |> member "raw_source" |> to_string);
      check bool "provenance notes env presence" true
        (entry |> member "provenance" |> member "raw_env_present" |> to_bool);
      check bool "provenance notes env is not blank" false
        (entry |> member "provenance" |> member "raw_env_blank" |> to_bool);
      check bool "provenance notes redaction" true
        (entry |> member "provenance" |> member "value_redacted" |> to_bool);
      check bool "marked sensitive" true (entry |> member "sensitive" |> to_bool);
      check string "masked token" "supe***"
        (entry |> member "value" |> to_string))

let test_to_json_treats_blank_env_as_default () =
  with_env "MASC_ADMIN_TOKEN" "   " (fun () ->
      let json = Env_config.to_json () in
      let entry = find_config_entry json "MASC_ADMIN_TOKEN" in
      let open Yojson.Safe.Util in
      check string "blank source is default" "default"
        (entry |> member "source" |> to_string);
      check bool "blank provenance preserves env presence" true
        (entry |> member "provenance" |> member "raw_env_present" |> to_bool);
      check bool "blank provenance marks blank env" true
        (entry |> member "provenance" |> member "raw_env_blank" |> to_bool);
      check string "blank provenance raw source falls back" "compiled_default"
        (entry |> member "provenance" |> member "raw_source" |> to_string);
      check bool "blank value omitted" true (entry |> member "value" = `Null))

let test_to_json_exposes_derived_and_runtime_provenance () =
  with_env "MASC_HTTP_BASE_URL" "   " (fun () ->
      with_env Env_config.base_path_env_key "   " (fun () ->
          let json = Env_config.to_json () in
          let base_url = find_config_entry json "MASC_HTTP_BASE_URL" in
          let base_path = find_config_entry json Env_config.base_path_env_key in
          let open Yojson.Safe.Util in
          check string "derived source" "derived"
            (base_url |> member "source" |> to_string);
          check string "derived provenance kind" "derived"
            (base_url |> member "provenance" |> member "kind" |> to_string);
          check string "derived provenance raw source" "derived_runtime"
            (base_url |> member "provenance" |> member "raw_source" |> to_string);
          check string "runtime source" "runtime"
            (base_path |> member "source" |> to_string);
          check string "runtime provenance kind" "runtime"
            (base_path |> member "provenance" |> member "kind" |> to_string);
          check string "runtime provenance raw source" "runtime"
            (base_path |> member "provenance" |> member "raw_source" |> to_string)))

(* ============================================================
   print_summary Tests
   ============================================================ *)

let test_print_summary_no_error () =
  Env_config.print_summary ();
  ()

(* ============================================================
   KeeperCascade.provider_allowlist Tests
   Iteration 1 runtime knob: MASC_KEEPER_CASCADE_PROVIDER_ALLOWLIST
   ============================================================ *)

let test_cascade_allowlist_blank_is_none () =
  with_env "MASC_KEEPER_CASCADE_PROVIDER_ALLOWLIST" "" (fun () ->
    let result = Env_config.KeeperCascade.provider_allowlist () in
    check (option (list string)) "blank env is None" None result)

let test_cascade_allowlist_whitespace_only_is_none () =
  with_env "MASC_KEEPER_CASCADE_PROVIDER_ALLOWLIST" "   " (fun () ->
    let result = Env_config.KeeperCascade.provider_allowlist () in
    check (option (list string)) "whitespace-only is None" None result)

let test_cascade_allowlist_single () =
  with_env "MASC_KEEPER_CASCADE_PROVIDER_ALLOWLIST" "ollama" (fun () ->
    let result = Env_config.KeeperCascade.provider_allowlist () in
    check (option (list string)) "single provider" (Some [ "ollama" ]) result)

let test_cascade_allowlist_multi () =
  with_env "MASC_KEEPER_CASCADE_PROVIDER_ALLOWLIST" "ollama,glm" (fun () ->
    let result = Env_config.KeeperCascade.provider_allowlist () in
    check (option (list string)) "multiple providers"
      (Some [ "ollama"; "glm" ]) result)

let test_cascade_allowlist_trims_whitespace () =
  with_env "MASC_KEEPER_CASCADE_PROVIDER_ALLOWLIST" " ollama , glm " (fun () ->
    let result = Env_config.KeeperCascade.provider_allowlist () in
    check (option (list string)) "entries are trimmed"
      (Some [ "ollama"; "glm" ]) result)

let test_cascade_allowlist_drops_empty_entries () =
  with_env "MASC_KEEPER_CASCADE_PROVIDER_ALLOWLIST" "ollama,,glm,,"
    (fun () ->
      let result = Env_config.KeeperCascade.provider_allowlist () in
      check (option (list string)) "empty entries dropped"
        (Some [ "ollama"; "glm" ]) result)

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Env_config Coverage" [
    "get_string", [
      test_case "default" `Quick test_get_string_default;
      test_case "empty default" `Quick test_get_string_empty_default;
    ];
    "get_int", [
      test_case "default" `Quick test_get_int_default;
      test_case "negative default" `Quick test_get_int_negative_default;
      test_case "zero default" `Quick test_get_int_zero_default;
    ];
    "get_float", [
      test_case "default" `Quick test_get_float_default;
      test_case "negative default" `Quick test_get_float_negative_default;
      test_case "zero default" `Quick test_get_float_zero_default;
    ];
    "get_bool", [
      test_case "default true" `Quick test_get_bool_default_true;
      test_case "default false" `Quick test_get_bool_default_false;
    ];
    "transport_variants", [
      test_case "use_h2 parses h2_only" `Quick
        test_transport_use_h2_parses_h2_only_variant;
      test_case "use_h2 preserves unknown" `Quick
        test_transport_use_h2_preserves_unknown_variant_tag;
      test_case "agent transport parses alias" `Quick
        test_agent_transport_opt_parses_alias_variant;
      test_case "board backend parses variant" `Quick
        test_board_backend_opt_parses_variant;
    ];
    "path_helpers", [
      test_case "base_path prefers env" `Quick test_base_path_prefers_env;
      test_case "base_path collapses .masc env input" `Quick
        test_base_path_collapses_masc_dir_env;
      test_case "base_path raw prefers preserved input env" `Quick
        test_base_path_raw_prefers_preserved_input_env;
      test_case "base url prefers env and trims" `Quick test_masc_http_base_url_prefers_env_and_trims;
      test_case "base url uses explicit host+port" `Quick test_masc_http_base_url_uses_explicit_host_and_port;
      test_case "server bootstrap sets runtime MCP URL" `Quick
        test_server_bootstrap_http_sets_runtime_mcp_url;
      test_case "sb_path_result missing is error" `Quick test_sb_path_result_missing_is_error;
      test_case "masc_host reads primary env" `Quick test_masc_host_prefers_primary_over_deprecated;
      test_case "assets dir reads primary env" `Quick test_assets_dir_prefers_primary_over_deprecated;
      test_case "cluster_name_opt trims empty" `Quick test_cluster_name_opt_trims_empty;
      test_case "to_json uses canonical introspection shape" `Quick
        test_to_json_uses_canonical_introspection_shape;
      test_case "to_json masks sensitive values and tracks sources" `Quick
        test_to_json_masks_sensitive_values_and_tracks_sources;
      test_case "to_json treats blank env as default" `Quick
        test_to_json_treats_blank_env_as_default;
      test_case "to_json exposes derived and runtime provenance" `Quick
        test_to_json_exposes_derived_and_runtime_provenance;
    ];
    "print_summary", [
      test_case "no error" `Quick test_print_summary_no_error;
    ];
    "keeper_cascade_provider_allowlist", [
      test_case "blank env is None" `Quick test_cascade_allowlist_blank_is_none;
      test_case "whitespace-only is None" `Quick
        test_cascade_allowlist_whitespace_only_is_none;
      test_case "single provider" `Quick test_cascade_allowlist_single;
      test_case "multiple providers" `Quick test_cascade_allowlist_multi;
      test_case "entries are trimmed" `Quick test_cascade_allowlist_trims_whitespace;
      test_case "empty entries dropped" `Quick
        test_cascade_allowlist_drops_empty_entries;
    ];
  ]
