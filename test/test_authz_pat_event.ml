(* Checks for the body of a scoped PAT record: the bytes it writes, that it
   reads back what it wrote, what equal tells apart, and every way a body fails
   to be one. No files, clock, or network. *)

open Authz_types
module E = Authz_pat_event
module D = Authz_credential_token.Pat.Digest

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let pat_of text = get (Pat_id.of_string text)
let user_of text = get (User_id.of_string text)
let runtime_of text = get (Runtime_id.of_string text)
let first = pat_of "pat-1"
let second = pat_of "pat-2"
let alice = user_of "alice"
let bob = user_of "bob"
let digest_hex = String.make 64 'd'

let digest =
  match D.of_hex digest_hex with
  | Some digest -> digest
  | None -> Alcotest.fail "fixture digest refused"
;;

let other_digest =
  match D.of_hex (String.make 64 'e') with
  | Some digest -> digest
  | None -> Alcotest.fail "fixture digest refused"
;;

let scope =
  { Authorization_scope.runtimes = Runtime_scope.only (Runtime_id.Set.singleton (runtime_of "r-1"))
  ; channels = Channel_scope.only (Channel.Set.singleton Channel.Direct)
  ; allowed_effects = Effect_scope.only (Effect.Set.singleton Effect.Read_state)
  }
;;

let issued
      ?(pat_id = first)
      ?(user_id = alice)
      ?(secret_digest = digest)
      ?(scope = scope)
      ?(expires_at_ms = Some 1_800_000_000_000)
      ()
  =
  E.Issued { pat_id; user_id; secret_digest; scope; expires_at_ms }
;;

let revoked = E.Revoked { pat_id = first }

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

let scope_json =
  `Assoc
    [ "runtimes", `List [ `String "r-1" ]
    ; "channels", `List [ `String "direct" ]
    ; "allowed_effects", `List [ `String "read_state" ]
    ]
;;

(* ---- the bytes ---- *)

let the_bytes_of_a_record () =
  Alcotest.(check string)
    "issued"
    ({|{"event":"issued","pat_id":"pat-1","user_id":"alice","secret_digest":"|}
     ^ digest_hex
     ^ {|","scope":{"runtimes":["r-1"],"channels":["direct"],"allowed_effects":["read_state"]},"expires_at_ms":1800000000000}|}
    )
    (Authz_body.to_string (to_body_exn (issued ())));
  Alcotest.(check string)
    "no expiry"
    ({|{"event":"issued","pat_id":"pat-1","user_id":"alice","secret_digest":"|}
     ^ digest_hex
     ^ {|","scope":{"runtimes":"all","channels":"all","allowed_effects":"all"},"expires_at_ms":null}|}
    )
    (Authz_body.to_string
       (to_body_exn (issued ~scope:Authorization_scope.all ~expires_at_ms:None ())));
  Alcotest.(check string)
    "revoked"
    {|{"event":"revoked","pat_id":"pat-1"}|}
    (Authz_body.to_string (to_body_exn revoked))
;;

let a_record_reads_back () =
  List.iter
    (fun (name, t) ->
       match E.of_body (to_body_exn t) with
       | Ok back -> Alcotest.(check bool) name true (E.equal t back)
       | Error e -> Alcotest.failf "%s: %s" name (E.error_to_string e))
    [ "issued", issued ()
    ; "no expiry", issued ~expires_at_ms:None ()
    ; "an expiry of zero", issued ~expires_at_ms:(Some 0) ()
    ; "a negative expiry", issued ~expires_at_ms:(Some (-1)) ()
    ; "an empty scope"
      , issued
          ~scope:
            { Authorization_scope.runtimes = Runtime_scope.empty
            ; channels = Channel_scope.empty
            ; allowed_effects = Effect_scope.empty
            }
          ()
    ; "revoked", revoked
    ]
;;

let equal_tells_records_apart () =
  let base = issued () in
  List.iter
    (fun (name, other) -> Alcotest.(check bool) name false (E.equal base other))
    [ "pat id", issued ~pat_id:second ()
    ; "user", issued ~user_id:bob ()
    ; "digest", issued ~secret_digest:other_digest ()
    ; "scope", issued ~scope:Authorization_scope.all ()
    ; "expiry", issued ~expires_at_ms:(Some 1) ()
    ; "no expiry", issued ~expires_at_ms:None ()
    ; "revoked", revoked
    ];
  Alcotest.(check bool) "the same" true (E.equal base (issued ()));
  Alcotest.(check string) "pat id of issued" "pat-1" (Pat_id.to_string (E.pat_id base));
  Alcotest.(check string)
    "pat id of revoked"
    "pat-1"
    (Pat_id.to_string (E.pat_id revoked))
;;

(* An expiry outside the range of an interoperable JSON integer has no body. *)
let an_expiry_out_of_range () =
  match E.to_body (issued ~expires_at_ms:(Some max_int) ()) with
  | Error Authz_body.Integer_out_of_range -> ()
  | Error other -> Alcotest.failf "another error: %s" (Authz_body.error_to_string other)
  | Ok _ -> Alcotest.fail "an expiry out of range has a body"
;;

(* ---- refusals ---- *)

let issued_json
      ?(pat_id = `String "pat-1")
      ?(user_id = `String "alice")
      ?(secret_digest = `String digest_hex)
      ?(scope = scope_json)
      ?(expires_at_ms = `Int 5)
      ()
  =
  `Assoc
    [ "event", `String "issued"
    ; "pat_id", pat_id
    ; "user_id", user_id
    ; "secret_digest", secret_digest
    ; "scope", scope
    ; "expires_at_ms", expires_at_ms
    ]
;;

let refused () =
  List.iter
    (fun (name, json, expected) ->
       match E.of_body (body_of_json json) with
       | Ok _ -> Alcotest.failf "%s: read as a PAT record" name
       | Error e -> Alcotest.check error name expected e)
    [ "a list", `List [], E.Not_an_object
    ; "a string", `String "issued", E.Not_an_object
    ; "no event", `Assoc [ "pat_id", `String "pat-1" ], E.Wrong_members
    ; "an event that is not a string", `Assoc [ "event", `Int 1 ], E.Wrong_members
    ; "an unknown event", `Assoc [ "event", `String "Issued" ], E.Unknown_event "Issued"
    ; ( "issued without an expiry member"
      , `Assoc
          [ "event", `String "issued"
          ; "pat_id", `String "pat-1"
          ; "user_id", `String "alice"
          ; "secret_digest", `String digest_hex
          ; "scope", scope_json
          ]
      , E.Wrong_members )
    ; ( "issued with a member more"
      , `Assoc
          [ "event", `String "issued"
          ; "pat_id", `String "pat-1"
          ; "user_id", `String "alice"
          ; "secret_digest", `String digest_hex
          ; "scope", scope_json
          ; "expires_at_ms", `Null
          ; "name", `String "ci"
          ]
      , E.Wrong_members )
    ; ( "issued in another order"
      , `Assoc
          [ "event", `String "issued"
          ; "user_id", `String "alice"
          ; "pat_id", `String "pat-1"
          ; "secret_digest", `String digest_hex
          ; "scope", scope_json
          ; "expires_at_ms", `Null
          ]
      , E.Wrong_members )
    ; "a scope that is a string", issued_json ~scope:(`String "all") (), E.Wrong_members
    ; "a scope that is null", issued_json ~scope:`Null (), E.Wrong_members
    ; "an expiry that is a string", issued_json ~expires_at_ms:(`String "5") (), E.Wrong_members
    ; "an expiry that is a bool", issued_json ~expires_at_ms:(`Bool false) (), E.Wrong_members
    ; "a pat id that is a number", issued_json ~pat_id:(`Int 1) (), E.Wrong_members
    ; ( "a bad pat id"
      , issued_json ~pat_id:(`String "pat/1") ()
      , E.Invalid_pat_id (Authz_id.Invalid_byte { index = 3 }) )
    ; "an empty user id", issued_json ~user_id:(`String "") (), E.Invalid_user_id Authz_id.Empty
    ; ( "a digest in upper case"
      , issued_json ~secret_digest:(`String (String.make 64 'D')) ()
      , E.Invalid_secret_digest )
    ; ( "a scope out of order"
      , issued_json
          ~scope:
            (`Assoc
                [ "runtimes", `List [ `String "r-2"; `String "r-1" ]
                ; "channels", `String "all"
                ; "allowed_effects", `String "all"
                ])
          ()
      , E.Invalid_scope (Authz_scope_body.Not_ascending Authz_scope_body.Runtimes) )
    ; ( "a scope with an unknown effect"
      , issued_json
          ~scope:
            (`Assoc
                [ "runtimes", `String "all"
                ; "channels", `String "all"
                ; "allowed_effects", `List [ `String "write" ]
                ])
          ()
      , E.Invalid_scope (Authz_scope_body.Unknown_effect "write") )
    (* The PAT id is read before the user id. *)
    ; ( "a bad pat id and a bad user id"
      , issued_json ~pat_id:(`String "") ~user_id:(`String "") ()
      , E.Invalid_pat_id Authz_id.Empty )
    ; ( "revoked with a member more"
      , `Assoc [ "event", `String "revoked"; "pat_id", `String "pat-1"; "user_id", `String "alice" ]
      , E.Wrong_members )
    ; ( "revoked with a number"
      , `Assoc [ "event", `String "revoked"; "pat_id", `Int 1 ]
      , E.Wrong_members )
    ; ( "revoked with a bad id"
      , `Assoc [ "event", `String "revoked"; "pat_id", `String ".." ]
      , E.Invalid_pat_id Authz_id.Path_segment )
    ]
;;

let () =
  Alcotest.run
    "authz_pat_event"
    [ ( "body"
      , [ Alcotest.test_case "the bytes of a record" `Quick the_bytes_of_a_record
        ; Alcotest.test_case "a record reads back" `Quick a_record_reads_back
        ; Alcotest.test_case "equal tells records apart" `Quick equal_tells_records_apart
        ; Alcotest.test_case "an expiry out of range" `Quick an_expiry_out_of_range
        ] )
    ; "refused", [ Alcotest.test_case "bodies that are not a PAT record" `Quick refused ]
    ]
;;
