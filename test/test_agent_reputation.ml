(** Tests for Agent_reputation — default values, JSON roundtrip, score calculation *)

open Masc_mcp

(** Create a temporary directory with .masc setup. *)
let make_test_config () =
  let tmp_dir = Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "test_agent_rep_%d_%d"
       (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.)))
  in
  Unix.mkdir tmp_dir 0o755;
  let config = Room.default_config tmp_dir in
  let masc_dir = Room.masc_dir config in
  (try Unix.mkdir masc_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  config

let cleanup_test_config (config : Room.config) =
  let rec rm_rf path =
    if Sys.is_directory path then begin
      Array.iter (fun f -> rm_rf (Filename.concat path f)) (Sys.readdir path);
      Unix.rmdir path
    end else
      Sys.remove path
  in
  (try rm_rf config.base_path with _ -> ())

(** {1 Default Reputation Tests} *)

let test_default_reputation () =
  let r = Agent_reputation.default_reputation ~agent_name:"claude" in
  Alcotest.(check string) "name" "claude" r.agent_name;
  Alcotest.(check int) "tasks_completed" 0 r.tasks_completed;
  Alcotest.(check int) "tasks_claimed" 0 r.tasks_claimed;
  Alcotest.(check (float 0.01)) "completion_rate" 0.0 r.completion_rate;
  Alcotest.(check int) "mentions_received" 0 r.mentions_received;
  Alcotest.(check int) "mentions_responded" 0 r.mentions_responded;
  Alcotest.(check (float 0.01)) "response_rate" 0.0 r.response_rate;
  Alcotest.(check int) "board_posts" 0 r.board_posts;
  Alcotest.(check int) "board_comments" 0 r.board_comments;
  Alcotest.(check int) "debates_participated" 0 r.debates_participated;
  Alcotest.(check (float 0.01)) "overall_score" 0.0 r.overall_score

(** {1 JSON Roundtrip Tests} *)

let test_reputation_roundtrip () =
  let r : Agent_reputation.agent_reputation = {
    agent_name = "gemini";
    tasks_completed = 5;
    tasks_claimed = 8;
    completion_rate = 0.625;
    mentions_received = 10;
    mentions_responded = 7;
    response_rate = 0.7;
    board_posts = 3;
    board_comments = 12;
    debates_participated = 2;
    overall_score = 0.65;
  } in
  let json = Agent_reputation.reputation_to_json r in
  match Agent_reputation.reputation_of_json json with
  | None -> Alcotest.fail "Roundtrip failed: of_json returned None"
  | Some r2 ->
    Alcotest.(check string) "name" r.agent_name r2.agent_name;
    Alcotest.(check int) "tasks_completed" r.tasks_completed r2.tasks_completed;
    Alcotest.(check int) "tasks_claimed" r.tasks_claimed r2.tasks_claimed;
    Alcotest.(check (float 0.001)) "completion_rate" r.completion_rate r2.completion_rate;
    Alcotest.(check int) "mentions_received" r.mentions_received r2.mentions_received;
    Alcotest.(check int) "mentions_responded" r.mentions_responded r2.mentions_responded;
    Alcotest.(check (float 0.001)) "response_rate" r.response_rate r2.response_rate;
    Alcotest.(check int) "board_posts" r.board_posts r2.board_posts;
    Alcotest.(check int) "board_comments" r.board_comments r2.board_comments;
    Alcotest.(check int) "debates" r.debates_participated r2.debates_participated;
    Alcotest.(check (float 0.001)) "overall_score" r.overall_score r2.overall_score

let test_reputation_of_json_invalid () =
  (* Missing agent_name *)
  let json = `Assoc [("tasks_completed", `Int 5)] in
  match Agent_reputation.reputation_of_json json with
  | None -> ()
  | Some _ -> Alcotest.fail "Expected None for missing agent_name"

let test_reputation_of_json_malformed () =
  match Agent_reputation.reputation_of_json (`String "not an object") with
  | None -> ()
  | Some _ -> Alcotest.fail "Expected None for non-object JSON"

(** {1 Overall Score Calculation Tests} *)

let test_overall_score_all_zero () =
  let score = Agent_reputation.compute_overall_score
    ~completion_rate:0.0 ~response_rate:0.0
    ~board_posts:0 ~board_comments:0 ~debates_participated:0
  in
  Alcotest.(check (float 0.001)) "all zero" 0.0 score

let test_overall_score_perfect () =
  let score = Agent_reputation.compute_overall_score
    ~completion_rate:1.0 ~response_rate:1.0
    ~board_posts:20 ~board_comments:0 ~debates_participated:10
  in
  (* 0.4*1.0 + 0.3*1.0 + 0.2*1.0 + 0.1*1.0 = 1.0 *)
  Alcotest.(check (float 0.001)) "perfect" 1.0 score

let test_overall_score_weighted () =
  let score = Agent_reputation.compute_overall_score
    ~completion_rate:0.5 ~response_rate:0.5
    ~board_posts:5 ~board_comments:5 ~debates_participated:5
  in
  (* 0.4*0.5 + 0.3*0.5 + 0.2*(10/20) + 0.1*(5/10) *)
  (* = 0.2 + 0.15 + 0.1 + 0.05 = 0.5 *)
  Alcotest.(check (float 0.001)) "weighted" 0.5 score

let test_overall_score_board_capped () =
  (* Board activity is capped at 20 actions *)
  let score_at_cap = Agent_reputation.compute_overall_score
    ~completion_rate:0.0 ~response_rate:0.0
    ~board_posts:10 ~board_comments:10 ~debates_participated:0
  in
  let score_over_cap = Agent_reputation.compute_overall_score
    ~completion_rate:0.0 ~response_rate:0.0
    ~board_posts:50 ~board_comments:50 ~debates_participated:0
  in
  (* Both should give same board contribution: capped at 1.0 *)
  Alcotest.(check (float 0.001)) "board capped" score_at_cap score_over_cap

(** {1 Compute Reputation Integration Tests} *)

let test_compute_empty_room () =
  let config = make_test_config () in
  Fun.protect ~finally:(fun () -> cleanup_test_config config) (fun () ->
    let r = Agent_reputation.compute_reputation config ~agent_name:"claude" in
    Alcotest.(check string) "name" "claude" r.agent_name;
    Alcotest.(check int) "tasks_completed" 0 r.tasks_completed;
    Alcotest.(check (float 0.01)) "overall_score" 0.0 r.overall_score)

let test_compute_with_mentions () =
  let config = make_test_config () in
  Fun.protect ~finally:(fun () -> cleanup_test_config config) (fun () ->
    (* Add some mentions *)
    let mention : Mention_inbox.mention_record = {
      id = "m-rep-1"; target_agent = "claude"; source_agent = "gemini";
      source_kind = "room_message"; source_id = "r1";
      content_preview = "test"; created_at = 1700000000.0; read_at = 0.0;
    } in
    Mention_inbox.append_mention config mention;
    let mention2 = { mention with id = "m-rep-2"; read_at = 1700001000.0 } in
    Mention_inbox.append_mention config mention2;
    let r = Agent_reputation.compute_reputation config ~agent_name:"claude" in
    Alcotest.(check int) "mentions_received" 2 r.mentions_received;
    Alcotest.(check int) "mentions_responded" 1 r.mentions_responded;
    Alcotest.(check (float 0.01)) "response_rate" 0.5 r.response_rate)

(** {1 Test Suite} *)

let () =
  let open Alcotest in
  run "Agent_reputation" [
    "defaults", [
      test_case "default_reputation" `Quick test_default_reputation;
    ];
    "json", [
      test_case "roundtrip" `Quick test_reputation_roundtrip;
      test_case "invalid" `Quick test_reputation_of_json_invalid;
      test_case "malformed" `Quick test_reputation_of_json_malformed;
    ];
    "scoring", [
      test_case "all_zero" `Quick test_overall_score_all_zero;
      test_case "perfect" `Quick test_overall_score_perfect;
      test_case "weighted" `Quick test_overall_score_weighted;
      test_case "board_capped" `Quick test_overall_score_board_capped;
    ];
    "integration", [
      test_case "empty_room" `Quick test_compute_empty_room;
      test_case "with_mentions" `Quick test_compute_with_mentions;
    ];
  ]
