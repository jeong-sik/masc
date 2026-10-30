(** Query parameters on /api/v1/agent-activity and /api/v1/agent-timeline. *)

open Alcotest

module A = Server_dashboard_http_agent_api

let float_result = result (float 0.0001) string
let int_result = result int string

let absent_uses_the_default () =
  check float_result "hours" (Ok 24.0) (A.positive_float_param ~name:"hours" ~default:24.0 None);
  check int_result "limit" (Ok 20) (A.positive_int_param ~name:"limit" ~default:20 None)
;;

let readable_values_pass () =
  check float_result "6" (Ok 6.0) (A.positive_float_param ~name:"hours" ~default:24.0 (Some "6"));
  check float_result "fraction" (Ok 1.5)
    (A.positive_float_param ~name:"hours" ~default:24.0 (Some "1.5"));
  check int_result "50" (Ok 50) (A.positive_int_param ~name:"limit" ~default:20 (Some "50"))
;;

(* The rejection must name the parameter: the response body is all the caller
   gets back. *)
let unreadable_values_are_rejected () =
  List.iter
    (fun raw ->
       match A.positive_float_param ~name:"hours" ~default:24.0 (Some raw) with
       | Ok v -> failf "hours=%S must not read as %f" raw v
       | Error msg -> check bool ("names hours: " ^ msg) true (String.length msg > 0))
    [ "abc"; ""; "0"; "-3"; "12abc"; "inf"; "infinity"; "nan"; "1e309"; " 1.5 " ];
  List.iter
    (fun raw ->
       match A.positive_int_param ~name:"limit" ~default:20 (Some raw) with
       | Ok v -> failf "limit=%S must not read as %d" raw v
       | Error _ -> ())
    [ "abc"; ""; "0"; "-1"; "3.5"; "0x10"; "1_000"; " 50 " ]
;;

let () =
  run
    "agent_api_query_params"
    [ ( "parsing"
      , [ test_case "absent uses the default" `Quick absent_uses_the_default
        ; test_case "readable values pass" `Quick readable_values_pass
        ; test_case "unreadable values are rejected" `Quick unreadable_values_are_rejected
        ] )
    ]
;;
