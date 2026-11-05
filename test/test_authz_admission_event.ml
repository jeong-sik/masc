(* Checks for the identity key of a person and the body of an admission: what
   each accepts, the bytes it writes, that it reads back what it wrote, and every
   way a body fails to be one. A last case puts an admission in a record and
   checks who may write it. No files, clock, or network. *)

open Authz_types
open Authz_records
module X = Authz_external_identity
module A = Authz_admission_event
module R = Authz_record

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture value rejected"
;;

let user = get (User_id.of_string "0123456789abcdef0123456789abcdef")
let invite = get (Invite_id.of_string "invite-1")
let google_alice = get (X.google ~sub:"110169484474386276334")
let github_alice = get (X.github ~user_id:583231)
let membership =
  { A.workspace_id = get (Workspace_id.of_string "workspace-1")
  ; account_home_namespace = get (Account_home_namespace.of_string "c0ffee00c0ffee00c0ffee00c0ffee00")
  }
;;

let admission identity = { A.user_id = user; identity; invite_id = invite; membership }

let to_body_exn to_body value =
  match to_body value with
  | Ok body -> body
  | Error error -> Alcotest.failf "the body was refused: %s" (Authz_body.error_to_string error)
;;

let body_of_json json =
  match Authz_body.of_yojson json with
  | Ok body -> body
  | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
;;

let identity_error_name : X.error -> string = function
  | X.Google_sub_empty -> "google sub empty"
  | X.Google_sub_too_long -> "google sub too long"
  | X.Google_sub_invalid_byte { index } -> Printf.sprintf "google sub invalid byte %d" index
  | X.Github_user_id_not_positive -> "github user id not positive"
  | X.Github_user_id_too_large -> "github user id too large"
;;

(* ---- the identity ---- *)

let what_an_identity_accepts () =
  List.iter
    (fun (name, result, expected) ->
      match result with
      | Ok identity -> Alcotest.(check string) name expected ("ok " ^ X.to_string identity)
      | Error error -> Alcotest.(check string) name expected (identity_error_name error))
    [ "a numeric sub", X.google ~sub:"110169484474386276334", "ok google:110169484474386276334"
    ; "a sub of 255 bytes", X.google ~sub:(String.make 255 'a'), "ok google:" ^ String.make 255 'a'
    ; "every visible character", X.google ~sub:"!~AZaz09", "ok google:!~AZaz09"
    ; "an empty sub", X.google ~sub:"", "google sub empty"
    ; "a sub of 256 bytes", X.google ~sub:(String.make 256 'a'), "google sub too long"
    ; "a space", X.google ~sub:"ab cd", "google sub invalid byte 2"
    ; "a control character", X.google ~sub:"\nab", "google sub invalid byte 0"
    ; "a byte above ASCII", X.google ~sub:"a\xc3\xa9", "google sub invalid byte 1"
    ; "a GitHub id", X.github ~user_id:583231, "ok github:583231"
    ; "the largest GitHub id", X.github ~user_id:((1 lsl 53) - 1), "ok github:9007199254740991"
    ; "zero", X.github ~user_id:0, "github user id not positive"
    ; "a negative id", X.github ~user_id:(-1), "github user id not positive"
    ; "an id above 2^53 - 1", X.github ~user_id:(1 lsl 53), "github user id too large"
    ]
;;

let identities_are_told_apart () =
  Alcotest.(check bool) "the same Google sub" true (X.equal google_alice (get (X.google ~sub:"110169484474386276334")));
  Alcotest.(check bool) "a sub differs in case" false (X.equal (get (X.google ~sub:"Ab")) (get (X.google ~sub:"ab")));
  Alcotest.(check bool) "Google and GitHub with the same digits" false
    (X.equal (get (X.google ~sub:"583231")) github_alice);
  Alcotest.(check bool) "another GitHub id" false (X.equal github_alice (get (X.github ~user_id:583232)));
  let map = X.Map.(empty |> add google_alice "google" |> add github_alice "github") in
  Alcotest.(check (option string)) "a map finds the Google one" (Some "google") (X.Map.find_opt google_alice map);
  Alcotest.(check (option string)) "a map finds the GitHub one" (Some "github") (X.Map.find_opt github_alice map)
;;

let bytes_of_an_identity () =
  Alcotest.(check string) "google" {|{"provider":"google","sub":"110169484474386276334"}|}
    (Authz_body.to_string (to_body_exn X.to_body google_alice));
  Alcotest.(check string) "github" {|{"provider":"github","user_id":583231}|}
    (Authz_body.to_string (to_body_exn X.to_body github_alice))
;;

(* ---- the admission ---- *)

let bytes_of_an_admission () =
  Alcotest.(check string)
    "google"
    ({|{"user_id":"0123456789abcdef0123456789abcdef","identity":{"provider":"google","sub":"110169484474386276334"},"invite_id":"invite-1","membership":{"workspace_id":"workspace-1","account_home_namespace":"c0ffee00c0ffee00c0ffee00c0ffee00"}}|})
    (Authz_body.to_string (to_body_exn A.to_body (admission google_alice)))
;;

let an_admission_reads_back () =
  List.iter
    (fun identity ->
      let t = admission identity in
      match A.of_body (to_body_exn A.to_body t) with
      | Ok back -> Alcotest.(check bool) (X.to_string identity) true (A.equal t back)
      | Error error -> Alcotest.failf "refused: %s" (A.error_to_string error))
    [ google_alice; github_alice; get (X.google ~sub:(String.make 255 '~')) ]
;;

let error_name : A.error -> string = function
  | A.Not_an_object -> "not an object"
  | A.Wrong_members -> "wrong members"
  | A.Invalid_user_id _ -> "invalid user id"
  | A.Invalid_identity X.Not_an_object -> "identity not an object"
  | A.Invalid_identity (X.Unknown_provider label) -> Printf.sprintf "unknown provider %S" label
  | A.Invalid_identity X.Wrong_members -> "identity wrong members"
  | A.Invalid_identity (X.Invalid error) -> "invalid identity: " ^ identity_error_name error
  | A.Invalid_invite_id _ -> "invalid invite id"
  | A.Invalid_workspace_id _ -> "invalid workspace id"
  | A.Invalid_account_home_namespace _ -> "invalid account home namespace"
;;

let body ?(user_id = `String "user-1") ?(identity = `Assoc [ "provider", `String "github"; "user_id", `Int 1 ])
    ?(invite_id = `String "invite-1") ?(workspace_id = `String "workspace-1")
    ?(namespace = `String "ns-1") () =
  `Assoc
    [ "user_id", user_id
    ; "identity", identity
    ; "invite_id", invite_id
    ; "membership", `Assoc [ "workspace_id", workspace_id; "account_home_namespace", namespace ]
    ]
;;

let refusals =
  [ "null", `Null, "not an object"
  ; "a list", `List [], "not an object"
  ; "an empty object", `Assoc [], "wrong members"
  ; "members in another order", `Assoc [ "invite_id", `String "i"; "user_id", `String "u"; "identity", `Assoc [] ], "wrong members"
  ; "an identity that is a string", body ~identity:(`String "google:1") (), "wrong members"
  ; "another member", `Assoc [ "user_id", `String "u"; "identity", `Assoc []; "invite_id", `String "i"; "role", `String "admin" ], "wrong members"
  ; "an empty user id", body ~user_id:(`String "") (), "invalid user id"
  ; "an empty identity", body ~identity:(`Assoc []) (), "identity wrong members"
  ; "an unknown provider", body ~identity:(`Assoc [ "provider", `String "gitlab"; "user_id", `Int 1 ]) (), {|unknown provider "gitlab"|}
  ; "a provider in another case", body ~identity:(`Assoc [ "provider", `String "Google"; "sub", `String "1" ]) (), {|unknown provider "Google"|}
  ; "a GitHub id that is a string", body ~identity:(`Assoc [ "provider", `String "github"; "user_id", `String "1" ]) (), "identity wrong members"
  ; "a Google identity with a user id", body ~identity:(`Assoc [ "provider", `String "google"; "user_id", `Int 1 ]) (), "identity wrong members"
  ; "a GitHub id of zero", body ~identity:(`Assoc [ "provider", `String "github"; "user_id", `Int 0 ]) (), "invalid identity: github user id not positive"
  ; "a Google sub with a space", body ~identity:(`Assoc [ "provider", `String "google"; "sub", `String "a b" ]) (), "invalid identity: google sub invalid byte 1"
  ; "an invite id that is a path segment", body ~invite_id:(`String "..") (), "invalid invite id"
  ; "a bad user id comes before a bad identity", body ~user_id:(`String "") ~identity:(`Assoc []) (), "invalid user id"
  ; "no membership", `Assoc [ "user_id", `String "u"; "identity", `Assoc [ "provider", `String "github"; "user_id", `Int 1 ]; "invite_id", `String "i" ], "wrong members"
  ; "a membership with its members in another order", `Assoc [ "user_id", `String "u"; "identity", `Assoc [ "provider", `String "github"; "user_id", `Int 1 ]; "invite_id", `String "i"; "membership", `Assoc [ "account_home_namespace", `String "n"; "workspace_id", `String "w" ] ], "wrong members"
  ; "a namespace that is a number", body ~namespace:(`Int 1) (), "wrong members"
  ; "an empty workspace id", body ~workspace_id:(`String "") (), "invalid workspace id"
  ; "a namespace that is a path segment", body ~namespace:(`String "..") (), "invalid account home namespace"
  ; "a bad invite id comes before a bad workspace", body ~invite_id:(`String "") ~workspace_id:(`String "") (), "invalid invite id"
  ]
;;

let a_body_that_is_not_an_admission_is_refused () =
  List.iter
    (fun (name, json, expected) ->
      match A.of_body (body_of_json json) with
      | Ok _ -> Alcotest.failf "%s was read as an admission" name
      | Error error -> Alcotest.(check string) name expected (error_name error))
    refusals
;;

(* ---- the admission in a record ---- *)

let only_an_authenticated_principal_writes_one () =
  let body = to_body_exn A.to_body (admission google_alice) in
  let make author = R.make ~head:R.genesis ~at_ms:1000 ~author ~kind:R.Kind.Admission ~body in
  (match make (Author.Authenticated (Principal.Human user)) with
   | Error _ -> Alcotest.fail "the person may write their admission"
   | Ok record ->
     (match R.of_line ~head:R.genesis (R.to_line record) with
      | Error _ -> Alcotest.fail "the line of the record is not read back"
      | Ok read ->
        Alcotest.(check string) "the kind" "admission" (R.Kind.to_string read.R.kind);
        (match A.of_body read.R.body with
         | Ok back -> Alcotest.(check bool) "the body" true (A.equal (admission google_alice) back)
         | Error error -> Alcotest.failf "refused: %s" (A.error_to_string error))));
  List.iter
    (fun author ->
      match make author with
      | Error (R.Author_not_admitted _) -> ()
      | Ok _ -> Alcotest.fail "an author who is not a principal wrote an admission")
    [ Author.Local_operator; Author.System_cron; Author.System_maintenance; Author.System_migration ]
;;

let () =
  Alcotest.run
    "authz_admission_event"
    [ ( "identity"
      , [ Alcotest.test_case "what it accepts" `Quick what_an_identity_accepts
        ; Alcotest.test_case "told apart" `Quick identities_are_told_apart
        ; Alcotest.test_case "bytes" `Quick bytes_of_an_identity
        ] )
    ; ( "admission"
      , [ Alcotest.test_case "bytes" `Quick bytes_of_an_admission
        ; Alcotest.test_case "reads back" `Quick an_admission_reads_back
        ; Alcotest.test_case "refusals" `Quick a_body_that_is_not_an_admission_is_refused
        ] )
    ; "record", [ Alcotest.test_case "who writes it" `Quick only_an_authenticated_principal_writes_one ]
    ]
;;
