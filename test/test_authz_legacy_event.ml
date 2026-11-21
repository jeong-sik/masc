(* Checks for the body of the legacy attribution record: the bytes it writes,
   that it reads back what it wrote, and every way a body fails to be one. No
   files, clock, or network. *)

open Authz_types
open Authz_records
module L = Authz_legacy_event
module R = Authz_record

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let invite = get (Invite_id.of_string "invite-1")
let alice = get (User_id.of_string "alice")
let keeper_a = get (Keeper_id.of_string "keeper-a")
let keeper_b = get (Keeper_id.of_string "keeper-b")
let runtime = get (Runtime_id.of_string "runtime-1")
let policy = get (Policy_id.of_string "policy-1")
let manifest_hex = String.make 64 'a'
let manifest =
  match R.Hash.of_hex manifest_hex with
  | Some hash -> hash
  | None -> Alcotest.fail "fixture hash rejected by Authz_record.Hash"
;;

let inventory ?keepers ?tasks () =
  L.Inventory_frozen
    { bootstrap_invite_id = invite
    ; cutover_at_ms = 1_800_000_000_000
    ; legacy_keepers = Option.value keepers ~default:[ keeper_a; keeper_b ]
    ; legacy_task_ids = Option.value tasks ~default:[ "task-1"; "task-2" ]
    ; legacy_manifest_sha256 = manifest
    }
;;

let candidate = L.Candidate_bound { user_id = alice; invite_id = invite }

let claimed =
  L.Keeper_claimed
    { engine_name = keeper_a
    ; claimant = alice
    ; keeper_id = keeper_b
    ; runtime_id = runtime
    ; policy_id = policy
    ; turn_scope = Authorization_scope.all
    }
;;

let retired = L.Keeper_retired { engine_name = keeper_a; actor = alice }
let events = [ inventory (); candidate; claimed; retired ]

let body_of_json json =
  match Authz_body.of_yojson json with
  | Ok body -> body
  | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
;;

let to_body_exn t =
  match L.to_body t with
  | Ok body -> body
  | Error error -> Alcotest.failf "the body was refused: %s" (Authz_body.error_to_string error)
;;

let text_of t = Authz_body.to_string (to_body_exn t)

let contains ~sub text =
  let sub_length = String.length sub in
  let rec go index =
    if index + sub_length > String.length text
    then false
    else if String.equal (String.sub text index sub_length) sub
    then true
    else go (index + 1)
  in
  go 0
;;

(* ---- the labels on disk ---- *)

(* The words that name an event on disk. Renaming one orphans every record
   written with it. *)
let labels_are_the_names_on_disk () =
  Alcotest.(check (list string))
    "labels"
    [ "inventory_frozen"; "candidate_bound"; "keeper_claimed"; "keeper_retired" ]
    (List.map L.label events)
;;

(* ---- the bytes ---- *)

(* The inventory is written in byte order and without a repeat, so the same
   inventory always hashes the same, whatever order the walk that found it
   gave. *)
let bytes_of_the_inventory () =
  let expected =
    Printf.sprintf
      {|{"event":"inventory_frozen","bootstrap_invite_id":"invite-1","cutover_at_ms":1800000000000,"legacy_keepers":["keeper-a","keeper-b"],"legacy_task_ids":["task-1","task-2"],"legacy_manifest_sha256":"%s"}|}
      manifest_hex
  in
  Alcotest.(check string) "canonical inventory" expected (text_of (inventory ()));
  Alcotest.(check string)
    "an unsorted inventory writes the same bytes"
    expected
    (text_of (inventory ~keepers:[ keeper_b; keeper_a ] ~tasks:[ "task-2"; "task-1" ] ()))
;;

let bytes_of_a_claim () =
  let text = text_of claimed in
  Alcotest.(check bool)
    "the claim names its six members in order"
    true
    (contains
       ~sub:
         {|"event":"keeper_claimed","engine_name":"keeper-a","claimant":"alice","keeper_id":"keeper-b","runtime_id":"runtime-1","policy_id":"policy-1","turn_scope":|}
       text)
;;

(* ---- reading ---- *)

let reads_back_what_it_wrote () =
  List.iter
    (fun t ->
      match L.of_body (to_body_exn t) with
      | Ok back -> Alcotest.(check bool) (L.label t) true (L.equal t back)
      | Error error -> Alcotest.failf "refused: %s" (L.error_to_string error))
    events
;;

let a_claim_keeps_its_scope () =
  match L.of_body (to_body_exn claimed) with
  | Error error -> Alcotest.failf "refused: %s" (L.error_to_string error)
  | Ok (L.Keeper_claimed { turn_scope; _ }) ->
    Alcotest.(check bool)
      "the scope"
      true
      (Authorization_scope.equal Authorization_scope.all turn_scope)
  | Ok (L.Inventory_frozen _ | L.Candidate_bound _ | L.Keeper_retired _) ->
    Alcotest.fail "a claim read back as another event"
;;

(* An unknown event is an error, never a default: a reader that guessed would
   read one event as another. *)
let an_unknown_event_is_refused () =
  match L.of_body (body_of_json (`Assoc [ "event", `String "settled" ])) with
  | Error (L.Unknown_event "settled") -> ()
  | Error error -> Alcotest.failf "another error: %s" (L.error_to_string error)
  | Ok _ -> Alcotest.fail "an unknown event was read"
;;

let a_body_that_is_not_a_legacy_attribution_is_refused () =
  let member name json = `Assoc (("event", `String name) :: json) in
  let refused (what, json) =
    match L.of_body (body_of_json json) with
    | Ok _ -> Alcotest.failf "%s was read" what
    | Error _ -> ()
  in
  List.iter refused
    [ ( "an object without an event"
      , `Assoc [ "invite_id", `String "invite-1" ] )
    ; "a list", `List [ `String "inventory_frozen" ]
    ; "a string", `String "inventory_frozen"
    ; "null", `Null
    ; ( "an inventory with another member"
      , member "inventory_frozen"
          [ ( "bootstrap_invite_id", `String "invite-1" )
          ; ( "cutover_at_ms", `Int 1 )
          ; ( "legacy_keepers", `List [] )
          ; ( "legacy_task_ids", `List [] )
          ; ( "legacy_manifest_sha256", `String manifest_hex )
          ; ( "extra", `Null )
          ] )
    ; ( "an inventory with its members in another order"
      , member "inventory_frozen"
          [ ( "cutover_at_ms", `Int 1 )
          ; ( "bootstrap_invite_id", `String "invite-1" )
          ; ( "legacy_keepers", `List [] )
          ; ( "legacy_task_ids", `List [] )
          ; ( "legacy_manifest_sha256", `String manifest_hex )
          ] )
    ; ( "an inventory whose cutover is a string"
      , member "inventory_frozen"
          [ ( "bootstrap_invite_id", `String "invite-1" )
          ; ( "cutover_at_ms", `String "1" )
          ; ( "legacy_keepers", `List [] )
          ; ( "legacy_task_ids", `List [] )
          ; ( "legacy_manifest_sha256", `String manifest_hex )
          ] )
    ; ( "an inventory whose keeper list is descending"
      , member "inventory_frozen"
          [ ( "bootstrap_invite_id", `String "invite-1" )
          ; ( "cutover_at_ms", `Int 1 )
          ; ( "legacy_keepers", `List [ `String "keeper-b"; `String "keeper-a" ] )
          ; ( "legacy_task_ids", `List [] )
          ; ( "legacy_manifest_sha256", `String manifest_hex )
          ] )
    ; ( "an inventory whose keeper list repeats a name"
      , member "inventory_frozen"
          [ ( "bootstrap_invite_id", `String "invite-1" )
          ; ( "cutover_at_ms", `Int 1 )
          ; ( "legacy_keepers", `List [ `String "keeper-a"; `String "keeper-a" ] )
          ; ( "legacy_task_ids", `List [] )
          ; ( "legacy_manifest_sha256", `String manifest_hex )
          ] )
    ; ( "an inventory whose keeper list holds a number"
      , member "inventory_frozen"
          [ ( "bootstrap_invite_id", `String "invite-1" )
          ; ( "cutover_at_ms", `Int 1 )
          ; ( "legacy_keepers", `List [ `Int 1 ] )
          ; ( "legacy_task_ids", `List [] )
          ; ( "legacy_manifest_sha256", `String manifest_hex )
          ] )
    ; ( "an inventory whose manifest hash is not hex"
      , member "inventory_frozen"
          [ ( "bootstrap_invite_id", `String "invite-1" )
          ; ( "cutover_at_ms", `Int 1 )
          ; ( "legacy_keepers", `List [] )
          ; ( "legacy_task_ids", `List [] )
          ; ( "legacy_manifest_sha256", `String "not-a-hash" )
          ] )
    ; ( "an inventory whose invite id is not one"
      , member "inventory_frozen"
          [ ( "bootstrap_invite_id", `String "Invite 1" )
          ; ( "cutover_at_ms", `Int 1 )
          ; ( "legacy_keepers", `List [] )
          ; ( "legacy_task_ids", `List [] )
          ; ( "legacy_manifest_sha256", `String manifest_hex )
          ] )
    ; "a candidate without its invite", member "candidate_bound" [ "user_id", `String "alice" ]
    ; ( "a claim whose scope is not one"
      , member "keeper_claimed"
          [ ( "engine_name", `String "keeper-a" )
          ; ( "claimant", `String "alice" )
          ; ( "keeper_id", `String "keeper-b" )
          ; ( "runtime_id", `String "runtime-1" )
          ; ( "policy_id", `String "policy-1" )
          ; ( "turn_scope", `String "all" )
          ] )
    ; ( "a retirement with another member name"
      , member "keeper_retired"
          [ ("engine_name", `String "keeper-a"); ("claimed_by", `String "alice") ] )
    ]
;;

let errors_are_told_apart () =
  let texts =
    List.map L.error_to_string
      [ L.Not_an_object
      ; L.Unknown_event "bogus"
      ; L.Wrong_members
      ; L.Not_ascending "legacy_keepers"
      ; L.Invalid_manifest_hash
      ; L.Invalid_user_id Authz_id.Empty
      ]
  in
  Alcotest.(check int)
    "each reason has its own text"
    (List.length texts)
    (List.length (List.sort_uniq String.compare texts));
  Alcotest.(check bool)
    "the event label is in the text"
    true
    (contains ~sub:"bogus" (L.error_to_string (L.Unknown_event "bogus")));
  Alcotest.(check bool)
    "the member is in the text"
    true
    (contains
       ~sub:"legacy_task_ids"
       (L.error_to_string (L.Not_ascending "legacy_task_ids")))
;;

let () =
  Alcotest.run
    "authz_legacy_event"
    [ ( "labels"
      , [ Alcotest.test_case "on disk" `Quick labels_are_the_names_on_disk ] )
    ; ( "body"
      , [ Alcotest.test_case "inventory bytes" `Quick bytes_of_the_inventory
        ; Alcotest.test_case "claim bytes" `Quick bytes_of_a_claim
        ; Alcotest.test_case "reads back" `Quick reads_back_what_it_wrote
        ; Alcotest.test_case "claim scope" `Quick a_claim_keeps_its_scope
        ; Alcotest.test_case "unknown event" `Quick an_unknown_event_is_refused
        ; Alcotest.test_case
            "not one"
            `Quick
            a_body_that_is_not_a_legacy_attribution_is_refused
        ; Alcotest.test_case "texts" `Quick errors_are_told_apart
        ] )
    ]
;;
