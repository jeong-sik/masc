open Alcotest

module Learning = Masc_mcp.Keeper_learning
module Room_utils = Room_utils
module Backend = Backend

(* ---------- Helpers ---------- *)

(** Create a temporary directory for test isolation. *)
let make_temp_dir () =
  let base = Filename.get_temp_dir_name () in
  let name =
    Printf.sprintf "masc-test-kl-%d-%d"
      (Unix.getpid ())
      (int_of_float (Unix.gettimeofday () *. 1000.0) mod 100_000)
  in
  let path = Filename.concat base name in
  Unix.mkdir path 0o755;
  path

(** Clean up a directory tree recursively. *)
let rec rm_rf path =
  if Sys.file_exists path then begin
    if Sys.is_directory path then begin
      Array.iter
        (fun entry -> rm_rf (Filename.concat path entry))
        (Sys.readdir path);
      Unix.rmdir path
    end
    else Sys.remove path
  end

(** Create a Room_utils.config pointing to a temp directory with Memory backend. *)
let make_test_config () =
  let tmp = make_temp_dir () in
  let backend_config : Backend.config = {
    backend_type = Backend.Memory;
    base_path = Filename.concat tmp ".masc";
    postgres_url = None;
    node_id = "test-node";
    cluster_name = "default";
    pubsub_max_messages = 1000;
  } in
  let memory_backend =
    match Backend.MemoryBackend.create backend_config with
    | Ok backend -> backend
    | Error e -> failwith (Backend.show_error e)
  in
  let config : Room_utils.config = {
    base_path = tmp;
    workspace_path = tmp;
    lock_expiry_minutes = 30;
    backend_config;
    backend = Room_utils.Memory memory_backend;
    scope = Default;
  } in
  (tmp, config)

(** Build a minimal decision_record for testing. *)
let make_decision ?(id = "dec-1000-0001") ?(keeper_name = "test-keeper")
    ?(timestamp = 1710000000.0) ?(triggers = [ "direct_mention" ])
    ?(observation_json = `Assoc [ ("direct_mention", `Bool true) ])
    ?(prompt_hash = "abcd1234") ?(action_chosen = "reply_in_room")
    ?(action_json =
      `Assoc
        [
          ("type", `String "reply_in_room");
          ("room_id", `String "room-1");
          ("content", `String "hello");
        ])
    ?(reasoning = "User asked a question") ?(confidence = 0.85)
    ?(cost_usd = 0.001) ?(outcome = "pending") ?(outcome_detail = "")
    ?(feedback_score = None) ?(feedback_comment = "") () :
    Learning.decision_record =
  {
    id;
    keeper_name;
    timestamp;
    triggers;
    observation_json;
    prompt_hash;
    action_chosen;
    action_json;
    reasoning;
    confidence;
    cost_usd;
    outcome;
    outcome_detail;
    feedback_score;
    feedback_comment;
  }

(* ---------- generate_decision_id tests ---------- *)

let test_generate_decision_id_format () =
  let id = Learning.generate_decision_id () in
  check bool "starts with dec-" true
    (String.length id > 4 && String.sub id 0 4 = "dec-");
  (* Should contain a hyphen-separated structure: dec-<timestamp>-<rand> *)
  let parts = String.split_on_char '-' id in
  check bool "at least 3 parts" true (List.length parts >= 3)

let test_generate_decision_id_uniqueness () =
  let id1 = Learning.generate_decision_id () in
  let id2 = Learning.generate_decision_id () in
  check bool "two IDs differ" true (id1 <> id2)

(* ---------- prompt_hash tests ---------- *)

let test_prompt_hash_length () =
  let h = Learning.prompt_hash "some prompt text" in
  check int "hash length is 8" 8 (String.length h)

let test_prompt_hash_deterministic () =
  let h1 = Learning.prompt_hash "same prompt" in
  let h2 = Learning.prompt_hash "same prompt" in
  check string "same input same hash" h1 h2

let test_prompt_hash_different_inputs () =
  let h1 = Learning.prompt_hash "prompt A" in
  let h2 = Learning.prompt_hash "prompt B" in
  check bool "different inputs different hash" true (h1 <> h2)

(* ---------- JSON roundtrip tests ---------- *)

let test_decision_record_json_roundtrip () =
  let original = make_decision () in
  let json = Learning.decision_record_to_json original in
  match Learning.decision_record_of_json json with
  | None -> fail "expected Some decision_record, got None"
  | Some parsed ->
      check string "id" original.id parsed.id;
      check string "keeper_name" original.keeper_name parsed.keeper_name;
      check (float 0.01) "timestamp" original.timestamp parsed.timestamp;
      check (list string) "triggers" original.triggers parsed.triggers;
      check string "prompt_hash" original.prompt_hash parsed.prompt_hash;
      check string "action_chosen" original.action_chosen parsed.action_chosen;
      check string "reasoning" original.reasoning parsed.reasoning;
      check (float 0.001) "confidence" original.confidence parsed.confidence;
      check (float 0.0001) "cost_usd" original.cost_usd parsed.cost_usd;
      check string "outcome" original.outcome parsed.outcome;
      check string "outcome_detail" original.outcome_detail
        parsed.outcome_detail;
      check bool "feedback_score is None" true
        (parsed.feedback_score = None);
      check string "feedback_comment" "" parsed.feedback_comment

let test_decision_record_json_roundtrip_with_feedback () =
  let original =
    make_decision ~feedback_score:(Some 0.75)
      ~feedback_comment:"good decision" ()
  in
  let json = Learning.decision_record_to_json original in
  match Learning.decision_record_of_json json with
  | None -> fail "expected Some decision_record, got None"
  | Some parsed ->
      check (option (float 0.001)) "feedback_score" (Some 0.75)
        parsed.feedback_score;
      check string "feedback_comment" "good decision"
        parsed.feedback_comment

let test_decision_record_of_json_missing_id () =
  let json = `Assoc [ ("keeper_name", `String "test") ] in
  check bool "missing id returns None" true
    (Learning.decision_record_of_json json = None)

let test_decision_record_of_json_missing_keeper_name () =
  let json = `Assoc [ ("id", `String "dec-1") ] in
  check bool "missing keeper_name returns None" true
    (Learning.decision_record_of_json json = None)

let test_decision_record_of_json_malformed () =
  let json = `String "not an object" in
  check bool "malformed json returns None" true
    (Learning.decision_record_of_json json = None)

(* ---------- record_decision + read_decisions tests ---------- *)

let test_record_and_read_decisions () =
  let tmp, config = make_test_config () in
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
      let d1 =
        make_decision ~id:"dec-001" ~timestamp:1710000001.0 ()
      in
      let d2 =
        make_decision ~id:"dec-002" ~timestamp:1710000002.0 ()
      in
      Learning.record_decision config d1;
      Learning.record_decision config d2;
      let records =
        Learning.read_decisions config ~keeper_name:"test-keeper" ~limit:10
      in
      check int "two records" 2 (List.length records);
      (* newest first *)
      let first = List.hd records in
      check string "newest first" "dec-002" first.id)

let test_read_decisions_limit () =
  let tmp, config = make_test_config () in
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
      for i = 1 to 5 do
        let d =
          make_decision
            ~id:(Printf.sprintf "dec-%03d" i)
            ~timestamp:(1710000000.0 +. float_of_int i)
            ()
        in
        Learning.record_decision config d
      done;
      let records =
        Learning.read_decisions config ~keeper_name:"test-keeper" ~limit:3
      in
      check int "limited to 3" 3 (List.length records);
      let first = List.hd records in
      check string "newest is dec-005" "dec-005" first.id)

let test_read_decisions_empty () =
  let tmp, config = make_test_config () in
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
      let records =
        Learning.read_decisions config ~keeper_name:"nonexistent" ~limit:10
      in
      check int "empty for missing keeper" 0 (List.length records))

let test_read_decisions_zero_limit_returns_all () =
  let tmp, config = make_test_config () in
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
      for i = 1 to 4 do
        let d =
          make_decision
            ~id:(Printf.sprintf "dec-%03d" i)
            ~timestamp:(1710000000.0 +. float_of_int i)
            ()
        in
        Learning.record_decision config d
      done;
      let records =
        Learning.read_decisions config ~keeper_name:"test-keeper" ~limit:0
      in
      check int "all 4 records" 4 (List.length records))

(* ---------- record_outcome tests ---------- *)

let test_record_outcome_updates_existing () =
  let tmp, config = make_test_config () in
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
      let d = make_decision ~id:"dec-outcome-1" () in
      Learning.record_decision config d;
      Learning.record_outcome config ~keeper_name:"test-keeper"
        ~decision_id:"dec-outcome-1" ~outcome:"success"
        ~detail:"task completed";
      let records =
        Learning.read_decisions config ~keeper_name:"test-keeper" ~limit:10
      in
      check int "still 1 record" 1 (List.length records);
      let r = List.hd records in
      check string "outcome updated" "success" r.outcome;
      check string "detail updated" "task completed" r.outcome_detail)

let test_record_outcome_nonexistent_decision () =
  let tmp, config = make_test_config () in
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
      let d = make_decision ~id:"dec-exists" () in
      Learning.record_decision config d;
      (* This should not crash and should not modify anything *)
      Learning.record_outcome config ~keeper_name:"test-keeper"
        ~decision_id:"dec-missing" ~outcome:"failure" ~detail:"not found";
      let records =
        Learning.read_decisions config ~keeper_name:"test-keeper" ~limit:10
      in
      let r = List.hd records in
      check string "original outcome unchanged" "pending" r.outcome)

(* ---------- record_feedback tests ---------- *)

let test_record_feedback_updates_existing () =
  let tmp, config = make_test_config () in
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
      let d = make_decision ~id:"dec-fb-1" () in
      Learning.record_decision config d;
      Learning.record_feedback config ~keeper_name:"test-keeper"
        ~decision_id:"dec-fb-1" ~score:0.8 ~comment:"good call";
      let records =
        Learning.read_decisions config ~keeper_name:"test-keeper" ~limit:10
      in
      let r = List.hd records in
      check (option (float 0.001)) "feedback_score set" (Some 0.8)
        r.feedback_score;
      check string "feedback_comment set" "good call" r.feedback_comment)

let test_record_feedback_clamps_score () =
  let tmp, config = make_test_config () in
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
      let d = make_decision ~id:"dec-fb-clamp" () in
      Learning.record_decision config d;
      Learning.record_feedback config ~keeper_name:"test-keeper"
        ~decision_id:"dec-fb-clamp" ~score:5.0 ~comment:"over";
      let records =
        Learning.read_decisions config ~keeper_name:"test-keeper" ~limit:10
      in
      let r = List.hd records in
      check (option (float 0.001)) "score clamped to 1.0" (Some 1.0)
        r.feedback_score)

let test_record_feedback_clamps_negative_score () =
  let tmp, config = make_test_config () in
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
      let d = make_decision ~id:"dec-fb-neg" () in
      Learning.record_decision config d;
      Learning.record_feedback config ~keeper_name:"test-keeper"
        ~decision_id:"dec-fb-neg" ~score:(-3.0) ~comment:"under";
      let records =
        Learning.read_decisions config ~keeper_name:"test-keeper" ~limit:10
      in
      let r = List.hd records in
      check (option (float 0.001)) "score clamped to -1.0" (Some (-1.0))
        r.feedback_score)

let test_record_feedback_nonexistent_decision () =
  let tmp, config = make_test_config () in
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
      let d = make_decision ~id:"dec-fb-exists" () in
      Learning.record_decision config d;
      Learning.record_feedback config ~keeper_name:"test-keeper"
        ~decision_id:"dec-fb-missing" ~score:0.5 ~comment:"nope";
      let records =
        Learning.read_decisions config ~keeper_name:"test-keeper" ~limit:10
      in
      let r = List.hd records in
      check bool "feedback_score still None" true
        (r.feedback_score = None))

(* ---------- Decision with no feedback ---------- *)

let test_decision_no_feedback_roundtrip () =
  let d = make_decision ~feedback_score:None ~feedback_comment:"" () in
  let json = Learning.decision_record_to_json d in
  match Learning.decision_record_of_json json with
  | None -> fail "expected Some"
  | Some parsed ->
      check bool "feedback_score is None" true (parsed.feedback_score = None);
      check string "feedback_comment is empty" "" parsed.feedback_comment

(* ---------- decisions_path test ---------- *)

let test_decisions_path_format () =
  let tmp, config = make_test_config () in
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
      let path = Learning.decisions_path config "my-keeper" in
      check bool "ends with .decisions.jsonl" true
        (Filename.check_suffix path ".decisions.jsonl");
      check bool "contains keeper name" true
        (try
           ignore
             (Str.search_forward (Str.regexp_string "my-keeper") path 0);
           true
         with Not_found -> false))

(* ---------- Multiple keepers isolation ---------- *)

let test_multiple_keepers_isolated () =
  let tmp, config = make_test_config () in
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
      let d1 = make_decision ~id:"dec-k1" ~keeper_name:"keeper-a" () in
      let d2 = make_decision ~id:"dec-k2" ~keeper_name:"keeper-b" () in
      Learning.record_decision config d1;
      Learning.record_decision config d2;
      let ra =
        Learning.read_decisions config ~keeper_name:"keeper-a" ~limit:10
      in
      let rb =
        Learning.read_decisions config ~keeper_name:"keeper-b" ~limit:10
      in
      check int "keeper-a has 1" 1 (List.length ra);
      check int "keeper-b has 1" 1 (List.length rb);
      check string "keeper-a decision" "dec-k1" (List.hd ra).id;
      check string "keeper-b decision" "dec-k2" (List.hd rb).id)

(* ================================================================ *)
(* Test runner                                                       *)
(* ================================================================ *)

let () =
  run "Keeper_learning"
    [
      ( "generate_decision_id",
        [
          test_case "format has dec- prefix" `Quick
            test_generate_decision_id_format;
          test_case "two IDs are different" `Quick
            test_generate_decision_id_uniqueness;
        ] );
      ( "prompt_hash",
        [
          test_case "hash length is 8" `Quick test_prompt_hash_length;
          test_case "deterministic for same input" `Quick
            test_prompt_hash_deterministic;
          test_case "different for different inputs" `Quick
            test_prompt_hash_different_inputs;
        ] );
      ( "json_roundtrip",
        [
          test_case "full roundtrip" `Quick
            test_decision_record_json_roundtrip;
          test_case "roundtrip with feedback" `Quick
            test_decision_record_json_roundtrip_with_feedback;
          test_case "missing id returns None" `Quick
            test_decision_record_of_json_missing_id;
          test_case "missing keeper_name returns None" `Quick
            test_decision_record_of_json_missing_keeper_name;
          test_case "malformed json returns None" `Quick
            test_decision_record_of_json_malformed;
          test_case "no feedback roundtrip" `Quick
            test_decision_no_feedback_roundtrip;
        ] );
      ( "record_and_read",
        [
          test_case "record and read back" `Quick
            test_record_and_read_decisions;
          test_case "limit caps results" `Quick test_read_decisions_limit;
          test_case "empty for missing keeper" `Quick
            test_read_decisions_empty;
          test_case "zero limit returns all" `Quick
            test_read_decisions_zero_limit_returns_all;
          test_case "multiple keepers isolated" `Quick
            test_multiple_keepers_isolated;
        ] );
      ( "record_outcome",
        [
          test_case "updates existing record" `Quick
            test_record_outcome_updates_existing;
          test_case "nonexistent decision is no-op" `Quick
            test_record_outcome_nonexistent_decision;
        ] );
      ( "record_feedback",
        [
          test_case "updates existing record" `Quick
            test_record_feedback_updates_existing;
          test_case "clamps positive score" `Quick
            test_record_feedback_clamps_score;
          test_case "clamps negative score" `Quick
            test_record_feedback_clamps_negative_score;
          test_case "nonexistent decision is no-op" `Quick
            test_record_feedback_nonexistent_decision;
        ] );
      ( "decisions_path",
        [
          test_case "path format" `Quick test_decisions_path_format;
        ] );
    ]
