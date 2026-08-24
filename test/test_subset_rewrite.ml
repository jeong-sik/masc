(** RFC execute-subset-dispositions §3.1: a refusal is a rewrite.

    The claim these tests carry is narrow and checkable -- of the constructs
    the subset excludes, exactly one has no call to suggest instead. If that
    stops being true, either a rewrite was lost or one was invented for a
    construct that has none. *)

module Rewrite = Keeper_tooling.Subset_rewrite
module Gate = Masc_exec_command_gate.Shell_command_gate

let every_construct : Masc_exec.Parsed.reason_too_complex list =
  [ `Heredoc
  ; `Here_string
  ; `Cmd_subst
  ; `Proc_subst
  ; `Subshell
  ; `Arith_expansion
  ; `Control_flow
  ; `Logic_op
  ; `Function_def
  ; `Glob_brace
  ; `Background
  ; `Command_separator
  ; `Redirect
  ]
;;

let rewrite_of construct = Rewrite.of_reason (Gate.Unsupported_construct construct)

let test_only_the_unnameable_has_no_rewrite () =
  List.iter
    (fun construct ->
       match rewrite_of construct with
       | Rewrite.Unrepresentable _ ->
         Alcotest.failf
           "%s has a call to suggest, so it must not be a refusal"
           (Rewrite.tag (rewrite_of construct))
       | _ -> ())
    every_construct;
  match rewrite_of (`Unknown_construct "whatever this is") with
  | Rewrite.Unrepresentable _ -> ()
  | other ->
    Alcotest.failf
      "a construct the parser could not name has no call to suggest, got %s"
      (Rewrite.tag other)
;;

let tag_is construct expected =
  Alcotest.(check string) (Rewrite.to_string (rewrite_of construct)) expected
    (Rewrite.tag (rewrite_of construct))
;;

let test_each_rewrite_names_the_right_move () =
  (* stdin is a field, and a heredoc is stdin *)
  tag_is `Heredoc "move_to_field:stdin";
  tag_is `Here_string "move_to_field:stdin";
  (* [;] is a connector, and the connector that keeps the failure is [&&] *)
  tag_is `Command_separator "move_to_field:connector";
  (* a program belongs in a file *)
  tag_is `Control_flow "call_this_instead:write-then-execute";
  tag_is `Function_def "call_this_instead:write-then-execute";
  tag_is `Subshell "call_this_instead:write-then-execute";
  (* a process that outlives the call needs the handle, not this tool *)
  tag_is `Background "call_this_instead:spawn";
  (* one command feeding another is two calls *)
  tag_is `Cmd_subst "call_this_instead:execute-twice"
;;

let test_the_separator_names_its_replacement () =
  (* Naming the construct is not enough: the caller has to be told which
     connector it meant, or [sh -c] is the only move it can work out. *)
  let text = Rewrite.to_string (rewrite_of `Command_separator) in
  Alcotest.(check bool)
    ("the [;] rewrite names && -- got: " ^ text)
    true
    (Astring.String.is_infix ~affix:"&&" text)
;;

let test_a_nested_pipeline_is_flattened_not_refused () =
  match Rewrite.of_reason Gate.Unsupported_nested_pipeline with
  | Rewrite.Move_to_field { field = Rewrite.Connector; _ } -> ()
  | other ->
    Alcotest.failf
      "a nested pipeline is written as one flat pipeline, got %s"
      (Rewrite.tag other)
;;

let () =
  Alcotest.run
    "subset_rewrite"
    [ ( "taxonomy"
      , [ Alcotest.test_case
            "only the unnameable has no rewrite"
            `Quick
            test_only_the_unnameable_has_no_rewrite
        ; Alcotest.test_case
            "each rewrite names the right move"
            `Quick
            test_each_rewrite_names_the_right_move
        ; Alcotest.test_case
            "the separator names its replacement"
            `Quick
            test_the_separator_names_its_replacement
        ; Alcotest.test_case
            "a nested pipeline is flattened, not refused"
            `Quick
            test_a_nested_pipeline_is_flattened_not_refused
        ] )
    ]
;;
