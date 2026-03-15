(** Tests for Mention_inbox — JSONL persistence, unread count, mark_read *)

open Masc_mcp

(** Create a temporary directory for test JSONL data.
    Uses Room.default_config which handles backend setup. *)
let make_test_config () =
  let tmp_dir = Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "test_mention_inbox_%d_%d"
       (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.)))
  in
  Unix.mkdir tmp_dir 0o755;
  let config = Room.default_config tmp_dir in
  (* Ensure .masc dir exists *)
  let masc_dir = Room.masc_dir config in
  (try Unix.mkdir masc_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  config

let cleanup_test_config (config : Room.config) =
  (* Best-effort recursive cleanup *)
  let rec rm_rf path =
    if Sys.is_directory path then begin
      Array.iter (fun f -> rm_rf (Filename.concat path f)) (Sys.readdir path);
      Unix.rmdir path
    end else
      Sys.remove path
  in
  (try rm_rf config.base_path with _ -> ())

(** {1 JSON Roundtrip Tests} *)

let test_mention_record_roundtrip () =
  let record : Mention_inbox.mention_record = {
    id = "m-1234567890-0042";
    target_agent = "claude";
    source_agent = "gemini";
    source_kind = "room_message";
    source_id = "room-default";
    content_preview = "Hey @claude, can you review this?";
    created_at = 1700000000.0;
    read_at = 0.0;
  } in
  let json = Mention_inbox.mention_record_to_json record in
  match Mention_inbox.mention_record_of_json json with
  | None -> Alcotest.fail "Roundtrip failed: of_json returned None"
  | Some r ->
    Alcotest.(check string) "id" record.id r.id;
    Alcotest.(check string) "target" record.target_agent r.target_agent;
    Alcotest.(check string) "source" record.source_agent r.source_agent;
    Alcotest.(check string) "kind" record.source_kind r.source_kind;
    Alcotest.(check string) "source_id" record.source_id r.source_id;
    Alcotest.(check string) "preview" record.content_preview r.content_preview;
    Alcotest.(check (float 0.01)) "created_at" record.created_at r.created_at;
    Alcotest.(check (float 0.01)) "read_at" record.read_at r.read_at

let test_mention_record_of_json_invalid () =
  (* Missing id field *)
  let json = `Assoc [("target_agent", `String "claude")] in
  match Mention_inbox.mention_record_of_json json with
  | None -> ()
  | Some _ -> Alcotest.fail "Expected None for invalid JSON"

let test_mention_record_of_json_malformed () =
  match Mention_inbox.mention_record_of_json (`String "not an object") with
  | None -> ()
  | Some _ -> Alcotest.fail "Expected None for non-object JSON"

(** {1 ID Generation Tests} *)

let test_generate_mention_id () =
  let id1 = Mention_inbox.generate_mention_id () in
  let id2 = Mention_inbox.generate_mention_id () in
  (* Both start with "m-" *)
  Alcotest.(check bool) "id1 starts with m-"
    true (String.length id1 > 2 && String.sub id1 0 2 = "m-");
  Alcotest.(check bool) "id2 starts with m-"
    true (String.length id2 > 2 && String.sub id2 0 2 = "m-");
  (* IDs should differ (not strictly guaranteed but very likely) *)
  if id1 = id2 then
    Printf.eprintf "[WARN] Generated identical IDs: %s (rare but possible)\n%!" id1

(** {1 Persistence Tests} *)

let test_append_and_read () =
  let config = make_test_config () in
  Fun.protect ~finally:(fun () -> cleanup_test_config config) (fun () ->
    let record : Mention_inbox.mention_record = {
      id = "m-test-0001";
      target_agent = "claude";
      source_agent = "gemini";
      source_kind = "board_post";
      source_id = "p-abc";
      content_preview = "Test mention content";
      created_at = 1700000000.0;
      read_at = 0.0;
    } in
    Mention_inbox.append_mention config record;
    let mentions = Mention_inbox.read_mentions config ~target_agent:"claude" ~limit:10 in
    Alcotest.(check int) "one mention" 1 (List.length mentions);
    let r = List.hd mentions in
    Alcotest.(check string) "id matches" "m-test-0001" r.id;
    Alcotest.(check string) "target matches" "claude" r.target_agent)

let test_read_filters_by_target () =
  let config = make_test_config () in
  Fun.protect ~finally:(fun () -> cleanup_test_config config) (fun () ->
    let make_record id target =
      { Mention_inbox.id; target_agent = target; source_agent = "gemini";
        source_kind = "room_message"; source_id = "r1";
        content_preview = "test"; created_at = 1700000000.0; read_at = 0.0 }
    in
    Mention_inbox.append_mention config (make_record "m-1" "claude");
    Mention_inbox.append_mention config (make_record "m-2" "codex");
    Mention_inbox.append_mention config (make_record "m-3" "claude");
    let claude_mentions = Mention_inbox.read_mentions config ~target_agent:"claude" ~limit:10 in
    Alcotest.(check int) "claude has 2" 2 (List.length claude_mentions);
    let codex_mentions = Mention_inbox.read_mentions config ~target_agent:"codex" ~limit:10 in
    Alcotest.(check int) "codex has 1" 1 (List.length codex_mentions))

let test_read_respects_limit () =
  let config = make_test_config () in
  Fun.protect ~finally:(fun () -> cleanup_test_config config) (fun () ->
    for i = 1 to 5 do
      let record = {
        Mention_inbox.id = Printf.sprintf "m-limit-%d" i;
        target_agent = "claude"; source_agent = "gemini";
        source_kind = "room_message"; source_id = "r1";
        content_preview = "test"; created_at = 1700000000.0 +. float_of_int i;
        read_at = 0.0;
      } in
      Mention_inbox.append_mention config record
    done;
    let mentions = Mention_inbox.read_mentions config ~target_agent:"claude" ~limit:3 in
    Alcotest.(check int) "limit 3" 3 (List.length mentions);
    (* Newest first *)
    let first = List.hd mentions in
    Alcotest.(check string) "newest first" "m-limit-5" first.id)

(** {1 Unread Count Tests} *)

let test_unread_count () =
  let config = make_test_config () in
  Fun.protect ~finally:(fun () -> cleanup_test_config config) (fun () ->
    let make_record id read_at =
      { Mention_inbox.id; target_agent = "claude"; source_agent = "gemini";
        source_kind = "room_message"; source_id = "r1";
        content_preview = "test"; created_at = 1700000000.0; read_at }
    in
    Mention_inbox.append_mention config (make_record "m-u1" 0.0);
    Mention_inbox.append_mention config (make_record "m-u2" 1700001000.0);
    Mention_inbox.append_mention config (make_record "m-u3" 0.0);
    let count = Mention_inbox.unread_count config ~target_agent:"claude" in
    Alcotest.(check int) "2 unread" 2 count)

(** {1 Mark Read Tests} *)

let test_mark_read () =
  let config = make_test_config () in
  Fun.protect ~finally:(fun () -> cleanup_test_config config) (fun () ->
    let record = {
      Mention_inbox.id = "m-mark-1";
      target_agent = "claude"; source_agent = "gemini";
      source_kind = "room_message"; source_id = "r1";
      content_preview = "test"; created_at = 1700000000.0; read_at = 0.0;
    } in
    Mention_inbox.append_mention config record;
    Alcotest.(check int) "1 unread before" 1
      (Mention_inbox.unread_count config ~target_agent:"claude");
    Mention_inbox.mark_read config ~mention_id:"m-mark-1";
    Alcotest.(check int) "0 unread after" 0
      (Mention_inbox.unread_count config ~target_agent:"claude");
    (* Verify the read_at was set *)
    let mentions = Mention_inbox.read_mentions config ~target_agent:"claude" ~limit:10 in
    let r = List.hd mentions in
    Alcotest.(check bool) "read_at > 0" true (r.read_at > 0.0))

let test_mark_read_nonexistent () =
  let config = make_test_config () in
  Fun.protect ~finally:(fun () -> cleanup_test_config config) (fun () ->
    let record = {
      Mention_inbox.id = "m-existing";
      target_agent = "claude"; source_agent = "gemini";
      source_kind = "room_message"; source_id = "r1";
      content_preview = "test"; created_at = 1700000000.0; read_at = 0.0;
    } in
    Mention_inbox.append_mention config record;
    (* Mark a non-existent ID; should not crash, and existing stays unread *)
    Mention_inbox.mark_read config ~mention_id:"m-nonexistent";
    Alcotest.(check int) "still 1 unread" 1
      (Mention_inbox.unread_count config ~target_agent:"claude"))

(** {1 Empty State Tests} *)

let test_empty_inbox () =
  let config = make_test_config () in
  Fun.protect ~finally:(fun () -> cleanup_test_config config) (fun () ->
    let mentions = Mention_inbox.read_mentions config ~target_agent:"claude" ~limit:10 in
    Alcotest.(check int) "empty" 0 (List.length mentions);
    let count = Mention_inbox.unread_count config ~target_agent:"claude" in
    Alcotest.(check int) "zero unread" 0 count)

(** {1 Test Suite} *)

let () =
  let open Alcotest in
  run "Mention_inbox" [
    "json", [
      test_case "roundtrip" `Quick test_mention_record_roundtrip;
      test_case "invalid" `Quick test_mention_record_of_json_invalid;
      test_case "malformed" `Quick test_mention_record_of_json_malformed;
    ];
    "id_gen", [
      test_case "generate" `Quick test_generate_mention_id;
    ];
    "persistence", [
      test_case "append_and_read" `Quick test_append_and_read;
      test_case "filter_by_target" `Quick test_read_filters_by_target;
      test_case "respects_limit" `Quick test_read_respects_limit;
    ];
    "unread", [
      test_case "count" `Quick test_unread_count;
    ];
    "mark_read", [
      test_case "basic" `Quick test_mark_read;
      test_case "nonexistent" `Quick test_mark_read_nonexistent;
    ];
    "empty", [
      test_case "empty_inbox" `Quick test_empty_inbox;
    ];
  ]
