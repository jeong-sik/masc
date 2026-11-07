(* Checks for the body of a browser session record: the bytes it writes, the
   digest of a secret, that it reads back what it wrote, and every way a body
   fails to be one. A last case puts the body in a record, reads the record
   back, and checks who may write one. No files, clock, or network. *)

open Authz_types
module E = Authz_session_event
module D = Authz_session_event.Secret_digest

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let session_of text = get (Session_id.of_string text)
let user_of text = get (User_id.of_string text)
let first = session_of "session-1"
let second = session_of "session-2"
let alice = user_of "alice"
let digest = D.of_secret "secret-1"

let issued ?(session_id = first) ?(user_id = alice) ?(secret_digest = digest) ?replaces () =
  E.Issued { session_id; user_id; secret_digest; replaces }
;;

let revoked = E.Revoked { session_id = first }

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

(* ---- the digest ---- *)

(* The bytes hashed carry a label, so the digest is not the SHA-256 of the
   secret alone. *)
let the_digest_of_a_secret () =
  let label = "masc-authz-browser-session-secret-v1\n" in
  let sha text = Agent_core_sha256.to_hex (Agent_core_sha256.digest_string text) in
  Alcotest.(check string) "labelled" (sha (label ^ "secret-1")) (D.to_hex digest);
  Alcotest.(check bool) "not the bare hash" false (String.equal (sha "secret-1") (D.to_hex digest));
  Alcotest.(check bool) "the same secret" true (D.equal digest (D.of_secret "secret-1"));
  Alcotest.(check bool) "another secret" false (D.equal digest (D.of_secret "secret-2"));
  (match D.of_hex (D.to_hex digest) with
   | Some back -> Alcotest.(check bool) "reads back" true (D.equal digest back)
   | None -> Alcotest.fail "the hex of a digest is refused");
  List.iter
    (fun (name, text) -> Alcotest.(check bool) name true (Option.is_none (D.of_hex text)))
    [ "upper case", String.uppercase_ascii (D.to_hex digest)
    ; "one short", String.sub (D.to_hex digest) 0 63
    ; "one long", D.to_hex digest ^ "0"
    ; "not hex", String.make 64 'g'
    ; "empty", ""
    ]
;;

(* ---- the body ---- *)

let bytes_of_the_body () =
  let hex = D.to_hex digest in
  Alcotest.(check string)
    "issued"
    ({|{"event":"issued","session_id":"session-1","user_id":"alice","secret_digest":"|}
     ^ hex
     ^ {|","replaces":null}|})
    (Authz_body.to_string (to_body_exn (issued ())));
  Alcotest.(check string)
    "issued in place of another"
    ({|{"event":"issued","session_id":"session-1","user_id":"alice","secret_digest":"|}
     ^ hex
     ^ {|","replaces":"session-2"}|})
    (Authz_body.to_string (to_body_exn (issued ~replaces:second ())));
  Alcotest.(check string)
    "revoked"
    {|{"event":"revoked","session_id":"session-1"}|}
    (Authz_body.to_string (to_body_exn revoked))
;;

(* An id of one letter, one with every punctuation mark the alphabet allows,
   and the longest one, as the session, its user, and the session it ends. *)
let a_body_reads_back () =
  let ids = [ "session-1"; "a"; "A.b_c:d-e"; String.make Authz_id.max_length 's' ] in
  let bodies =
    List.concat_map
      (fun text ->
        let session_id = session_of text in
        [ E.Revoked { session_id }
        ; issued ~session_id ()
        ; issued ~user_id:(user_of text) ()
        ; issued ~replaces:session_id ()
        ])
      ids
  in
  List.iter
    (fun t ->
      match E.of_body (to_body_exn t) with
      | Ok back ->
        Alcotest.(check bool) (Authz_body.to_string (to_body_exn t)) true (E.equal t back)
      | Error error -> Alcotest.failf "refused: %s" (E.error_to_string error))
    bodies
;;

let equality_looks_at_every_member () =
  let t = issued ~replaces:second () in
  Alcotest.(check bool) "itself" true (E.equal t t);
  List.iter
    (fun (name, other) -> Alcotest.(check bool) name false (E.equal t other))
    [ "another session", issued ~session_id:(session_of "session-3") ~replaces:second ()
    ; "another user", issued ~user_id:(user_of "bob") ~replaces:second ()
    ; "another secret", issued ~secret_digest:(D.of_secret "secret-2") ~replaces:second ()
    ; "another replaced session", issued ~replaces:(session_of "session-3") ()
    ; "nothing replaced", issued ()
    ; "a revocation", revoked
    ];
  Alcotest.(check bool)
    "a revocation of another session"
    false
    (E.equal revoked (E.Revoked { session_id = second }));
  Alcotest.(check string)
    "the session of an issue"
    "session-1"
    (Session_id.to_string (E.session_id t));
  Alcotest.(check string)
    "the session of a revocation"
    "session-1"
    (Session_id.to_string (E.session_id revoked))
;;

(* ---- the bodies that are not session records ---- *)

let id_error_name : Authz_id.error -> string = function
  | Authz_id.Empty -> "empty"
  | Authz_id.Too_long -> "too long"
  | Authz_id.Invalid_byte { index } -> Printf.sprintf "invalid byte %d" index
  | Authz_id.Path_segment -> "path segment"
;;

let error_name : E.error -> string = function
  | E.Not_an_object -> "not an object"
  | E.Unknown_event label -> Printf.sprintf "unknown event %S" label
  | E.Wrong_members -> "wrong members"
  | E.Invalid_session_id error -> "invalid session id: " ^ id_error_name error
  | E.Invalid_user_id error -> "invalid user id: " ^ id_error_name error
  | E.Invalid_secret_digest -> "invalid secret digest"
  | E.Invalid_replaces error -> "invalid replaces: " ^ id_error_name error
;;

let hex = `String (D.to_hex digest)

let issued_members
  ?(session = `String "session-1")
  ?(user = `String "alice")
  ?(secret = hex)
  ?(replaces = `Null)
  ()
  =
  [ "event", `String "issued"
  ; "session_id", session
  ; "user_id", user
  ; "secret_digest", secret
  ; "replaces", replaces
  ]
;;

let without name members = List.filter (fun (member, _) -> member <> name) members

let refusals =
  [ "null", `Null, "not an object"
  ; "a string", `String "issued", "not an object"
  ; "an integer", `Int 1, "not an object"
  ; "a boolean", `Bool true, "not an object"
  ; "a list", `List [ `String "issued" ], "not an object"
  ; "an empty object", `Assoc [], "wrong members"
  ; ( "event is not first"
    , `Assoc [ "session_id", `String "session-1"; "event", `String "revoked" ]
    , "wrong members" )
  ; ( "event is not a string"
    , `Assoc [ "event", `Int 1; "session_id", `String "session-1" ]
    , "wrong members" )
  ; ( "an unknown event"
    , `Assoc [ "event", `String "expired"; "session_id", `String "session-1" ]
    , {|unknown event "expired"|} )
  ; "an event label in another case", `Assoc [ "event", `String "Issued" ], {|unknown event "Issued"|}
  ; ( "an event of the allowlist"
    , `Assoc [ "event", `String "removed"; "session_id", `String "session-1" ]
    , {|unknown event "removed"|} )
  ; "revoked with no session", `Assoc [ "event", `String "revoked" ], "wrong members"
  ; ( "revoked with a user"
    , `Assoc [ "event", `String "revoked"; "session_id", `String "session-1"; "user_id", `String "alice" ]
    , "wrong members" )
  ; ( "revoked with a session of another type"
    , `Assoc [ "event", `String "revoked"; "session_id", `Int 1 ]
    , "wrong members" )
  ; ( "revoked with an empty session"
    , `Assoc [ "event", `String "revoked"; "session_id", `String "" ]
    , "invalid session id: empty" )
  ; "issued with no replaces", `Assoc (without "replaces" (issued_members ())), "wrong members"
  ; "issued with no digest", `Assoc (without "secret_digest" (issued_members ())), "wrong members"
  ; "issued with no user", `Assoc (without "user_id" (issued_members ())), "wrong members"
  ; "issued with its members in another order", `Assoc (List.rev (issued_members ())), "wrong members"
  ; ( "issued with another member"
    , `Assoc (issued_members () @ [ "expires_at_ms", `Int 1 ])
    , "wrong members" )
  ; ( "issued with the secret instead of its digest"
    , `Assoc
        [ "event", `String "issued"
        ; "session_id", `String "session-1"
        ; "user_id", `String "alice"
        ; "secret", hex
        ; "replaces", `Null
        ]
    , "wrong members" )
  ; ( "issued with replaces a list"
    , `Assoc (issued_members ~replaces:(`List [ `String "session-2" ]) ())
    , "wrong members" )
  ; "issued with replaces false", `Assoc (issued_members ~replaces:(`Bool false) ()), "wrong members"
  ; "issued with a user that is a number", `Assoc (issued_members ~user:(`Int 1) ()), "wrong members"
  ; "issued with a digest that is a number", `Assoc (issued_members ~secret:(`Int 1) ()), "wrong members"
  ; ( "issued with a session that is a path segment"
    , `Assoc (issued_members ~session:(`String "..") ())
    , "invalid session id: path segment" )
  ; ( "issued with an empty user"
    , `Assoc (issued_members ~user:(`String "") ())
    , "invalid user id: empty" )
  ; ( "issued with an upper case digest"
    , `Assoc (issued_members ~secret:(`String (String.uppercase_ascii (D.to_hex digest))) ())
    , "invalid secret digest" )
  ; ( "issued with a short digest"
    , `Assoc (issued_members ~secret:(`String "ab") ())
    , "invalid secret digest" )
  ; ( "issued in place of an empty session"
    , `Assoc (issued_members ~replaces:(`String "") ())
    , "invalid replaces: empty" )
  ; ( "an invalid session comes before an invalid user"
    , `Assoc (issued_members ~session:(`String "") ~user:(`String "") ())
    , "invalid session id: empty" )
  ; ( "an invalid user comes before an invalid digest"
    , `Assoc (issued_members ~user:(`String "") ~secret:(`String "x") ())
    , "invalid user id: empty" )
  ; ( "an invalid digest comes before an invalid replaces"
    , `Assoc (issued_members ~secret:(`String "x") ~replaces:(`String "") ())
    , "invalid secret digest" )
  ]
;;

let a_body_that_is_not_a_session_record_is_refused () =
  List.iter
    (fun (name, json, expected) ->
      match E.of_body (body_of_json json) with
      | Ok _ -> Alcotest.failf "%s was read as a session record" name
      | Error error -> Alcotest.(check string) name expected (error_name error))
    refusals
;;

let contains ~sub text =
  let n = String.length sub in
  let rec go i = i + n <= String.length text && (String.equal (String.sub text i n) sub || go (i + 1)) in
  go 0
;;

let errors_are_told_apart () =
  let texts =
    List.map
      E.error_to_string
      [ E.Not_an_object
      ; E.Unknown_event "e"
      ; E.Wrong_members
      ; E.Invalid_session_id Authz_id.Empty
      ; E.Invalid_session_id Authz_id.Path_segment
      ; E.Invalid_user_id Authz_id.Empty
      ; E.Invalid_secret_digest
      ; E.Invalid_replaces Authz_id.Empty
      ]
  in
  Alcotest.(check int)
    "each reason has its own text"
    (List.length texts)
    (List.length (List.sort_uniq String.compare texts));
  Alcotest.(check bool)
    "the event label is in the text"
    true
    (contains ~sub:"bogus" (E.error_to_string (E.Unknown_event "bogus")))
;;

(* ---- the body in a record ---- *)

module R = Authz_record

let alice_author = Authz_records.Author.Authenticated (Principal.Human alice)
let events = [ issued (); issued ~replaces:second (); revoked ]

let a_record_carries_the_body () =
  List.iter
    (fun t ->
      match
        R.make ~head:R.genesis ~at_ms:1000 ~author:alice_author ~kind:R.Kind.Session
          ~body:(to_body_exn t)
      with
      | Error (R.Author_not_admitted _) -> Alcotest.fail "a principal may write a session record"
      | Ok record ->
        (match R.of_line ~head:R.genesis (R.to_line record) with
         | Error _ -> Alcotest.fail "the line of the record is not read back"
         | Ok read ->
           Alcotest.(check string) "the kind" "session" (R.Kind.to_string read.R.kind);
           (match E.of_body read.R.body with
            | Ok back -> Alcotest.(check bool) "the body" true (E.equal t back)
            | Error error -> Alcotest.failf "refused: %s" (E.error_to_string error))))
    events
;;

(* A session belongs to a person who signed in; no system author and not the
   local operator writes one. *)
let no_other_author_may_write_one () =
  List.iter
    (fun (name, author) ->
      match
        R.make ~head:R.genesis ~at_ms:1000 ~author ~kind:R.Kind.Session
          ~body:(to_body_exn revoked)
      with
      | Error (R.Author_not_admitted _) -> ()
      | Ok _ -> Alcotest.failf "%s wrote a session record" name)
    [ "the local operator", Authz_records.Author.Local_operator
    ; "system cron", Authz_records.Author.System_cron
    ; "system maintenance", Authz_records.Author.System_maintenance
    ; "system migration", Authz_records.Author.System_migration
    ]
;;

let () =
  Alcotest.run
    "authz_session_event"
    [ "digest", [ Alcotest.test_case "of a secret" `Quick the_digest_of_a_secret ]
    ; ( "body"
      , [ Alcotest.test_case "bytes" `Quick bytes_of_the_body
        ; Alcotest.test_case "reads back" `Quick a_body_reads_back
        ; Alcotest.test_case "equality" `Quick equality_looks_at_every_member
        ; Alcotest.test_case "refused" `Quick a_body_that_is_not_a_session_record_is_refused
        ; Alcotest.test_case "texts" `Quick errors_are_told_apart
        ] )
    ; ( "record"
      , [ Alcotest.test_case "carries the body" `Quick a_record_carries_the_body
        ; Alcotest.test_case "other authors" `Quick no_other_author_may_write_one
        ] )
    ]
;;
