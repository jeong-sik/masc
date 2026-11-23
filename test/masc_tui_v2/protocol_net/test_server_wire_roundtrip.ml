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
   report; a tool outside [top_20] has no usage row. *)
let test_tools_catalog_roundtrip () =
  let seeded =
    Tool_metrics.replace_samples (fun add ->
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
      let inventory =
        `Assoc
          [
            ( "tools",
              `List
                [
                  `Assoc
                    [
                      ("name", `String "masc_status");
                      ("description", `String "Room status");
                    ];
                  `Assoc
                    [
                      ("name", `String "masc_tasks");
                      ("description", `String "Task list");
                    ];
                ] );
          ]
      in
      let body =
        `Assoc
          [
            ("tool_inventory", inventory);
            ("tool_usage", Masc.Tool_unified.summary_report ());
          ]
      in
      match Wire_runtime.decode_tools_catalog ~observed_at body with
      | Error e -> Alcotest.fail ("tools catalog decode failed: " ^ e)
      | Ok tools ->
          let find name =
            List.find_opt
              (fun (t : Wire_runtime.tool_summary) -> String.equal t.name name)
              tools
          in
          (match find "masc_status" with
          | Some t ->
              Alcotest.(check (option int))
                "called tool reports its call count" (Some 2)
                (Observed.to_option t.calls);
              Alcotest.(check (option (float 0.001)))
                "failure rate from failure_count / call_count" (Some 50.0)
                (Observed.to_option t.failure_rate_pct)
          | None -> Alcotest.fail "masc_status missing from catalog");
          match find "masc_tasks" with
          | Some t ->
              Alcotest.(check bool)
                "tool outside top_20 stays Unreported" true
                (match t.calls with
                | Observed.Unreported -> true
                | Observed.Loading _ | Observed.Value _ | Observed.Absent
                | Observed.Failed _ ->
                    false)
          | None -> Alcotest.fail "masc_tasks missing from catalog")

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
        ] );
    ]
