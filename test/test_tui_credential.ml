open Alcotest

module Credential = Masc_tui_credential

let has needle line = String_util.string_contains_substring ~needle line

let reasons = [ Credential.Expired; Credential.Insufficient_role; Credential.Rejected ]

let every_case =
  List.concat_map (fun sent -> List.map (fun r -> (sent, r)) reasons) [ true; false ]

(* The two clauses must not be readable as each other: an operator who already
   presented a bearer needs to hear that it was rejected, not to be told to
   provide one they have. *)
let test_causes_do_not_overlap () =
  let absent = Credential.refusal_cause ~credential_sent:false Credential.Rejected in
  let refused = Credential.refusal_cause ~credential_sent:true Credential.Rejected in
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
    (fun (credential_sent, reason) ->
      let clause = Credential.refusal_cause ~credential_sent reason in
      check bool "the cause names this agent" true (has Credential.agent_name clause))
    every_case

(* Callers with no context of their own get cause and remedy together; callers
   that add their own sentence take the two halves apart. Both must hold. *)
let test_refusal_is_cause_and_remedy () =
  List.iter
    (fun (credential_sent, reason) ->
      let whole = Credential.refusal ~credential_sent reason in
      check bool "the whole carries its cause" true
        (has (Credential.refusal_cause ~credential_sent reason) whole);
      check bool "the whole carries the remedy" true (has Credential.remedy whole))
    every_case

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
    (("the remedy", Credential.remedy)
     :: List.map
          (fun (credential_sent, reason) ->
            ("a cause", Credential.refusal_cause ~credential_sent reason))
          every_case)

(* The server's typed code is what tells an expired bearer from a rejected one.
   The body is written with the server's own [to_string], so the round trip is
   the one the wire makes. *)
let test_the_server_reason_comes_from_the_typed_code () =
  let body code = Printf.sprintf {|{"error":"x","auth_error_code":%S}|} code in
  let of_code code =
    Credential.server_reason_of_body
      (body (Masc_error.Auth_error_code.to_string code))
  in
  check bool "an expired code is Expired" true
    (of_code Masc_error.Auth_error_code.Token_expired = Some Credential.Expired);
  check bool "an insufficient role is its own reason" true
    (of_code Masc_error.Auth_error_code.Insufficient_role
     = Some Credential.Insufficient_role);
  check bool "an invalid token is a plain refusal" true
    (of_code Masc_error.Auth_error_code.Invalid_token = Some Credential.Rejected);
  (* An /mcp refusal is a JSON-RPC error with the code under error.data. *)
  check bool "a JSON-RPC refusal is read from error.data" true
    (Credential.server_reason_of_body
       (Printf.sprintf
          {|{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"x","data":{"auth_error_code":%S}}}|}
          (Masc_error.Auth_error_code.to_string
             Masc_error.Auth_error_code.Token_expired))
     = Some Credential.Expired);
  List.iter
    (fun (label, raw) ->
      check bool (label ^ " is a plain refusal") true
        (Credential.server_reason_of_body raw = Some Credential.Rejected))
    [ ("a code the server never writes", body "brand_new_code")
    ; ("a code that is not a string", {|{"auth_error_code":1}|})
    ];
  (* No code at all is not a credential refusal: the auth layer writes one on
     every refusal, so these came from a handler refusing the request. *)
  List.iter
    (fun (label, raw) ->
      check bool (label ^ " is not about the credential") true
        (Credential.server_reason_of_body raw = None))
    [ ("a handler's own refusal", {|{"error":"only your own queued message can be prioritized"}|})
    ; ("a body that is not JSON", "forbidden")
    ; ("a JSON value that is not an object", {|"token_expired"|})
    ]

(* Each reason says something different, and none of them contradicts sending a
   bearer; without one the reason is not consulted. *)
let test_each_reason_reads_as_itself () =
  let sent = Credential.refusal_cause ~credential_sent:true in
  check bool "expired says expired" true (has "has expired" (sent Credential.Expired));
  check bool "a forbidden bearer says it is not allowed" true
    (has "not allowed" (sent Credential.Insufficient_role));
  check bool "the rest is a refusal" true (has "was refused" (sent Credential.Rejected));
  List.iter
    (fun reason ->
      check string "no bearer ignores the reason"
        (Credential.refusal_cause ~credential_sent:false Credential.Rejected)
        (Credential.refusal_cause ~credential_sent:false reason))
    reasons

(* The environment wins so one run can be pointed at another credential, and
   the workspace file is next because that is where masc login put it. *)
let test_plan_prefers_the_environment () =
  let chosen = function
    | Credential.Use token -> token
    | Credential.Mint _ -> "mint"
    | Credential.Go_without -> "go-without"
    | Credential.No_workspace -> "no-workspace"
  in
  let plan ?(env = None) ?(file = Credential.Not_stored) ?(requires = true)
      ?(here = true) () =
    chosen
      (Credential.plan ~env_token:env ~workspace_token:file
         ~workspace_requires_token:requires ~workspace_initialized:here)
  in
  check string "the environment wins over the workspace" "env"
    (plan ~env:(Some "env") ~file:(Credential.Stored "file") ());
  check string "the workspace file is used when the environment is empty" "file"
    (plan ~file:(Credential.Stored "file") ());
  check string "an environment bearer is used even where none is demanded" "env"
    (plan ~env:(Some "env") ~requires:false ())

(* Minting is for a workspace that is already here and demands a bearer. The
   two conditions are separate: a missing auth config reads as the default and
   the default demands one, so an empty directory claims to require a bearer it
   has nowhere to put. *)
let test_plan_mints_only_into_a_workspace_that_demands_one () =
  let plan ~requires ~here =
    Credential.plan ~env_token:None ~workspace_token:Credential.Not_stored
      ~workspace_requires_token:requires ~workspace_initialized:here
  in
  check bool "a demanding workspace that is here mints" true
    (plan ~requires:true ~here:true = Credential.Mint Credential.First_token);
  check bool "a demanding path with no workspace does not mint" true
    (plan ~requires:true ~here:false = Credential.No_workspace);
  check bool "an open workspace does not mint" true
    (plan ~requires:false ~here:true = Credential.Go_without);
  check bool "an open path with no workspace needs nothing" true
    (plan ~requires:false ~here:false = Credential.Go_without)

(* A persisted bearer whose record has expired is not a bearer this client can
   use. Carrying it was the bug: every read came back refused, and restarting
   found the same file and carried it again. The environment still wins -- an
   operator who pointed this run at a credential gets that credential. *)
let test_an_expired_stored_token_is_replaced () =
  let plan ?(env = None) ?(requires = true) ?(here = true) () =
    Credential.plan ~env_token:env ~workspace_token:Credential.Stored_expired
      ~workspace_requires_token:requires ~workspace_initialized:here
  in
  check bool "a demanding workspace replaces it" true
    (plan () = Credential.Mint Credential.Replaces_expired);
  check bool "the environment still wins" true
    (plan ~env:(Some "env") () = Credential.Use "env");
  check bool "an open workspace goes without rather than carry it" true
    (plan ~requires:false () = Credential.Go_without);
  check bool "no workspace, no mint" true
    (plan ~here:false () = Credential.No_workspace)

(* The two mints are different news. An operator whose credential ran out
   should hear that, not that it never had one. *)
let test_a_replacement_says_the_old_one_expired () =
  match Credential.outcome_notice (Credential.Minted Credential.Replaces_expired) with
  | None -> fail "a replacement must be reported"
  | Some notice ->
      check bool "it says the stored one expired" true (has "had expired" notice);
      check bool "it does not claim none was present" false
        (has "no operator token was present" notice)

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
  (match Credential.outcome_notice (Credential.Minted Credential.First_token) with
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
  match Credential.outcome_notice (Credential.Mint_failed "disk is read-only") with
  | None -> fail "a failed mint must be reported"
  | Some notice ->
      check bool "a failed mint carries its own detail" true
        (has "disk is read-only" notice);
      check bool "a failed mint names the remedy" true
        (has Credential.remedy notice)

(* The one outcome a first install produces. It is the ordinary path -- the
   server that makes the workspace is the one the TUI starts a moment later --
   so the line must not hand over a command for a state that clears itself,
   which is what made the operator distrust it. *)
let test_a_pending_workspace_asks_nothing_of_the_operator () =
  match Credential.outcome_notice Credential.Workspace_pending with
  | None -> fail "a pending workspace must be reported"
  | Some notice ->
      check bool "it says what is missing" true
        (has "no workspace to mint into" notice);
      check bool "it says this client takes it again" true
        (has "mints one once a server answers" notice);
      check bool "it hands over no command" false
        (has Credential.login_command notice);
      check bool "it does not name the remedy" false
        (has Credential.remedy notice)

(* A boot with no workspace is the one outcome a workspace appearing later
   would change, and the reason a first install recovers without [masc login]:
   the server that makes the workspace is the one the TUI starts a moment
   after the boot decision was taken. The other four are answers already --
   including a mint that failed against a workspace that was already here,
   which is local file work and fails the same way after the server is up. *)
let test_only_a_pending_workspace_is_taken_again () =
  check bool "a missing workspace is taken again" true
    (Credential.outcome_needs_retry Credential.Workspace_pending);
  List.iter
    (fun (label, outcome) ->
      check bool (label ^ " is settled") false
        (Credential.outcome_needs_retry outcome))
    [ ("a held bearer", Credential.Held)
    ; ("a fresh mint", Credential.Minted Credential.First_token)
    ; ("a replaced expired bearer", Credential.Minted Credential.Replaces_expired)
    ; ("a workspace that demands none", Credential.Not_required)
    ; ("a mint that failed", Credential.Mint_failed "disk is read-only")
    ]

(* The level is part of the contract, not decoration: a first install's pending
   workspace is the ordinary path and must not read as an error, while a mint
   that failed is the one the operator has to act on. Reporting the pending
   workspace as an error made a working first start read as a broken one. *)
let test_only_a_failed_mint_is_an_error () =
  check string "a failed mint is an error" "error"
    (Credential.outcome_level (Credential.Mint_failed "disk is read-only"));
  List.iter
    (fun (label, outcome) ->
      check string (label ^ " is not an error") "system"
        (Credential.outcome_level outcome))
    [ ("a held bearer", Credential.Held)
    ; ("a fresh mint", Credential.Minted Credential.First_token)
    ; ("a replaced expired bearer", Credential.Minted Credential.Replaces_expired)
    ; ("a workspace that demands none", Credential.Not_required)
    ; ("a pending workspace", Credential.Workspace_pending)
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
        ; test_case "the server reason comes from the typed code" `Quick
            test_the_server_reason_comes_from_the_typed_code
        ; test_case "each reason reads as itself" `Quick
            test_each_reason_reads_as_itself
        ; test_case "the plan prefers the environment" `Quick
            test_plan_prefers_the_environment
        ; test_case "minting is only into a workspace that demands one" `Quick
            test_plan_mints_only_into_a_workspace_that_demands_one
        ; test_case "an expired stored token is replaced" `Quick
            test_an_expired_stored_token_is_replaced
        ; test_case "a replacement says the old one expired" `Quick
            test_a_replacement_says_the_old_one_expired
        ; test_case "the self-mint window is the client's own" `Quick
            test_self_mint_window_is_neither_a_day_nor_forever
        ; test_case "only the notable outcomes speak" `Quick
            test_only_the_notable_outcomes_speak
        ; test_case "a pending workspace asks nothing of the operator" `Quick
            test_a_pending_workspace_asks_nothing_of_the_operator
        ; test_case "only a pending workspace is taken again" `Quick
            test_only_a_pending_workspace_is_taken_again
        ; test_case "only a failed mint is an error" `Quick
            test_only_a_failed_mint_is_an_error
        ] )
    ]
