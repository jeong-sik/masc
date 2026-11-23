(** Server encoder -> TUI decoder round trips.

    Each case builds the JSON with the server's own encoder and decodes it
    with the TUI decoder that reads that endpoint, so a renamed or reshaped
    field fails here instead of on the operator's screen. *)

open Masc_tui_core
module Wire_runtime = Masc_tui_protocol.Wire_runtime
module Wire_work = Masc_tui_protocol.Wire_work

let observed_at = Clock.Mono.of_ns 1_000_000_000L

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
    Wire_work.decode_schedules_snapshot (`Assoc [ ("requests", `List [ row ]) ])
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

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Alcotest.run "server_wire_roundtrip"
    [
      ( "work",
        [
          Alcotest.test_case "schedule wake record -> decode_schedules_snapshot"
            `Quick test_schedule_wake_roundtrip;
        ] );
      ( "runtime",
        [
          Alcotest.test_case "tool usage summary -> decode_tools_catalog" `Quick
            test_tools_catalog_roundtrip;
          Alcotest.test_case "warming tools body -> Tools_warming" `Quick
            test_tools_warming_roundtrip;
        ] );
    ]
