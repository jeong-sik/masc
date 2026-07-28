(* RFC-0356: the replayed write must carry the approved payload, not a
   payload the model re-emits. These cases pin the reconstruction from a
   stored Gate input to the write tool arguments. *)

let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal

let result_json =
  Alcotest.result json (Alcotest.testable Fmt.string String.equal)
;;

(* The pinned resource identity stays in the approved input and is
   deliberately absent from the reconstructed arguments: the write handler
   re-derives it, so a target replaced between approval and replay produces a
   different canonical input and the approval no longer matches. *)
let approved_content_input =
  `Assoc
    [ ( "effect"
      , `Assoc
          [ "operation", `String "atomic_replace_entry"
          ; ( "target_resource"
            , `Assoc [ "device", `Intlit "16777232"; "inode", `Intlit "94211" ]
            )
          ] )
    ; "requested_target", `String "/playground/executor/repos/masc/a.ml"
    ; "content", `String "let a = 1\n"
    ]
;;

let approved_edit_input =
  `Assoc
    [ "effect", `Assoc [ "operation", `String "patch_then_atomic_replace_entry" ]
    ; "requested_target", `String "/playground/executor/repos/masc/b.ml"
    ; "content", `String ""
    ; "old_string", `String "let b = 1"
    ; "new_string", `String "let b = 2"
    ; "replace_all", `Bool true
    ]
;;

let test_content_write () =
  Alcotest.check
    result_json
    "content write keeps the approved target and payload"
    (Ok
       (`Assoc
           [ "path", `String "/playground/executor/repos/masc/a.ml"
           ; "mode", `String "overwrite"
           ; "content", `String "let a = 1\n"
           ]))
    (Masc.Keeper_gate_replay.write_args_of_gate_input approved_content_input)
;;

let test_edit_write () =
  Alcotest.check
    result_json
    "edit write carries old_string, new_string, and replace_all"
    (Ok
       (`Assoc
           [ "path", `String "/playground/executor/repos/masc/b.ml"
           ; "mode", `String "patch"
           ; "content", `String ""
           ; "old_string", `String "let b = 1"
           ; "new_string", `String "let b = 2"
           ; "replace_all", `Bool true
           ]))
    (Masc.Keeper_gate_replay.write_args_of_gate_input approved_edit_input)
;;

(* A content write must not acquire edit fields: reconstruction carries only
   what the approval contained, so replay cannot widen the approved effect. *)
let test_absent_fields_are_not_invented () =
  match
    Masc.Keeper_gate_replay.write_args_of_gate_input approved_content_input
  with
  | Error detail -> Alcotest.fail detail
  | Ok (`Assoc fields) ->
    List.iter
      (fun name ->
         Alcotest.check
           Alcotest.bool
           (Printf.sprintf "%s absent" name)
           false
           (List.mem_assoc name fields))
      [ "old_string"; "new_string"; "replace_all" ]
  | Ok _ -> Alcotest.fail "reconstructed arguments are not an object"
;;

(* An approved append must not replay as an overwrite: the mode arg defaults
   to overwrite, so dropping it would destroy the file the operator approved
   appending to. *)
let approved_append_input =
  `Assoc
    [ "effect", `Assoc [ "operation", `String "append_pinned_resource" ]
    ; "requested_target", `String "/playground/executor/repos/masc/log.txt"
    ; "content", `String "one more line\n"
    ]
;;

let test_append_stays_append () =
  Alcotest.check
    result_json
    "append mode survives the round trip"
    (Ok
       (`Assoc
           [ "path", `String "/playground/executor/repos/masc/log.txt"
           ; "mode", `String "append"
           ; "content", `String "one more line\n"
           ]))
    (Masc.Keeper_gate_replay.write_args_of_gate_input approved_append_input)
;;

let test_unreproducible_effect_is_rejected () =
  match
    Masc.Keeper_gate_replay.write_args_of_gate_input
      (`Assoc
          [ "effect", `Assoc [ "operation", `String "create_entry_exclusive" ]
          ; "requested_target", `String "/playground/executor/new.txt"
          ; "content", `String "x"
          ])
  with
  | Ok _ ->
    Alcotest.fail "an effect this module cannot reproduce must not replay"
  | Error _ -> ()
;;

let test_missing_target_is_rejected () =
  match
    Masc.Keeper_gate_replay.write_args_of_gate_input
      (`Assoc [ "content", `String "orphan" ])
  with
  | Ok _ -> Alcotest.fail "input without requested_target must not reconstruct"
  | Error _ -> ()
;;

let test_non_object_input_is_rejected () =
  match Masc.Keeper_gate_replay.write_args_of_gate_input (`String "opaque") with
  | Ok _ -> Alcotest.fail "non-object input must not reconstruct"
  | Error _ -> ()
;;


(* [tool_execute] is 66% of live approvals and was Not_applicable until now,
   so a Keeper had to re-emit a byte-identical command to spend its own
   approval. Unlike the write path nothing is reconstructed: the Gate request
   wraps the arguments with execution context instead of re-encoding them. *)
let approved_execute_input =
  `Assoc
    [ "schema", `String "masc.keeper_gate.request.v1"
    ; ( "input"
      , `Assoc
          [ "argv", `List [ `String "git"; `String "status" ]
          ; "timeout_sec", `Int 30
          ] )
    ; "cwd", `String "/repo"
    ; "sandbox_profile", `String "docker"
    ; "sandbox_target", `String "docker:masc"
    ]
;;

let test_execute_args_are_the_approved_arguments () =
  Alcotest.check
    result_json
    "the approved arguments are replayed verbatim"
    (Ok
       (`Assoc
          [ "argv", `List [ `String "git"; `String "status" ]
          ; "timeout_sec", `Int 30
          ]))
    (Masc.Keeper_gate_replay.execute_args_of_gate_input approved_execute_input)
;;

let test_execute_context_is_not_replayed () =
  (* cwd and the sandbox fields describe where the approval was granted. The
     handler re-derives them from the current turn; carrying the stored ones
     would execute somewhere the approval never described. *)
  match
    Masc.Keeper_gate_replay.execute_args_of_gate_input approved_execute_input
  with
  | Error detail -> Alcotest.fail detail
  | Ok (`Assoc fields) ->
    List.iter
      (fun key ->
         Alcotest.check
           Alcotest.bool
           (key ^ " is not carried into the replayed arguments")
           false
           (List.mem_assoc key fields))
      [ "cwd"; "sandbox_profile"; "sandbox_target"; "schema" ]
  | Ok _ -> Alcotest.fail "replayed execute arguments are not an object"
;;

let test_execute_without_input_is_rejected () =
  match
    Masc.Keeper_gate_replay.execute_args_of_gate_input
      (`Assoc [ "cwd", `String "/repo" ])
  with
  | Ok _ -> Alcotest.fail "a Gate input with no arguments replayed anyway"
  | Error _ -> ()
;;


(* The decode functions above are only reachable if dispatch routes to them.
   An operation that has a decoder but is never dispatched to is
   indistinguishable from a working replay at the call site — it just returns
   Not_applicable and the Keeper is left re-emitting its own approved call. *)
let test_dispatch_covers_both_replayable_operations () =
  let open Masc.Keeper_gate_replay in
  Alcotest.check
    Alcotest.bool
    "an approved filesystem_write is replayed"
    true
    (replayable_of_operation "filesystem_write" = Some Replay_write);
  Alcotest.check
    Alcotest.bool
    "an approved tool_execute is replayed"
    true
    (replayable_of_operation "tool_execute" = Some Replay_execute)
;;

let test_dispatch_refuses_unknown_operations () =
  let open Masc.Keeper_gate_replay in
  List.iter
    (fun operation ->
       Alcotest.check
         Alcotest.bool
         (operation ^ " still requires resubmission")
         true
         (replayable_of_operation operation = None))
    [ "network_read"; "keeper_board_post"; "" ]
;;

let () =
  Alcotest.run
    "keeper_gate_replay"
    [ ( "write_args_of_gate_input"
      , [ Alcotest.test_case "content write" `Quick test_content_write
        ; Alcotest.test_case "edit write" `Quick test_edit_write
        ; Alcotest.test_case
            "absent fields stay absent"
            `Quick
            test_absent_fields_are_not_invented
        ; Alcotest.test_case "append stays append" `Quick test_append_stays_append
        ; Alcotest.test_case
            "unreproducible effect rejected"
            `Quick
            test_unreproducible_effect_is_rejected
        ; Alcotest.test_case
            "missing target rejected"
            `Quick
            test_missing_target_is_rejected
        ; Alcotest.test_case
            "non-object rejected"
            `Quick
            test_non_object_input_is_rejected
        ] )
    ; ( "execute replay"
      , [ Alcotest.test_case
            "approved arguments replayed verbatim"
            `Quick
            test_execute_args_are_the_approved_arguments
        ; Alcotest.test_case
            "approval-time context is not replayed"
            `Quick
            test_execute_context_is_not_replayed
        ; Alcotest.test_case
            "input without arguments rejected"
            `Quick
            test_execute_without_input_is_rejected
        ] )
    ; ( "dispatch"
      , [ Alcotest.test_case
            "covers both replayable operations"
            `Quick
            test_dispatch_covers_both_replayable_operations
        ; Alcotest.test_case
            "refuses operations it cannot replay"
            `Quick
            test_dispatch_refuses_unknown_operations
        ] )
    ]
;;
