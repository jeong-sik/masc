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
        ] )
    ]
;;
