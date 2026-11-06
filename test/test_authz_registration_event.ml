(* Checks for the body of an allowlist record: the bytes it writes, that it
   reads back what it wrote, and every way a body fails to be one. A last case
   puts the body in a record and reads the record back, and checks who may
   write one. No files, clock, or network. *)

open Authz_types
open Authz_records
module E = Authz_registration_event
module X = Authz_external_identity
module R = Authz_record

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let identity_of = function
  | Ok identity -> identity
  | Error error -> Alcotest.failf "fixture identity refused: %s" (X.error_to_string error)
;;

let registration_of text = get (Registration_id.of_string text)
let registration = registration_of "registration-1"
let google = identity_of (X.google ~sub:"110169484474386276334")
let github = identity_of (X.github ~user_id:583231)
let registered identity = E.Registered { registration_id = registration; identity }
let removed = E.Removed { registration_id = registration }

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

(* ---- the body ---- *)

let bytes_of_the_body () =
  Alcotest.(check string)
    "registered, google"
    {|{"event":"registered","registration_id":"registration-1","identity":{"provider":"google","sub":"110169484474386276334"}}|}
    (Authz_body.to_string (to_body_exn (registered google)));
  Alcotest.(check string)
    "registered, github"
    {|{"event":"registered","registration_id":"registration-1","identity":{"provider":"github","user_id":583231}}|}
    (Authz_body.to_string (to_body_exn (registered github)));
  Alcotest.(check string)
    "removed"
    {|{"event":"removed","registration_id":"registration-1"}|}
    (Authz_body.to_string (to_body_exn removed))
;;

(* An id of one letter, one with every punctuation mark the alphabet allows,
   and the longest one, each with both providers and the largest GitHub id. *)
let a_body_reads_back () =
  let ids =
    [ "registration-1"; "a"; "A.b_c:d-e"; String.make Authz_id.max_length 'r' ]
  in
  let identities = [ google; github; identity_of (X.github ~user_id:((1 lsl 53) - 1)) ] in
  let bodies =
    List.concat_map
      (fun text ->
        let registration_id = registration_of text in
        E.Removed { registration_id }
        :: List.map (fun identity -> E.Registered { registration_id; identity }) identities)
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
  let t = registered google in
  let other_registration = registration_of "registration-2" in
  Alcotest.(check bool) "itself" true (E.equal t t);
  List.iter
    (fun (name, other) -> Alcotest.(check bool) name false (E.equal t other))
    [ "another identity", registered github
    ; ( "another google sub"
      , registered (identity_of (X.google ~sub:"110169484474386276335")) )
    ; ( "another registration"
      , E.Registered { registration_id = other_registration; identity = google } )
    ; "a removal", removed
    ];
  Alcotest.(check bool)
    "a removal of another registration"
    false
    (E.equal removed (E.Removed { registration_id = other_registration }));
  Alcotest.(check string)
    "the registration of an event"
    "registration-1"
    (Registration_id.to_string (E.registration_id t));
  Alcotest.(check string)
    "the registration of a removal"
    "registration-1"
    (Registration_id.to_string (E.registration_id removed))
;;

(* ---- the bodies that are not allowlist records ---- *)

let id_error_name : Authz_id.error -> string = function
  | Authz_id.Empty -> "empty"
  | Authz_id.Too_long -> "too long"
  | Authz_id.Invalid_byte { index } -> Printf.sprintf "invalid byte %d" index
  | Authz_id.Path_segment -> "path segment"
;;

let identity_error_name : X.body_error -> string = function
  | X.Not_an_object -> "not an object"
  | X.Unknown_provider label -> Printf.sprintf "unknown provider %S" label
  | X.Wrong_members -> "wrong members"
  | X.Invalid error -> "invalid: " ^ X.error_to_string error
;;

let error_name : E.error -> string = function
  | E.Not_an_object -> "not an object"
  | E.Unknown_event label -> Printf.sprintf "unknown event %S" label
  | E.Wrong_members -> "wrong members"
  | E.Invalid_registration_id error -> "invalid registration id: " ^ id_error_name error
  | E.Invalid_identity error -> "invalid identity: " ^ identity_error_name error
;;

let google_identity = `Assoc [ "provider", `String "google"; "sub", `String "110169484474386276334" ]

let registered_members ?(registration = `String "registration-1") ?(identity = google_identity) () =
  [ "event", `String "registered"; "registration_id", registration; "identity", identity ]
;;

let refusals =
  [ "null", `Null, "not an object"
  ; "a string", `String "registered", "not an object"
  ; "an integer", `Int 1, "not an object"
  ; "a boolean", `Bool true, "not an object"
  ; "a list", `List [ `String "registered" ], "not an object"
  ; "an empty object", `Assoc [], "wrong members"
  ; ( "event is not first"
    , `Assoc [ "registration_id", `String "registration-1"; "event", `String "removed" ]
    , "wrong members" )
  ; ( "event is not a string"
    , `Assoc [ "event", `Int 1; "registration_id", `String "registration-1" ]
    , "wrong members" )
  ; ( "an unknown event"
    , `Assoc [ "event", `String "consumed"; "registration_id", `String "registration-1" ]
    , {|unknown event "consumed"|} )
  ; "an event label in another case", `Assoc [ "event", `String "Registered" ], {|unknown event "Registered"|}
  ; ( "an event of an invitation"
    , `Assoc [ "event", `String "revoked"; "registration_id", `String "registration-1" ]
    , {|unknown event "revoked"|} )
  ; "removed with no registration", `Assoc [ "event", `String "removed" ], "wrong members"
  ; ( "removed with an identity"
    , `Assoc
        [ "event", `String "removed"
        ; "registration_id", `String "registration-1"
        ; "identity", google_identity
        ]
    , "wrong members" )
  ; ( "removed with a registration of another type"
    , `Assoc [ "event", `String "removed"; "registration_id", `Int 1 ]
    , "wrong members" )
  ; ( "removed with an empty registration"
    , `Assoc [ "event", `String "removed"; "registration_id", `String "" ]
    , "invalid registration id: empty" )
  ; ( "registered with no identity"
    , `Assoc (List.filter (fun (name, _) -> name <> "identity") (registered_members ()))
    , "wrong members" )
  ; "registered with its members in another order", `Assoc (List.rev (registered_members ())), "wrong members"
  ; ( "registered with another member"
    , `Assoc (registered_members () @ [ "role", `String "member" ])
    , "wrong members" )
  ; ( "registered with an identity that is a string"
    , `Assoc (registered_members ~identity:(`String "google:110169484474386276334") ())
    , "wrong members" )
  ; ( "registered with a registration that is a path segment"
    , `Assoc (registered_members ~registration:(`String "..") ())
    , "invalid registration id: path segment" )
  ; ( "registered with an unknown provider"
    , `Assoc (registered_members ~identity:(`Assoc [ "provider", `String "gitlab"; "id", `Int 1 ]) ())
    , {|invalid identity: unknown provider "gitlab"|} )
  ; ( "registered with a github id that is a string"
    , `Assoc
        (registered_members
           ~identity:(`Assoc [ "provider", `String "github"; "user_id", `String "583231" ])
           ())
    , "invalid identity: wrong members" )
  ; ( "registered with a github id of zero"
    , `Assoc
        (registered_members ~identity:(`Assoc [ "provider", `String "github"; "user_id", `Int 0 ]) ())
    , "invalid identity: invalid: " ^ X.error_to_string X.Github_user_id_not_positive )
  ; ( "an invalid registration comes before an invalid identity"
    , `Assoc (registered_members ~registration:(`String "") ~identity:(`Assoc []) ())
    , "invalid registration id: empty" )
  ]
;;

let a_body_that_is_not_an_allowlist_record_is_refused () =
  List.iter
    (fun (name, json, expected) ->
      match E.of_body (body_of_json json) with
      | Ok _ -> Alcotest.failf "%s was read as an allowlist record" name
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
      ; E.Invalid_registration_id Authz_id.Empty
      ; E.Invalid_registration_id Authz_id.Path_segment
      ; E.Invalid_identity X.Not_an_object
      ; E.Invalid_identity X.Wrong_members
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

let alice = Author.Authenticated (Principal.Human (get (User_id.of_string "alice")))
let events = [ registered google; registered github; removed ]

let a_record_carries_the_body () =
  List.iter
    (fun t ->
      match
        R.make ~head:R.genesis ~at_ms:1000 ~author:alice ~kind:R.Kind.Registration
          ~body:(to_body_exn t)
      with
      | Error (R.Author_not_admitted _) -> Alcotest.fail "a principal may write an allowlist record"
      | Ok record ->
        (match R.of_line ~head:R.genesis (R.to_line record) with
         | Error _ -> Alcotest.fail "the line of the record is not read back"
         | Ok read ->
           Alcotest.(check string) "the kind" "registration" (R.Kind.to_string read.R.kind);
           (match E.of_body read.R.body with
            | Ok back -> Alcotest.(check bool) "the body" true (E.equal t back)
            | Error error -> Alcotest.failf "refused: %s" (E.error_to_string error))))
    events
;;

(* The local operator invites the first Admin; it does not register. *)
let no_other_author_may_write_one () =
  List.iter
    (fun (name, author) ->
      match
        R.make ~head:R.genesis ~at_ms:1000 ~author ~kind:R.Kind.Registration
          ~body:(to_body_exn removed)
      with
      | Error (R.Author_not_admitted _) -> ()
      | Ok _ -> Alcotest.failf "%s wrote an allowlist record" name)
    [ "the local operator", Author.Local_operator
    ; "system cron", Author.System_cron
    ; "system maintenance", Author.System_maintenance
    ; "system migration", Author.System_migration
    ]
;;

let () =
  Alcotest.run
    "authz_registration_event"
    [ ( "body"
      , [ Alcotest.test_case "bytes" `Quick bytes_of_the_body
        ; Alcotest.test_case "reads back" `Quick a_body_reads_back
        ; Alcotest.test_case "equality" `Quick equality_looks_at_every_member
        ; Alcotest.test_case "refusals" `Quick a_body_that_is_not_an_allowlist_record_is_refused
        ; Alcotest.test_case "texts" `Quick errors_are_told_apart
        ] )
    ; ( "record"
      , [ Alcotest.test_case "carries the body" `Quick a_record_carries_the_body
        ; Alcotest.test_case "other authors" `Quick no_other_author_may_write_one
        ] )
    ]
;;
