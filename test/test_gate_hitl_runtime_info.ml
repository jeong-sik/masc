open Alcotest

let member name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some value -> value
     | None -> failf "missing field %s" name)
  | _ -> fail "expected JSON object"
;;

let has_field name = function
  | `Assoc fields -> Option.is_some (List.assoc_opt name fields)
  | _ -> false
;;

let test_nonblocking_hitl_is_available () =
  let json = Server_dashboard_http_runtime_info.gate_hitl_json () in
  check string
    "schema"
    "masc.gate_hitl.v1"
    Yojson.Safe.Util.(member "schema" json |> to_string);
  check string
    "state"
    "available"
    Yojson.Safe.Util.(member "state" json |> to_string);
  check bool
    "nonblocking"
    true
    Yojson.Safe.Util.(member "nonblocking" json |> to_bool);
  check bool "no environment kill switch" false (has_field "disable_env_key" json)
;;

let () =
  run
    "gate_hitl_runtime_info"
    [ "gate_hitl", [ test_case "available and nonblocking" `Quick test_nonblocking_hitl_is_available ] ]
;;
