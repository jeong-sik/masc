(* The claim check of a Google ID token: the payload that a verified signature
   gave back, read against the client ID and the nonce of one login. No
   network, no clock, no keys: the payloads are JSON written here. *)

module G = Oidc_google
module Identity = Authz_external_identity

let client_id = "client-1.apps.googleusercontent.com"
let nonce = "nonce-1"

let payload ?(iss = `String "https://accounts.google.com") ?(aud = `String client_id) ?(nonce_claim = `String nonce)
    ?(sub = `String "110169484474386276334") ?(extra = []) ()
  =
  `Assoc ([ "iss", iss; "aud", aud; "nonce", nonce_claim; "sub", sub ] @ extra)
;;

let without name = function
  | `Assoc members -> `Assoc (List.filter (fun (member, _) -> not (String.equal member name)) members)
  | other -> other
;;

let error_name : G.error -> string = function
  | G.Payload_not_an_object -> "not an object"
  | G.Issuer_not_google -> "issuer"
  | G.Audience_is_a_list -> "audience list"
  | G.Audience_not_this_client -> "audience"
  | G.Nonce_differs -> "nonce"
  | G.Subject_not_a_string -> "sub missing"
  | G.Subject_invalid Identity.Google_sub_empty -> "sub empty"
  | G.Subject_invalid Identity.Google_sub_too_long -> "sub too long"
  | G.Subject_invalid (Identity.Google_sub_invalid_byte { index }) -> Printf.sprintf "sub byte %d" index
  | G.Subject_invalid (Identity.Github_user_id_not_positive | Identity.Github_user_id_too_large) ->
    "a GitHub error"
;;

let outcome json =
  match G.identity ~client_id ~nonce json with
  | Ok identity -> "ok " ^ Identity.to_string identity
  | Error error -> error_name error
;;

let check label expected json = Alcotest.(check string) label expected (outcome json)

let a_google_token_names_its_subject () =
  check "the issuer with a scheme" "ok google:110169484474386276334" (payload ());
  check "the issuer without one" "ok google:110169484474386276334" (payload ~iss:(`String "accounts.google.com") ());
  check
    "claims it does not read"
    "ok google:110169484474386276334"
    (payload ~extra:[ "email", `String "a@example.com"; "hd", `String "example.com"; "azp", `String "other" ] ())
;;

let the_identity_is_the_google_branch () =
  match G.identity ~client_id ~nonce (payload ()) with
  | Ok identity ->
    (match Identity.google ~sub:"110169484474386276334" with
     | Ok expected -> Alcotest.(check bool) "the same identity" true (Identity.equal identity expected)
     | Error _ -> Alcotest.fail "fixture sub refused")
  | Error error -> Alcotest.failf "refused: %s" (G.error_to_string error)
;;

let tokens_for_another_login_are_refused () =
  List.iter
    (fun (label, expected, json) -> check label expected json)
    [ "not an object", "not an object", `List [ payload () ]
    ; "no issuer", "issuer", without "iss" (payload ())
    ; "another issuer", "issuer", payload ~iss:(`String "https://login.example.com") ()
    ; "a trailing slash", "issuer", payload ~iss:(`String "https://accounts.google.com/") ()
    ; "another case", "issuer", payload ~iss:(`String "https://Accounts.google.com") ()
    ; "plain http", "issuer", payload ~iss:(`String "http://accounts.google.com") ()
    ; "an issuer list", "issuer", payload ~iss:(`List [ `String "accounts.google.com" ]) ()
    ; "no audience", "audience", without "aud" (payload ())
    ; "another client", "audience", payload ~aud:(`String "client-2.apps.googleusercontent.com") ()
    ; "an audience number", "audience", payload ~aud:(`Int 1) ()
    ; "a list with this client", "audience list", payload ~aud:(`List [ `String client_id ]) ()
    ; ( "a list with this client and another"
      , "audience list"
      , payload ~aud:(`List [ `String client_id; `String "client-2" ]) () )
    ; "no nonce", "nonce", without "nonce" (payload ())
    ; "another nonce", "nonce", payload ~nonce_claim:(`String "nonce-2") ()
    ; "a nonce prefix", "nonce", payload ~nonce_claim:(`String "nonce-") ()
    ; "a longer nonce", "nonce", payload ~nonce_claim:(`String "nonce-11") ()
    ; "an empty nonce", "nonce", payload ~nonce_claim:(`String "") ()
    ; "a nonce number", "nonce", payload ~nonce_claim:(`Int 1) ()
    ; "no sub", "sub missing", without "sub" (payload ())
    ; "a sub number", "sub missing", payload ~sub:(`Int 110169484) ()
    ; "an empty sub", "sub empty", payload ~sub:(`String "") ()
    ; "a sub of 256 bytes", "sub too long", payload ~sub:(`String (String.make 256 'a')) ()
    ; "a sub with a space", "sub byte 3", payload ~sub:(`String "110 169") ()
    ]
;;

let the_first_failing_check_is_the_answer () =
  check
    "issuer before audience"
    "issuer"
    (payload ~iss:(`String "other") ~aud:(`String "other") ());
  check "audience before nonce" "audience" (payload ~aud:(`String "other") ~nonce_claim:(`String "other") ());
  check "nonce before sub" "nonce" (payload ~nonce_claim:(`String "other") ~sub:(`String "") ())
;;

let a_sub_of_255_bytes_is_one () =
  check "255 bytes" ("ok google:" ^ String.make 255 'a') (payload ~sub:(`String (String.make 255 'a')) ())
;;

let errors_are_told_apart () =
  let texts =
    List.map
      G.error_to_string
      [ G.Payload_not_an_object
      ; G.Issuer_not_google
      ; G.Audience_is_a_list
      ; G.Audience_not_this_client
      ; G.Nonce_differs
      ; G.Subject_not_a_string
      ; G.Subject_invalid Identity.Google_sub_empty
      ]
  in
  Alcotest.(check int) "each error has its own text" (List.length texts) (List.length (List.sort_uniq String.compare texts))
;;

let () =
  Alcotest.run
    "oidc_google"
    [ ( "claims"
      , [ Alcotest.test_case "a Google token" `Quick a_google_token_names_its_subject
        ; Alcotest.test_case "the Google branch" `Quick the_identity_is_the_google_branch
        ; Alcotest.test_case "another login" `Quick tokens_for_another_login_are_refused
        ; Alcotest.test_case "order" `Quick the_first_failing_check_is_the_answer
        ; Alcotest.test_case "255 bytes" `Quick a_sub_of_255_bytes_is_one
        ; Alcotest.test_case "texts" `Quick errors_are_told_apart
        ] )
    ]
;;
