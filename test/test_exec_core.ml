open Alcotest

let field name = Yojson.Safe.Util.member name

let test_exited_zero_is_success () =
  let json =
    Masc.Exec_core.process_result_json
      ~status:(Unix.WEXITED 0)
      ~output:"raw output"
      ~extra:[ "operation", `String "caller-owned" ]
      ()
  in
  check bool "ok" true (field "ok" json |> Yojson.Safe.Util.to_bool);
  check string "output" "raw output" (field "output" json |> Yojson.Safe.Util.to_string);
  check string
    "status kind"
    "exit"
    (field "status" json |> field "kind" |> Yojson.Safe.Util.to_string);
  check int
    "exit code"
    0
    (field "status" json |> field "code" |> Yojson.Safe.Util.to_int);
  check string
    "explicit extra"
    "caller-owned"
    (field "operation" json |> Yojson.Safe.Util.to_string)
;;

let test_nonzero_and_signal_are_not_success () =
  let exited =
    Masc.Exec_core.process_result_json ~status:(Unix.WEXITED 1) ~output:"literal" ()
  in
  let signaled =
    Masc.Exec_core.process_result_json ~status:(Unix.WSIGNALED Sys.sigterm) ~output:"" ()
  in
  check bool "exit one" false (field "ok" exited |> Yojson.Safe.Util.to_bool);
  check bool "signal" false (field "ok" signaled |> Yojson.Safe.Util.to_bool);
  check string
    "signal kind"
    "signal"
    (field "status" signaled |> field "kind" |> Yojson.Safe.Util.to_string)
;;

let test_no_inferred_fields () =
  let json =
    Masc.Exec_core.process_result_json
      ~status:(Unix.WEXITED 1)
      ~output:"fatal: not a git repository"
      ()
  in
  List.iter
    (fun key -> check bool key true (Yojson.Safe.Util.member key json = `Null))
    [ "semantic_status"
    ; "semantic_exit"
    ; "retryability"
    ; "recovery_hint"
    ; "structured_output"
    ; "environment"
    ; "artifact_refs"
    ; "output_cap"
    ]
;;

let () =
  run
    "exec_core"
    [ ( "objective_process_result"
      , [ test_case "exit zero" `Quick test_exited_zero_is_success
        ; test_case "nonzero and signal" `Quick test_nonzero_and_signal_are_not_success
        ; test_case "no inferred fields" `Quick test_no_inferred_fields
        ] )
    ]
;;
