(** Round trips between the server's code and the TUI's code for one endpoint.

    A response case builds the JSON with the server's own encoder and decodes
    it with the TUI decoder that reads that endpoint. A request case encodes
    the body with the TUI encoder and parses it with the server's own parser.
    A renamed or reshaped field fails here instead of on the operator's
    screen. *)

open Masc_tui_core
module Wire_knowledge = Masc_tui_protocol.Wire_knowledge
module Wire_infra = Masc_tui_protocol.Wire_infra
module Wire_fleet = Masc_tui_protocol.Wire_fleet
module Wire_runtime = Masc_tui_protocol.Wire_runtime
module Wire_work = Masc_tui_protocol.Wire_work
module Stream_route = Server_routes_http_keeper_stream
module Owner_registry = Masc.Keeper_owner_registry
module Workspace = Masc.Workspace
module Projection = Masc.Keeper_context_observation_projection

let observed_at = Clock.Mono.of_ns 1_000_000_000L

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

(* GET /api/v1/repositories. The match is exhaustive over the server's
   status type, so a status added there stops this file from compiling until
   the TUI reads it. *)
let tui_status_of_server (status : Repo_manager_types.repository_status) :
    Wire_infra.repo_status =
  match status with
  | Repo_manager_types.Active -> Wire_infra.Repo_active
  | Repo_manager_types.Paused -> Wire_infra.Repo_paused
  | Repo_manager_types.Cloning -> Wire_infra.Repo_cloning
  | Repo_manager_types.Error message -> Wire_infra.Repo_error message

let repo_status_label = function
  | Wire_infra.Repo_active -> "active"
  | Wire_infra.Repo_paused -> "paused"
  | Wire_infra.Repo_cloning -> "cloning"
  | Wire_infra.Repo_error message -> "error: " ^ message

let test_repositories_roundtrip () =
  let base_path = "/srv/masc-base" in
  let statuses =
    [
      Repo_manager_types.Active;
      Repo_manager_types.Paused;
      Repo_manager_types.Cloning;
      Repo_manager_types.Error "fetch failed: authentication required";
    ]
  in
  let repos =
    List.mapi
      (fun i status : Repo_manager_types.repository ->
        {
          id = Printf.sprintf "repo-%d" i;
          name = Printf.sprintf "repo-%d" i;
          url = Printf.sprintf "https://github.com/example/repo-%d" i;
          local_path = Printf.sprintf "repos/repo-%d" i;
          aliases = [];
          default_branch = "main";
          keepers = [ "alpha" ];
          status;
          auto_sync = true;
          sync_interval = 300;
          created_at = 0L;
          updated_at = 0L;
        })
      statuses
  in
  let body =
    `Assoc
      [
        ( "repositories",
          `List
            (List.map
               (Server_routes_http_routes_repositories.repository_json
                  ~base_path)
               repos) );
        ("total", `Int (List.length repos));
      ]
  in
  match Wire_infra.decode_repositories body with
  | Error e -> Alcotest.fail ("repositories decode failed: " ^ e)
  | Ok decoded ->
      Alcotest.(check (list string))
        "every server status reads as its own TUI status"
        (List.map
           (fun (r : Repo_manager_types.repository) ->
             repo_status_label (tui_status_of_server r.status))
           repos)
        (List.map
           (fun (r : Wire_infra.repository) -> repo_status_label r.status)
           decoded);
      Alcotest.(check (list string))
        "the link path is the absolute one the server resolved"
        (List.init (List.length repos)
           (Printf.sprintf "/srv/masc-base/repos/repo-%d"))
        (List.map
           (fun (r : Wire_infra.repository) -> r.resolved_local_path)
           decoded)

(* GET /api/v1/ide/repository-activity. Each row is encoded by the
   projection's own [to_json], and edit and insert evidence comes from the
   patch step that writes the file. The envelope is the one
   [Server_ide_http.repository_activity_json] builds inside [json_ok]. *)
module Change = Masc.Keeper_tool_call_file_change
module Evidence = Masc.Keeper_file_change_evidence
module Patch = Masc.Keeper_tool_patch

let patch_evidence operation content =
  match Patch.apply operation content with
  | Ok application -> Patch.file_change_evidence application
  | Error e -> Alcotest.fail ("patch failed: " ^ e)

let change_row ?(succeeded = true) ?line_evidence ~path kind : Change.t =
  {
    at = 1795173600.0;
    keeper = "alpha";
    turn = Some 3;
    task_id = None;
    execution_id = Some ("exec-" ^ path);
    line_evidence;
    location = Change.In_repo { repo_id = "masc"; relative_path = path };
    kind;
    succeeded;
  }

let activity_body ~repo_id rows =
  `Assoc
    [
      ("ok", `Bool true);
      ( "data",
        `Assoc
          [
            ("repo_id", `String repo_id);
            ("window_hours", `Float 24.0);
            ("changes", `List (List.map Change.to_json rows));
            ("incomplete", `Int 2);
            ("unattributed", `Int 1);
          ] );
    ]

(* Exhaustive over the server's kind, so a kind added there stops this file
   from compiling until the TUI reads it. *)
let server_change_label (row : Change.t) =
  let kind =
    match row.kind with
    | Change.Edited { before; after; replace_all } ->
        Printf.sprintf "edit %S -> %S replace_all=%b" before after replace_all
    | Change.Written { content } -> Printf.sprintf "write %S" content
    | Change.Inserted { line; text } -> Printf.sprintf "insert %d %S" line text
    | Change.Materialized { sha256 } -> "materialize " ^ sha256
  in
  let path =
    match row.location with
    | Change.In_repo { relative_path; _ } -> relative_path
    | Change.In_bundle { bundle_path } -> "bundle:" ^ bundle_path
    | Change.At_absolute_path { path } -> "absolute:" ^ path
  in
  Printf.sprintf "%s %s @%s ok=%b" path kind row.keeper row.succeeded

let tui_change_label (fc : Wire_infra.file_change) =
  let kind =
    match fc.change with
    | Wire_infra.Change_edit { before; after; replace_all } ->
        Printf.sprintf "edit %S -> %S replace_all=%b" before after replace_all
    | Wire_infra.Change_write { content } -> Printf.sprintf "write %S" content
    | Wire_infra.Change_insert { line; text } ->
        Printf.sprintf "insert %d %S" line text
    | Wire_infra.Change_materialize { sha256 } -> "materialize " ^ sha256
  in
  Printf.sprintf "%s %s @%s ok=%b" fc.path kind fc.keeper fc.succeeded

let line_counts_label (fc : Wire_infra.file_change) =
  let counts = Wire_infra.file_change_line_counts fc in
  let side = function Some n -> string_of_int n | None -> "?" in
  Printf.sprintf "%s +%s -%s" fc.path (side counts.added) (side counts.removed)

let test_repository_activity_roundtrip () =
  let edit_before = "let x = 1\nlet y = 2" in
  let edit_after = "let x = 1\nlet y = 3\nlet z = 4" in
  let rows =
    [
      change_row ~path:"lib/edit.ml"
        ~line_evidence:
          (patch_evidence
             (Patch.Replace
                {
                  old_string = edit_before;
                  new_string = edit_after;
                  replace_all = false;
                })
             "(* head *)\nlet x = 1\nlet y = 2\n")
        (Change.Edited
           { before = edit_before; after = edit_after; replace_all = false });
      change_row ~path:"lib/all.ml"
        ~line_evidence:
          (patch_evidence
             (Patch.Replace
                { old_string = "foo"; new_string = "bar\nbaz"; replace_all = true })
             "foo\nx\nfoo\n")
        (Change.Edited { before = "foo"; after = "bar\nbaz"; replace_all = true });
      change_row ~path:"docs/new.md"
        ~line_evidence:(Evidence.written "a\nb\nc\n")
        (Change.Written { content = "a\nb\nc\n" });
      change_row ~path:"lib/memo.ml"
        ~line_evidence:
          (patch_evidence
             (Patch.Insert_before_line { line = 2; text = "(* note *)" })
             "let a = 1\nlet q = 0\n")
        (Change.Inserted { line = 2; text = "(* note *)" });
      change_row ~path:"assets/blob.bin"
        ~line_evidence:(Evidence.written "x\ny")
        (Change.Materialized { sha256 = String.make 64 'a' });
      change_row ~path:"lib/failed.ml" ~succeeded:false
        (Change.Written { content = "zzz" });
      change_row ~path:"lib/old.ml"
        (Change.Edited { before = "a"; after = "b"; replace_all = false });
      change_row ~path:"lib/many.ml"
        ~line_evidence:
          (Evidence.edited_ranges_omitted
             ~occurrence_count:(Evidence.max_recorded_edit_occurrences + 1))
        (Change.Edited { before = "a"; after = "b"; replace_all = true });
    ]
  in
  match
    Wire_infra.decode_repository_activity ~repo_id:"masc"
      (activity_body ~repo_id:"masc" rows)
  with
  | Error e -> Alcotest.fail ("repository activity decode failed: " ^ e)
  | Ok activity ->
      Alcotest.(check (list string)) "every row keeps its path, kind and outcome"
        (List.map server_change_label rows)
        (List.map tui_change_label activity.changes);
      Alcotest.(check (list string))
        "line counts come only from what the row determines"
        [
          "lib/edit.ml +3 -2";
          "lib/all.ml +4 -2";
          "docs/new.md +3 -?";
          "lib/memo.ml +1 -0";
          "assets/blob.bin +? -?";
          "lib/failed.ml +? -?";
          "lib/old.ml +? -?";
          "lib/many.ml +? -?";
        ]
        (List.map line_counts_label activity.changes);
      Alcotest.(check (pair int int)) "unreadable counts are carried"
        (2, 1)
        (activity.incomplete, activity.unattributed);
      Alcotest.(check bool) "an answer for another repository is rejected" true
        (Result.is_error
           (Wire_infra.decode_repository_activity ~repo_id:"docs"
              (activity_body ~repo_id:"masc" rows)));
      let bundle_row =
        {
          (change_row ~path:"notes.md" (Change.Written { content = "n" })) with
          location = Change.In_bundle { bundle_path = "notes.md" };
        }
      in
      Alcotest.(check bool) "a change outside the repository is rejected" true
        (Result.is_error
           (Wire_infra.decode_repository_activity ~repo_id:"masc"
              (activity_body ~repo_id:"masc" [ bundle_row ])))

(* The context projection reads the keeper's turn-record store, so the
   roster cases run against a throwaway workspace. *)
let with_temp_workspace f =
  let path = Filename.temp_file "tui-wire-roundtrip-" ".dir" in
  Sys.remove path;
  Sys.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree path)
    (fun () -> f (Masc.Workspace.default_config path))

let trace_id = "trace-1781200000000-00000"
let record_ts = 1_781_200_000.0

let turn_record ~keeper ?(absolute_turn = 7) ?(input_tokens = Some 40_000)
    ?(context_window = Some 200_000) ?(provider_context_window = None)
    ?(usage_scope = Runtime_usage_scope.Per_request)
    ?(input_provenance = Some Turn_input_provenance.Measured_request) () :
    Turn_record.t =
  {
    request_observations = [];
    execution_ids = [];
    keeper;
    agent_name = keeper ^ "-agent";
    turn_kind = Turn_record.Direct;
    trace_id;
    absolute_turn;
    turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn;
    blocks =
      [
        {
          Turn_record.block = Prompt_block_id.Keeper_instructions;
          bytes = 4;
          digest = String.make 64 'a';
        };
      ];
    input_components =
      Some [ { component = Turn_record.Tool_schemas; bytes = 8192 } ];
    tool_surface_ref = None;
    runtime_profile = "glm-coding.glm-5-turbo";
    selected_model = Some "glm-5-turbo";
    finish_reason = Some "completed";
    context_window;
    provider_context_window;
    price_input_per_million = None;
    price_output_per_million = None;
    request_latency_ms = Some 1234;
    ttfrc_ms = None;
    request_wire_observation =
      Some { runtime_profile = "glm-coding.glm-5-turbo"; body_bytes = 560_513 };
    model_input_window = None;
    response_observed_model_input = None;
    refused_model_input = None;
    raw_trace_run_ref = None;
    sampling =
      {
        temperature = None;
        top_p = None;
        max_tokens = None;
        enable_thinking = Some true;
      };
    usage =
      {
        input_tokens;
        output_tokens = Some 412;
        cache_creation_input_tokens = None;
        cache_read_input_tokens = Some 15_000;
        scope = usage_scope;
        input_provenance;
      };
    turn_output_tokens = None;
    ts = record_ts;
  }

let append_record config (record : Turn_record.t) =
  Dated_jsonl.append
    (Masc.Keeper_types_support.keeper_turn_record_store config record.keeper)
    (Turn_record.to_json record)

let keeper_row name context_fields =
  `Assoc
    ([
       ("name", `String name);
       ("health", `String "healthy");
       ("paused", `Bool false);
       ("keepalive_running", `Bool true);
       ("activation_mode", `String "autonomous");
       ("runtime_id", `String "glm-coding.glm-5-turbo");
     ]
    @ context_fields)

(* GET /api/v1/gate/keepers?detail=true: every detail row carries the context
   projection, and a keeper whose meta did not read is an error row that must
   not fail the rest of the roster. *)
let test_keepers_roster_roundtrip () =
  with_temp_workspace (fun config ->
      append_record config (turn_record ~keeper:"alpha" ());
      append_record config
        (turn_record ~keeper:"beta"
           ~input_provenance:(Some Turn_input_provenance.Context_estimate) ());
      let context name =
        Projection.context_fields ~config ~keeper_name:name
          ~current_trace_id:trace_id
      in
      let error_row =
        Masc.Keeper_tool_surface_ops.keeper_list_error_row_json
          ~persisted_meta:None ~runtime_class:"keeper" config "broken"
          "keeper.toml: unknown field model_x"
      in
      let body =
        `Assoc
          [
            ( "keepers",
              `List
                [
                  keeper_row "alpha" (context "alpha");
                  keeper_row "beta" (context "beta");
                  keeper_row "gamma" (Projection.missing_context_fields ());
                  error_row;
                ] );
          ]
      in
      match Wire_fleet.decode_keepers_roster ~observed_at body with
      | Error e -> Alcotest.fail ("roster decode failed: " ^ e)
      | Ok roster -> (
          Alcotest.(check (list (pair string string)))
            "the error row is an unreadable keeper with its message"
            [ ("broken", "keeper.toml: unknown field model_x") ]
            (List.map
               (fun (u : Wire_fleet.unreadable_keeper) -> (u.name, u.reason))
               roster.unreadable);
          let context_of name =
            match
              List.find_opt
                (fun (k : Wire_fleet.keeper_summary) -> String.equal k.name name)
                roster.keepers
            with
            | Some k -> Observed.to_option k.context
            | None -> Alcotest.fail (name ^ " is missing from the roster")
          in
          (match context_of "alpha" with
          | Some
              (Wire_fleet.Context_measured
                 { ratio; tokens; window; absolute_turn; measured_at_unix }) ->
              Alcotest.(check (option (float 1e-9)))
                "measured ratio is tokens over window" (Some 0.2) ratio;
              Alcotest.(check int) "measured tokens" 40_000 tokens;
              Alcotest.(check (option int)) "window" (Some 200_000) window;
              Alcotest.(check (option int)) "turn" (Some 7) absolute_turn;
              Alcotest.(check (option (float 1.0)))
                "measured at the record's time" (Some record_ts) measured_at_unix
          | Some (Wire_fleet.Context_not_measured _) | None ->
              Alcotest.fail "alpha's context decodes as measured");
          (match context_of "beta" with
          | Some
              (Wire_fleet.Context_not_measured
                 { reason = Wire_fleet.Context_input_estimate; estimated_ratio })
            ->
              Alcotest.(check (option (float 1e-9)))
                "the estimate comes with the reason" (Some 0.2) estimated_ratio
          | Some
              (Wire_fleet.Context_not_measured _ | Wire_fleet.Context_measured _)
          | None ->
              Alcotest.fail "beta's context decodes as an input estimate");
          match context_of "gamma" with
          | Some
              (Wire_fleet.Context_not_measured
                 {
                   reason = Wire_fleet.Context_measurement_missing;
                   estimated_ratio = None;
                 }) ->
              ()
          | Some
              (Wire_fleet.Context_not_measured _ | Wire_fleet.Context_measured _)
          | None ->
              Alcotest.fail "gamma's context decodes as a missing measurement"))

(* GET /api/v1/keepers/:name/turn-records: each entry wraps
   Turn_record.to_json, oldest first. Only a per-request input the provider
   measured, within the window, counts as a fill. *)
let test_turn_records_roundtrip () =
  let records =
    [
      turn_record ~keeper:"alpha" ~absolute_turn:5 ();
      turn_record ~keeper:"alpha" ~absolute_turn:6
        ~input_provenance:(Some Turn_input_provenance.Context_estimate) ();
      turn_record ~keeper:"alpha" ~absolute_turn:7
        ~usage_scope:Runtime_usage_scope.Conversation_cumulative ();
      turn_record ~keeper:"alpha" ~absolute_turn:8
        ~provider_context_window:(Some 100_000) ();
      turn_record ~keeper:"alpha" ~absolute_turn:9
        ~input_tokens:(Some 250_000) ();
    ]
  in
  let body =
    `Assoc
      [
        ("keeper", `String "alpha");
        ("count", `Int (List.length records));
        ("skipped_rows", `Int 1);
        ( "entries",
          `List
            (List.map
               (fun record ->
                 `Assoc
                   [
                     ("record", Turn_record.to_json record);
                     ("diff_vs_prev", `Null);
                   ])
               records) );
      ]
  in
  match Wire_fleet.decode_keeper_turn_records body with
  | Error e -> Alcotest.fail ("turn records decode failed: " ^ e)
  | Ok decoded ->
      Alcotest.(check string) "keeper" "alpha" decoded.keeper;
      Alcotest.(check int) "skipped rows" 1 decoded.skipped_rows;
      Alcotest.(check (list int)) "turns, oldest first" [ 5; 6; 7; 8; 9 ]
        (List.map
           (fun (r : Wire_fleet.turn_record_row) -> r.absolute_turn)
           decoded.rows);
      Alcotest.(check (list (option (float 1e-9))))
        "fill per turn: measured, estimate, cumulative, provider window, over \
         the window"
        [ Some 0.2; None; None; Some 0.4; None ]
        (List.map Wire_fleet.turn_record_context_fill decoded.rows)

(* The roster's top-level [candle] is Candle_observation.to_json. Only a ready
   ledger carries a supply; off and disabled stay apart from a 0 supply. *)
let test_candle_observation_roundtrip () =
  let decode candle =
    Result.map
      (fun (extras : Wire_fleet.keeper_roster_extras) -> extras.candle_summary)
      (Wire_fleet.decode_keepers_roster_extras
         (`Assoc
            [ ("keepers", `List []); ("candle", Candle_observation.to_json candle) ]))
  in
  Alcotest.(check bool) "off" true
    (decode Candle_observation.Off = Ok (Some Wire_fleet.Candle_off));
  Alcotest.(check bool) "disabled keeps its reason" true
    (decode (Candle_observation.Disabled { reason = "candle.toml unreadable" })
    = Ok (Some (Wire_fleet.Candle_disabled { reason = "candle.toml unreadable" })));
  Alcotest.(check bool) "ready carries the supply" true
    (decode
       (Candle_observation.Ready
          {
            Candle_balance.issued_milli = "10000";
            burned_milli = "2500";
            circulating_milli = "7500";
          })
    = Ok
        (Some
           (Wire_fleet.Candle_ready
              {
                issued_milli = "10000";
                burned_milli = "2500";
                circulating_milli = "7500";
              })))

(* GET /api/v1/keepers/<keeper>/chat/events. The journal rows are written by
   the server's own encoder and served through the route's own query parsing,
   at the paths the TUI builds; the TUI decodes the pages and folds them with
   Cut_reply. The text has to equal the reply the channel connectors keep
   from the same events (Keeper_chat_discord, Keeper_chat_slack), folded here
   with the server's own Keeper_chat_response_ownership. *)
module Chat_events = Masc.Keeper_chat_events
module Chat_event_log = Masc.Keeper_chat_event_log
module Response_ownership = Masc.Keeper_chat_response_ownership
module Chat_operations_http = Server_dashboard_http_keeper_chat_operations
module Wire_chat_journal = Masc_tui_protocol.Wire_chat_journal
module Cut_reply = Masc_tui_store.Cut_reply

(* The connectors' fold: Run_started starts over with fresh ownership, an
   attempt boundary retires the owner and starts over, a Stale delta is
   dropped, and Run_finished or Event_error ends the reply. *)
let connector_reply events =
  let rec fold ~text ~ownership = function
    | [] -> text
    | (event : Chat_events.keeper_chat_event) :: rest -> (
        match event with
        | Chat_events.Run_started _ ->
            fold ~text:"" ~ownership:(Response_ownership.create ()) rest
        | Chat_events.Agent_core_runtime_attempt_started _ ->
            fold ~text:""
              ~ownership:(Response_ownership.retire_attempt ownership)
              rest
        | Chat_events.Text_delta { text = delta; response } -> (
            match Response_ownership.admit ownership response with
            | Response_ownership.Stale -> fold ~text ~ownership rest
            | Response_ownership.Admitted ownership
            | Response_ownership.Preserved_unobserved ownership ->
                fold ~text:(text ^ delta) ~ownership rest)
        | Chat_events.Run_finished _ | Chat_events.Event_error _ -> text
        | _ -> fold ~text ~ownership rest)
  in
  match fold ~text:"" ~ownership:(Response_ownership.create ()) events with
  | "" -> None
  | text -> Some text

let journal_rows events =
  events
  |> List.mapi (fun seq event ->
         Chat_event_log.journaled_event_to_string
           { Chat_event_log.seq; ts = 1_781_300_000.0 +. Float.of_int seq; event }
         ^ "\n")
  |> String.concat ""

let cut_operation_id = "kmsg-roundtrip-cut"

let tui_reply events =
  let rows = journal_rows events in
  let rec read cut =
    match Cut_reply.next_page cut with
    | None -> cut
    | Some from -> (
        let target =
          Wire_chat_journal.path ~keeper:"alpha" ~operation_id:cut_operation_id
            ~from
        in
        match
          Chat_operations_http.For_testing.events_page_of_request
            ~path:"kmsg-roundtrip-cut.jsonl"
            (Httpun.Request.create `GET target)
            rows
        with
        | Error (_status, code) ->
            Alcotest.failf "the route refused %s: %s" target code
        | Ok body -> (
            match
              Wire_chat_journal.decode_page ~operation_id:cut_operation_id body
            with
            | Ok page -> read (Cut_reply.apply_page page cut)
            | Error detail -> Alcotest.failf "the TUI refused a page: %s" detail))
  in
  Cut_reply.text (read Cut_reply.start)

let observed generation scope =
  Chat_events.Observed_response
    { response_generation = generation; response_scope = scope }

let delta ?(response = Chat_events.Unobserved_scope None) text =
  Chat_events.Text_delta { text; response }

let run_started =
  Chat_events.Run_started { run_id = "run-cut"; thread_id = "keeper:alpha" }

let attempt_started index =
  Chat_events.Agent_core_runtime_attempt_started
    { runtime_id = Some "runtime-b"; attempt_index = Some index }

let cut = Chat_events.Event_error { message = "interrupted" }

(* Events the fold passes over, the way they sit between text deltas. *)
let unread_events =
  [
    Chat_events.Text_message_start
      { message_id = "msg-cut"; role = Chat_events.Assistant };
    Chat_events.Agent_core_thinking_delta
      { index = 0; delta = "thinking"; response = None };
    Chat_events.Text_message_end;
  ]

let random_journal state =
  let pick list = List.nth list (Random.State.int state (List.length list)) in
  List.init
    (1 + Random.State.int state 40)
    (fun index ->
      let text = Printf.sprintf "<%d>" index in
      match Random.State.int state 20 with
      | 0 -> run_started
      | 1 | 2 -> attempt_started index
      | 3 -> cut
      | 4 | 5 -> pick unread_events
      | 6 | 7 | 8 -> delta text
      | 9 | 10 ->
          delta
            ~response:
              (Chat_events.Unobserved_scope (Some (Random.State.int state 4)))
            text
      | _ ->
          delta
            ~response:
              (observed (Random.State.int state 3) (Random.State.int state 4))
            text)

let test_cut_reply_journal_roundtrip () =
  Alcotest.(check int) "the TUI pages at the route's ceiling"
    Chat_event_log.page_max_limit Wire_chat_journal.page_limit;
  let cases =
    [
      ( "streamed text before the cut"
      , [ run_started ] @ unread_events
        @ [ delta "Hel"; delta "lo"; cut; delta "after the cut" ] );
      ( "an attempt boundary"
      , [
          run_started;
          delta ~response:(observed 1 0) "first";
          attempt_started 1;
          delta ~response:(observed 1 0) "late";
          delta ~response:(observed 2 0) "second";
          cut;
        ] );
      ("a new run", [ run_started; delta "a"; run_started; delta "b" ]);
      ( "a bare scope ahead of the admitted response"
      , [
          delta ~response:(observed 1 4) "A";
          delta ~response:(Chat_events.Unobserved_scope (Some 6)) "U";
          delta ~response:(observed 1 5) "B";
          delta ~response:(observed 1 6) "C";
          cut;
        ] );
      ( "a finished run"
      , [
          run_started;
          delta "done";
          Chat_events.Run_finished { run_id = "run-cut" };
          delta "late";
        ] );
      ("no text", [ run_started; cut ]);
      ( "three pages"
      , (run_started
        :: List.init
             ((2 * Wire_chat_journal.page_limit) + 3)
             (fun index -> delta (string_of_int (index mod 10))))
        @ [ cut ] );
    ]
  in
  List.iter
    (fun (label, events) ->
      Alcotest.(check (option string)) label (connector_reply events)
        (tui_reply events))
    cases;
  let state = Random.State.make [| 54492 |] in
  for round = 1 to 300 do
    let events = random_journal state in
    Alcotest.(check (option string))
      (Printf.sprintf "random journal %d" round)
      (connector_reply events) (tui_reply events)
  done

(* POST /api/v1/keepers/chat/stream live AG-UI SSE projection:
   Server_keeper_chat_agui_projection.project -> Ag_ui.event_to_json ->
   Wire_fleet.decode_chat_stream_chunk -> Fleet_store.apply_chat_stream_chunk.
   Live streaming text must equal [connector_reply] across runtime attempt
   retries, superseded response generations/scopes, and post-terminal frames. *)
module Agui_projection = Server_keeper_chat_agui_projection
module Fleet_store = Masc_tui_store.Fleet_store

let tui_live_stream_reply events =
  let _, fleet =
    List.fold_left
      (fun (proj, fleet) event ->
        let proj, agui_opt =
          Agui_projection.project ~timestamp:1_781_300_000.0
            ~redact_text:Fun.id proj event
        in
        let fleet =
          match agui_opt with
          | None -> fleet
          | Some agui_ev -> (
              let json = Ag_ui.event_to_json agui_ev in
              match Wire_fleet.decode_chat_stream_chunk json with
              | Ok chunk ->
                  Fleet_store.apply_chat_stream_chunk ~keeper:"alpha"
                    ~request_id:cut_operation_id chunk fleet
              | Error detail ->
                  Alcotest.failf
                    "the TUI refused a projected AG-UI frame: %s (%s)" detail
                    (Yojson.Safe.to_string json))
        in
        (proj, fleet))
      ( Agui_projection.initial
      , Fleet_store.start_chat_stream ~keeper:"alpha"
          ~request_id:cut_operation_id Fleet_store.empty )
      events
  in
  match Fleet_store.String_map.find_opt "alpha" fleet.chat_streams with
  | Some buf when not (String.equal buf.text "") -> Some buf.text
  | Some _ | None -> None

let test_live_chat_stream_ownership_roundtrip () =
  let cases =
    [
      ( "live stream before cut"
      , [ run_started ] @ unread_events
        @ [ delta "Hel"; delta "lo"; cut; delta "after the cut" ] );
      ( "live stream runtime attempt retry retires attempt 1"
      , [
          run_started;
          delta ~response:(observed 1 0) "first";
          attempt_started 1;
          delta ~response:(observed 1 0) "late";
          delta ~response:(observed 2 0) "second";
          Chat_events.Run_finished { run_id = "run-cut" };
        ] );
      ( "live stream runtime attempt with None runtime_id"
      , [
          run_started;
          delta ~response:(observed 1 0) "stale";
          Chat_events.Agent_core_runtime_attempt_started
            { runtime_id = None; attempt_index = Some 2 };
          delta ~response:(observed 1 0) "dropped";
          delta ~response:(observed 2 0) "fresh";
        ] );
      ("live stream new run resets", [ run_started; delta "a"; run_started; delta "b" ]);
      ( "live stream bare scope ahead of admitted response"
      , [
          delta ~response:(observed 1 4) "A";
          delta ~response:(Chat_events.Unobserved_scope (Some 6)) "U";
          delta ~response:(observed 1 5) "B";
          delta ~response:(observed 1 6) "C";
          cut;
        ] );
      ( "live stream finished run ignores late delta"
      , [
          run_started;
          delta "done";
          Chat_events.Run_finished { run_id = "run-cut" };
          delta "late";
        ] );
      ("live stream no text", [ run_started; cut ]);
    ]
  in
  List.iter
    (fun (label, events) ->
      Alcotest.(check (option string)) label (connector_reply events)
        (tui_live_stream_reply events))
    cases;
  let state = Random.State.make [| 54530 |] in
  for round = 1 to 300 do
    let events = random_journal state in
    Alcotest.(check (option string))
      (Printf.sprintf "random live stream %d" round)
      (connector_reply events) (tui_live_stream_reply events)
  done

(* GET /api/v1/keepers/turns: Keeper_turn_preview.to_json and
   Keeper_owner.turn_lane_to_string round-trip cleanly into Wire_fleet.active_turn. *)
let test_keeper_turns_preview_roundtrip () =
  let module Preview = Masc.Keeper_turn_preview in
  let writer =
    Preview.reset ~base_path:"/tmp/wire-rt" ~keeper_name:"roundtrip-keeper"
      ~execution_scope:None ~turn_ref:None ~now:1795503000.0
      ~redaction:Masc.Keeper_secret_redaction.empty
  in
  Preview.note_attempt ~writer:(Some writer) ~now:1795503001.0
    ~runtime_id:"ollama-rt";
  Preview.note_tool ~writer:(Some writer) ~now:1795503002.0 "Execute";
  Preview.note_request ~writer:(Some writer) ~now:1795503003.0;
  Preview.note_text ~writer:(Some writer) ~now:1795503004.0
    "Streaming summary line";
  let snap_stream = Preview.snapshot writer in
  let prep_snap =
    let prep_writer =
      Preview.reset ~base_path:"/tmp/wire-rt" ~keeper_name:"roundtrip-prep"
        ~execution_scope:None ~turn_ref:None ~now:1795503010.0
        ~redaction:Masc.Keeper_secret_redaction.empty
    in
    Preview.with_preparation ~writer:(Some prep_writer) ~turn_ref:None
      ~phase:Preview.Context_preparation (fun () -> Preview.snapshot prep_writer)
  in
  let envelope =
    `Assoc
      [
        ("schema", `String "masc.keeper_turns.v1");
        ( "keepers"
        , `List
            [
              `Assoc
                [
                  ("status", `String "ok");
                  ("keeper_name", `String "roundtrip-keeper");
                  ("chat_control_token", `String "ctrl-rt-1");
                  ( "turn"
                  , `Assoc
                      [
                        ( "lane"
                        , `String
                            (Masc.Keeper_owner.turn_lane_to_string
                               Masc.Keeper_owner.Autonomous) );
                        ("turn_ref", `String "trace-rt#42");
                        ("started_at_unix", `Float 1795503000.0);
                        ("interrupt_token", `String "itok-rt-1");
                        ("preview", Preview.to_json snap_stream);
                      ] );
                ];
              `Assoc
                [
                  ("status", `String "ok");
                  ("keeper_name", `String "roundtrip-prep");
                  ("chat_control_token", `String "ctrl-rt-2");
                  ( "turn"
                  , `Assoc
                      [
                        ( "lane"
                        , `String
                            (Masc.Keeper_owner.turn_lane_to_string
                               Masc.Keeper_owner.Chat_operation) );
                        ("turn_ref", `Null);
                        ("started_at_unix", `Float 1795503010.0);
                        ("interrupt_token", `String "itok-rt-2");
                        ("preview", Preview.to_json prep_snap);
                      ] );
                ];
            ] );
      ]
  in
  match Wire_fleet.decode_keeper_turns envelope with
  | Error e -> Alcotest.fail ("decode_keeper_turns roundtrip failed: " ^ e)
  | Ok [ r1; r2 ] -> (
      (match r1.state with
      | Wire_fleet.Turn_active t -> (
          Alcotest.(check bool) "Autonomous maps to Lane_proactive" true
            (Wire_fleet.equal_turn_lane t.lane Wire_fleet.Lane_proactive);
          Alcotest.(check (option string)) "turn_ref preserved"
            (Some "trace-rt#42") t.turn_ref;
          match t.preview with
          | Some p ->
              Alcotest.(check (option int)) "preview revision preserved"
                (Some snap_stream.revision) p.revision;
              Alcotest.(check bool) "stream activity preserved" true
                (Wire_fleet.equal_turn_preview_activity p.activity
                   Wire_fleet.Preview_streaming);
              Alcotest.(check (option string)) "last_tool preserved"
                (Some "Execute") p.last_tool;
              Alcotest.(check string) "text_tail preserved"
                "Streaming summary line" p.text_tail
          | None -> Alcotest.fail "expected preview on r1")
      | Wire_fleet.Turn_idle | Wire_fleet.Turn_unavailable _ ->
          Alcotest.fail "expected Turn_active for r1");
      match r2.state with
      | Wire_fleet.Turn_active t -> (
          Alcotest.(check bool) "Chat_operation maps to Lane_chat" true
            (Wire_fleet.equal_turn_lane t.lane Wire_fleet.Lane_chat);
          match t.preview with
          | Some { preparation = Some prep; _ } ->
              Alcotest.(check bool) "Context_preparation maps to Prep_context"
                true
                (Wire_fleet.equal_turn_preparation_phase prep.phase
                   Wire_fleet.Prep_context);
              Alcotest.(check bool) "active preparation maps to Prep_active"
                true
                (Wire_fleet.equal_turn_preparation_state prep.state
                   Wire_fleet.Prep_active)
          | Some { preparation = None; _ } | None ->
              Alcotest.fail "expected active preparation on r2")
      | Wire_fleet.Turn_idle | Wire_fleet.Turn_unavailable _ ->
          Alcotest.fail "expected Turn_active for r2")
  | Ok _ -> Alcotest.fail "expected exactly two keeper turn rows"

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
          Alcotest.test_case
            "context projection and error row -> decode_keepers_roster" `Quick
            test_keepers_roster_roundtrip;
          Alcotest.test_case
            "Turn_record.to_json entries -> decode_keeper_turn_records" `Quick
            test_turn_records_roundtrip;
          Alcotest.test_case
            "Candle_observation.to_json -> decode_keepers_roster_extras" `Quick
            test_candle_observation_roundtrip;
          Alcotest.test_case
            "chat events route pages -> Wire_chat_journal and Cut_reply"
            `Quick test_cut_reply_journal_roundtrip;
          Alcotest.test_case
            "live AG-UI chat stream projection -> Wire_fleet and Fleet_store ownership"
            `Quick test_live_chat_stream_ownership_roundtrip;
          Alcotest.test_case
            "Keeper_turn_preview.to_json -> decode_keeper_turns"
            `Quick test_keeper_turns_preview_roundtrip;
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
          Alcotest.test_case "wiki PUT answer -> decode_wiki_put_result" `Quick
            test_wiki_put_roundtrip;
        ] );
      ( "infra",
        [
          Alcotest.test_case "repository_json -> decode_repositories" `Quick
            test_repositories_roundtrip;
          Alcotest.test_case
            "file change to_json -> decode_repository_activity" `Quick
            test_repository_activity_roundtrip;
        ] );
    ]
