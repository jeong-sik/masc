(** Social Module Coverage Tests

    Tests for lib/social.ml covering:
    - Type construction
    - JSON serialization/deserialization roundtrips
    - ID generation
    - Directory path functions
*)

open Alcotest

module Social = Masc_mcp.Social

(* ============================================================
   ID Generation Tests
   ============================================================ *)

let test_generate_post_id_format () =
  let id = Social.generate_post_id () in
  check bool "starts with post-" true
    (String.length id > 5 && String.sub id 0 5 = "post-")

let test_generate_post_id_uniqueness () =
  let id1 = Social.generate_post_id () in
  let id2 = Social.generate_post_id () in
  check bool "unique ids" true (id1 <> id2)

let test_generate_comment_id_format () =
  let id = Social.generate_comment_id () in
  check bool "starts with cmt-" true
    (String.length id > 4 && String.sub id 0 4 = "cmt-")

let test_generate_comment_id_uniqueness () =
  let id1 = Social.generate_comment_id () in
  let id2 = Social.generate_comment_id () in
  check bool "unique ids" true (id1 <> id2)

(* ============================================================
   Post JSON Roundtrip Tests
   ============================================================ *)

let sample_post : Social.post = {
  id = "post-123-456";
  author = "claude";
  content = "Hello, world.";
  submolt = Some "general";
  created_at = 1706745600.0;
  votes = 5;
}

let sample_post_no_submolt : Social.post = {
  id = "post-789-012";
  author = "gemini";
  content = "Testing without submolt.";
  submolt = None;
  created_at = 1706832000.0;
  votes = 0;
}

let test_post_to_yojson_basic () =
  let json = Social.post_to_yojson sample_post in
  let open Yojson.Safe.Util in
  check string "id" "post-123-456" (json |> member "id" |> to_string);
  check string "author" "claude" (json |> member "author" |> to_string);
  check string "content" "Hello, world." (json |> member "content" |> to_string);
  check string "submolt" "general" (json |> member "submolt" |> to_string);
  check int "votes" 5 (json |> member "votes" |> to_int)

let test_post_to_yojson_null_submolt () =
  let json = Social.post_to_yojson sample_post_no_submolt in
  let open Yojson.Safe.Util in
  check bool "submolt is null" true
    (json |> member "submolt" = `Null)

let test_post_roundtrip () =
  let json = Social.post_to_yojson sample_post in
  match Social.post_of_yojson json with
  | Ok decoded ->
    check string "id" sample_post.id decoded.id;
    check string "author" sample_post.author decoded.author;
    check string "content" sample_post.content decoded.content;
    check (option string) "submolt" sample_post.submolt decoded.submolt;
    check int "votes" sample_post.votes decoded.votes
  | Error e -> fail ("Roundtrip failed: " ^ e)

let test_post_roundtrip_no_submolt () =
  let json = Social.post_to_yojson sample_post_no_submolt in
  match Social.post_of_yojson json with
  | Ok decoded ->
    check (option string) "submolt" None decoded.submolt
  | Error e -> fail ("Roundtrip failed: " ^ e)

let test_post_of_yojson_invalid () =
  let invalid_json = `Assoc [("not_id", `String "bad")] in
  match Social.post_of_yojson invalid_json with
  | Ok _ -> fail "Should have failed on invalid JSON"
  | Error e ->
    check bool "has error message" true (String.length e > 0)

let test_post_of_yojson_wrong_type () =
  let bad = `String "not an object" in
  match Social.post_of_yojson bad with
  | Ok _ -> fail "Should have failed"
  | Error _ -> ()

(* ============================================================
   Comment JSON Roundtrip Tests
   ============================================================ *)

let sample_comment : Social.comment = {
  id = "cmt-100-200";
  post_id = "post-123-456";
  parent_id = None;
  author = "codex";
  content = "Great post.";
  created_at = 1706745700.0;
  votes = 2;
}

let sample_threaded_comment : Social.comment = {
  id = "cmt-100-300";
  post_id = "post-123-456";
  parent_id = Some "cmt-100-200";
  author = "claude";
  content = "Thanks for the feedback.";
  created_at = 1706745800.0;
  votes = 1;
}

let test_comment_to_yojson_basic () =
  let json = Social.comment_to_yojson sample_comment in
  let open Yojson.Safe.Util in
  check string "id" "cmt-100-200" (json |> member "id" |> to_string);
  check string "post_id" "post-123-456" (json |> member "post_id" |> to_string);
  check bool "parent_id is null" true (json |> member "parent_id" = `Null);
  check string "author" "codex" (json |> member "author" |> to_string);
  check int "votes" 2 (json |> member "votes" |> to_int)

let test_comment_to_yojson_threaded () =
  let json = Social.comment_to_yojson sample_threaded_comment in
  let open Yojson.Safe.Util in
  check string "parent_id" "cmt-100-200" (json |> member "parent_id" |> to_string)

let test_comment_roundtrip () =
  let json = Social.comment_to_yojson sample_comment in
  match Social.comment_of_yojson json with
  | Ok decoded ->
    check string "id" sample_comment.id decoded.id;
    check string "post_id" sample_comment.post_id decoded.post_id;
    check (option string) "parent_id" None decoded.parent_id;
    check string "author" sample_comment.author decoded.author;
    check string "content" sample_comment.content decoded.content;
    check int "votes" sample_comment.votes decoded.votes
  | Error e -> fail ("Roundtrip failed: " ^ e)

let test_comment_roundtrip_threaded () =
  let json = Social.comment_to_yojson sample_threaded_comment in
  match Social.comment_of_yojson json with
  | Ok decoded ->
    check (option string) "parent_id" (Some "cmt-100-200") decoded.parent_id
  | Error e -> fail ("Roundtrip failed: " ^ e)

let test_comment_of_yojson_invalid () =
  let invalid = `Assoc [("bad_field", `Int 42)] in
  match Social.comment_of_yojson invalid with
  | Ok _ -> fail "Should have failed"
  | Error e -> check bool "has error" true (String.length e > 0)

(* ============================================================
   Post Edge Case Tests
   ============================================================ *)

let test_post_empty_content () =
  let p : Social.post = {
    id = "post-empty"; author = "test"; content = "";
    submolt = None; created_at = 0.0; votes = 0;
  } in
  let json = Social.post_to_yojson p in
  match Social.post_of_yojson json with
  | Ok decoded -> check string "empty content" "" decoded.content
  | Error e -> fail ("Roundtrip failed: " ^ e)

let test_post_negative_votes () =
  let p : Social.post = {
    id = "post-neg"; author = "test"; content = "Controversial";
    submolt = Some "debate"; created_at = 1706745600.0; votes = -10;
  } in
  let json = Social.post_to_yojson p in
  match Social.post_of_yojson json with
  | Ok decoded -> check int "negative votes" (-10) decoded.votes
  | Error e -> fail ("Roundtrip failed: " ^ e)

let test_post_unicode_content () =
  let p : Social.post = {
    id = "post-uni"; author = "claude";
    content = "Hello, world.";
    submolt = Some "general"; created_at = 1706745600.0; votes = 1;
  } in
  let json = Social.post_to_yojson p in
  match Social.post_of_yojson json with
  | Ok decoded -> check string "unicode" p.content decoded.content
  | Error e -> fail ("Roundtrip failed: " ^ e)

let test_comment_empty_content () =
  let c : Social.comment = {
    id = "cmt-empty"; post_id = "post-1"; parent_id = None;
    author = "test"; content = ""; created_at = 0.0; votes = 0;
  } in
  let json = Social.comment_to_yojson c in
  match Social.comment_of_yojson json with
  | Ok decoded -> check string "empty content" "" decoded.content
  | Error e -> fail ("Roundtrip failed: " ^ e)

(* ============================================================
   Vote Direction Type Tests
   ============================================================ *)

let test_vote_direction_up_equality () =
  let d : Social.vote_direction = Social.Up in
  check bool "up = up" true (d = Social.Up)

let test_vote_direction_down_equality () =
  let d : Social.vote_direction = Social.Down in
  check bool "down = down" true (d = Social.Down)

let test_vote_direction_inequality () =
  check bool "up <> down" true (Social.Up <> Social.Down)

(* ============================================================
   Vote Record Type Tests
   ============================================================ *)

let test_vote_record_construction () =
  let vr : Social.vote_record = {
    voter = "claude";
    direction = Social.Up;
    voted_at = 1706745600.0;
  } in
  check string "voter" "claude" vr.voter;
  check bool "direction up" true (vr.direction = Social.Up)

(* ============================================================
   Test Runner
   ============================================================ *)

let () =
  run "Social Coverage" [
    "id_generation", [
      test_case "post id format" `Quick test_generate_post_id_format;
      test_case "post id uniqueness" `Quick test_generate_post_id_uniqueness;
      test_case "comment id format" `Quick test_generate_comment_id_format;
      test_case "comment id uniqueness" `Quick test_generate_comment_id_uniqueness;
    ];
    "post_json", [
      test_case "to_yojson basic" `Quick test_post_to_yojson_basic;
      test_case "to_yojson null submolt" `Quick test_post_to_yojson_null_submolt;
      test_case "roundtrip" `Quick test_post_roundtrip;
      test_case "roundtrip no submolt" `Quick test_post_roundtrip_no_submolt;
      test_case "of_yojson invalid" `Quick test_post_of_yojson_invalid;
      test_case "of_yojson wrong type" `Quick test_post_of_yojson_wrong_type;
    ];
    "comment_json", [
      test_case "to_yojson basic" `Quick test_comment_to_yojson_basic;
      test_case "to_yojson threaded" `Quick test_comment_to_yojson_threaded;
      test_case "roundtrip" `Quick test_comment_roundtrip;
      test_case "roundtrip threaded" `Quick test_comment_roundtrip_threaded;
      test_case "of_yojson invalid" `Quick test_comment_of_yojson_invalid;
    ];
    "edge_cases", [
      test_case "post empty content" `Quick test_post_empty_content;
      test_case "post negative votes" `Quick test_post_negative_votes;
      test_case "post unicode content" `Quick test_post_unicode_content;
      test_case "comment empty content" `Quick test_comment_empty_content;
    ];
    "vote_types", [
      test_case "direction up" `Quick test_vote_direction_up_equality;
      test_case "direction down" `Quick test_vote_direction_down_equality;
      test_case "direction inequality" `Quick test_vote_direction_inequality;
      test_case "vote_record construction" `Quick test_vote_record_construction;
    ];
  ]
