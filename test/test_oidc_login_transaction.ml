(* Logins in flight: a transaction is taken once, with its state, before it
   expires; a full store refuses a start; the invitation token and the return
   path parse by their grammar. No network; the clock is the [now_ms] passed
   in. *)

module T = Oidc_login_transaction

let token = String.make 64 'a'

let invite_of text =
  match T.Invite_token.of_form text with
  | Some invite -> invite
  | None -> Alcotest.fail "fixture token refused"
;;

let path_of text =
  match T.Local_path.of_string text with
  | Some path -> path
  | None -> Alcotest.fail "fixture path refused"
;;

let started store ~now_ms ?invite ?(return_to = T.Local_path.root) () =
  match T.start store ~now_ms ~invite ~return_to with
  | Ok started -> started
  | Error T.Full -> Alcotest.fail "the store is full"
;;

let outcome = function
  | Ok (_ : T.taken) -> "ok"
  | Error T.Unknown -> "unknown"
  | Error T.Expired -> "expired"
  | Error T.State_differs -> "state differs"
;;

let a_login_takes_back_what_it_started () =
  let store = T.create ~capacity:4 in
  let s = started store ~now_ms:0 ~invite:(invite_of token) ~return_to:(path_of "/board?tab=1") () in
  match T.take store ~now_ms:1 s.id ~state:s.state with
  | Error error -> Alcotest.failf "refused: %s" (T.take_error_to_string error)
  | Ok taken ->
    Alcotest.(check string) "the nonce sent to Google" s.nonce taken.nonce;
    Alcotest.(check string)
      "the challenge is S256 of the verifier"
      s.code_challenge
      (Auth_oauth.pkce_s256 taken.code_verifier);
    Alcotest.(check string) "the return path" "/board?tab=1" (T.Local_path.to_string taken.return_to);
    (match taken.invite with
     | Some invite ->
       Alcotest.(check string)
         "the invitation digest"
         (Authz_invite_event.Token_digest.to_hex (Authz_invite_event.Token_digest.of_token token))
         (Authz_invite_event.Token_digest.to_hex (T.Invite_token.digest invite))
     | None -> Alcotest.fail "the invitation was dropped")
;;

let a_transaction_is_taken_once () =
  let store = T.create ~capacity:4 in
  let s = started store ~now_ms:0 () in
  Alcotest.(check string) "first" "ok" (outcome (T.take store ~now_ms:0 s.id ~state:s.state));
  Alcotest.(check string) "again" "unknown" (outcome (T.take store ~now_ms:0 s.id ~state:s.state))
;;

let a_wrong_state_spends_the_transaction () =
  let store = T.create ~capacity:4 in
  let s = started store ~now_ms:0 () in
  let other = started store ~now_ms:0 () in
  Alcotest.(check string)
    "another login's state"
    "state differs"
    (outcome (T.take store ~now_ms:0 s.id ~state:other.state));
  Alcotest.(check string) "then the right one" "unknown" (outcome (T.take store ~now_ms:0 s.id ~state:s.state));
  Alcotest.(check string)
    "the other login is untouched"
    "ok"
    (outcome (T.take store ~now_ms:0 other.id ~state:other.state))
;;

let a_transaction_expires () =
  let store = T.create ~capacity:4 in
  let early = started store ~now_ms:1000 () in
  let late = started store ~now_ms:1000 () in
  Alcotest.(check string)
    "just before its lifetime"
    "ok"
    (outcome (T.take store ~now_ms:(1000 + T.lifetime_ms - 1) early.id ~state:early.state));
  Alcotest.(check string)
    "at its lifetime"
    "expired"
    (outcome (T.take store ~now_ms:(1000 + T.lifetime_ms) late.id ~state:late.state));
  Alcotest.(check string)
    "an expired one is gone"
    "unknown"
    (outcome (T.take store ~now_ms:(1000 + T.lifetime_ms) late.id ~state:late.state))
;;

let a_full_store_refuses_a_start () =
  let store = T.create ~capacity:2 in
  let first = started store ~now_ms:0 () in
  let (_ : T.started) = started store ~now_ms:5 () in
  let full () =
    match T.start store ~now_ms:10 ~invite:None ~return_to:T.Local_path.root with
    | Error T.Full -> true
    | Ok _ -> false
  in
  Alcotest.(check bool) "a third start" true (full ());
  Alcotest.(check int) "both live" 2 (T.live store ~now_ms:10);
  Alcotest.(check string)
    "the first one survived the refusal"
    "ok"
    (outcome (T.take store ~now_ms:10 first.id ~state:first.state));
  Alcotest.(check bool) "a taken one frees a place" false (full ());
  Alcotest.(check bool) "full again" true (full ());
  Alcotest.(check int) "none live after the lifetime" 0 (T.live store ~now_ms:(10 + T.lifetime_ms));
  match T.start store ~now_ms:(10 + T.lifetime_ms) ~invite:None ~return_to:T.Local_path.root with
  | Ok _ -> ()
  | Error T.Full -> Alcotest.fail "expired transactions were counted"
;;

let a_store_holds_at_least_one () =
  Alcotest.check_raises
    "capacity 0"
    (Invalid_argument "Oidc_login_transaction.create: capacity below 1")
    (fun () -> ignore (T.create ~capacity:0 : T.t))
;;

let is_lower_hex_of length text =
  String.length text = length
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       text
;;

let secrets_are_drawn_apart () =
  let store = T.create ~capacity:8 in
  let a = started store ~now_ms:0 () in
  let b = started store ~now_ms:0 () in
  List.iter
    (fun (label, value) -> Alcotest.(check bool) label true (is_lower_hex_of 64 value))
    [ "id", T.Id.to_string a.id; "state", a.state; "nonce", a.nonce ];
  Alcotest.(check int) "the challenge is 43 base64url characters" 43 (String.length a.code_challenge);
  let values = [ T.Id.to_string a.id; a.state; a.nonce; T.Id.to_string b.id; b.state; b.nonce ] in
  Alcotest.(check int)
    "no two are the same"
    (List.length values)
    (List.length (List.sort_uniq String.compare values));
  Alcotest.(check bool) "two challenges differ" false (String.equal a.code_challenge b.code_challenge)
;;

let ids_parse_back () =
  let store = T.create ~capacity:1 in
  let s = started store ~now_ms:0 () in
  (match T.Id.of_string (T.Id.to_string s.id) with
   | Some id -> Alcotest.(check string) "read back" "ok" (outcome (T.take store ~now_ms:0 id ~state:s.state))
   | None -> Alcotest.fail "an ID did not read back");
  List.iter
    (fun text -> Alcotest.(check bool) text true (Option.is_none (T.Id.of_string text)))
    [ ""; String.make 63 'a'; String.make 65 'a'; String.make 64 'A'; String.make 64 'g' ]
;;

let invitation_tokens_parse_by_form () =
  Alcotest.(check bool) "64 lowercase hex" true (Option.is_some (T.Invite_token.of_form token));
  List.iter
    (fun (label, text) -> Alcotest.(check bool) label true (Option.is_none (T.Invite_token.of_form text)))
    [ "empty", ""
    ; "63", String.make 63 'a'
    ; "65", String.make 65 'a'
    ; "upper case", String.make 64 'A'
    ; "not hex", String.make 64 'g'
    ; "a space", String.make 63 'a' ^ " "
    ]
;;

let return_paths_parse_by_grammar () =
  List.iter
    (fun text ->
      Alcotest.(check (option string))
        text
        (Some text)
        (Option.map T.Local_path.to_string (T.Local_path.of_string text)))
    [ "/"
    ; "/dashboard"
    ; "/a/b?x=1&y=%2F"
    ; "/a//b"
    ; "/?"
    ; "/a:b@c!$&'()*+,;=-._~"
    ; "/%41%5a"
    ; "/a?b/c?d"
    ];
  List.iter
    (fun (label, text) -> Alcotest.(check bool) label true (Option.is_none (T.Local_path.of_string text)))
    [ "empty", ""
    ; "relative", "dashboard"
    ; "an authority", "//evil.example"
    ; "a backslash host", "/\\evil.example"
    ; "a backslash later", "/a\\b"
    ; "a scheme", "https://evil.example/"
    ; "a scheme without slashes", "javascript:alert(1)"
    ; "a space", "/a b"
    ; "a fragment", "/a#b"
    ; "a fragment in the query", "/a?b#c"
    ; "a bad escape", "/%zz"
    ; "a short escape", "/%2"
    ; "an escape at the end of the query", "/a?%"
    ; "a newline", "/a\n"
    ; "a byte above ASCII", "/\xc3\xa9"
    ; "a quote", "/a\"b"
    ; "angle brackets", "/<script>"
    ]
;;

let take_errors_are_told_apart () =
  let texts = List.map T.take_error_to_string [ T.Unknown; T.Expired; T.State_differs ] in
  Alcotest.(check int) "each error has its own text" 3 (List.length (List.sort_uniq String.compare texts))
;;

let () =
  Alcotest.run
    "oidc_login_transaction"
    [ ( "transaction"
      , [ Alcotest.test_case "takes back what it started" `Quick a_login_takes_back_what_it_started
        ; Alcotest.test_case "taken once" `Quick a_transaction_is_taken_once
        ; Alcotest.test_case "a wrong state spends it" `Quick a_wrong_state_spends_the_transaction
        ; Alcotest.test_case "expires" `Quick a_transaction_expires
        ; Alcotest.test_case "a full store" `Quick a_full_store_refuses_a_start
        ; Alcotest.test_case "capacity" `Quick a_store_holds_at_least_one
        ; Alcotest.test_case "secrets" `Quick secrets_are_drawn_apart
        ; Alcotest.test_case "ids" `Quick ids_parse_back
        ; Alcotest.test_case "error texts" `Quick take_errors_are_told_apart
        ] )
    ; ( "forms"
      , [ Alcotest.test_case "invitation tokens" `Quick invitation_tokens_parse_by_form
        ; Alcotest.test_case "return paths" `Quick return_paths_parse_by_grammar
        ] )
    ]
;;
