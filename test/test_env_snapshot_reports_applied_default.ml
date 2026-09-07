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

(* Every knob [Env_setting] declares must reach this JSON.

   The first shape of this tried a registry filled at declaration time. OCaml
   links only the modules a binary references, so this executable never linked
   the declaring module and the catalogue reported nothing -- this case is what
   caught it. The declarations are a closed vocabulary now, which is why the
   list is complete regardless of what a binary happens to link. *)
let reported_env_names () =
  Env_config_snapshot.all_categories ()
  |> List.concat_map (fun (_category, entries) ->
    match entries with
    | `List entries -> entries
    | _ -> [])
  |> List.filter_map (function
    | `Assoc fields ->
      (match List.assoc_opt "env" fields with
       | Some (`String name) -> Some name
       | _ -> None)
    | _ -> None)
;;

(* A knob moved into [Env_setting] whose hand-written row was not deleted is
   reported twice. Writing this slice did exactly that: MASC_WEB_SEARCH_* were
   already declared in Keeper_runtime_setting_registry, and declaring them again
   put two rows in front of the operator. Arithmetic caught it -- nine
   declarations moved the gap by seven -- which is not a check. *)
let test_no_declaration_is_reported_twice () =
  let reported = reported_env_names () in
  let counted name = List.length (List.filter (String.equal name) reported) in
  let duplicated =
    Env_setting.all_rows
    |> List.filter_map (fun (row : Env_setting.row) ->
      let n = counted row.env_name in
      if n > 1 then Some (Printf.sprintf "%s x%d" row.env_name n) else None)
  in
  check (list string) "declared knobs the snapshot reports more than once" [] duplicated
;;

(* [reported_env_names] answers what is reported; this answers where, and with
   what default, because that is what duplicated rows disagree about. *)
let reported_rows () =
  Env_config_snapshot.all_categories ()
  |> List.concat_map (fun (category, entries) ->
    match entries with
    | `List entries ->
      entries
      |> List.filter_map (function
        | `Assoc fields ->
          (match List.assoc_opt "env" fields with
           | Some (`String name) ->
             let default =
               match List.assoc_opt "default" fields with
               | Some (`String d) -> d
               | _ -> ""
             in
             Some (category, name, default)
           | _ -> None)
        | _ -> None)
    | _ -> [])
;;

(* The check above walks [Env_setting.all_rows] only, so a knob that reaches the
   catalogue by module constant or by the feature-flag registry could be listed
   twice without failing anything. Four log/telemetry knobs were: both
   [runtime_entries] and [telemetry_entries] land in the "runtime" category, so
   an operator read the same row twice in one section. *)
let test_no_category_lists_a_knob_twice () =
  let rows = reported_rows () in
  let duplicated =
    rows
    |> List.filter_map (fun (category, name, _) ->
      let n =
        List.length
          (List.filter
             (fun (c, e, _) -> String.equal c category && String.equal e name)
             rows)
      in
      if n > 1 then Some (Printf.sprintf "%s in %s x%d" name category n) else None)
    |> List.sort_uniq String.compare
  in
  check (list string) "knobs a category lists more than once" [] duplicated
;;

(* A knob an operator finds in two sections must not answer "what happens when I
   leave this unset" differently in each. MASC_LOG_LEVEL said "(auto)" in one row
   and "(none)" in the other while the reader leaves the level at info. *)
let test_shared_knobs_agree_on_default () =
  let rows = reported_rows () in
  let names = rows |> List.map (fun (_, n, _) -> n) |> List.sort_uniq String.compare in
  let disagreeing =
    names
    |> List.filter_map (fun name ->
      let defaults =
        rows
        |> List.filter_map (fun (_, n, d) ->
          if String.equal n name then Some d else None)
        |> List.sort_uniq String.compare
      in
      match defaults with
      | _ :: _ :: _ ->
        Some (Printf.sprintf "%s: %s" name (String.concat " | " defaults))
      | _ -> None)
  in
  check (list string) "knobs reported with more than one default" [] disagreeing
;;

let test_declarations_reach_the_operator_surface () =
  let declared = Env_setting.all_rows in
  check bool "at least one knob is declared" true (declared <> []);
  let reported = reported_env_names () in
  let missing =
    declared
    |> List.filter (fun (row : Env_setting.row) ->
      not (List.exists (String.equal row.env_name) reported))
    |> List.map (fun (row : Env_setting.row) -> row.env_name)
  in
  check (list string) "declared knobs the snapshot omits" [] missing
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
        ; test_case
            "declarations reach the operator surface"
            `Quick
            test_declarations_reach_the_operator_surface
        ; test_case
            "no declaration is reported twice"
            `Quick
            test_no_declaration_is_reported_twice
        ; test_case
            "no category lists a knob twice"
            `Quick
            test_no_category_lists_a_knob_twice
        ; test_case
            "knobs shared by two sections agree on the default"
            `Quick
            test_shared_knobs_agree_on_default
        ] )
    ]
;;
