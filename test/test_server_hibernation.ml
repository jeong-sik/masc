open Alcotest

let member name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some value -> value
     | None -> failf "missing field %s" name)
  | _ -> fail "expected JSON object"
;;

let string_field name json =
  match member name json with
  | `String value -> value
  | _ -> failf "field %s is not a string" name
;;

let bool_field name json =
  match member name json with
  | `Bool value -> value
  | _ -> failf "field %s is not a bool" name
;;

let test_status_contract () =
  let json = Server_hibernation.status_json () in
  check string "schema" "masc.server_hibernation.v1" (string_field "schema" json);
  check string "status" "not_implemented" (string_field "status" json);
  check string "mode" "long_running" (string_field "mode" json);
  check bool "scale-to-zero unsupported" false
    (bool_field "scale_to_zero_supported" json);
  check bool "suspend-on-idle unsupported" false
    (bool_field "suspend_on_idle_supported" json);
  check bool "orchestrator absent" false
    (bool_field "resume_orchestrator_present" json);
  check string "terminal reason" "no_hibernation_orchestrator"
    (string_field "terminal_reason" json)
;;

let test_health_exposes_status () =
  let headers = Httpun.Headers.of_list [ "host", "localhost:8935" ] in
  let request = Httpun.Request.create ~headers `GET "/health" in
  let request_authority =
    match Server_request_authority.classify_http1_request request with
    | Server_request_authority.Single authority -> authority
    | ( Server_request_authority.Missing
      | Server_request_authority.Multiple
      | Server_request_authority.Malformed ) ->
      fail "expected valid authority"
  in
  let json =
    Server_routes_http_runtime.make_health_json ~request_authority request
  in
  let hibernation = member "server_hibernation" json in
  check string "health status" "not_implemented" (string_field "status" hibernation);
  check string "health mode" "long_running" (string_field "mode" hibernation)
;;

let () =
  run
    "server_hibernation"
    [ ( "status"
      , [ test_case "status contract" `Quick test_status_contract
        ; test_case "health exposes status" `Quick test_health_exposes_status
        ] )
    ]
;;
