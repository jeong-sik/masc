(** Pins the operator surface to the value the server actually applies.

    [Env_config_snapshot] is what [masc_config_*] introspection, the H2 gateway
    and the dashboard answer with when asked what a knob defaults to. It stated
    MASC_HTTP_MAX_CONNECTIONS as 128 while [Http_server_eio] used 512, for the
    three months between #14143 raising the reader and this suite.

    [check-env-snapshot-default-drift.py] catches the same class by comparing
    literals across the two sources. It cannot check this knob any more,
    because the fix was to stop writing a literal on either side — so the
    property is asserted here instead, through the JSON the operator actually
    receives. *)

open Alcotest

let entry_default ~env_name =
  Env_config_snapshot.all_categories ()
  |> List.concat_map (fun (_category, entries) ->
    match entries with
    | `List entries -> entries
    | _ -> [])
  |> List.filter_map (function
    | `Assoc fields ->
      (match List.assoc_opt "env" fields, List.assoc_opt "default" fields with
       | Some (`String name), Some (`String default) when String.equal name env_name ->
         Some default
       | _ -> None)
    | _ -> None)
;;

let test_max_connections_matches_the_server () =
  match entry_default ~env_name:"MASC_HTTP_MAX_CONNECTIONS" with
  | [ reported ] ->
    check
      string
      "the snapshot reports the ceiling the HTTP server applies"
      (string_of_int Masc.Http_server_eio.default_config.Masc.Http_server_eio.max_connections)
      reported
  | [] -> fail "MASC_HTTP_MAX_CONNECTIONS is absent from the operator snapshot"
  | many -> failf "MASC_HTTP_MAX_CONNECTIONS appears %d times" (List.length many)
;;

(* The two sites now name one constant instead of restating a number. This
   fails if either re-inlines a literal. *)
let test_both_sites_name_the_constant () =
  check
    int
    "the reader resolves to the shared constant"
    Masc_network_defaults.masc_http_default_max_connections
    Masc.Http_server_eio.default_config.Masc.Http_server_eio.max_connections;
  check
    string
    "the string form the snapshot uses agrees with the int form"
    (string_of_int Masc_network_defaults.masc_http_default_max_connections)
    Masc_network_defaults.masc_http_default_max_connections_s
;;

(* The host entry is the precedent the fix followed; pinning it keeps the
   example from rotting into a counter-example. *)
let test_host_entry_still_names_its_constant () =
  match entry_default ~env_name:"MASC_HTTP_HOST" with
  | [ reported ] ->
    check
      string
      "the snapshot reports the host constant"
      Masc_network_defaults.masc_http_default_host
      reported
  | [] -> fail "MASC_HTTP_HOST is absent from the operator snapshot"
  | many -> failf "MASC_HTTP_HOST appears %d times" (List.length many)
;;

let test_base_path_lease_directory_is_visible () =
  match entry_default ~env_name:"MASC_BASE_PATH_LEASE_DIR" with
  | [ reported ] ->
    check
      string
      "the snapshot reports the host run-directory fallback"
      "(host temp directory)"
      reported
  | [] -> fail "MASC_BASE_PATH_LEASE_DIR is absent from the operator snapshot"
  | many -> failf "MASC_BASE_PATH_LEASE_DIR appears %d times" (List.length many)
;;

let test_collector_reads_environment_once () =
  let reads = ref 0 in
  let getenv name =
    incr reads;
    if String.equal name "MASC_TEST_SNAPSHOT_VALUE" then Some "  resolved  " else None
  in
  let collector =
    Env_config_snapshot_collector.entry
      ~getenv
      ~default:"fallback"
      "MASC_TEST_SNAPSHOT_VALUE"
      "test value"
  in
  let json = Env_config_snapshot_collector.to_json collector in
  check int "one boundary read" 1 !reads;
  check
    string
    "pure projection receives the trimmed observed value"
    "resolved"
    Yojson.Safe.Util.(json |> member "value" |> to_string)
;;

let test_pure_projection_redacts_explicit_observation () =
  let spec =
    Env_config_snapshot_core.make_spec
      ~sensitive:true
      ~default:"(none)"
      "MASC_TEST_SNAPSHOT_TOKEN"
      "test token"
  in
  let json =
    Env_config_snapshot_core.to_json
      spec
      (Env_config_snapshot_core.Applied_value
         { value = "secret-value"; source = Env_config_snapshot_core.Environment })
  in
  check
    string
    "core redacts the supplied value"
    "[REDACTED]"
    Yojson.Safe.Util.(json |> member "value" |> to_string);
  check
    string
    "core preserves applied provenance"
    "env"
    Yojson.Safe.Util.(json |> member "source" |> to_string)
;;

let () =
  run
    "env snapshot reports the applied default"
    [ ( "http server"
      , [ test_case
            "max connections matches the server"
            `Quick
            test_max_connections_matches_the_server
        ; test_case "both sites name one constant" `Quick test_both_sites_name_the_constant
        ; test_case
            "the host precedent still holds"
            `Quick
            test_host_entry_still_names_its_constant
        ; test_case
            "base path lease directory is visible"
            `Quick
            test_base_path_lease_directory_is_visible
        ; test_case
            "collector reads environment once"
            `Quick
            test_collector_reads_environment_once
        ; test_case
            "pure projection redacts explicit observations"
            `Quick
            test_pure_projection_redacts_explicit_observation
        ] )
    ]
;;
