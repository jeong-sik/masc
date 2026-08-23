open Alcotest

module Credential = Masc_tui_credential

let has needle line = String_util.string_contains_substring ~needle line

(* The two clauses must not be readable as each other: an operator who already
   presented a bearer needs to hear that it was rejected, not to be told to
   provide one they have. *)
let test_causes_do_not_overlap () =
  let absent = Credential.refusal_cause ~credential_sent:false in
  let refused = Credential.refusal_cause ~credential_sent:true in
  check bool "absent says it holds none" true (has "holds no operator token" absent);
  check bool "absent does not say refused" false (has "was refused" absent);
  check bool "refused says it was refused" true (has "was refused" refused);
  check bool "refused does not say it holds none" false
    (has "holds no operator token" refused)

(* The name is one fact. A rename that reaches the header and the credential
   file but not the command leaves the operator provisioning something under a
   name that no longer exists. *)
let test_one_name_reaches_the_command () =
  check bool "the login command names this agent" true
    (has Credential.agent_name Credential.login_command);
  check bool "the remedy carries the command" true
    (has Credential.login_command Credential.remedy);
  List.iter
    (fun credential_sent ->
      let clause = Credential.refusal_cause ~credential_sent in
      check bool "the cause names this agent" true (has Credential.agent_name clause))
    [ true; false ]

(* Callers with no context of their own get cause and remedy together; callers
   that add their own sentence take the two halves apart. Both must hold. *)
let test_refusal_is_cause_and_remedy () =
  List.iter
    (fun credential_sent ->
      let whole = Credential.refusal ~credential_sent in
      check bool "the whole carries its cause" true
        (has (Credential.refusal_cause ~credential_sent) whole);
      check bool "the whole carries the remedy" true (has Credential.remedy whole))
    [ true; false ]

(* Clauses, not sentences: a caller places them mid-sentence, so a capital or a
   trailing period would read as a break in its own line. *)
let test_clauses_compose () =
  List.iter
    (fun (label, clause) ->
      check bool (label ^ " does not end a sentence") false
        (String.length clause > 0 && clause.[String.length clause - 1] = '.');
      check bool (label ^ " does not start one") false
        (String.length clause > 0
         && Char.equal clause.[0] (Char.uppercase_ascii clause.[0])
         && Char.lowercase_ascii clause.[0] <> clause.[0]))
    [ ("the absent cause", Credential.refusal_cause ~credential_sent:false)
    ; ("the refused cause", Credential.refusal_cause ~credential_sent:true)
    ; ("the remedy", Credential.remedy)
    ]

let () =
  run "tui_credential"
    [ ( "refusal"
      , [ test_case "the two causes do not overlap" `Quick test_causes_do_not_overlap
        ; test_case "one name reaches the command" `Quick
            test_one_name_reaches_the_command
        ; test_case "a whole refusal is cause and remedy" `Quick
            test_refusal_is_cause_and_remedy
        ; test_case "the clauses compose" `Quick test_clauses_compose
        ] )
    ]
