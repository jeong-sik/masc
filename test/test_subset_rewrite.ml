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
  ; `Function_def
  ; `Glob_brace
  ; `Background
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
  (* a program belongs in a file *)
  tag_is `Control_flow "call_this_instead:write-then-execute";
  tag_is `Function_def "call_this_instead:write-then-execute";
  tag_is `Subshell "call_this_instead:write-then-execute";
  (* a process that outlives the call needs the handle, not this tool *)
  tag_is `Background "call_this_instead:spawn";
  (* one command feeding another is two calls *)
  tag_is `Cmd_subst "call_this_instead:execute-twice"
;;

let test_a_nested_pipeline_is_flattened_not_refused () =
  match Rewrite.of_reason Gate.Unsupported_nested_pipeline with
  | Rewrite.Move_to_field { field = Rewrite.Connector; _ } -> ()
  | other ->
    Alcotest.failf
      "a nested pipeline is written as one flat pipeline, got %s"
      (Rewrite.tag other)
;;

(* The advice for a backgrounded command names a tool, not a pattern, and a
   name nobody has is worse than no advice. [Subset_rewrite] lives below the
   tool schemas and cannot read them; this is the layer that sees both. *)
let test_the_background_advice_names_a_registered_tool () =
  let sentence = Rewrite.to_string (Rewrite.of_reason (Gate.Unsupported_construct `Background)) in
  let spawn =
    match
      List.find_opt
        (fun (d : Tool_schemas_spawn.definition) ->
           d.action = Tool_schemas_spawn.Start)
        Tool_schemas_spawn.definitions
    with
    | Some d -> d.schema.Masc_domain.name
    | None -> Alcotest.fail "the spawn surface has no Start tool"
  in
  Alcotest.(check string)
    "the sentence names the spawn tool as it is registered"
    (Printf.sprintf
       "call %s instead: [&] backgrounds nothing here -- the child inherits this call's \
        output pipe, so the call waits for it anyway, and a timeout leaves it running \
        with no handle to stop it"
       spawn)
    sentence
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
            "a nested pipeline is flattened, not refused"
            `Quick
            test_a_nested_pipeline_is_flattened_not_refused
        ; Alcotest.test_case
            "the background advice names a registered tool"
            `Quick
            test_the_background_advice_names_a_registered_tool
        ] )
    ]
;;
