(* Checks for the body of a Service credential record: the bytes it writes,
   that it reads back what it wrote, what equal tells apart, and every way a
   body fails to be one. No files, clock, or network. *)

open Authz_types
module E = Authz_service_credential_event
module D = Authz_credential_token.Service_credential.Digest

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let credential_of text = get (Service_credential_id.of_string text)
let service_of text = get (Service_id.of_string text)
let first = credential_of "cred-1"
let second = credential_of "cred-2"
let keeper_runner = service_of "keeper-runner"
let other_service = service_of "board-trigger"
let digest_hex = String.make 64 'c'

let digest_of hex =
  match D.of_hex hex with
  | Some digest -> digest
  | None -> Alcotest.fail "fixture digest refused"
;;

let digest = digest_of digest_hex
let other_digest = digest_of (String.make 64 'f')

let issued ?(credential_id = first) ?(service_id = keeper_runner) ?(secret_digest = digest) () =
  E.Issued { credential_id; service_id; secret_digest }
;;

let revoked = E.Revoked { credential_id = first }

let body_of_json json =
  match Authz_body.of_yojson json with
  | Ok body -> body
  | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
;;

let to_body_exn t =
  match E.to_body t with
  | Ok body -> body
  | Error error -> Alcotest.failf "the body was refused: %s" (Authz_body.error_to_string error)
;;

let error = Alcotest.testable (fun ppf e -> Format.pp_print_string ppf (E.error_to_string e)) ( = )

(* ---- the bytes ---- *)

let the_bytes_of_a_record () =
  Alcotest.(check string)
    "issued"
    ({|{"event":"issued","credential_id":"cred-1","service_id":"keeper-runner","secret_digest":"|}
     ^ digest_hex
     ^ {|"}|})
    (Authz_body.to_string (to_body_exn (issued ())));
  Alcotest.(check string)
    "revoked"
    {|{"event":"revoked","credential_id":"cred-1"}|}
    (Authz_body.to_string (to_body_exn revoked))
;;

let a_record_reads_back () =
  List.iter
    (fun (name, t) ->
       match E.of_body (to_body_exn t) with
       | Ok back -> Alcotest.(check bool) name true (E.equal t back)
       | Error e -> Alcotest.failf "%s: %s" name (E.error_to_string e))
    [ "issued", issued (); "an id with a dot", issued ~credential_id:(credential_of "a.b") (); "revoked", revoked ]
;;

let equal_tells_records_apart () =
  let base = issued () in
  List.iter
    (fun (name, other) -> Alcotest.(check bool) name false (E.equal base other))
    [ "credential id", issued ~credential_id:second ()
    ; "service", issued ~service_id:other_service ()
    ; "digest", issued ~secret_digest:other_digest ()
    ; "revoked", revoked
    ];
  Alcotest.(check bool) "the same" true (E.equal base (issued ()));
  Alcotest.(check bool) "revoked twice" true (E.equal revoked (E.Revoked { credential_id = first }));
  Alcotest.(check string)
    "credential id of issued"
    "cred-1"
    (Service_credential_id.to_string (E.credential_id base));
  Alcotest.(check string)
    "credential id of revoked"
    "cred-1"
    (Service_credential_id.to_string (E.credential_id revoked))
;;

(* ---- refusals ---- *)

let issued_json
      ?(credential_id = `String "cred-1")
      ?(service_id = `String "keeper-runner")
      ?(secret_digest = `String digest_hex)
      ()
  =
  `Assoc
    [ "event", `String "issued"
    ; "credential_id", credential_id
    ; "service_id", service_id
    ; "secret_digest", secret_digest
    ]
;;

let refused () =
  List.iter
    (fun (name, json, expected) ->
       match E.of_body (body_of_json json) with
       | Ok _ -> Alcotest.failf "%s: read as a Service credential record" name
       | Error e -> Alcotest.check error name expected e)
    [ "a list", `List [], E.Not_an_object
    ; "null", `Null, E.Not_an_object
    ; "no event", `Assoc [ "credential_id", `String "cred-1" ], E.Wrong_members
    ; "an unknown event", `Assoc [ "event", `String "expired" ], E.Unknown_event "expired"
    ; ( "issued without a digest"
      , `Assoc
          [ "event", `String "issued"
          ; "credential_id", `String "cred-1"
          ; "service_id", `String "keeper-runner"
          ]
      , E.Wrong_members )
    ; ( "issued with an expiry"
      , `Assoc
          [ "event", `String "issued"
          ; "credential_id", `String "cred-1"
          ; "service_id", `String "keeper-runner"
          ; "secret_digest", `String digest_hex
          ; "expires_at_ms", `Null
          ]
      , E.Wrong_members )
    ; ( "issued in another order"
      , `Assoc
          [ "event", `String "issued"
          ; "service_id", `String "keeper-runner"
          ; "credential_id", `String "cred-1"
          ; "secret_digest", `String digest_hex
          ]
      , E.Wrong_members )
    ; "a service id that is a number", issued_json ~service_id:(`Int 1) (), E.Wrong_members
    ; "a digest that is null", issued_json ~secret_digest:`Null (), E.Wrong_members
    ; ( "a bad credential id"
      , issued_json ~credential_id:(`String "cred 1") ()
      , E.Invalid_credential_id (Authz_id.Invalid_byte { index = 4 }) )
    ; ( "a bad service id"
      , issued_json ~service_id:(`String ".") ()
      , E.Invalid_service_id Authz_id.Path_segment )
    ; ( "a digest one short"
      , issued_json ~secret_digest:(`String (String.make 63 'c')) ()
      , E.Invalid_secret_digest )
    (* The credential id is read before the service id. *)
    ; ( "a bad credential id and a bad service id"
      , issued_json ~credential_id:(`String "") ~service_id:(`String "") ()
      , E.Invalid_credential_id Authz_id.Empty )
    ; ( "revoked with a service"
      , `Assoc
          [ "event", `String "revoked"
          ; "credential_id", `String "cred-1"
          ; "service_id", `String "keeper-runner"
          ]
      , E.Wrong_members )
    ; ( "revoked with a number"
      , `Assoc [ "event", `String "revoked"; "credential_id", `Int 1 ]
      , E.Wrong_members )
    ; ( "revoked with a bad id"
      , `Assoc [ "event", `String "revoked"; "credential_id", `String "" ]
      , E.Invalid_credential_id Authz_id.Empty )
    ]
;;

let () =
  Alcotest.run
    "authz_service_credential_event"
    [ ( "body"
      , [ Alcotest.test_case "the bytes of a record" `Quick the_bytes_of_a_record
        ; Alcotest.test_case "a record reads back" `Quick a_record_reads_back
        ; Alcotest.test_case "equal tells records apart" `Quick equal_tells_records_apart
        ] )
    ; ( "refused"
      , [ Alcotest.test_case "bodies that are not a Service credential record" `Quick refused ] )
    ]
;;
