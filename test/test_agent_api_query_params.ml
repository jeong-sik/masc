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

(* A viewer west of Greenwich sends a negative offset; every other number the
   parser rejects must stay rejected, or a typo would read as a different
   offset. *)
let signed_int_reads_both_signs_and_rejects_the_rest () =
  let read raw = A.signed_int_param ~name:"utc_offset_min" ~default:0 raw in
  check int_result "absent" (Ok 0) (read None);
  check int_result "east" (Ok 540) (read (Some "540"));
  check int_result "west" (Ok (-300)) (read (Some "-300"));
  check int_result "zero" (Ok 0) (read (Some "0"));
  List.iter
    (fun raw ->
       match read (Some raw) with
       | Ok v -> failf "utc_offset_min=%S must not read as %d" raw v
       | Error msg ->
         check bool ("names the parameter: " ^ msg) true
           (String.length msg > 0))
    [ "abc"; ""; "-"; "--3"; "+5"; "3.5"; "0x10"; "1_000"; " 5 "; "99999999999999999999" ]
;;

let tool_name_result = result (option string) string

(* The response cache trims every value and reads an empty one as absent, and
   the scan filters on the name as sent. A name the cache would change must be
   refused, or " " and an absent filter share one cache entry while the scan
   matches no row for " ". *)
let tool_name_is_kept_as_sent_or_refused () =
  check tool_name_result "absent" (Ok None) (A.tool_name_param None);
  check tool_name_result "plain" (Ok (Some "Execute")) (A.tool_name_param (Some "Execute"));
  check tool_name_result "inner space" (Ok (Some "a b")) (A.tool_name_param (Some "a b"));
  let longest = String.make A.tool_series_max_tool_name_bytes 'a' in
  check tool_name_result "longest" (Ok (Some longest)) (A.tool_name_param (Some longest));
  List.iter
    (fun raw ->
       match A.tool_name_param (Some raw) with
       | Ok read -> failf "tool=%S must not read as %s" raw (Option.value read ~default:"none")
       | Error msg -> check bool ("names the parameter: " ^ msg) true (String.length msg > 0))
    [ ""
    ; " "
    ; " Execute"
    ; "Execute "
    ; "\tExecute"
    ; "Execute\n"
    ; String.make (A.tool_series_max_tool_name_bytes + 1) 'a'
    ]
;;

let () =
  run
    "agent_api_query_params"
    [ ( "parsing"
      , [ test_case "absent uses the default" `Quick absent_uses_the_default
        ; test_case "readable values pass" `Quick readable_values_pass
        ; test_case "unreadable values are rejected" `Quick unreadable_values_are_rejected
        ; test_case
            "signed integers read both signs and reject the rest"
            `Quick
            signed_int_reads_both_signs_and_rejects_the_rest
        ; test_case
            "a tool filter is kept as sent or refused"
            `Quick
            tool_name_is_kept_as_sent_or_refused
        ] )
    ]
;;
