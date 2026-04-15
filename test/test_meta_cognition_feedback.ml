module Feedback = Masc_mcp.Server_meta_cognition_feedback
module Board = Masc_mcp.Board
module Board_dispatch = Masc_mcp.Board_dispatch
module Coord = Masc_mcp.Coord

let () = Mirage_crypto_rng_unix.use_default ()

let counter = ref 0

let temp_dir () =
  incr counter;
  let dir =
    Filename.temp_file (Printf.sprintf "test_meta_cognition_feedback_%d_" !counter) ""
  in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let with_env key value f =
  let old = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some prev -> Unix.putenv key prev
      | None -> Unix.putenv key "")
    f

let with_ctx f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      with_env "MASC_BASE_PATH" base_dir @@ fun () ->
      Board.reset_global_for_test ();
      Board_dispatch.reset_for_test ();
      Board_dispatch.init_jsonl ();
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "tester"));
      f config)

let assoc_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let contains_substring haystack needle =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with Not_found -> false

let meta_summary ?(stagnation = 0.72) ?(contested = 1)
    ?(belief_id = "belief:masc_tools_blocked")
    ?(belief_claim = "keepers believe masc_* tools are blocked")
    ?(belief_status = "contested")
    ?(tension_id = "tension:masc_tool_blockage")
    ?(tension_topic = "keeper-facing masc_* tool blockage")
    ?(tension_severity = "high")
    ?(needs_operator = true)
    ?(desire_id = "desire:operator_guidance")
    ?(desired_state = "get operator guidance to unblock current work")
    ?(actionability = "operator") () =
  `Assoc
    [
      ("stagnation_score", `Float stagnation);
      ("belief_count", `Int 2);
      ("contested_belief_count", `Int contested);
      ( "dominant_belief",
        `Assoc
          [
            ("id", `String belief_id);
            ("claim", `String belief_claim);
            ("status", `String belief_status);
            ("support_agent_count", `Int 2);
            ("challenge_agent_count", `Int contested);
            ("evidence_refs", `List [ `String "post:p-root" ]);
            ("challenge_refs", `List [ `String "comment:c-1" ]);
          ] );
      ( "top_tension",
        `Assoc
          [
            ("id", `String tension_id);
            ("topic", `String tension_topic);
            ("severity", `String tension_severity);
            ("needs_operator", `Bool needs_operator);
            ("evidence_refs", `List [ `String "post:p-root" ]);
          ] );
      ( "top_desire",
        `Assoc
          [
            ("id", `String desire_id);
            ("desired_state", `String desired_state);
            ("actionability", `String actionability);
            ("evidence_refs", `List [ `String "post:p-root" ]);
          ] );
    ]

let namespace_truth_snapshot ?(focus_reason = "집단 인식에 이견이 있습니다")
    ?(focus_source = "meta_cognition") summary =
  `Assoc
    [
      ( "meta_cognition",
        `Assoc
          [ ("summary", summary); ("provenance", `String "shell") ] );
      ( "focus",
        `Assoc
          [
            ("label", `String "주의 필요");
            ("reason", `String focus_reason);
            ("source", `String focus_source);
            ("provenance", `String "derived");
            ("target_kind", `String "meta_cognition");
            ("target_id", `String "namespace:default");
            ("suggested_tab", `String "overview");
            ("suggested_params", `Assoc []);
          ] );
    ]

let list_digest_posts () =
  Board_dispatch.list_posts ~hearth:"meta-cognition"
    ~post_kind_filter:Board.Automation_post ~sort_by:Board_dispatch.Recent
    ~limit:10 ()

let test_posts_digest_once_for_same_snapshot () =
  with_ctx @@ fun config ->
  let snapshot = namespace_truth_snapshot (meta_summary ()) in
  let first = Feedback.maybe_post_digest ~config snapshot in
  let second = Feedback.maybe_post_digest ~config snapshot in
  let posts = list_digest_posts () in
  let first_meta =
    match posts with
    | post :: _ -> post.Board.meta_json
    | [] -> None
  in
  Alcotest.(check bool) "first digest posted" true
    (match first with Feedback.Posted _ -> true | _ -> false);
  Alcotest.(check bool) "second digest deduped" true
    (match second with Feedback.Deduped -> true | _ -> false);
  Alcotest.(check int) "single digest post" 1 (List.length posts);
  Alcotest.(check string) "digest author" "meta-cognition-observer"
    (posts |> List.hd |> fun post -> Board.Agent_id.to_string post.author);
  Alcotest.(check bool) "meta source tagged" true
    (match Option.bind first_meta (fun meta -> assoc_opt "source" meta) with
    | Some (`String "meta_cognition_digest") -> true
    | _ -> false)

let test_posts_new_digest_when_signal_changes () =
  with_ctx @@ fun config ->
  let first_snapshot = namespace_truth_snapshot (meta_summary ()) in
  let second_snapshot =
    namespace_truth_snapshot
      (meta_summary ~contested:0 ~belief_status:"corroborated"
         ~tension_id:"tension:idle_backlog_empty"
         ~tension_topic:"idle room with empty backlog"
         ~desired_state:"seed new tasks for idle keepers" ())
  in
  ignore (Feedback.maybe_post_digest ~config first_snapshot);
  ignore (Feedback.maybe_post_digest ~config second_snapshot);
  let posts = list_digest_posts () in
  Alcotest.(check int) "distinct digests create two posts" 2 (List.length posts)

let test_exposes_latest_digest_reference () =
  with_ctx @@ fun config ->
  let summary = meta_summary () in
  let snapshot = namespace_truth_snapshot summary in
  let posted_id =
    match Feedback.maybe_post_digest ~config snapshot with
    | Feedback.Posted post_id -> post_id
    | Feedback.Deduped -> Alcotest.fail "expected fresh digest post"
    | Feedback.Skipped -> Alcotest.fail "expected digest post, got skipped"
    | Feedback.Failed err -> Alcotest.failf "expected digest post, got %s" err
  in
  let latest = Feedback.latest_digest_json ~summary () in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "latest digest id" posted_id
    (latest |> member "post_id" |> to_string);
  Alcotest.(check string) "latest digest hearth" "meta-cognition"
    (latest |> member "hearth" |> to_string);
  Alcotest.(check bool) "latest digest matches summary" true
    (latest |> member "matches_summary" |> to_bool)

let test_digest_body_keeps_secondary_signals () =
  with_ctx @@ fun config ->
  let snapshot = namespace_truth_snapshot (meta_summary ()) in
  (match Feedback.maybe_post_digest ~config snapshot with
   | Feedback.Posted _ -> ()
   | Feedback.Deduped -> Alcotest.fail "expected fresh digest post"
   | Feedback.Skipped -> Alcotest.fail "expected digest post, got skipped"
   | Feedback.Failed err -> Alcotest.failf "expected digest post, got %s" err);
  match list_digest_posts () with
  | post :: _ ->
      Alcotest.(check bool) "primary signal in body" true
        (contains_substring post.body "primary signal: contested belief");
      Alcotest.(check bool) "secondary signal line present" true
        (contains_substring post.body
           "secondary signals: operator tension, operator desire, stagnant room");
      Alcotest.(check bool) "evidence refs line present" true
        (contains_substring post.body "room evidence refs:"
         && contains_substring post.body "post:p-root"
         && contains_substring post.body "comment:c-1")
  | [] -> Alcotest.fail "expected digest post to exist"

module Meta_cognition = Masc_mcp.Meta_cognition

(* --- parse_summary robustness tests --- *)

let summary_json_without_stagnation_score =
  `Assoc
    [
      ("belief_count", `Int 2);
      ("contested_belief_count", `Int 1);
      ( "dominant_belief",
        `Assoc
          [
            ("id", `String "b1");
            ("claim", `String "claim");
            ("status", `String "active");
            ("support_agent_count", `Int 1);
            ("challenge_agent_count", `Int 0);
            ("evidence_refs", `List []);
            ("challenge_refs", `List []);
          ] );
      ( "top_tension",
        `Assoc
          [
            ("id", `String "t1");
            ("topic", `String "topic");
            ("severity", `String "low");
            ("needs_operator", `Bool false);
            ("evidence_refs", `List []);
          ] );
      ( "top_desire",
        `Assoc
          [
            ("id", `String "d1");
            ("desired_state", `String "state");
            ("actionability", `String "agent");
            ("evidence_refs", `List []);
          ] );
    ]

let test_parse_summary_without_stagnation_score () =
  match Meta_cognition.parse_summary summary_json_without_stagnation_score with
  | Error msg -> Alcotest.fail (Printf.sprintf "parse_summary should succeed without stagnation_score: %s" msg)
  | Ok summary ->
      Alcotest.(check (float 0.01)) "default stagnation_score is 0.0"
        0.0 summary.stagnation_score

let test_parse_summary_with_stagnation_score () =
  let json =
    `Assoc
      (("stagnation_score", `Float 0.85)
       :: (match summary_json_without_stagnation_score with
           | `Assoc fields -> fields
           | _ -> []))
  in
  match Meta_cognition.parse_summary json with
  | Error msg -> Alcotest.fail (Printf.sprintf "parse_summary should succeed: %s" msg)
  | Ok summary ->
      Alcotest.(check (float 0.01)) "stagnation_score is parsed"
        0.85 summary.stagnation_score

let () =
  Alcotest.run "Meta_cognition_feedback"
    [
      ( "digest",
        [
          Alcotest.test_case "posts once for same snapshot" `Quick
            test_posts_digest_once_for_same_snapshot;
          Alcotest.test_case "posts again when signal changes" `Quick
            test_posts_new_digest_when_signal_changes;
          Alcotest.test_case "exposes latest digest reference" `Quick
            test_exposes_latest_digest_reference;
          Alcotest.test_case "body keeps secondary signals" `Quick
            test_digest_body_keeps_secondary_signals;
        ] );
      ( "parse_summary",
        [
          Alcotest.test_case "succeeds without stagnation_score" `Quick
            test_parse_summary_without_stagnation_score;
          Alcotest.test_case "parses stagnation_score when present" `Quick
            test_parse_summary_with_stagnation_score;
        ] );
    ]
