(* Logins in flight: the server seals a transaction and the browser carries
   it. A sealed transaction opens with its state before it expires, under the
   key that sealed it and for the flow that started it; a start is never
   refused for the starts before it; the invitation token and the return
   path parse by their grammar. No network; the clock is the [now_ms] passed
   in. *)

module T = Oidc_login_transaction

let token = String.make 64 'a'

let invite_of text =
  match T.Invite_token.of_form text with
  | Some invite -> invite
  | None -> Alcotest.fail "fixture token refused"
;;

let session_of text =
  match Authz_types.Session_id.of_string text with
  | Ok session_id -> session_id
  | Error (_ : Authz_id.error) -> Alcotest.fail "fixture session id refused"
;;

let path_of text =
  match T.Local_path.of_string text with
  | Some path -> path
  | None -> Alcotest.fail "fixture path refused"
;;

let started key ~now_ms ?invite ?(return_to = T.Local_path.root) ?replaces () =
  match T.start key ~now_ms T.Google ~invite ~return_to ~replaces with
  | Ok started -> started
  | Error T.Too_long -> Alcotest.fail "the sealed transaction is too long"
;;

let outcome = function
  | Ok (_ : _ T.taken) -> "ok"
  | Error T.Unknown -> "unknown"
  | Error T.Other_flow -> "other flow"
  | Error T.Expired -> "expired"
  | Error T.State_differs -> "state differs"
;;

let sealed_of text =
  match T.Sealed.of_string text with
  | Some sealed -> sealed
  | None -> Alcotest.failf "not the shape of a sealed transaction: %d characters" (String.length text)
;;

let a_login_opens_what_it_started () =
  let key = T.create () in
  let s =
    started
      key
      ~now_ms:0
      ~invite:(invite_of token)
      ~return_to:(path_of "/board?tab=1")
      ~replaces:(session_of "session-1")
      ()
  in
  match T.open_ key ~now_ms:1 T.Google s.sealed ~state:s.state with
  | Error error -> Alcotest.failf "refused: %s" (T.open_error_to_string error)
  | Ok taken ->
    Alcotest.(check string) "the nonce sent to Google" s.held.nonce taken.held.nonce;
    Alcotest.(check string)
      "the challenge is S256 of the verifier"
      s.code_challenge
      (Auth_oauth.pkce_s256 taken.code_verifier);
    Alcotest.(check string) "the return path" "/board?tab=1" (T.Local_path.to_string taken.return_to);
    Alcotest.(check (option string))
      "the session of the browser that started"
      (Some "session-1")
      (Option.map Authz_types.Session_id.to_string taken.replaces);
    Alcotest.(check (option string))
      "the digest of the invitation"
      (Some (Authz_invite_event.Token_digest.to_hex (Authz_invite_event.Token_digest.of_token token)))
      (Option.map Authz_invite_event.Token_digest.to_hex taken.invite)
;;

(* The server remembers nothing of a transaction, so one that opened opens
   again, and a wrong state does not spend it. What a second callback could
   spend is spent once at the provider and in the log; the flow tests hold
   that. *)
let a_sealed_transaction_opens_again () =
  let key = T.create () in
  let s = started key ~now_ms:0 () in
  let other = started key ~now_ms:0 () in
  Alcotest.(check string)
    "another login's state"
    "state differs"
    (outcome (T.open_ key ~now_ms:0 T.Google s.sealed ~state:other.state));
  Alcotest.(check string) "then the right one" "ok" (outcome (T.open_ key ~now_ms:0 T.Google s.sealed ~state:s.state));
  Alcotest.(check string) "and again" "ok" (outcome (T.open_ key ~now_ms:0 T.Google s.sealed ~state:s.state))
;;

let a_transaction_expires () =
  let key = T.create () in
  let s = started key ~now_ms:1000 () in
  Alcotest.(check string)
    "just before its lifetime"
    "ok"
    (outcome (T.open_ key ~now_ms:(1000 + T.lifetime_ms - 1) T.Google s.sealed ~state:s.state));
  Alcotest.(check string)
    "at its lifetime"
    "expired"
    (outcome (T.open_ key ~now_ms:(1000 + T.lifetime_ms) T.Google s.sealed ~state:s.state));
  Alcotest.(check string)
    "a clock that was set back opens it"
    "ok"
    (outcome (T.open_ key ~now_ms:0 T.Google s.sealed ~state:s.state))
;;

(* The callback of one provider does not open the transaction of another. *)
let a_transaction_of_another_flow_does_not_open () =
  let key = T.create () in
  let github ~invite =
    match T.start key ~now_ms:0 T.Github ~invite ~return_to:(path_of "/keepers") ~replaces:None with
    | Ok (started : unit T.started) -> started
    | Error T.Too_long -> Alcotest.fail "the sealed transaction is too long"
  in
  let first = github ~invite:(Some (invite_of token)) in
  Alcotest.(check string)
    "a GitHub transaction at the Google callback"
    "other flow"
    (outcome (T.open_ key ~now_ms:0 T.Google first.sealed ~state:first.state));
  let google = started key ~now_ms:0 () in
  Alcotest.(check string)
    "a Google transaction at the GitHub callback"
    "other flow"
    (outcome (T.open_ key ~now_ms:0 T.Github google.sealed ~state:google.state));
  let second = github ~invite:None in
  match T.open_ key ~now_ms:1 T.Github second.sealed ~state:second.state with
  | Error error -> Alcotest.failf "refused: %s" (T.open_error_to_string error)
  | Ok (taken : unit T.taken) ->
    Alcotest.(check string)
      "the GitHub challenge is S256 of the verifier"
      second.code_challenge
      (Auth_oauth.pkce_s256 taken.code_verifier);
    Alcotest.(check string) "the return path" "/keepers" (T.Local_path.to_string taken.return_to);
    Alcotest.(check (option string))
      "no session at the start"
      None
      (Option.map Authz_types.Session_id.to_string taken.replaces);
    Alcotest.(check bool) "no invitation" true (Option.is_none taken.invite)
;;

(* Issue #51394: the store of the build before held a fixed number of logins,
   so starts with no credential could keep everyone else from starting. *)
let starts_do_not_wait_for_each_other () =
  let key = T.create () in
  let many = 2000 in
  let logins = List.init many (fun (_ : int) -> started key ~now_ms:0 ()) in
  Alcotest.(check int)
    "every one of them opens"
    many
    (List.length
       (List.filter
          (fun (s : T.google T.started) ->
            Result.is_ok (T.open_ key ~now_ms:1 T.Google s.sealed ~state:s.state))
          logins))
;;

let another_key_does_not_open () =
  let key = T.create () in
  let s = started key ~now_ms:0 () in
  Alcotest.(check string)
    "the key of another process"
    "unknown"
    (outcome (T.open_ (T.create ()) ~now_ms:0 T.Google s.sealed ~state:s.state))
;;

(* A character of the base64url alphabet that is not [c]. *)
let other_than c = if Char.equal c 'A' then 'B' else 'A'

let a_changed_character_does_not_open () =
  let key = T.create () in
  let s = started key ~now_ms:0 ~return_to:(path_of "/board") () in
  let text = T.Sealed.to_string s.sealed in
  let length = String.length text in
  (* Every character is in the nonce, the sealed bytes or the tag. The last
     one of an unpadded base64 text can hold bits that decode to nothing: a
     change there leaves the bytes, and the text is refused as another text
     of them. *)
  let opened_after_a_change =
    List.filter
      (fun at ->
        let changed = String.mapi (fun i c -> if i = at then other_than c else c) text in
        Result.is_ok (T.open_ key ~now_ms:0 T.Google (sealed_of changed) ~state:s.state))
      (List.init length Fun.id)
  in
  Alcotest.(check (list int)) "no changed text opens" [] opened_after_a_change;
  let opened_with_one_more =
    List.filter
      (fun more ->
        Result.is_ok
          (T.open_ key ~now_ms:0 T.Google (sealed_of (text ^ String.make 1 more)) ~state:s.state))
      [ 'A'; 'B'; 'Q'; 'g'; 'w'; '_' ]
  in
  Alcotest.(check (list char)) "no text with one more character opens" [] opened_with_one_more;
  Alcotest.(check string)
    "a text cut short"
    "unknown"
    (outcome (T.open_ key ~now_ms:0 T.Google (sealed_of (String.sub text 0 (length / 2))) ~state:s.state));
  Alcotest.(check string)
    "a text that was never sealed"
    "unknown"
    (outcome (T.open_ key ~now_ms:0 T.Google (sealed_of (String.make 80 'A')) ~state:s.state))
;;

let bytes_of (sealed : T.Sealed.t) =
  match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet (T.Sealed.to_string sealed) with
  | Ok bytes -> bytes
  | Error (`Msg detail) -> Alcotest.failf "a sealed transaction is not base64url: %s" detail
;;

let contains text ~part =
  let length = String.length part in
  let rec from at =
    at + length <= String.length text && (String.equal (String.sub text at length) part || from (at + 1))
  in
  from 0
;;

(* The browser reads the cookie. What it holds of the login is the sealed
   bytes, in which the state and the nonce the provider sees, and the return
   path, are not readable. *)
let the_sealed_bytes_show_nothing () =
  let key = T.create () in
  let s = started key ~now_ms:0 ~invite:(invite_of token) ~return_to:(path_of "/board-of-the-case") () in
  let bytes = bytes_of s.sealed in
  List.iter
    (fun (label, part) -> Alcotest.(check bool) label false (contains bytes ~part))
    [ "the state", s.state
    ; "the nonce", s.held.nonce
    ; "the return path", "/board-of-the-case"
    ; "the invitation token", token
    ; "the name of a field", "state"
    ]
;;

(* ChaCha20-Poly1305 gives up its key stream when two texts are sealed under
   one nonce. The nonce is the first twelve bytes of the sealed bytes. *)
let nonce_bytes = 12

let no_nonce_comes_twice () =
  let key = T.create () in
  let per_domain = 500 in
  let domains = 4 in
  let seal () =
    List.init per_domain (fun (_ : int) -> String.sub (bytes_of (started key ~now_ms:0 ()).sealed) 0 nonce_bytes)
  in
  let nonces = List.concat_map Domain.join (List.init domains (fun (_ : int) -> Domain.spawn seal)) in
  Alcotest.(check int)
    "the nonces of four domains that seal at once"
    (per_domain * domains)
    (List.length (List.sort_uniq String.compare nonces));
  let a = started key ~now_ms:0 () in
  let b = started key ~now_ms:0 () in
  Alcotest.(check bool)
    "two logins that start in the same millisecond are sealed apart"
    false
    (String.equal (T.Sealed.to_string a.sealed) (T.Sealed.to_string b.sealed))
;;

(* The return path is the one part of a transaction whose length the request
   chooses. *)
let a_return_path_too_long_for_a_cookie_is_refused () =
  let key = T.create () in
  let start_with length =
    T.start
      key
      ~now_ms:0
      T.Google
      ~invite:(Some (invite_of token))
      ~return_to:(path_of ("/" ^ String.make (length - 1) 'a'))
      ~replaces:(Some (session_of "session-1"))
  in
  (match start_with 2048 with
   | Ok (s : T.google T.started) ->
     Alcotest.(check bool)
       "a path of 2048 characters fits"
       true
       (String.length (T.Sealed.to_string s.sealed) <= T.max_sealed_length)
   | Error T.Too_long -> Alcotest.fail "a path of 2048 characters was refused");
  match start_with 4096 with
  | Error T.Too_long -> ()
  | Ok (_ : T.google T.started) -> Alcotest.fail "a path of 4096 characters was sealed"
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
  let key = T.create () in
  let a = started key ~now_ms:0 () in
  let b = started key ~now_ms:0 () in
  List.iter
    (fun (label, value) -> Alcotest.(check bool) label true (is_lower_hex_of 64 value))
    [ "state", a.state; "nonce", a.held.nonce ];
  Alcotest.(check int) "the challenge is 43 base64url characters" 43 (String.length a.code_challenge);
  let values = [ a.state; a.held.nonce; b.state; b.held.nonce ] in
  Alcotest.(check int)
    "no two are the same"
    (List.length values)
    (List.length (List.sort_uniq String.compare values));
  Alcotest.(check bool) "two challenges differ" false (String.equal a.code_challenge b.code_challenge)
;;

let sealed_texts_parse_by_shape () =
  let key = T.create () in
  let s = started key ~now_ms:0 () in
  (match T.Sealed.of_string (T.Sealed.to_string s.sealed) with
   | Some sealed ->
     Alcotest.(check string) "read back" "ok" (outcome (T.open_ key ~now_ms:0 T.Google sealed ~state:s.state))
   | None -> Alcotest.fail "a sealed transaction did not read back");
  Alcotest.(check bool)
    "the longest text"
    true
    (Option.is_some (T.Sealed.of_string (String.make T.max_sealed_length 'a')));
  List.iter
    (fun (label, text) -> Alcotest.(check bool) label true (Option.is_none (T.Sealed.of_string text)))
    [ "empty", ""
    ; "one character too long", String.make (T.max_sealed_length + 1) 'a'
    ; "padding", "YWJj="
    ; "the plus of standard base64", "ab+c"
    ; "a slash", "ab/c"
    ; "a space", "ab c"
    ; "a semicolon", "abc;"
    ]
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

let open_errors_are_told_apart () =
  let texts = List.map T.open_error_to_string [ T.Unknown; T.Other_flow; T.Expired; T.State_differs ] in
  Alcotest.(check int) "each error has its own text" 4 (List.length (List.sort_uniq String.compare texts))
;;

let () =
  Alcotest.run
    "oidc_login_transaction"
    [ ( "transaction"
      , [ Alcotest.test_case "opens what it started" `Quick a_login_opens_what_it_started
        ; Alcotest.test_case "opens again" `Quick a_sealed_transaction_opens_again
        ; Alcotest.test_case "expires" `Quick a_transaction_expires
        ; Alcotest.test_case "another flow" `Quick a_transaction_of_another_flow_does_not_open
        ; Alcotest.test_case "starts do not wait" `Quick starts_do_not_wait_for_each_other
        ; Alcotest.test_case "another key" `Quick another_key_does_not_open
        ; Alcotest.test_case "a changed character" `Quick a_changed_character_does_not_open
        ; Alcotest.test_case "the sealed bytes" `Quick the_sealed_bytes_show_nothing
        ; Alcotest.test_case "nonces" `Quick no_nonce_comes_twice
        ; Alcotest.test_case "a long return path" `Quick a_return_path_too_long_for_a_cookie_is_refused
        ; Alcotest.test_case "secrets" `Quick secrets_are_drawn_apart
        ; Alcotest.test_case "sealed texts" `Quick sealed_texts_parse_by_shape
        ; Alcotest.test_case "error texts" `Quick open_errors_are_told_apart
        ] )
    ; ( "forms"
      , [ Alcotest.test_case "invitation tokens" `Quick invitation_tokens_parse_by_form
        ; Alcotest.test_case "return paths" `Quick return_paths_parse_by_grammar
        ] )
    ]
;;
