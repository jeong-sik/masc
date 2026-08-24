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
  (* [;] is not in Shell_ir.connector on purpose: it means "run the next thing
     whether or not the last one worked".  Inside the costume it runs anyway. *)
  Alcotest.(check string) "separator" "command_separator" (tag_of "false; echo hi");
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
  (* A loop is reported by the first thing it trips on, not by what it is: the
     tag is [command_separator], not [control_flow].  Any count grouped by tag
     under-reports control flow for exactly this reason. *)
  case "for f in a b; do echo $f; done" "command_separator"
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
