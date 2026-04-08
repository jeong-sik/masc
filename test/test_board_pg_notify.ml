open Alcotest
open Masc_mcp.Board_pg_notify

(* --- Board_pg_notify event_to_json --- *)

let test_pg_notify_post_created () =
  let json_str = event_to_json
    (Post_created { post_id = "p1"; author = "alice"; hearth = Some "general" }) in
  let json = Yojson.Safe.from_string json_str in
  let typ = Yojson.Safe.Util.(member "type" json |> to_string) in
  check string "type" "post_created" typ;
  let hearth = Yojson.Safe.Util.(member "hearth" json |> to_string) in
  check string "hearth" "general" hearth

let test_pg_notify_post_created_no_hearth () =
  let json_str = event_to_json
    (Post_created { post_id = "p2"; author = "bob"; hearth = None }) in
  let json = Yojson.Safe.from_string json_str in
  let hearth = Yojson.Safe.Util.member "hearth" json in
  check bool "no hearth field" true
    (hearth = `Null || not (List.mem_assoc "hearth" (Yojson.Safe.Util.to_assoc json)))

let test_pg_notify_post_voted () =
  let json_str = event_to_json
    (Post_voted { post_id = "p1"; voter = "alice"; direction = "up"; new_score = 5 }) in
  let json = Yojson.Safe.from_string json_str in
  check string "type" "post_voted"
    Yojson.Safe.Util.(member "type" json |> to_string);
  check int "new_score" 5
    Yojson.Safe.Util.(member "new_score" json |> to_int)

let test_pg_notify_comment_added () =
  let json_str = event_to_json
    (Comment_added { post_id = "p1"; comment_id = "c1"; author = "alice" }) in
  let json = Yojson.Safe.from_string json_str in
  check string "type" "comment_added"
    Yojson.Safe.Util.(member "type" json |> to_string);
  check string "comment_id" "c1"
    Yojson.Safe.Util.(member "comment_id" json |> to_string)

let test_pg_notify_comment_voted () =
  let json_str = event_to_json
    (Comment_voted { comment_id = "c1"; voter = "bob"; direction = "down" }) in
  let json = Yojson.Safe.from_string json_str in
  check string "type" "comment_voted"
    Yojson.Safe.Util.(member "type" json |> to_string);
  check string "direction" "down"
    Yojson.Safe.Util.(member "direction" json |> to_string)

(* --- pg_notify max_notify_payload --- *)

let test_pg_notify_max_payload () =
  check bool "max payload < 8000"
    true (max_notify_payload < 8000);
  check bool "max payload > 0"
    true (max_notify_payload > 0)

let () =
  run "Board_pg_notify" [
    "event_to_json", [
      test_case "post_created" `Quick test_pg_notify_post_created;
      test_case "post_created no hearth" `Quick test_pg_notify_post_created_no_hearth;
      test_case "post_voted" `Quick test_pg_notify_post_voted;
      test_case "comment_added" `Quick test_pg_notify_comment_added;
      test_case "comment_voted" `Quick test_pg_notify_comment_voted;
    ];
    "max_payload", [
      test_case "within bounds" `Quick test_pg_notify_max_payload;
    ];
  ]
