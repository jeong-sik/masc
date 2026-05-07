module Tool_agent = Masc_mcp.Tool_agent
module Coord = Masc_mcp.Coord
module Meta_cognition = Masc_mcp.Meta_cognition
module Prometheus = Masc_mcp.Prometheus

let counter = ref 0
let persistence_surface = "meta_cognition_snapshot"

let temp_dir () =
  incr counter;
  let dir =
    Filename.temp_file (Printf.sprintf "test_meta_cognition_%d_" !counter) ""
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

let with_ctx f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  let config = Coord.default_config base_dir in
  ignore (Coord.init config ~agent_name:(Some "tester"));
  let ctx : Tool_agent.context = { config; agent_name = "tester" } in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) (fun () -> f ctx)

let save_jsonl path entries =
  let body =
    entries
    |> List.map Yojson.Safe.to_string
    |> String.concat "\n"
  in
  Fs_compat.save_file path (if body = "" then "" else body ^ "\n")

let post_json ~id ~author ?(title = "") ?(body = "") ?hearth ?thread_id
    ?(created_at = 1000.0) () =
  let fields =
    [
      ("id", `String id);
      ("author", `String author);
      ("title", `String title);
      ("body", `String body);
      ("content", `String body);
      ("post_kind", `String "automation");
      ("visibility", `String "internal");
      ("created_at", `Float created_at);
      ("updated_at", `Float created_at);
      ("expires_at", `Float 0.0);
      ("votes_up", `Int 0);
      ("votes_down", `Int 0);
      ("reply_count", `Int 0);
    ]
  in
  let fields =
    match hearth with
    | Some value -> ("hearth", `String value) :: fields
    | None -> fields
  in
  let fields =
    match thread_id with
    | Some value -> ("thread_id", `String value) :: fields
    | None -> fields
  in
  `Assoc fields

let comment_json ~id ~post_id ~author ~content ?(created_at = 1000.0) () =
  `Assoc
    [
      ("id", `String id);
      ("post_id", `String post_id);
      ("author", `String author);
      ("content", `String content);
      ("created_at", `Float created_at);
      ("expires_at", `Float 0.0);
      ("votes_up", `Int 0);
      ("votes_down", `Int 0);
    ]

let json_list_ids key json =
  let open Yojson.Safe.Util in
  json |> member key |> to_list
  |> List.filter_map (fun item ->
         match item |> member "id" with
         | `String value -> Some value
         | _ -> None)

let persistence_counter reason =
  Prometheus.metric_value_or_zero Prometheus.metric_persistence_read_drops
    ~labels:[("surface", persistence_surface); ("reason", reason)] ()

let test_snapshot_detects_signals () =
  with_ctx @@ fun ctx ->
  ignore (Coord.join ctx.config ~agent_name:"peer" ~capabilities:[] ());
  ignore (Coord.join ctx.config ~agent_name:"observer" ~capabilities:[] ());
  let masc_dir = Coord.masc_dir ctx.config in
  save_jsonl
    (Filename.concat masc_dir "board_posts.jsonl")
    [
      post_json ~id:"p-root" ~author:"admin-keeper"
        ~title:"RBAC blockage"
        ~body:
          "All masc_* tools tested return unregistered_masc_tool. \
           Operator intervention needed. keeper_* tools function normally."
        ~hearth:"ops" ~created_at:1000.0 ();
      post_json ~id:"p-follow" ~author:"detail-demo"
        ~title:"Cross-check"
        ~body:
          "Confirmed same unregistered_masc_tool block. This is a policy restriction."
        ~hearth:"ops" ~thread_id:"p-root" ~created_at:1005.0 ();
      post_json ~id:"p-idle" ~author:"detail-demo"
        ~title:"Idle status"
        ~body:
          "No active tasks. backlog empty. idle and available for new work. \
           This could be a good window to seed new tasks or run a synthetic multi-agent exercise."
        ~hearth:"ops" ~created_at:1010.0 ();
    ];
  save_jsonl
    (Filename.concat masc_dir "board_comments.jsonl")
    [
      comment_json ~id:"c-1" ~post_id:"p-root"
        ~author:"audit-keeper-decision"
        ~content:"Corroborated. This aligns with admin-keeper's finding."
        ~created_at:1006.0 ();
    ];
  let ok, body =
    (true, Yojson.Safe.to_string (Meta_cognition.snapshot_json ~limit:5 ctx.config))
  in
  Alcotest.(check bool) "snapshot succeeds" true ok;
  let json = Yojson.Safe.from_string body in
  let belief_ids = json_list_ids "beliefs" json in
  let tension_ids = json_list_ids "tensions" json in
  let desire_ids = json_list_ids "collective_desires" json in
  let open Yojson.Safe.Util in
  let edges = json |> member "social_edges" |> to_list in
  let has_corroborate_edge =
    List.exists
      (fun edge ->
        edge |> member "from_agent" |> to_string = "audit-keeper-decision"
        && edge |> member "to_agent" |> to_string = "admin-keeper"
        && edge |> member "edge_type" |> to_string = "corroborates")
      edges
  in
  Alcotest.(check bool) "tool blockage belief detected" true
    (List.mem "belief:masc_tools_blocked" belief_ids);
  Alcotest.(check bool) "idle backlog belief detected" true
    (List.mem "belief:idle_backlog_empty" belief_ids);
  Alcotest.(check bool) "tool blockage tension detected" true
    (List.mem "tension:masc_tool_blockage" tension_ids);
  Alcotest.(check bool) "task seeding desire detected" true
    (List.mem "desire:task_seeding" desire_ids);
  Alcotest.(check bool) "synthetic exercise desire detected" true
    (List.mem "desire:synthetic_exercise" desire_ids);
  Alcotest.(check bool) "social edge extracted" true has_corroborate_edge;
  Alcotest.(check bool) "stagnation score elevated" true
    (json |> member "stagnation_score" |> to_float > 0.5)

let test_snapshot_marks_contested_belief () =
  with_ctx @@ fun ctx ->
  let masc_dir = Coord.masc_dir ctx.config in
  save_jsonl
    (Filename.concat masc_dir "board_posts.jsonl")
    [
      post_json ~id:"p-root" ~author:"admin-keeper"
        ~title:"RBAC blockage"
        ~body:
          "All masc_* tools tested return unregistered_masc_tool. \
           keeper_* tools function normally."
        ~hearth:"ops" ~created_at:1000.0 ();
    ];
  save_jsonl
    (Filename.concat masc_dir "board_comments.jsonl")
    [
      comment_json ~id:"c-1" ~post_id:"p-root" ~author:"keeper-a"
        ~content:
          "This contradicts the uniform block hypothesis. Access may be per-agent."
        ~created_at:1010.0 ();
    ];
  let ok, body =
    (true, Yojson.Safe.to_string (Meta_cognition.snapshot_json ~limit:5 ctx.config))
  in
  Alcotest.(check bool) "snapshot succeeds" true ok;
  let json = Yojson.Safe.from_string body in
  let contested_ids = json_list_ids "contested_beliefs" json in
  Alcotest.(check bool) "contested belief captured" true
    (List.mem "belief:masc_tools_blocked" contested_ids)

let test_parse_summary_preserves_refs_and_secondary_signals () =
  let summary =
    `Assoc
      [
        ("stagnation_score", `Float 0.72);
        ("belief_count", `Int 2);
        ("contested_belief_count", `Int 1);
        ( "dominant_belief",
          `Assoc
            [
              ("id", `String "belief:masc_tools_blocked");
              ("claim", `String "keepers believe masc_* tools are blocked");
              ("status", `String "contested");
              ("evidence_refs", `List [ `String "post:p-root" ]);
              ("challenge_refs", `List [ `String "comment:c-1" ]);
            ] );
        ( "top_tension",
          `Assoc
            [
              ("id", `String "tension:masc_tool_blockage");
              ("topic", `String "keeper-facing masc_* tool blockage");
              ("severity", `String "high");
              ("needs_operator", `Bool true);
              ("evidence_refs", `List [ `String "post:p-root" ]);
            ] );
        ( "top_desire",
          `Assoc
            [
              ("id", `String "desire:operator_guidance");
              ("desired_state", `String "get operator guidance to unblock current work");
              ("actionability", `String "operator");
              ("evidence_refs", `List [ `String "post:p-root" ]);
            ] );
      ]
  in
  match Meta_cognition.parse_summary summary with
  | Error err -> Alcotest.failf "expected summary to parse, got %s" err
  | Ok parsed ->
      Alcotest.(check (list string)) "belief evidence refs"
        [ "post:p-root" ]
        (parsed.dominant_belief
        |> Option.map (fun (belief : Meta_cognition.belief_summary) -> belief.evidence_refs)
        |> Option.value ~default:[]);
      Alcotest.(check (list string)) "belief challenge refs"
        [ "comment:c-1" ]
        (parsed.dominant_belief
        |> Option.map (fun (belief : Meta_cognition.belief_summary) -> belief.challenge_refs)
        |> Option.value ~default:[]);
      let interpretation = Meta_cognition.interpret parsed in
      Alcotest.(check string) "primary signal" "contested_belief"
        (Meta_cognition.salience_to_string interpretation.primary_salience);
      Alcotest.(check (list string)) "secondary signals"
        [ "operator_tension"; "operator_desire"; "stagnant_room" ]
        (interpretation.secondary_saliences
        |> List.map Meta_cognition.salience_to_string);
      Alcotest.(check (list string)) "primary evidence refs merged"
        [ "comment:c-1"; "post:p-root" ]
        (interpretation.evidence_refs |> List.sort String.compare)

let test_snapshot_jsonl_load_failure_increments_drop_metric () =
  with_ctx @@ fun ctx ->
  let posts_path =
    Filename.concat (Coord.masc_dir ctx.config) "board_posts.jsonl"
  in
  Fs_compat.save_file posts_path "{not-json\n";
  let before =
    persistence_counter Safe_ops.persistence_read_drop_reason_entry_load_error
  in
  let json = Meta_cognition.snapshot_json ~limit:5 ctx.config in
  let open Yojson.Safe.Util in
  Alcotest.(check int) "snapshot falls back to empty beliefs" 0
    (json |> member "beliefs" |> to_list |> List.length);
  Alcotest.(check (float 0.1)) "jsonl load failure increments entry_load_error" 1.0
    (persistence_counter Safe_ops.persistence_read_drop_reason_entry_load_error
     -. before)

let test_snapshot_governance_cases_skip_bad_entries_with_metric () =
  with_ctx @@ fun ctx ->
  let cases_dir = Filename.concat (Coord.masc_dir ctx.config) "governance_v2/cases" in
  Fs_compat.mkdir_p cases_dir;
  Fs_compat.save_file (Filename.concat cases_dir "good.json")
    (Yojson.Safe.to_string
       (`Assoc
         [
           ("id", `String "case-1");
           ("title", `String "good governance case");
           ("status", `String "pending_ruling");
         ]));
  Fs_compat.save_file (Filename.concat cases_dir "missing-id.json")
    (Yojson.Safe.to_string
       (`Assoc
         [
           ("title", `String "bad governance case");
           ("status", `String "pending_ruling");
         ]));
  Fs_compat.save_file (Filename.concat cases_dir "broken.json") "{not-json";
  let before_entry =
    persistence_counter Safe_ops.persistence_read_drop_reason_entry_load_error
  in
  let before_invalid =
    persistence_counter Safe_ops.persistence_read_drop_reason_invalid_payload
  in
  let json = Meta_cognition.snapshot_json ~limit:5 ctx.config in
  let open Yojson.Safe.Util in
  Alcotest.(check int) "valid governance case still counted" 1
    (json |> member "room_state" |> member "governance_case_count" |> to_int);
  Alcotest.(check (float 0.1)) "broken file increments entry_load_error" 1.0
    (persistence_counter Safe_ops.persistence_read_drop_reason_entry_load_error
     -. before_entry);
  Alcotest.(check (float 0.1)) "missing id increments invalid_payload" 1.0
    (persistence_counter Safe_ops.persistence_read_drop_reason_invalid_payload
     -. before_invalid)

let () =
  Alcotest.run "Meta_cognition_snapshot"
    [
      ( "snapshot",
        [
          Alcotest.test_case "detects signals" `Quick
            test_snapshot_detects_signals;
          Alcotest.test_case "marks contested belief" `Quick
            test_snapshot_marks_contested_belief;
          Alcotest.test_case "parses summary refs and secondary signals" `Quick
            test_parse_summary_preserves_refs_and_secondary_signals;
          Alcotest.test_case "jsonl load failures increment drop metric" `Quick
            test_snapshot_jsonl_load_failure_increments_drop_metric;
          Alcotest.test_case "governance cases skip bad entries with metric"
            `Quick test_snapshot_governance_cases_skip_bad_entries_with_metric;
        ] );
    ]
