(** Tests for [Keeper_msg_async.For_testing.is_safe_request_id] path
    traversal guards and the partitioned record-path integration (#20942).

    Rewritten from the ppx_inline_test style the original commit used:
    the test stanza has no inline-test preprocessor, so [let%test] never
    compiled — this file follows the repo-wide Alcotest convention. *)

open Alcotest
module Keeper_msg_async = Masc.Keeper_msg_async

let is_safe = Keeper_msg_async.For_testing.is_safe_request_id

let record_paths =
  [ Keeper_msg_async.For_testing.active_record_path
  ; Keeper_msg_async.For_testing.terminal_record_path
  ]
;;

let test_valid_ids () =
  check bool "normal alphanumeric" true (is_safe "abc123");
  check bool "with hyphens" true (is_safe "my-request-42");
  check bool "with underscores" true (is_safe "my_request_42");
  check bool "single char alpha" true (is_safe "a");
  check bool "max length valid" true (is_safe (String.init 128 (fun _ -> 'x')));
  check bool "dot in middle" true (is_safe "req.123");
  check bool "trailing dot" true (is_safe "request.");
  (* "..." has no traversal semantics — only "." and ".." are directory
     references. The never-compiled #20942 test asserted rejection here,
     contradicting the implementation it shipped with. *)
  check bool "triple dot accepted" true (is_safe "...")

let test_traversal_rejected () =
  check bool "single dot rejected" false (is_safe ".");
  check bool "double dot rejected" false (is_safe "..");
  check bool "empty string rejected" false (is_safe "");
  check bool "over max length rejected" false
    (is_safe (String.init 129 (fun _ -> 'x')));
  check bool "slash rejected" false (is_safe "../etc/passwd");
  check bool "dots with slash rejected" false (is_safe "../../config");
  check bool "dots and slash combo rejected" false (is_safe "a/../b")

let test_record_path_integration () =
  List.iter
    (fun record_path ->
       check bool "Some for safe id" true
         (Option.is_some (record_path ~base_path:"/tmp" ~request_id:"safe-42"));
       check bool "None for double dot" true
         (Option.is_none (record_path ~base_path:"/tmp" ~request_id:".."));
       check bool "None for single dot" true
         (Option.is_none (record_path ~base_path:"/tmp" ~request_id:".")))
    record_paths

let () =
  run "keeper_msg_async_path_traversal"
    [
      ( "is_safe_request_id",
        [
          test_case "valid ids accepted" `Quick test_valid_ids;
          test_case "traversal ids rejected" `Quick test_traversal_rejected;
          test_case "record_path integration" `Quick
            test_record_path_integration;
        ] );
    ]
