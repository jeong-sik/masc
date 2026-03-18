(** Test Room_vote - Consensus voting input validation and core logic *)

open Masc_mcp

let () = Mirage_crypto_rng_unix.use_default ()

(** Isolated test directory *)
let test_base_path =
  let dir = Filename.concat (Filename.get_temp_dir_name ()) "masc-test-room-vote" in
  dir

(** Wrap test body in Eio runtime with filesystem backend *)
let with_eio f () =
  Eio_main.run @@ fun _env ->
  (* Force filesystem backend, avoid PG connection errors *)
  Unix.putenv "MASC_BASE_PATH" test_base_path;
  (try Unix.putenv "MASC_POSTGRES_URL" "" with _ -> ());
  let config = Room.default_config test_base_path in
  let _ = Room.init config ~agent_name:(Some "test-agent") in
  f config

let contains needle haystack =
  let n = String.length needle in
  let h = String.length haystack in
  let rec loop i =
    if i + n > h then false
    else if String.sub haystack i n = needle then true
    else loop (i + 1)
  in
  n = 0 || loop 0

(** Helper to create a vote and extract vote_id *)
let create_vote config ~topic ~options ~required_votes =
  let result = Room.vote_create config ~proposer:"proposer" ~topic
    ~options ~required_votes in
  (* Extract vote_id from "Vote created: vote-XXXX\n..." *)
  let parts = String.split_on_char ':' result in
  let after_colon = List.nth parts 1 in
  String.trim (List.hd (String.split_on_char '\n' after_colon))

(** {1 vote_create validation} *)

let test_vote_create_valid config =
  let result = Room.vote_create config ~proposer:"alice" ~topic:"deploy?"
    ~options:["yes"; "no"] ~required_votes:2 in
  Alcotest.(check bool) "creates successfully" true (contains "Vote created" result)

let test_vote_create_zero_required config =
  let result = Room.vote_create config ~proposer:"alice" ~topic:"bad"
    ~options:["yes"; "no"] ~required_votes:0 in
  Alcotest.(check bool) "rejects 0 required_votes" true (contains "must be at least 1" result)

let test_vote_create_negative_required config =
  let result = Room.vote_create config ~proposer:"alice" ~topic:"bad"
    ~options:["yes"; "no"] ~required_votes:(-1) in
  Alcotest.(check bool) "rejects negative required_votes" true (contains "must be at least 1" result)

let test_vote_create_empty_options config =
  let result = Room.vote_create config ~proposer:"alice" ~topic:"bad"
    ~options:[] ~required_votes:2 in
  Alcotest.(check bool) "rejects empty options" true (contains "cannot be empty" result)

(** {1 vote_cast validation} *)

let test_vote_cast_not_found config =
  let result = Room.vote_cast config ~agent_name:"bob"
    ~vote_id:"vote-nonexistent-999" ~choice:"yes" in
  Alcotest.(check bool) "vote not found" true (contains "not found" result)

let test_vote_cast_invalid_choice config =
  let vote_id = create_vote config ~topic:"choice test"
    ~options:["yes"; "no"] ~required_votes:3 in
  let result = Room.vote_cast config ~agent_name:"bob"
    ~vote_id ~choice:"maybe" in
  Alcotest.(check bool) "rejects invalid choice" true (contains "Invalid choice" result)

let test_vote_cast_duplicate config =
  let vote_id = create_vote config ~topic:"dup test"
    ~options:["yes"; "no"] ~required_votes:3 in
  let _ = Room.vote_cast config ~agent_name:"bob" ~vote_id ~choice:"yes" in
  let result = Room.vote_cast config ~agent_name:"bob" ~vote_id ~choice:"no" in
  Alcotest.(check bool) "rejects duplicate vote" true (contains "already voted" result)

let test_vote_cast_valid config =
  let vote_id = create_vote config ~topic:"valid cast"
    ~options:["yes"; "no"] ~required_votes:3 in
  let result = Room.vote_cast config ~agent_name:"bob" ~vote_id ~choice:"yes" in
  Alcotest.(check bool) "cast succeeds" true (contains "Vote cast" result)

(** {1 Quorum and resolution} *)

let test_vote_quorum_approved config =
  let vote_id = create_vote config ~topic:"quorum test"
    ~options:["yes"; "no"] ~required_votes:2 in
  let _ = Room.vote_cast config ~agent_name:"alice" ~vote_id ~choice:"yes" in
  let result = Room.vote_cast config ~agent_name:"bob" ~vote_id ~choice:"yes" in
  Alcotest.(check bool) "vote resolved" true (contains "resolved" result);
  Alcotest.(check bool) "winner is yes" true (contains "yes" result)

let test_vote_tie config =
  let vote_id = create_vote config ~topic:"tie test"
    ~options:["yes"; "no"] ~required_votes:2 in
  let _ = Room.vote_cast config ~agent_name:"alice" ~vote_id ~choice:"yes" in
  let result = Room.vote_cast config ~agent_name:"bob" ~vote_id ~choice:"no" in
  Alcotest.(check bool) "vote resolved" true (contains "resolved" result);
  Alcotest.(check bool) "result is tied" true (contains "Tied" result)

let test_vote_cast_after_resolved config =
  let vote_id = create_vote config ~topic:"resolved test"
    ~options:["yes"; "no"] ~required_votes:1 in
  let _ = Room.vote_cast config ~agent_name:"alice" ~vote_id ~choice:"yes" in
  let result = Room.vote_cast config ~agent_name:"bob" ~vote_id ~choice:"no" in
  Alcotest.(check bool) "already resolved" true (contains "already resolved" result)

(** {1 vote_status and list_votes} *)

let test_vote_status_not_found config =
  let json = Room.vote_status config ~vote_id:"nonexistent-999" in
  let has_error = match json with
    | `Assoc fields -> List.mem_assoc "error" fields
    | _ -> false
  in
  Alcotest.(check bool) "returns error for missing vote" true has_error

let test_list_votes config =
  (* Create a vote first, then list *)
  let _ = create_vote config ~topic:"list test"
    ~options:["a"; "b"] ~required_votes:2 in
  let json = Room.list_votes config in
  let count = match json with
    | `Assoc fields ->
        (match List.assoc_opt "count" fields with
         | Some (`Int n) -> n
         | _ -> -1)
    | _ -> -1
  in
  Alcotest.(check bool) "has votes" true (count >= 1)

(** {1 Test Runner} *)

let () =
  Alcotest.run "Room_vote" [
    "create_validation", [
      Alcotest.test_case "valid create" `Quick (with_eio test_vote_create_valid);
      Alcotest.test_case "zero required_votes" `Quick (with_eio test_vote_create_zero_required);
      Alcotest.test_case "negative required_votes" `Quick (with_eio test_vote_create_negative_required);
      Alcotest.test_case "empty options" `Quick (with_eio test_vote_create_empty_options);
    ];
    "cast_validation", [
      Alcotest.test_case "vote not found" `Quick (with_eio test_vote_cast_not_found);
      Alcotest.test_case "invalid choice" `Quick (with_eio test_vote_cast_invalid_choice);
      Alcotest.test_case "duplicate vote rejected" `Quick (with_eio test_vote_cast_duplicate);
      Alcotest.test_case "valid cast" `Quick (with_eio test_vote_cast_valid);
    ];
    "resolution", [
      Alcotest.test_case "quorum approved" `Quick (with_eio test_vote_quorum_approved);
      Alcotest.test_case "tie" `Quick (with_eio test_vote_tie);
      Alcotest.test_case "cast after resolved" `Quick (with_eio test_vote_cast_after_resolved);
    ];
    "status", [
      Alcotest.test_case "not found" `Quick (with_eio test_vote_status_not_found);
      Alcotest.test_case "list votes" `Quick (with_eio test_list_votes);
    ];
  ]
