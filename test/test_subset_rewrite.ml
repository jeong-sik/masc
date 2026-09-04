(** RFC execute-boundary-is-the-sandbox: the shell runs the line, so most
    constructs need no advice at all.

    §3.1 of the parent RFC wrote this taxonomy while the subset was what ran,
    and the claim was that exactly one construct had no call to suggest. That
    inverted when [script] became a shell. The claim these tests carry now is
    the other way round: exactly one construct has a move, and inventing
    one for the rest sends a caller to rewrite code that works -- which
    happened on 2026-08-31 to a keeper told "this tool runs no shell" about a
    working [$PWD]. *)

module Rewrite = Keeper_tooling.Subset_rewrite
module Gate = Masc_exec_command_gate.Shell_command_gate

(* The advice sentences this suite asserts moved out of the .ml sources into
   config/prompts/subset_rewrite.md, rendered through the prompt registry. *)
let () =
  Masc.Prompt_defaults.init ()
;;

let every_construct : Masc_exec.Parsed.reason_too_complex list =
  [ `Heredoc
  ; `Here_string
  ; `Cmd_subst
  ; `Proc_subst
  ; `Subshell
  ; `Arith_expansion
  ; `Param_expansion
  ; `Control_flow
  ; `Function_def
  ; `Glob_brace
  ; `Background
  ; `Redirect
  ]
;;

(* [every_construct] is written by hand, so an arm added to the reason type
   would be checked everywhere the compiler looks and skipped here, which is
   the one place that claims to cover all of them. This witness makes that a
   compile error: add the arm below and to the list above together. *)
let _every_construct_is_listed : Masc_exec.Parsed.reason_too_complex -> unit
  = function
  | `Heredoc
  | `Here_string
  | `Cmd_subst
  | `Proc_subst
  | `Subshell
  | `Arith_expansion
  | `Param_expansion
  | `Control_flow
  | `Function_def
  | `Glob_brace
  | `Background
  | `Redirect
  (* Deliberately not in [every_construct]: the test below asserts it is the
     one construct with no rewrite, so it is applied separately. *)
  | `Unknown_construct _ -> ()
;;

let rewrite_of construct = Rewrite.of_reason (Gate.Unsupported_construct construct)

let mentions ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec at i = i + n <= h && (String.sub haystack i n = needle || at (i + 1)) in
  n > 0 && at 0
;;


(* The one that keeps a move, named here so adding a second is a decision
   rather than a drift. *)
let has_a_move : Masc_exec.Parsed.reason_too_complex list = [ `Background ]

let test_only_one_construct_has_a_move () =
  List.iter
    (fun construct ->
       let expected_move = List.mem construct has_a_move in
       match rewrite_of construct, expected_move with
       | Rewrite.Unrepresentable _, false -> ()
       | Rewrite.Unrepresentable _, true ->
         Alcotest.failf
           "%s lost the move it still has"
           (Rewrite.tag (rewrite_of construct))
       | other, true -> ignore other
       | other, false ->
         Alcotest.failf
           "a shell runs this construct, so advising %s sends the caller to \
            rewrite working code"
           (Rewrite.tag other))
    every_construct;
  match rewrite_of (`Unknown_construct "whatever this is") with
  | Rewrite.Unrepresentable _ -> ()
  | other ->
    Alcotest.failf
      "a construct the parser could not name has nothing to suggest, got %s"
      (Rewrite.tag other)
;;

(* The sentence a caller reads must not claim the tool cannot run what they
   wrote. That claim was true until [script] became a shell, and it is the
   exact wording a keeper acted on. *)
let test_no_advice_claims_there_is_no_shell () =
  List.iter
    (fun construct ->
       let sentence = Rewrite.to_string (rewrite_of construct) in
       List.iter
         (fun claim ->
            Alcotest.(check bool)
              (Printf.sprintf "%s must not say %S: %S"
                 (Rewrite.tag (rewrite_of construct)) claim sentence)
              false
              (mentions ~needle:claim sentence))
         [ "runs no shell"; "does not run"; "no shell" ])
    (`Unknown_construct "unnamed" :: every_construct)
;;

let tag_is construct expected =
  Alcotest.(check string) (Rewrite.to_string (rewrite_of construct)) expected
    (Rewrite.tag (rewrite_of construct))
;;

let test_each_rewrite_names_the_right_move () =
  (* The shell running the line exits when the line does, so a backgrounded
     child is left with no handle. Spawn returns one. *)
  tag_is `Background "call_this_instead:spawn";
  (* A shell runs each of these, so there is no other call to name. *)
  List.iter
    (fun construct -> tag_is construct "unrepresentable")
    [ `Heredoc
    ; `Here_string
    ; `Cmd_subst
    ; `Param_expansion
    ; `Arith_expansion
    ; `Glob_brace
    ; `Subshell
    ; `Proc_subst
    ; `Control_flow
    ; `Function_def
    ; `Redirect
    ]
;;

(* [`Redirect] is reached by [&>], [>|], [<>] and [>&-] -- forms bash takes.
   It used to answer "this tool has no operator that joins two streams", which
   stopped being true. Execute has no stdin field, so naming one would send
   the caller to a field that does not exist. It answers with neither. *)
let test_the_redirect_advice_does_not_forbid_what_bash_takes () =
  let sentence = Rewrite.to_string (rewrite_of `Redirect) in
  List.iter
    (fun claim ->
       Alcotest.(check bool)
         (Printf.sprintf "must not say %S: %S" claim sentence)
         false
         (mentions ~needle:claim sentence))
    [ "stdin"; "has no operator" ]
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
       "call %s instead: the shell running this line exits when the line does, so [&] \
        leaves a child with no handle to wait on, read from, or stop"
       spawn)
    sentence
;;

let () =
  Alcotest.run
    "subset_rewrite"
    [ ( "taxonomy"
      , [ Alcotest.test_case
            "only one construct has a move"
            `Quick
            test_only_one_construct_has_a_move
        ; Alcotest.test_case
            "no advice claims there is no shell"
            `Quick
            test_no_advice_claims_there_is_no_shell
        ; Alcotest.test_case
            "each rewrite names the right move"
            `Quick
            test_each_rewrite_names_the_right_move
        ; Alcotest.test_case
            "the redirect advice does not forbid what bash takes"
            `Quick
            test_the_redirect_advice_does_not_forbid_what_bash_takes
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
