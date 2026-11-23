(** Round trips between the server's code and the TUI's code for one endpoint.

    A response case builds the JSON with the server's own encoder and decodes
    it with the TUI decoder that reads that endpoint. A request case encodes
    the body with the TUI encoder and parses it with the server's own parser.
    A renamed or reshaped field fails here instead of on the operator's
    screen. *)

open Masc_tui_core
module Wire_knowledge = Masc_tui_protocol.Wire_knowledge
module Wire_runtime = Masc_tui_protocol.Wire_runtime
module Wire_work = Masc_tui_protocol.Wire_work
module Wire_fleet = Masc_tui_protocol.Wire_fleet
module Stream_route = Server_routes_http_keeper_stream
module Owner_registry = Masc.Keeper_owner_registry
module Workspace = Masc.Workspace

let observed_at = Clock.Mono.of_ns 1_000_000_000L

let rec rm_rf path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
      (try
         Array.iter
           (fun entry -> rm_rf (Filename.concat path entry))
           (Sys.readdir path)
       with Sys_error _ -> ());
      (try Unix.rmdir path with Unix.Unix_error _ -> ())
  | _ -> ( try Unix.unlink path with Unix.Unix_error _ -> ())

(* A fresh workspace, and the [expected_workspace] pair the TUI sends for it:
   the canonical paths [/health] reports, which is what the TUI stores. *)
let with_workspace f =
  let base = Filename.temp_dir "masc_tui_wire_rt_" "" in
  Fun.protect
    ~finally:(fun () -> rm_rf base)
    (fun () ->
      let config = Workspace.default_config base in
      ignore (Workspace.init config ~agent_name:None : string);
      let expected_workspace : Wire_work.expected_workspace =
        {
          base_path = Unix.realpath config.Workspace.base_path;
          masc_root = Unix.realpath (Workspace.masc_dir config);
        }
      in
      f config expected_workspace)

(* GET /api/v1/dashboard/scheduled-automation: a keeper wake stores its
   enqueue receipt object in [detail]; a failed wake carries [error]. *)
let test_schedule_wake_roundtrip () =
  let wake : Schedule_domain.wake_record =
    {
      schedule_instance_id = "si-1";
      schedule_id = "sched-daily";
      attempt_identity = Schedule_domain.Unidentified;
      settlement_kind = None;
      started_at = 1795173600.0;
      finished_at = Some 1795173605.0;
      due_at = 1795173600.0;
      payload_digest = "digest-1";
      status = Schedule_domain.Wake_failed;
      detail =
        Some
          (`Assoc
             [
               ("kind", `String "keeper_wake_enqueued");
               ("queue", `String "keeper_event_queue");
             ]);
      error = Some "provider timeout";
    }
  in
  let row =
    `Assoc
      [
        ("schedule_instance_id", `String "si-1");
        ("schedule_id", `String "sched-daily");
        ("status", `String "scheduled");
        ("source", `String "operator");
        ("due_at", `Float 1795260000.0);
        ("next_due_at", `Float 1795260000.0);
        ("recurrence_kind", `String "cron");
        ("recurrence_summary", `String "0 9 * * *");
        ("payload_kind", `String "keeper_wake");
        ("payload_support", `String "supported");
        ("payload_target", `String "wkbl-growth");
        ("payload_keeper_name", `String "wkbl-growth");
        ("payload_summary", `String "Daily standup");
        ("last_wake", Schedule_domain.wake_record_to_yojson wake);
      ]
  in
  match
    Wire_work.decode_schedules_snapshot
      (`Assoc [ ("status", `String "ok"); ("requests", `List [ row ]) ])
  with
  | Error e -> Alcotest.fail ("schedules decode failed: " ^ e)
  | Ok ([ (r : Wire_work.schedule_row) ], _) -> (
      Alcotest.(check (option (float 0.001)))
        "wake time is finished_at" (Some 1795173605.0) r.last_wake_unix;
      match r.last_disposition with
      | Wire_work.Wake_failed reason ->
          Alcotest.(check (option string))
            "failure reason comes from error" (Some "provider timeout") reason
      | Wire_work.Wake_succeeded | Wire_work.Wake_running | Wire_work.Wake_never
        ->
          Alcotest.fail "a failed wake decodes as Wake_failed")
  | Ok (_, _) -> Alcotest.fail "expected exactly one schedule row"

(* GET /api/v1/dashboard/tools: usage comes from the server's own summary
   report. [by_tool] covers every called tool, past the top 20; a tool the
   report lists as never called counts 0; a name the report never mentions
   stays Unreported. *)
let test_tools_catalog_roundtrip () =
  let busy = List.init 20 (fun i -> Printf.sprintf "busy_tool_%02d" i) in
  let seeded =
    Tool_metrics.replace_samples (fun add ->
        List.iter
          (fun tool_name ->
            for _i = 1 to 3 do
              add
                {
                  Tool_metrics.tool_name;
                  disposition = Tool_metrics.Completed;
                  duration_ms = 5.0;
                }
            done)
          busy;
        add
          {
            Tool_metrics.tool_name = "masc_status";
            disposition = Tool_metrics.Completed;
            duration_ms = 12.0;
          };
        add
          {
            Tool_metrics.tool_name = "masc_status";
            disposition = Tool_metrics.Failed;
            duration_ms = 30.0;
          };
        Ok ())
  in
  (match seeded with
  | Ok () -> ()
  | Error () -> Alcotest.fail "seeding tool metrics failed");
  Fun.protect ~finally:Tool_metrics.clear (fun () ->
      let usage = Masc.Tool_unified.summary_report () in
      let row_named name row =
        match Yojson.Safe.Util.member "name" row with
        | `String n -> String.equal n name
        | _ -> false
      in
      (match Yojson.Safe.Util.member "top_20" usage with
      | `List rows ->
          Alcotest.(check bool) "masc_status ranks past the top 20" false
            (List.exists (row_named "masc_status") rows)
      | _ -> Alcotest.fail "summary report without top_20");
      let never_called_name =
        match Yojson.Safe.Util.member "never_called" usage with
        | `List (row :: _) -> (
            match Yojson.Safe.Util.member "name" row with
            | `String name -> name
            | _ -> Alcotest.fail "never_called row without a name")
        | _ -> Alcotest.fail "the catalog has no never-called tool"
      in
      let tool name =
        `Assoc [ ("name", `String name); ("description", `String "d") ]
      in
      let body =
        `Assoc
          [
            ( "tool_inventory",
              `Assoc
                [
                  ( "tools",
                    `List
                      [
                        tool "masc_status";
                        tool never_called_name;
                        tool "not_in_the_usage_report";
                      ] );
                ] );
            ("tool_usage", usage);
          ]
      in
      match Wire_runtime.decode_tools_catalog ~observed_at body with
      | Error e -> Alcotest.fail ("tools catalog decode failed: " ^ e)
      | Ok Wire_runtime.Tools_warming ->
          Alcotest.fail "a ready body decodes as ready"
      | Ok (Wire_runtime.Tools_ready tools) ->
          let find name =
            match
              List.find_opt
                (fun (t : Wire_runtime.tool_summary) -> String.equal t.name name)
                tools
            with
            | Some t -> t
            | None -> Alcotest.fail (name ^ " missing from catalog")
          in
          let status = find "masc_status" in
          Alcotest.(check (option int))
            "a tool past the top 20 reports its call count" (Some 2)
            (Observed.to_option status.calls);
          Alcotest.(check (option (float 0.001)))
            "failure rate from failure_count / call_count" (Some 50.0)
            (Observed.to_option status.failure_rate_pct);
          Alcotest.(check (option int)) "a never-called tool counts 0" (Some 0)
            (Observed.to_option (find never_called_name).calls);
          Alcotest.(check bool) "a tool the report never names stays Unreported"
            true
            (match (find "not_in_the_usage_report").calls with
            | Observed.Unreported -> true
            | Observed.Loading _ | Observed.Value _ | Observed.Absent
            | Observed.Failed _ ->
                false))

(* The server answers its warming body until the first tools compute
   finishes; that is not an empty catalog. *)
let test_tools_warming_roundtrip () =
  match
    Wire_runtime.decode_tools_catalog ~observed_at
      (Server_dashboard_http_runtime_info.dashboard_tools_warming_json ())
  with
  | Ok Wire_runtime.Tools_warming -> ()
  | Ok (Wire_runtime.Tools_ready _) ->
      Alcotest.fail "the warming body decodes as an empty catalog"
  | Error e -> Alcotest.fail ("warming body decode failed: " ^ e)

(* GET /api/v1/dashboard/exact-lane-runs: the server projection merges three
   registries, each with its own status words. Every status any of them can
   name decodes, and the TUI spells it back the way the server did. *)
let test_lane_run_statuses_roundtrip () =
  let module Projection = Server_standalone_lane_projection in
  let module Exact = Masc.Exact_lane_run_registry in
  let module Verification = Masc.Verification_run_registry in
  let module Goal = Masc.Goal_verification_run_registry in
  let started_at = 1795173600.0 in
  let exact_run ~run_id status : Exact.run =
    {
      run_id;
      lane = Exact.Librarian;
      actor = "keeper-test";
      started_at;
      input = Exact.Exact_input (`Assoc []);
      status;
      slot_observations = None;
      input_availability = Exact.Available;
      output_availability =
        (match status with
        | Exact.Running -> None
        | Exact.Completed _ | Exact.Completion_persistence_failed _ ->
            Some Exact.Available);
    }
  in
  let exact_completed outcome =
    Exact.Completed
      {
        outcome;
        origin = Exact.Producer;
        elapsed_s = None;
        output = `Null;
        selected_slot = None;
        usage = None;
      }
  in
  let exact_unpersisted state =
    Exact.Completion_persistence_failed
      {
        intended_outcome = Exact.Succeeded;
        elapsed_s = None;
        output = `Null;
        selected_slot = None;
        usage = None;
        failure = { Exact.detail = "disk full"; state };
      }
  in
  let exact_runs =
    List.mapi
      (fun i status -> exact_run ~run_id:(Printf.sprintf "exact-%d" i) status)
      [
        Exact.Running;
        exact_completed Exact.Succeeded;
        exact_completed Exact.Cancelled;
        exact_completed (Exact.Failed { code = "provider"; detail = "offline" });
        exact_unpersisted Exact.Not_persisted;
        exact_unpersisted Exact.Durability_unknown;
      ]
  in
  let task_run ~verification_id status : Verification.run =
    {
      verification_id;
      task_id = "task-9";
      producer = "keeper-test";
      authority_kind = "system_llm";
      authority_actor = "verifier";
      started_at;
      status;
    }
  in
  let task_completed outcome =
    Verification.Completed
      { outcome; evaluator_runtime = None; elapsed_s = 1.0; tools = [] }
  in
  let verification_runs =
    List.mapi
      (fun i status ->
        task_run ~verification_id:(Printf.sprintf "task-run-%d" i) status)
      (Verification.Running
      :: List.map task_completed
           [
             Verification.Approved { reason = "" };
             Verification.Rejected { reason = "missing proof" };
             Verification.Infrastructure_unavailable
               { stage = Verification.Review_preparation; detail = "" };
             Verification.Not_reviewed { gate = "gate"; detail = "" };
             Verification.Commit_failed { detail = "" };
             Verification.Execution_pending { detail = "" };
             Verification.Execution_repair_required { detail = "" };
             Verification.Raised { detail = "" };
             Verification.Review_cancelled { detail = "" };
             Verification.Superseded_by { authority = "hitl" };
           ])
  in
  let goal_run ~run_id status : Goal.run =
    {
      run_id;
      goal_id = "goal-4";
      request_id = "proof-request-" ^ run_id;
      criterion =
        Goal_store.Criterion
          {
            revision = "criterion-4";
            title = "Four verified services";
            measure = Goal_measure_fixture.done_when "4";
            procedure = "verified services";
          };
      review_kind = Goal.Proof;
      authority_actor = "verifier";
      started_at;
      status;
    }
  in
  let goal_completed outcome =
    Goal.Completed
      {
        outcome;
        evaluated_verdict = None;
        evaluator_runtime = None;
        elapsed_s = 1.0;
        tools = [];
      }
  in
  let goal_verification_runs =
    List.mapi
      (fun i status -> goal_run ~run_id:(Printf.sprintf "goal-run-%d" i) status)
      (Goal.Running
      :: List.map goal_completed
           [
             Goal.Reviewed;
             Goal.Committed;
             Goal.Superseded { detail = "" };
             Goal.Deferred { detail = "" };
             Goal.Raised { detail = "" };
             Goal.Review_cancelled { detail = "" };
           ])
  in
  let expected =
    List.map (fun (r : Exact.run) -> (r.run_id, Exact.status_label r.status)) exact_runs
    @ List.map
        (fun (r : Verification.run) ->
          (r.verification_id, Verification.status_label r.status))
        verification_runs
    @ List.map (fun (r : Goal.run) -> (r.run_id, Goal.status_label r.status))
        goal_verification_runs
  in
  let page =
    match
      Projection.For_testing.recent_run_page_json_with ~limit:100 ~before:None
        ~lane:None ~run_kind:None ~exact_runs ~verification_runs
        ~goal_verification_runs
    with
    | Ok json -> json
    | Error detail -> Alcotest.fail ("server run page failed: " ^ detail)
  in
  match Wire_runtime.decode_exact_lane_runs page with
  | Error e -> Alcotest.fail ("exact-lane runs decode failed: " ^ e)
  | Ok runs ->
      let decoded =
        List.map
          (fun (r : Wire_runtime.exact_lane_run) ->
            (r.run_id, Wire_runtime.lane_run_status_label r.status))
          runs
      in
      let sort = List.sort (fun (a, _) (b, _) -> String.compare a b) in
      Alcotest.(check (list (pair string string)))
        "every server status decodes and keeps its spelling" (sort expected)
        (sort decoded);
      (match
         List.find_opt
           (fun (r : Wire_runtime.exact_lane_run) -> String.equal r.run_id "exact-3")
           runs
       with
      | Some
          {
            status =
              Wire_runtime.Exact_output
                (Wire_runtime.Exact_failed { code = "provider"; detail = "offline" });
            _;
          } ->
          ()
      | Some _ | None -> Alcotest.fail "failed exact run keeps its code and detail");
      match
        List.find_opt
          (fun (r : Wire_runtime.exact_lane_run) ->
            String.equal r.run_id "task-run-0")
          runs
      with
      | Some r ->
          Alcotest.(check (option string))
            "a task review names its task" (Some "task-9") r.subject_id
      | None -> Alcotest.fail "task review row missing"

(* GET /api/v1/dashboard/gate: Dashboard_gate.dashboard_json sends a null
   approval_queue beside the unavailable state when the queue store cannot be
   read. The TUI must report the failure instead of an empty queue. *)
let test_gate_queue_state_roundtrip () =
  let module Queue_result = Masc.Keeper_approval_queue_result in
  let gate ~queue ~state =
    `Assoc [ ("approval_queue", queue); ("approval_queue_state", state) ]
  in
  (match
     Wire_work.decode_gate_pending_list
       (gate ~queue:(`List []) ~state:Queue_result.approval_queue_ready_state_json)
   with
  | Ok [] -> ()
  | Ok _ -> Alcotest.fail "ready empty queue decodes to no rows"
  | Error e -> Alcotest.fail ("ready gate decode failed: " ^ e));
  match
    Wire_work.decode_gate_pending_list
      (gate ~queue:`Null
         ~state:
           (Queue_result.approval_queue_unavailable_state_json
              { Queue_result.path = "/srv/masc/.masc/approvals"; reason = "corrupt" }))
  with
  | Error reason ->
      Alcotest.(check bool) "failure names the server's title" true
        (String.starts_with
           ~prefix:Queue_result.approval_queue_unavailable_title reason)
  | Ok _ -> Alcotest.fail "an unavailable queue must not decode as empty"

(* POST /api/v1/keepers/chat/stream: a follow-up carries no admission intent,
   so the server queues it behind the running turn. A steer names only the
   operation this TUI submitted, never a turn token, because the server
   cancels any non-maintenance turn that holds a token. *)
let test_chat_submit_admission_roundtrip () =
  let parse mode =
    let request : Wire_fleet.chat_submit_request =
      {
        request_id = "tui-roundtrip-2";
        keeper_name = "alpha";
        message = "second";
        origin = Wire_fleet.Origin_bare;
        mode;
        turn_instructions = None;
        since_seq = None;
        attachments = [];
      }
    in
    Stream_route.parse_keeper_chat_stream_request
      ~media_store:(Agent_core.History.Memory_store.create ())
      (Yojson.Safe.to_string (Wire_fleet.encode_chat_submit_request request))
  in
  (match parse Wire_fleet.Follow_up with
  | Ok { Stream_route.admission_intent = Stream_route.Queue_only; _ } -> ()
  | Ok { Stream_route.admission_intent = Stream_route.Interactive _; _ } ->
      Alcotest.fail "a follow-up must queue, not interrupt"
  | Error detail -> Alcotest.failf "server rejected the follow-up: %s" detail);
  match
    parse
      (Wire_fleet.Steer
         { control_token = "ctrl-1"; operation_id = "tui-roundtrip-1" })
  with
  | Ok
      {
        Stream_route.admission_intent =
          Stream_route.Interactive
            {
              control_token;
              target = Some (Owner_registry.Direct_operation_id operation_id);
            };
        _;
      } ->
      Alcotest.(check string) "steer keeps the control token" "ctrl-1"
        control_token;
      Alcotest.(check string) "steer cuts exactly the TUI's own operation"
        "tui-roundtrip-1"
        (Masc.Keeper_owner.Chat_operation.Operation_id.to_string operation_id)
  | Ok
      {
        Stream_route.admission_intent =
          Stream_route.Interactive
            { target = Some (Owner_registry.Observed_turn_token _); _ };
        _;
      } ->
      Alcotest.fail "a steer must not name the observed turn token"
  | Ok
      {
        Stream_route.admission_intent =
          Stream_route.Interactive { target = None; _ };
        _;
      } ->
      Alcotest.fail "a steer must name its own operation"
  | Ok { Stream_route.admission_intent = Stream_route.Queue_only; _ } ->
      Alcotest.fail "a steer must reach the server as an interactive admission"
  | Error detail -> Alcotest.failf "server rejected the steer: %s" detail

(* GET /api/v1/board/<id>?format=flat: the route appends the comment rows to
   the post's own fields. A comment row carries its vote tallies and no
   score. *)
let test_board_comment_votes_roundtrip () =
  let post_id = "p-0123456789abcdef0123456789abcdef" in
  let comment : Masc.Board.comment =
    {
      id =
        Masc.Board.Comment_id.of_string "c-0123456789abcdef0123456789abcdef"
        |> Result.get_ok;
      post_id = Masc.Board.Post_id.of_string post_id |> Result.get_ok;
      parent_id = None;
      author = Masc.Board.Agent_id.of_string "analyst" |> Result.get_ok;
      content = "Measured twice";
      audience = None;
      created_at = 1795252000.0;
      expires_at = 1795338400.0;
      votes_up = 3;
      votes_down = 1;
    }
  in
  let thread =
    `Assoc
      [
        ("id", `String post_id);
        ("title", `String "Release notes");
        ("body", `String "Ship the fix");
        ("author", `String "e-masc-the-leader");
        ("created_at", `Float 1795251000.0);
        ("votes", `Int 2);
        ("comment_count", `Int 1);
        ("author_karma", `Int 5);
        ( "comments",
          `List [ Masc.Server_utils.board_comment_dashboard_json comment ] );
      ]
  in
  match Wire_knowledge.decode_board_thread ~observed_at thread with
  | Error e -> Alcotest.fail ("board thread decode failed: " ^ e)
  | Ok (_, [ c ]) ->
      Alcotest.(check int) "comment score is votes_up - votes_down" 2 c.score
  | Ok (_, comments) ->
      Alcotest.fail
        (Printf.sprintf "expected one comment, got %d" (List.length comments))

(* GET /api/v1/published-artifacts: each row is the latest revision's summary
   and its body is a content-addressed [_blob] reference. *)
let test_published_artifact_roundtrip () =
  let sha256 = String.make 64 'a' in
  let body =
    match
      Tool_output.make_artifact_ref ~sha256 ~bytes:2048 ~preview:"# Weekly"
        ~mime:"text/markdown"
    with
    | Ok body -> body
    | Error e -> Alcotest.fail (Tool_output.make_error_to_string e)
  in
  let revision : Masc.Published_artifact.revision =
    {
      revision = 2;
      title = "Weekly report";
      summary = "Throughput and failures";
      format = Masc.Published_artifact.Markdown;
      author = "e-masc-the-leader";
      created_at = "2026-11-23T01:02:03Z";
      body;
      task_id = None;
      goal_id = None;
    }
  in
  let id = "artifact-0123456789abcdef0123456789abcdef" in
  let response =
    `Assoc
      [
        ( "artifacts",
          `List [ Masc.Published_artifact.summary_to_json ~id revision ] );
        ("diagnostics", `List []);
      ]
  in
  match Wire_knowledge.decode_artifacts_list response with
  | Error e -> Alcotest.fail ("published artifacts decode failed: " ^ e)
  | Ok [ a ] ->
      Alcotest.(check string) "id" id a.id;
      Alcotest.(check int) "revision" 2 a.revision;
      Alcotest.(check string) "title" "Weekly report" a.title;
      Alcotest.(check string) "summary" "Throughput and failures" a.summary;
      Alcotest.(check string) "author" "e-masc-the-leader" a.author;
      Alcotest.(check (float 0.001))
        "created_at reads the RFC3339 string" 1795395723.0 a.created_at_unix;
      Alcotest.(check string) "body sha256" sha256 a.body.sha256;
      Alcotest.(check int) "body bytes" 2048 a.body.bytes;
      Alcotest.(check string) "body mime" "text/markdown" a.body.mime
  | Ok rows ->
      Alcotest.fail
        (Printf.sprintf "expected one artifact row, got %d" (List.length rows))

(* Removes a temporary workspace. Cleanup errors are ignored: the assertions
   have already run. *)
let rec rm_rf path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
      (try
         Array.iter
           (fun entry -> rm_rf (Filename.concat path entry))
           (Sys.readdir path)
       with Sys_error _ -> ());
      (try Unix.rmdir path with Unix.Unix_error _ -> ())
  | {
      Unix.st_kind =
        ( Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO
        | Unix.S_SOCK );
      _;
    } -> (
      try Unix.unlink path with Unix.Unix_error _ -> ())

let rec mkdir_p path =
  if not (Sys.file_exists path) then begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let unsupported_shape_name = function
  | Wire_knowledge.Unsupported_anchor -> "anchor"
  | Wire_knowledge.Unsupported_scheme -> "scheme"
  | Wire_knowledge.Unsupported_path -> "path"
  | Wire_knowledge.Unsupported_not_markdown -> "not_markdown"
  | Wire_knowledge.Unsupported_wikilink -> "wikilink"

let pp_link_target ppf = function
  | Wire_knowledge.Link_page { slug; exists } ->
      Format.fprintf ppf "page %s (exists=%b)" slug exists
  | Wire_knowledge.Link_own_file file -> Format.fprintf ppf "own_file %s" file
  | Wire_knowledge.Link_external url -> Format.fprintf ppf "external %s" url
  | Wire_knowledge.Link_invalid_name raw ->
      Format.fprintf ppf "invalid_name %s" raw
  | Wire_knowledge.Link_unsupported shape ->
      Format.fprintf ppf "unsupported %s" (unsupported_shape_name shape)

let link_target = Alcotest.testable pp_link_target ( = )

(* GET /api/v1/wiki/<slug>: one row per link in the page body. The server
   sends an unsupported link's raw text as its target, and that text is blank
   for [[x]()] and [[x](<>)]. *)
let test_wiki_page_links_roundtrip () =
  let base = Filename.temp_dir "masc_tui_wiki_links_" "" in
  Fun.protect
    ~finally:(fun () -> rm_rf base)
    (fun () ->
      mkdir_p (Filename.concat base ".masc/config/keepers");
      mkdir_p (Filename.concat base ".masc/keepers");
      let config = Masc.Workspace.default_config base in
      let base_path = config.Masc.Workspace.base_path in
      let slug = "link-shapes" in
      let page_body =
        String.concat "\n"
          [
            "[Self](link-shapes.md)";
            "[Missing](missing-page.md)";
            "[Index](index.md)";
            "[Docs](https://example.com/docs)";
            "[Bad](Bad_Name.md)";
            "[Anchor](link-shapes.md#top)";
            "[Mail](mailto:ops)";
            "[Nested](notes/guide.md)";
            "[Plain](notes.txt)";
            "[Empty]()";
            "[Angle](<>)";
            "[[old-style]]";
          ]
      in
      let put_body =
        Yojson.Safe.to_string
          (`Assoc
             [
               ("title", `String "Link shapes");
               ("source", `String "observation");
               ("summary", `String "Every link shape the wiki reads");
               ("tags", `List [ `String "wiki" ]);
               ("body", `String page_body);
             ])
      in
      let now = 1795252092.0 in
      (match
         Server_dashboard_http_wiki.put_page_json ~now ~config ~actor:"tester"
           ~slug ~body_str:put_body ()
       with
      | Ok _ -> ()
      | Error (_, json) ->
          Alcotest.fail ("wiki PUT failed: " ^ Yojson.Safe.to_string json));
      let page_json =
        match
          Server_dashboard_http_wiki.get_page_json ~now ~base_path ~slug ()
        with
        | Ok json -> json
        | Error (_, json) ->
            Alcotest.fail ("wiki GET failed: " ^ Yojson.Safe.to_string json)
      in
      match Wire_knowledge.decode_wiki_page_detail page_json with
      | Error e -> Alcotest.fail ("wiki page decode failed: " ^ e)
      | Ok page ->
          let decoded =
            List.map
              (fun (link : Wire_knowledge.wiki_outgoing_link) ->
                (link.text, link.target))
              page.outgoing_links
            |> List.sort compare
          in
          let expected =
            [
              ("Self", Wire_knowledge.Link_page { slug; exists = true });
              ( "Missing",
                Wire_knowledge.Link_page
                  { slug = "missing-page"; exists = false } );
              ("Index", Wire_knowledge.Link_own_file "index.md");
              ("Docs", Wire_knowledge.Link_external "https://example.com/docs");
              ("Bad", Wire_knowledge.Link_invalid_name "Bad_Name.md");
              ( "Anchor",
                Wire_knowledge.Link_unsupported Wire_knowledge.Unsupported_anchor
              );
              ( "Mail",
                Wire_knowledge.Link_unsupported Wire_knowledge.Unsupported_scheme
              );
              ( "Nested",
                Wire_knowledge.Link_unsupported Wire_knowledge.Unsupported_path );
              ( "Plain",
                Wire_knowledge.Link_unsupported
                  Wire_knowledge.Unsupported_not_markdown );
              ( "Empty",
                Wire_knowledge.Link_unsupported
                  Wire_knowledge.Unsupported_not_markdown );
              ( "Angle",
                Wire_knowledge.Link_unsupported
                  Wire_knowledge.Unsupported_not_markdown );
              ( "old-style",
                Wire_knowledge.Link_unsupported
                  Wire_knowledge.Unsupported_wikilink );
            ]
            |> List.sort compare
          in
          Alcotest.(check (list (pair string link_target)))
            "every link shape decodes to its kind" expected decoded)

(* POST /api/v1/tools/masc_goal_transition refuses a body without
   [expected_workspace]. The check it then runs accepts the pair the TUI sends
   and strips it, so the Goal tool reads only the transition itself. *)
let test_goal_transition_workspace_roundtrip () =
  with_workspace (fun config expected_workspace ->
      let body =
        Wire_work.encode_goal_transition ~goal_id:"goal-1"
          ~action:Wire_work.Pause ~note:None ~expected_workspace
      in
      Alcotest.(check bool)
        "the body names the workspace" true
        (List.mem "expected_workspace" (Yojson.Safe.Util.keys body));
      match Workspace.validate_expected_workspace ~config body with
      | Ok args ->
          Alcotest.(check (list string))
            "the Goal tool reads goal_id and action" [ "action"; "goal_id" ]
            (List.sort String.compare (Yojson.Safe.Util.keys args))
      | Error error ->
          Alcotest.fail (Workspace.expected_workspace_error_message error))

(* POST /api/v1/dashboard/tasks/cancel: the route's own parser and commit
   take the body the TUI encodes. The body the TUI sent before, without
   [expected_workspace], is refused. *)
let test_task_cancel_roundtrip () =
  with_workspace (fun config expected_workspace ->
      ignore
        (Workspace.add_task config ~title:"Cancel from the terminal" ~priority:1
           ~description:""
          : string);
      let module Route = Server_routes_http_routes_verification.For_testing in
      let commit body =
        Route.commit_operator_cancel_json ~config ~operator_id:"operator-test"
          body
      in
      (match commit (`Assoc [ ("task_id", `String "task-001") ]) with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "a cancel without expected_workspace committed");
      match
        commit
          (Wire_work.encode_task_cancel ~task_id:"task-001"
             ~reason:(Some "wrong scope") ~expected_workspace)
      with
      | Ok outcome ->
          Alcotest.(check bool)
            "the cancel commits instead of a no-op" false outcome.Workspace.noop
      | Error error -> Alcotest.fail (Masc_domain.masc_error_to_string error))

(* POST /api/v1/tools/masc_schedule_create validates the body against the
   tool schema, then the tool reads a Keeper wake, a recurrence and exactly
   one due input from it. The body the form sent before is refused by the
   schema. *)
let test_schedule_create_roundtrip () =
  let schema =
    match Tool_schemas_schedule.find_definition "masc_schedule_create" with
    | Some definition -> definition.Tool_schemas_schedule.schema.input_schema
    | None -> Alcotest.fail "masc_schedule_create has no registered schema"
  in
  let validate args =
    Masc.Tool_input_validation.validate ~schema ~name:"masc_schedule_create"
      ~args ()
  in
  (match
     validate
       (`Assoc
          [
            ("keeper", `String "alpha");
            ("recurrence", `String "every 1h");
            ("prompt", `String "Check the queue");
          ])
   with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "the old form body passed the schema");
  let dispatched_at = 1_795_000_000.0 in
  List.iter
    (fun (label, repeat, expected_recurrence) ->
      let body =
        Wire_work.encode_schedule_create
          {
            keeper_name = "alpha";
            message = "Check the queue";
            first_due_in_sec = 600;
            repeat;
          }
      in
      match validate body with
      | Error rejection ->
          Alcotest.fail
            (label ^ ": " ^ rejection.Masc.Tool_input_validation.message)
      | Ok args -> (
          (match Masc.Tool_schedule.payload_from_args args with
          | Ok _ -> ()
          | Error e -> Alcotest.fail (label ^ ": " ^ e));
          match Masc.Tool_schedule.recurrence_of_arg args with
          | Error e -> Alcotest.fail (label ^ ": " ^ e)
          | Ok recurrence -> (
              Alcotest.(check string)
                (label ^ ": recurrence") expected_recurrence
                (Yojson.Safe.to_string
                   (Schedule_domain.recurrence_to_yojson recurrence));
              match
                Masc.Tool_schedule.resolve_due_at ~dispatched_at recurrence
                  args
              with
              | Ok due_at ->
                  Alcotest.(check (float 0.001))
                    (label ^ ": first due counts from the server clock")
                    (dispatched_at +. 600.0) due_at
              | Error _ -> Alcotest.fail (label ^ ": no single due input"))))
    [
      ("once", Wire_work.Repeat_once, {|{"kind":"one_shot"}|});
      ( "every 30m",
        Wire_work.Repeat_every { interval_sec = 1800 },
        {|{"kind":"interval","interval_sec":1800}|} );
    ]

(* PUT /api/v1/wiki/:slug answers with the revision it wrote and no page.
   The decoded answer agrees with the page read back with GET, and a second
   save that names the page read back is accepted as an update. *)
let test_wiki_put_roundtrip () =
  with_workspace (fun config _ ->
      let base_path = config.Workspace.base_path in
      let put ~expected_revision ~expected_sha256 body =
        let request : Wire_knowledge.wiki_put_request =
          {
            expected_revision;
            expected_sha256;
            title = "Guide";
            summary = "How the operator runs the room";
            source = Wire_knowledge.Source_observation;
            tags = [ "ops" ];
            body;
            note = "TUI inline edit";
          }
        in
        match
          Server_dashboard_http_wiki.put_page_json ~config ~actor:"operator"
            ~slug:"guide"
            ~body_str:
              (Yojson.Safe.to_string
                 (Wire_knowledge.encode_wiki_put_request request))
            ()
        with
        | Error (status, json) ->
            Alcotest.failf "PUT refused (HTTP %d): %s"
              (Httpun.Status.to_code status)
              (Yojson.Safe.to_string json)
        | Ok json -> (
            match Wire_knowledge.decode_wiki_put_result json with
            | Ok saved -> saved
            | Error e -> Alcotest.fail ("PUT answer: " ^ e))
      in
      let read_back () =
        match Server_dashboard_http_wiki.get_page_json ~base_path ~slug:"guide" ()
        with
        | Error (status, json) ->
            Alcotest.failf "GET refused (HTTP %d): %s"
              (Httpun.Status.to_code status)
              (Yojson.Safe.to_string json)
        | Ok json -> (
            match Wire_knowledge.decode_wiki_page_detail json with
            | Ok page -> page
            | Error e -> Alcotest.fail ("GET answer: " ^ e))
      in
      let created =
        put ~expected_revision:None ~expected_sha256:None "# Guide\n\nFirst."
      in
      (match created.action with
      | Wire_knowledge.Wiki_page_created -> ()
      | Wire_knowledge.Wiki_page_updated ->
          Alcotest.fail "a new page decoded as an update");
      let page = read_back () in
      Alcotest.(check int)
        "the created revision is the page's" page.frontmatter.revision
        created.revision;
      let updated =
        put ~expected_revision:(Some page.frontmatter.revision)
          ~expected_sha256:(Some page.sha256) "# Guide\n\nSecond."
      in
      (match updated.action with
      | Wire_knowledge.Wiki_page_updated -> ()
      | Wire_knowledge.Wiki_page_created ->
          Alcotest.fail "an update decoded as a new page");
      Alcotest.(check int)
        "the update writes the page's next revision"
        (created.revision + 1) updated.revision;
      Alcotest.(check int)
        "the page read back has the revision the update named" updated.revision
        (read_back ()).frontmatter.revision;
      Alcotest.(check (list string))
        "no journal or index write failed" [] updated.warnings)

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Alcotest.run "server_wire_roundtrip"
    [
      ( "work",
        [
          Alcotest.test_case "schedule wake record -> decode_schedules_snapshot"
            `Quick test_schedule_wake_roundtrip;
          Alcotest.test_case "approval queue state -> decode_gate_pending_list"
            `Quick test_gate_queue_state_roundtrip;
          Alcotest.test_case
            "goal transition body -> validate_expected_workspace" `Quick
            test_goal_transition_workspace_roundtrip;
          Alcotest.test_case "task cancel body -> commit_operator_cancel_json"
            `Quick test_task_cancel_roundtrip;
          Alcotest.test_case "schedule create body -> masc_schedule_create"
            `Quick test_schedule_create_roundtrip;
        ] );
      ( "runtime",
        [
          Alcotest.test_case "tool usage summary -> decode_tools_catalog" `Quick
            test_tools_catalog_roundtrip;
          Alcotest.test_case "warming tools body -> Tools_warming" `Quick
            test_tools_warming_roundtrip;
          Alcotest.test_case "lane run page -> decode_exact_lane_runs" `Quick
            test_lane_run_statuses_roundtrip;
        ] );
      ( "fleet",
        [
          Alcotest.test_case
            "encode_chat_submit_request -> parse_keeper_chat_stream_request"
            `Quick test_chat_submit_admission_roundtrip;
        ] );
      ( "knowledge",
        [
          Alcotest.test_case
            "board comment dashboard row -> decode_board_thread" `Quick
            test_board_comment_votes_roundtrip;
          Alcotest.test_case
            "published artifact summary -> decode_artifacts_list" `Quick
            test_published_artifact_roundtrip;
          Alcotest.test_case "wiki page links -> decode_wiki_page_detail"
            `Quick test_wiki_page_links_roundtrip;
        ] );
      ( "knowledge",
        [
          Alcotest.test_case "wiki PUT answer -> decode_wiki_put_result" `Quick
            test_wiki_put_roundtrip;
        ] );
    ]
