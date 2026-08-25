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

(* The environment wins so one run can be pointed at another credential, and
   the workspace file is next because that is where masc login put it. *)
let test_plan_prefers_the_environment () =
  let chosen = function
    | Credential.Use token -> token
    | Credential.Mint -> "mint"
    | Credential.Go_without -> "go-without"
    | Credential.No_workspace -> "no-workspace"
  in
  let plan ?(env = None) ?(file = None) ?(requires = true) ?(here = true) () =
    chosen
      (Credential.plan ~env_token:env ~workspace_token:file
         ~workspace_requires_token:requires ~workspace_initialized:here)
  in
  check string "the environment wins over the workspace" "env"
    (plan ~env:(Some "env") ~file:(Some "file") ());
  check string "the workspace file is used when the environment is empty" "file"
    (plan ~file:(Some "file") ());
  check string "an environment bearer is used even where none is demanded" "env"
    (plan ~env:(Some "env") ~requires:false ())

(* Minting is for a workspace that is already here and demands a bearer. The
   two conditions are separate: a missing auth config reads as the default and
   the default demands one, so an empty directory claims to require a bearer it
   has nowhere to put. *)
let test_plan_mints_only_into_a_workspace_that_demands_one () =
  let plan ~requires ~here =
    Credential.plan ~env_token:None ~workspace_token:None
      ~workspace_requires_token:requires ~workspace_initialized:here
  in
  check bool "a demanding workspace that is here mints" true
    (plan ~requires:true ~here:true = Credential.Mint);
  check bool "a demanding path with no workspace does not mint" true
    (plan ~requires:true ~here:false = Credential.No_workspace);
  check bool "an open workspace does not mint" true
    (plan ~requires:false ~here:true = Credential.Go_without);
  check bool "an open path with no workspace needs nothing" true
    (plan ~requires:false ~here:false = Credential.Go_without)

(* The self-mint window is this client's own policy, not the workspace's. The
   workspace default is a day, meant for an operator sitting in front of a
   session; a client left running overnight is exactly what that window
   refuses. The upper bound is the store's: a longer window would make every
   mint fail instead of lasting longer. *)
let test_self_mint_window_is_neither_a_day_nor_forever () =
  check int "thirty days" (24 * 30) Credential.self_mint_expiry_hours;
  check bool "outlasts an operator session" true
    (Credential.self_mint_expiry_hours > 24);
  check bool "within the year the credential store will issue" true
    (Credential.self_mint_expiry_hours <= 8_760)

(* Silence is right for the two ordinary outcomes; a mint and a failure both
   change what the operator should expect from the next few reads. *)
let test_only_the_notable_outcomes_speak () =
  check bool "holding a bearer says nothing" true
    (Credential.outcome_notice Credential.Held = None);
  check bool "a workspace that demands nothing says nothing" true
    (Credential.outcome_notice Credential.Not_required = None);
  (match Credential.outcome_notice Credential.Minted with
   | None -> fail "a fresh mint must be reported"
   | Some notice ->
       check bool "a mint says it made one" true (has "minted one" notice);
       check bool "a mint warns the server may not see it yet" true
         (has "credential index" notice);
       (* Read off the constant rather than spelled out, so the sentence
          cannot go on claiming thirty days after the window changes. *)
       check bool "a mint says how long it lasts" true
         (has
            (Printf.sprintf "%d days" (Credential.self_mint_expiry_hours / 24))
            notice));
  match
    Credential.outcome_notice
      (Credential.Unavailable Credential.no_workspace_detail)
  with
  | None -> fail "a failed mint must be reported"
  | Some notice ->
      check bool "a failure carries its own detail" true
        (has "no workspace to mint into" notice);
      check bool "a failure still names the remedy" true (has "masc login" notice)

let () =
  run "tui_credential"
    [ ( "refusal"
      , [ test_case "the two causes do not overlap" `Quick test_causes_do_not_overlap
        ; test_case "one name reaches the command" `Quick
            test_one_name_reaches_the_command
        ; test_case "a whole refusal is cause and remedy" `Quick
            test_refusal_is_cause_and_remedy
        ; test_case "the clauses compose" `Quick test_clauses_compose
        ; test_case "the plan prefers the environment" `Quick
            test_plan_prefers_the_environment
        ; test_case "minting is only into a workspace that demands one" `Quick
            test_plan_mints_only_into_a_workspace_that_demands_one
        ; test_case "the self-mint window is the client's own" `Quick
            test_self_mint_window_is_neither_a_day_nor_forever
        ; test_case "only the notable outcomes speak" `Quick
            test_only_the_notable_outcomes_speak
        ] )
    ]
