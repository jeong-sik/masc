(* Checks for the body of an invite record: the bytes it writes, that it reads
   back what it wrote, every way a body fails to be one, and the digest of a
   token. A last case puts the body in a record and reads the record back, and
   checks who may write one. No files, clock, or network. *)

open Authz_types
open Authz_records
module I = Authz_invite_event
module R = Authz_record

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let invite_of text = get (Invite_id.of_string text)
let invite = invite_of "invite-1"

(* SHA-256 of "masc-authz-invite-token-v1\ntoken-1", computed outside OCaml. *)
let token_1_digest_hex = "798fe3af29119130a3eddcd672f868f2a538f2be36d6d3f1d01d11ed3217785a"

(* SHA-256 of "token-1" alone: what the digest would be without its domain. *)
let token_1_plain_sha256 = "3f08aace122ee2368432c1ca23a049bc640bafbf00fdf33a52429f38ba12dbf9"

let digest = I.Token_digest.of_token "token-1"

let issued role =
  I.Issued { invite_id = invite; token_digest = digest; expires_at_ms = 1_800_000_000_000; role }
;;

let revoked = I.Revoked { invite_id = invite }
let events = [ issued I.Member; issued I.Admin; revoked ]

let body_of_json json =
  match Authz_body.of_yojson json with
  | Ok body -> body
  | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
;;

let to_body_exn t =
  match I.to_body t with
  | Ok body -> body
  | Error error -> Alcotest.failf "the body was refused: %s" (Authz_body.error_to_string error)
;;

(* ---- roles ---- *)

(* An exhaustive match, so a new role cannot be added without this file. *)
let ordinal = function
  | I.Member -> 0
  | I.Admin -> 1
;;

let roles_are_all_listed () =
  let sorted roles = List.sort Int.compare (List.map ordinal roles) in
  Alcotest.(check (list int)) "roles names every role once" [ 0; 1 ] (sorted I.roles)
;;

(* The words that name a role on disk. Renaming one orphans every record
   written with it. *)
let role_labels_are_the_names_on_disk () =
  Alcotest.(check (list string)) "labels" [ "member"; "admin" ] (List.map I.role_label I.roles);
  List.iter
    (fun role ->
      match I.role_of_label (I.role_label role) with
      | Some back -> Alcotest.(check int) (I.role_label role) (ordinal role) (ordinal back)
      | None -> Alcotest.failf "label %s does not read back" (I.role_label role))
    I.roles;
  List.iter
    (fun label ->
      Alcotest.(check bool) (label ^ " is no label") true (Option.is_none (I.role_of_label label)))
    [ ""; "Admin"; "admin "; "owner"; "Member" ]
;;

(* ---- the token digest ---- *)

let the_digest_of_a_token_is_pinned () =
  Alcotest.(check string) "token-1" token_1_digest_hex (I.Token_digest.to_hex digest);
  Alcotest.(check bool)
    "not the SHA-256 of the token alone"
    false
    (String.equal token_1_plain_sha256 (I.Token_digest.to_hex digest));
  Alcotest.(check bool)
    "another token, another digest"
    false
    (I.Token_digest.equal digest (I.Token_digest.of_token "token-2"))
;;

let a_digest_is_64_lowercase_hex () =
  (match I.Token_digest.of_hex token_1_digest_hex with
   | Some back -> Alcotest.(check bool) "reads back" true (I.Token_digest.equal digest back)
   | None -> Alcotest.fail "the hex of a digest is refused");
  List.iter
    (fun (name, text) ->
      Alcotest.(check bool) name true (Option.is_none (I.Token_digest.of_hex text)))
    [ "upper case", String.uppercase_ascii token_1_digest_hex
    ; "63 characters", String.sub token_1_digest_hex 0 63
    ; "65 characters", token_1_digest_hex ^ "0"
    ; "not hex", String.make 64 'g'
    ; "empty", ""
    ]
;;

(* ---- the body ---- *)

let bytes_of_the_body () =
  Alcotest.(check string)
    "issued, admin"
    ({|{"event":"issued","invite_id":"invite-1","token_digest":"|}
     ^ token_1_digest_hex
     ^ {|","expires_at_ms":1800000000000,"role":"admin"}|})
    (Authz_body.to_string (to_body_exn (issued I.Admin)));
  Alcotest.(check string)
    "revoked"
    {|{"event":"revoked","invite_id":"invite-1"}|}
    (Authz_body.to_string (to_body_exn revoked))
;;

(* An id of one letter, one with every punctuation mark the alphabet allows,
   and the longest one. A negative and a zero expiry are carried as they are:
   whether an invitation has expired is the writer's question. *)
let a_body_reads_back () =
  let ids = [ "invite-1"; "a"; "A.b_c:d-e"; String.make Authz_id.max_length 'i' ] in
  let bodies =
    List.concat_map
      (fun text ->
        let invite_id = invite_of text in
        [ I.Revoked { invite_id } ]
        @ List.concat_map
            (fun role ->
              List.map
                (fun expires_at_ms ->
                  I.Issued { invite_id; token_digest = digest; expires_at_ms; role })
                [ 0; -1; 1_800_000_000_000 ])
            I.roles)
      ids
  in
  List.iter
    (fun t ->
      match I.of_body (to_body_exn t) with
      | Ok back ->
        Alcotest.(check bool) (Authz_body.to_string (to_body_exn t)) true (I.equal t back)
      | Error error -> Alcotest.failf "refused: %s" (I.error_to_string error))
    bodies
;;

let equality_looks_at_every_member () =
  let t = issued I.Member in
  let other_invite = invite_of "invite-2" in
  Alcotest.(check bool) "itself" true (I.equal t t);
  List.iter
    (fun (name, other) -> Alcotest.(check bool) name false (I.equal t other))
    [ "another role", issued I.Admin
    ; ( "another invite"
      , I.Issued
          { invite_id = other_invite; token_digest = digest; expires_at_ms = 1_800_000_000_000
          ; role = I.Member } )
    ; ( "another digest"
      , I.Issued
          { invite_id = invite; token_digest = I.Token_digest.of_token "token-2"
          ; expires_at_ms = 1_800_000_000_000; role = I.Member } )
    ; ( "another expiry"
      , I.Issued { invite_id = invite; token_digest = digest; expires_at_ms = 1; role = I.Member } )
    ; "a revocation", revoked
    ];
  Alcotest.(check bool)
    "a revocation of another invite"
    false
    (I.equal revoked (I.Revoked { invite_id = other_invite }));
  Alcotest.(check string) "the invite of an event" "invite-1" (Invite_id.to_string (I.invite_id t))
;;

(* ---- the bodies that are not invite records ---- *)

let id_error_name : Authz_id.error -> string = function
  | Authz_id.Empty -> "empty"
  | Authz_id.Too_long -> "too long"
  | Authz_id.Invalid_byte { index } -> Printf.sprintf "invalid byte %d" index
  | Authz_id.Path_segment -> "path segment"
;;

let error_name : I.error -> string = function
  | I.Not_an_object -> "not an object"
  | I.Unknown_event label -> Printf.sprintf "unknown event %S" label
  | I.Wrong_members -> "wrong members"
  | I.Invalid_invite_id error -> "invalid invite id: " ^ id_error_name error
  | I.Invalid_token_digest -> "invalid token digest"
  | I.Unknown_role label -> Printf.sprintf "unknown role %S" label
;;

let issued_members ?(invite = `String "invite-1") ?(digest = `String token_1_digest_hex)
    ?(expires = `Int 1) ?(role = `String "admin") () =
  [ "event", `String "issued"
  ; "invite_id", invite
  ; "token_digest", digest
  ; "expires_at_ms", expires
  ; "role", role
  ]
;;

let refusals =
  [ "null", `Null, "not an object"
  ; "a string", `String "issued", "not an object"
  ; "an integer", `Int 1, "not an object"
  ; "a boolean", `Bool true, "not an object"
  ; "a list", `List [ `String "issued" ], "not an object"
  ; "an empty object", `Assoc [], "wrong members"
  ; "event is not first", `Assoc [ "invite_id", `String "invite-1"; "event", `String "revoked" ], "wrong members"
  ; "event is not a string", `Assoc [ "event", `Int 1; "invite_id", `String "invite-1" ], "wrong members"
  ; "an unknown event", `Assoc [ "event", `String "consumed"; "invite_id", `String "invite-1" ], {|unknown event "consumed"|}
  ; "an event label in another case", `Assoc [ "event", `String "Issued" ], {|unknown event "Issued"|}
  ; "revoked with no invite", `Assoc [ "event", `String "revoked" ], "wrong members"
  ; ( "revoked with another member"
    , `Assoc [ "event", `String "revoked"; "invite_id", `String "invite-1"; "role", `String "admin" ]
    , "wrong members" )
  ; "revoked with an invite of another type", `Assoc [ "event", `String "revoked"; "invite_id", `Int 1 ], "wrong members"
  ; "revoked with an empty invite", `Assoc [ "event", `String "revoked"; "invite_id", `String "" ], "invalid invite id: empty"
  ; "issued with no role", `Assoc (List.filter (fun (name, _) -> name <> "role") (issued_members ())), "wrong members"
  ; "issued with its members in another order", `Assoc (List.rev (issued_members ())), "wrong members"
  ; "issued with another member", `Assoc (issued_members () @ [ "note", `String "x" ]), "wrong members"
  ; "issued with an expiry that is a string", `Assoc (issued_members ~expires:(`String "1") ()), "wrong members"
  ; "issued with a role that is a number", `Assoc (issued_members ~role:(`Int 1) ()), "wrong members"
  ; "issued with an invite that is a path segment", `Assoc (issued_members ~invite:(`String "..") ()), "invalid invite id: path segment"
  ; "issued with an upper case digest", `Assoc (issued_members ~digest:(`String (String.uppercase_ascii token_1_digest_hex)) ()), "invalid token digest"
  ; "issued with a short digest", `Assoc (issued_members ~digest:(`String "abc") ()), "invalid token digest"
  ; "issued with an unknown role", `Assoc (issued_members ~role:(`String "owner") ()), {|unknown role "owner"|}
  ; "an invalid invite comes before an invalid digest", `Assoc (issued_members ~invite:(`String "") ~digest:(`String "abc") ()), "invalid invite id: empty"
  ; "an invalid digest comes before an invalid role", `Assoc (issued_members ~digest:(`String "abc") ~role:(`String "owner") ()), "invalid token digest"
  ]
;;

let a_body_that_is_not_an_invite_record_is_refused () =
  List.iter
    (fun (name, json, expected) ->
      match I.of_body (body_of_json json) with
      | Ok _ -> Alcotest.failf "%s was read as an invite record" name
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
      I.error_to_string
      [ I.Not_an_object
      ; I.Unknown_event "e"
      ; I.Wrong_members
      ; I.Invalid_invite_id Authz_id.Empty
      ; I.Invalid_invite_id Authz_id.Path_segment
      ; I.Invalid_token_digest
      ; I.Unknown_role "r"
      ]
  in
  Alcotest.(check int)
    "each reason has its own text"
    (List.length texts)
    (List.length (List.sort_uniq String.compare texts));
  Alcotest.(check bool)
    "the event label is in the text"
    true
    (contains ~sub:"bogus" (I.error_to_string (I.Unknown_event "bogus")));
  Alcotest.(check bool)
    "the role label is in the text"
    true
    (contains ~sub:"bogus" (I.error_to_string (I.Unknown_role "bogus")))
;;

(* ---- the body in a record ---- *)

let alice = Author.Authenticated (Principal.Human (get (User_id.of_string "alice")))

let a_record_carries_the_body () =
  List.iter
    (fun (author, t) ->
      match
        R.make ~head:R.genesis ~at_ms:1000 ~author ~kind:R.Kind.Invite ~body:(to_body_exn t)
      with
      | Error (R.Author_not_admitted _) -> Alcotest.fail "the author may write an invite record"
      | Ok record ->
        (match R.of_line ~head:R.genesis (R.to_line record) with
         | Error _ -> Alcotest.fail "the line of the record is not read back"
         | Ok read ->
           Alcotest.(check string) "the kind" "invite" (R.Kind.to_string read.R.kind);
           (match I.of_body read.R.body with
            | Ok back -> Alcotest.(check bool) "the body" true (I.equal t back)
            | Error error -> Alcotest.failf "refused: %s" (I.error_to_string error))))
    (List.concat_map (fun t -> [ Author.Local_operator, t; alice, t ]) events)
;;

let a_system_author_may_not_write_one () =
  List.iter
    (fun author ->
      match
        R.make ~head:R.genesis ~at_ms:1000 ~author ~kind:R.Kind.Invite ~body:(to_body_exn revoked)
      with
      | Error (R.Author_not_admitted _) -> ()
      | Ok _ -> Alcotest.fail "a system author wrote an invite record")
    [ Author.System_cron; Author.System_maintenance; Author.System_migration ]
;;

let () =
  Alcotest.run
    "authz_invite_event"
    [ ( "roles"
      , [ Alcotest.test_case "all listed" `Quick roles_are_all_listed
        ; Alcotest.test_case "labels on disk" `Quick role_labels_are_the_names_on_disk
        ] )
    ; ( "token digest"
      , [ Alcotest.test_case "pinned" `Quick the_digest_of_a_token_is_pinned
        ; Alcotest.test_case "hex" `Quick a_digest_is_64_lowercase_hex
        ] )
    ; ( "body"
      , [ Alcotest.test_case "bytes" `Quick bytes_of_the_body
        ; Alcotest.test_case "reads back" `Quick a_body_reads_back
        ; Alcotest.test_case "equality" `Quick equality_looks_at_every_member
        ; Alcotest.test_case "refusals" `Quick a_body_that_is_not_an_invite_record_is_refused
        ; Alcotest.test_case "texts" `Quick errors_are_told_apart
        ] )
    ; ( "record"
      , [ Alcotest.test_case "carries the body" `Quick a_record_carries_the_body
        ; Alcotest.test_case "system authors" `Quick a_system_author_may_not_write_one
        ] )
    ]
;;
