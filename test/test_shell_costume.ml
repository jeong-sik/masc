(** RFC execute-subset-dispositions, step 1.

    [argv:["sh";"-c";S]] and [script:S] are the same text, but only the second
    crosses the gate.  These tests pin what the recogniser accepts and what the
    classifier calls the text underneath, because the distribution of those
    tags over live traffic is what decides which constructs the subset resolves
    next. *)

module Costume = Keeper_tooling.Shell_costume
module Gate = Masc_exec_command_gate.Shell_command_gate

let syntax_policy : Gate.syntax_policy =
  { Gate.redirect_allowed = true; allow_pipes = true }
;;

let sandbox = Gate.host_sandbox

let shows argv expected_script =
  match Costume.of_argv argv with
  | Some t ->
    Alcotest.(check string) (String.concat " " argv) expected_script t.Costume.script
  | None ->
    Alcotest.failf "expected a shell costume for [%s]" (String.concat "; " argv)
;;

let hides argv =
  match Costume.of_argv argv with
  | None -> ()
  | Some t ->
    Alcotest.failf
      "expected no costume for [%s], got script %S"
      (String.concat "; " argv)
      t.Costume.script
;;

let test_recognises_the_costume () =
  shows [ "sh"; "-c"; "echo hi" ] "echo hi";
  (* the path is stripped: /bin/bash and bash are the same shell *)
  shows [ "/bin/bash"; "-c"; "echo hi" ] "echo hi";
  (* bundled flags reach for the same thing *)
  shows [ "bash"; "-ec"; "echo hi" ] "echo hi";
  shows [ "zsh"; "-lc"; "echo hi" ] "echo hi"
;;

let test_leaves_everything_else_alone () =
  hides [];
  hides [ "sh" ];
  (* -c with nothing after it carries no script *)
  hides [ "sh"; "-c" ];
  (* a shell running a file, not a string *)
  hides [ "sh"; "script.sh" ];
  (* not a shell, even though it took a -c flag *)
  hides [ "gcc"; "-c"; "main.c" ];
  (* -- ends option parsing, so this -c is an argument *)
  hides [ "sh"; "--"; "-c"; "echo hi" ]
;;

let tag_of script =
  match Costume.of_argv [ "sh"; "-c"; script ] with
  | None -> Alcotest.failf "the recogniser missed %S" script
  | Some t -> Costume.finding_tag (Costume.classify ~syntax_policy ~sandbox t)
;;

let test_names_what_the_gate_would_have_said () =
  (* Text the IR can hold: nothing is hidden by the costume. *)
  Alcotest.(check string) "plain command" "representable" (tag_of "echo hi");
  Alcotest.(check string) "connector" "representable" (tag_of "true && echo hi");
  (* [;] is a Shell_ir connector now (RFC-0391), so the costume hides nothing
     the typed path could not have said. *)
  Alcotest.(check string) "separator" "representable" (tag_of "false; echo hi");
  (* Brace expansion builds argv before exec -- category A in the RFC. *)
  Alcotest.(check string) "brace" "glob_brace" (tag_of "ls {a,b}.txt")
;;

(* Measured 2026-08-24, then pinned.  Read as a table of what the raw gate
   already does, because the RFC's staging depends on it and two of these were
   the opposite of what the author assumed.

   [ls *.ml] is the one that matters: a wildcard is *not* refused, it survives
   as a literal argv token.  So the same text means two different things
   depending on which field it arrived in -- the shell expands it, the typed
   path passes it through -- and routing one to the other changes what runs. *)
let test_measured_dispositions () =
  let case script expected = Alcotest.(check string) script expected (tag_of script) in
  case "ls *.ml" "representable";
  case "echo hi > out.txt" "representable";
  case "echo $(date)" "cmd_subst";
  case "sleep 5 &" "background";
  case "cat <<'EOF'\nbody\nEOF" "heredoc";
  (* A loop has no rule of its own -- [for], [while] and [if] lex as words --
     so it is reported by the excluded lexeme it does reach, here the [$f].
     [`Control_flow] still has no producer, and a count grouped by tag still
     does not see control flow; what changed is that the tag now names a
     construct the text contains. *)
  case "for f in a b; do echo $f; done" "param_expansion"
;;

(* The tag names what the lexer refused, not the first metacharacter someone
   found by scanning the source.

   Every case here but the [$(date)] one was reported as [redirect] before --
   that one had [$(] to find, which the scan checked before [>]. The advice
   attached to [redirect] told the caller to move the script into the [stdin]
   field, which is not an answer for [>] under any reading, and it pointed at
   redirects that were all fine. The expansion beside them was not, and that
   is now what the tag says. *)
let test_a_tag_names_the_refused_lexeme_not_a_neighbour () =
  let case script expected = Alcotest.(check string) script expected (tag_of script) in
  case "echo $HOME > out.txt" "param_expansion";
  case "echo exit=$? >> out.txt" "param_expansion";
  case "echo \"$HOME\" > out.txt" "param_expansion";
  case "echo $(date) > out.txt" "cmd_subst";
  (* The witness, as the keeper sent it. *)
  case
    "echo cmd=build > ev.txt && git rev-parse HEAD >> ev.txt 2>&1; dune build \
     >> ev.txt 2>&1; echo exit=$? >> ev.txt"
    "param_expansion"
;;

(* [redirect] survives as a tag, and now means only what it says: the redirect
   operators the grammar does not spell. Everything the subset does spell --
   [>], [>>], [<], [n>&m] -- parses. *)
let test_redirect_now_means_only_the_forms_the_subset_lacks () =
  let case script expected = Alcotest.(check string) script expected (tag_of script) in
  case "echo hi > out.txt" "representable";
  case "echo hi >> out.txt" "representable";
  case "dune build >> out.txt 2>&1" "representable";
  case "dune build &> out.txt" "redirect";
  case "echo hi >| out.txt" "redirect"
;;

(* The tap reports [lowered] from the dispatch result, and both of its readings
   said a costume had come off when it had not.  Live records on 2026-08-29
   carried [finding=cmd_subst lowered=true] for [/bin/zsh -lc "x=$(...)"]: the
   script was outside the subset, so nothing lowered it, and the shell was
   still there under a path the predicate did not recognise. *)
let simple bin =
  match Masc_exec.Exec_program.of_string bin with
  | Ok program ->
    Masc_exec.Shell_ir.Simple
      { bin = program
      ; args = []
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Masc_exec.Sandbox_target.host ()
      }
  | Error _ -> Alcotest.fail ("not a program: " ^ bin)
;;

let test_a_shell_by_path_is_still_a_shell () =
  Alcotest.(check bool) "zsh" true (Costume.names_a_shell "zsh");
  Alcotest.(check bool) "/bin/zsh" true (Costume.names_a_shell "/bin/zsh");
  Alcotest.(check bool) "/usr/local/bin/bash" true (Costume.names_a_shell "/usr/local/bin/bash");
  Alcotest.(check bool) "/usr/bin/git" false (Costume.names_a_shell "/usr/bin/git")
;;

let test_one_lowered_stage_does_not_lower_its_sibling () =
  Alcotest.(check bool)
    "a lowered simple keeps no shell"
    false
    (Costume.ir_keeps_a_shell (simple "ls"));
  Alcotest.(check bool)
    "a pipeline whose second stage is still a shell"
    true
    (Costume.ir_keeps_a_shell
       (Masc_exec.Shell_ir.Pipeline [ simple "ls"; simple "/bin/bash" ]));
  Alcotest.(check bool)
    "a sequence whose tail is still a shell"
    true
    (Costume.ir_keeps_a_shell
       (Masc_exec.Shell_ir.Sequence
          { head = simple "ls"; tail = [ Masc_exec.Shell_ir.And_if, simple "sh" ] }));
  Alcotest.(check bool)
    "a sequence of ordinary programs"
    false
    (Costume.ir_keeps_a_shell
       (Masc_exec.Shell_ir.Sequence
          { head = simple "ls"; tail = [ Masc_exec.Shell_ir.And_if, simple "dune" ] }))
;;

let () =
  Alcotest.run
    "shell_costume"
    [ ( "recogniser"
      , [ Alcotest.test_case "recognises the costume" `Quick test_recognises_the_costume
        ; Alcotest.test_case
            "leaves everything else alone"
            `Quick
            test_leaves_everything_else_alone
        ] )
    ; ( "tags name the refused lexeme"
      , [ Alcotest.test_case
            "a tag names the refused lexeme, not a neighbour"
            `Quick
            test_a_tag_names_the_refused_lexeme_not_a_neighbour
        ; Alcotest.test_case
            "redirect means only the forms the subset lacks"
            `Quick
            test_redirect_now_means_only_the_forms_the_subset_lacks
        ] )
    ; ( "lowered is a fact about every stage"
      , [ Alcotest.test_case
            "a shell by path is still a shell"
            `Quick
            test_a_shell_by_path_is_still_a_shell
        ; Alcotest.test_case
            "one lowered stage does not lower its sibling"
            `Quick
            test_one_lowered_stage_does_not_lower_its_sibling
        ] )
    ; ( "classifier"
      , [ Alcotest.test_case
            "names what the gate would have said"
            `Quick
            test_names_what_the_gate_would_have_said
        ; Alcotest.test_case
            "measured dispositions stay put"
            `Quick
            test_measured_dispositions
        ] )
    ]
;;
