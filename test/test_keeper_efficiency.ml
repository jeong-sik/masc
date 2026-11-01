(** Tests for the per-Keeper month aggregation over the cost ledger and the
    tool-call ledger.

    The contract under test ([Keeper_efficiency]):
      - turns are distinct (agent, keeper_turn_id) pairs over cost rows
      - token/cost sums add only Resolved_delta / Resolved_attempt_delta rows
      - raw observations count a turn but never add spend
      - tool rows: record_kind = tool_call only, typed disposition classes
      - the per-day boundary cache is exact: appended rows appear on the
        next call, a rewritten (shrunk) day file is recomputed from zero,
        and a corrupt cache rebuilds
      - the record_kind strings stay pinned to Keeper_tool_call_log's own
        classifier, since this module decodes that ledger without
        depending on the [masc] library *)

open Alcotest

module KE = Keeper_efficiency
module CL = Cost_ledger

let counter = ref 0

let tmpdir prefix =
  incr counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s_%d_%d_%.0f" prefix !counter (Unix.getpid ()) (Unix.time ()))
  in
  Unix.mkdir dir 0o755;
  dir
;;

let with_masc_root f =
  let dir = tmpdir "keeper_efficiency" in
  Fun.protect
    ~finally:(fun () -> try Fs_compat.remove_tree dir with _ -> ())
    (fun () -> f dir)
;;

let costs_store root = CL.store_of_masc_root root

let tool_store root =
  Dated_jsonl.open_store
    Dated_jsonl.Store.(at (root_of_masc_dir root) Root.Tool_calls)
;;

type projection = Resolved | Resolved_attempt | Raw_turn_total

let cost_row ~agent ~turn ~input_tokens ~output_tokens ~cost_usd projection : CL.t =
  let identity : CL.inference_identity =
    { trace_id = "trace-test"; keeper_turn_id = turn; agent_core_turn_ordinal = 0 }
  in
  let usage_projection =
    match projection with
    | Resolved -> CL.Resolved_delta
    | Resolved_attempt ->
      CL.Resolved_attempt_delta
        { routing_run_id = "run-test"; lane_attempt_index = 0; reading_index = 0 }
    | Raw_turn_total -> CL.Raw_observation Runtime_usage_scope.Turn_total
  in
  { CL.agent = agent
  ; task_id = None
  ; model = "test-model"
  ; usage = CL.Usage_reported { input_tokens; output_tokens; cost_usd }
  ; usage_projection
  ; timestamp = "2026-10-03T00:00:00Z"
  ; ts_unix = 1791000000.0
  ; source = CL.Auto_trajectory identity
  }
;;

let tool_row ?(record_kind = "tool_call") ?(keeper = "polisher") ?(disposition = "completed")
    ?(duration_ms = 10.0) () =
  `Assoc
    ([ ("ts", `Float 1791000000.0)
     ; ("record_kind", `String record_kind)
     ; ("keeper", `String keeper)
     ; ("tool", `String "Execute")
     ; ("duration_ms", `Float duration_ms)
     ]
    @
    match disposition with
    | "none" -> []
    | d -> [ ("disposition", `String d) ])
;;

(* [Dated_jsonl.append] files rows under the wall clock's own month and day,
   so the fixtures land in today's day file and every query below uses the
   wall clock's month rather than a hard-coded one. *)
let today_month () =
  let t = Unix.gmtime (Unix.time ()) in
  Printf.sprintf "%04d-%02d" (t.Unix.tm_year + 1900) (t.Unix.tm_mon + 1)
;;

let today_day_file store_dir =
  let t = Unix.gmtime (Unix.time ()) in
  Filename.concat store_dir
    (Printf.sprintf "%04d-%02d/%02d.jsonl" (t.Unix.tm_year + 1900) (t.Unix.tm_mon + 1) t.Unix.tm_mday)
;;

let keeper_row view name =
  List.find_opt (fun (k : KE.keeper_month) -> String.equal k.keeper name) view.KE.keepers
;;

let near label expected actual =
  check bool label true (Float.abs (expected -. actual) < 1e-9)
;;

let month_tests =
  [ ( "aggregates resolved spend, distinct turns, and tool classes"
    , `Quick
    , fun () ->
      with_masc_root (fun root ->
          let costs = costs_store root in
          Dated_jsonl.append costs
            (CL.to_json (cost_row ~agent:"polisher" ~turn:1 ~input_tokens:100
                           ~output_tokens:50 ~cost_usd:0.5 Resolved));
          (* The same turn under a resolved attempt reading: the turn stays
             counted once; the attempt's spend adds. *)
          Dated_jsonl.append costs
            (CL.to_json
               (cost_row ~agent:"polisher" ~turn:1 ~input_tokens:10 ~output_tokens:5
                  ~cost_usd:0.1 Resolved_attempt));
          (* A raw turn_total observation: turn 2 counts, its tokens do not. *)
          Dated_jsonl.append costs
            (CL.to_json
               (cost_row ~agent:"polisher" ~turn:2 ~input_tokens:999 ~output_tokens:999
                  ~cost_usd:9.9 Raw_turn_total));
          (* Malformed rows are skipped, as ledger reads skip them. *)
          Dated_jsonl.append costs (`String "not-an-object");
          Dated_jsonl.append costs
            (CL.to_json
               (cost_row ~agent:"sangsu" ~turn:7 ~input_tokens:1 ~output_tokens:2
                  ~cost_usd:0.0 Resolved));
          let tools = tool_store root in
          Dated_jsonl.append tools (tool_row ~keeper:"polisher" ~duration_ms:100.0 ());
          Dated_jsonl.append tools
            (tool_row ~keeper:"polisher" ~disposition:"failed" ~duration_ms:50.0 ());
          Dated_jsonl.append tools (tool_row ~record_kind:"composition_run" ~keeper:"polisher" ());
          Dated_jsonl.append tools (tool_row ~record_kind:"lifecycle_event" ~keeper:"polisher" ());
          Dated_jsonl.append tools (tool_row ~keeper:"sangsu" ~disposition:"deferred" ());
          Dated_jsonl.append tools (tool_row ~keeper:"sangsu" ~disposition:"none" ());
          let view = KE.read_month ~masc_root:root ~month:(today_month ()) |> Result.get_ok in
          check int "days_covered" 1 view.KE.days_covered;
          let polisher = keeper_row view "polisher" |> Option.get in
          check int "polisher turns" 2 polisher.KE.turns;
          check int "polisher input_tokens" 110 polisher.KE.input_tokens;
          check int "polisher output_tokens" 55 polisher.KE.output_tokens;
          near "polisher cost_usd" 0.6 polisher.KE.cost_usd;
          check int "polisher calls" 2 polisher.KE.calls;
          check int "polisher failed" 1 polisher.KE.failed;
          check int "polisher deferred" 0 polisher.KE.deferred;
          near "polisher tool_ms" 150.0 polisher.KE.tool_ms;
          let sangsu = keeper_row view "sangsu" |> Option.get in
          check int "sangsu turns" 1 sangsu.KE.turns;
          check int "sangsu calls" 2 sangsu.KE.calls;
          check int "sangsu deferred" 1 sangsu.KE.deferred;
          check int "fleet turns_total" 3 view.KE.fleet.KE.turns_total;
          near "fleet calls_per_turn" (4.0 /. 3.0) view.KE.fleet.KE.calls_per_turn) )
  ; ( "appended rows count once across calls; a shrunk day file rebuilds"
    , `Quick
    , fun () ->
      with_masc_root (fun root ->
          let costs = costs_store root in
          Dated_jsonl.append costs
            (CL.to_json (cost_row ~agent:"polisher" ~turn:1 ~input_tokens:1
                           ~output_tokens:1 ~cost_usd:0.0 Resolved));
          let tools = tool_store root in
          Dated_jsonl.append tools (tool_row ~keeper:"polisher" ());
          let first = KE.read_month ~masc_root:root ~month:(today_month ()) |> Result.get_ok in
          check int "first turns" 1 ((keeper_row first "polisher" |> Option.get).KE.turns);
          check int "first calls" 1 ((keeper_row first "polisher" |> Option.get).KE.calls);
          (* Growth: the second call reads only the appended tail. *)
          Dated_jsonl.append costs
            (CL.to_json (cost_row ~agent:"polisher" ~turn:2 ~input_tokens:1
                           ~output_tokens:1 ~cost_usd:0.0 Resolved));
          Dated_jsonl.append tools (tool_row ~keeper:"polisher" ());
          let second = KE.read_month ~masc_root:root ~month:(today_month ()) |> Result.get_ok in
          check int "second turns" 2 ((keeper_row second "polisher" |> Option.get).KE.turns);
          check int "second calls" 2 ((keeper_row second "polisher" |> Option.get).KE.calls);
          (* Rewrite: the day file shrinks below the cached boundary, so the
             day is recomputed from zero instead of double-counting. *)
          Fs_compat.save_file
            (today_day_file (Filename.concat root "costs"))
            (Yojson.Safe.to_string
               (CL.to_json
                  (cost_row ~agent:"polisher" ~turn:9 ~input_tokens:1 ~output_tokens:1
                     ~cost_usd:0.0 Resolved))
             ^ "\n");
          Fs_compat.save_file
            (today_day_file (Filename.concat root "tool_calls"))
            (Yojson.Safe.to_string (tool_row ~keeper:"polisher" ()) ^ "\n");
          let third = KE.read_month ~masc_root:root ~month:(today_month ()) |> Result.get_ok in
          check int "after rewrite turns" 1
            ((keeper_row third "polisher" |> Option.get).KE.turns);
          check int "after rewrite calls" 1
            ((keeper_row third "polisher" |> Option.get).KE.calls);
          (* Removal: deleting the day file invalidates the cached day
             boundary and recomputes the day from the remaining files. *)
          Sys.remove (today_day_file (Filename.concat root "costs"));
          Sys.remove (today_day_file (Filename.concat root "tool_calls"));
          let fourth = KE.read_month ~masc_root:root ~month:(today_month ()) |> Result.get_ok in
          check int "after removal days_covered" 0 fourth.KE.days_covered;
          check int "after removal keepers" 0 (List.length fourth.KE.keepers)) )
  ; ( "a corrupt cache rebuilds from the ledgers"
    , `Quick
    , fun () ->
      with_masc_root (fun root ->
          let costs = costs_store root in
          Dated_jsonl.append costs
            (CL.to_json (cost_row ~agent:"polisher" ~turn:1 ~input_tokens:5
                           ~output_tokens:6 ~cost_usd:0.25 Resolved));
          let tools = tool_store root in
          Dated_jsonl.append tools (tool_row ~keeper:"polisher" ~duration_ms:10.0 ());
          let (_ : KE.month_view) = KE.read_month ~masc_root:root ~month:(today_month ()) |> Result.get_ok in
          let cache = KE.cache_path ~masc_root:root ~month:(today_month ()) |> Result.get_ok in
          Fs_compat.save_file cache "{ not json";
          let view = KE.read_month ~masc_root:root ~month:(today_month ()) |> Result.get_ok in
          let row = keeper_row view "polisher" |> Option.get in
          check int "rebuilt turns" 1 row.KE.turns;
          check int "rebuilt input_tokens" 5 row.KE.input_tokens;
          check int "rebuilt calls" 1 row.KE.calls;
          (* A structurally partial cache (valid turn_ids and today's day, but
             corrupted or missing cursor lists for a ledger whose totals are
             present) must rebuild from zero rather than folding from offset 0
             on top of the cached keeper totals. *)
          let day_num = (Unix.gmtime (Unix.time ())).Unix.tm_mday in
          let tool_path = today_day_file (Filename.concat root "tool_calls") in
          let tool_size = (Unix.stat tool_path).Unix.st_size in
          let broken_cursors =
            Printf.sprintf
              {|{"schema":"masc.keeper-efficiency-cache/v1","month":%S,"days":[{"day":%d,"section":{"day":%d,"costs_cursors":"corrupt","tool_cursors":[{"path":%S,"boundary":%d}],"turn_ids":[{"agent":"polisher","turn":1}],"keepers":[{"keeper":"polisher","turns":1,"input_tokens":5,"output_tokens":6,"cost_usd":0.25,"calls":1,"failed":0,"deferred":0,"tool_ms":10.0}]}}]}|}
              (today_month ()) day_num day_num tool_path tool_size
          in
          Fs_compat.save_file cache broken_cursors;
          let view_after_corrupt =
            KE.read_month ~masc_root:root ~month:(today_month ()) |> Result.get_ok
          in
          let row_after_corrupt = keeper_row view_after_corrupt "polisher" |> Option.get in
          check int "corrupt cursor does not double-count input_tokens" 5
            row_after_corrupt.KE.input_tokens;
          (* Missing only one ledger's cursor list while retaining both ledgers'
             totals must also be rejected and rebuilt instead of replaying the
             cursorless ledger on top of cached totals. *)
          let missing_cost_cursor_only =
            Printf.sprintf
              {|{"schema":"masc.keeper-efficiency-cache/v1","month":%S,"days":[{"day":%d,"section":{"day":%d,"costs_cursors":[],"tool_cursors":[{"path":%S,"boundary":%d}],"turn_ids":[{"agent":"polisher","turn":1}],"keepers":[{"keeper":"polisher","turns":1,"input_tokens":5,"output_tokens":6,"cost_usd":0.25,"calls":1,"failed":0,"deferred":0,"tool_ms":10.0}]}}]}|}
              (today_month ()) day_num day_num tool_path tool_size
          in
          Fs_compat.save_file cache missing_cost_cursor_only;
          let view_after_missing_one =
            KE.read_month ~masc_root:root ~month:(today_month ()) |> Result.get_ok
          in
          let row_after_missing_one =
            keeper_row view_after_missing_one "polisher" |> Option.get
          in
          check int "empty cost cursor with cost state does not double-count" 5
            row_after_missing_one.KE.input_tokens;
          check int "tool calls stay single-counted" 1
            row_after_missing_one.KE.calls;
          (* A section with positive cost cursors and keepers[].turns = 1 whose
             turn_ids were corrupted to [] must also be rejected and rebuilt so
             a subsequent attempt for turn 1 does not double-count turns. *)
          let cost_path = today_day_file (Filename.concat root "costs") in
          let cost_size = (Unix.stat cost_path).Unix.st_size in
          let empty_turn_ids_with_turn =
            Printf.sprintf
              {|{"schema":"masc.keeper-efficiency-cache/v1","month":%S,"days":[{"day":%d,"section":{"day":%d,"costs_cursors":[{"path":%S,"boundary":%d}],"tool_cursors":[{"path":%S,"boundary":%d}],"turn_ids":[],"keepers":[{"keeper":"polisher","turns":1,"input_tokens":5,"output_tokens":6,"cost_usd":0.25,"calls":1,"failed":0,"deferred":0,"tool_ms":10.0}]}}]}|}
              (today_month ()) day_num day_num cost_path cost_size tool_path tool_size
          in
          Fs_compat.save_file cache empty_turn_ids_with_turn;
          Dated_jsonl.append costs
            (CL.to_json (cost_row ~agent:"polisher" ~turn:1 ~attempt:1
                           ~input_tokens:3 ~output_tokens:4 ~cost_usd:0.15 Resolved));
          let view_after_turn_id_mismatch =
            KE.read_month ~masc_root:root ~month:(today_month ()) |> Result.get_ok
          in
          let row_after_turn_id_mismatch =
            keeper_row view_after_turn_id_mismatch "polisher" |> Option.get
          in
          check int "rebuilt turn_ids deduplicates same turn across attempts" 1
            row_after_turn_id_mismatch.KE.turns;
          check int "both attempts' input_tokens summed" 8
            row_after_turn_id_mismatch.KE.input_tokens) )
  ; ( "negative or overflowing tool duration is clamped so TUI decoder accepts month_view_to_json"
    , `Quick
    , fun () ->
      with_masc_root (fun root ->
          let tools = tool_store root in
          Dated_jsonl.append tools (tool_row ~keeper:"polisher" ~duration_ms:(-25.0) ());
          let view = KE.read_month ~masc_root:root ~month:(today_month ()) |> Result.get_ok in
          let row = keeper_row view "polisher" |> Option.get in
          near "negative duration clamped to 0" 0.0 row.KE.tool_ms;
          check bool "TUI decoder accepts view json" true
            (Result.is_ok
               (Masc.Tui_decode_keeper_efficiency.of_json (KE.month_view_to_json view)));
          Dated_jsonl.append tools (tool_row ~keeper:"polisher" ~duration_ms:1e308 ());
          Dated_jsonl.append tools (tool_row ~keeper:"polisher" ~duration_ms:1e308 ());
          let view_overflow =
            KE.read_month ~masc_root:root ~month:(today_month ()) |> Result.get_ok
          in
          let row_overflow = keeper_row view_overflow "polisher" |> Option.get in
          check bool "overflowing tool_ms saturates to finite float" true
            (Float.is_finite row_overflow.KE.tool_ms);
          check bool "TUI decoder accepts saturated view json" true
            (Result.is_ok
               (Masc.Tui_decode_keeper_efficiency.of_json
                  (KE.month_view_to_json view_overflow)))) )
  ; ( "invalid month is an error; empty ledgers are an empty view"
    , `Quick
    , fun () ->
      with_masc_root (fun root ->
          check bool "invalid month errors" true
            (Result.is_error (KE.read_month ~masc_root:root ~month:"2026-13"));
          let view = KE.read_month ~masc_root:root ~month:(today_month ()) |> Result.get_ok in
          check int "empty view keepers" 0 (List.length view.KE.keepers);
          check int "empty view days" 0 view.KE.days_covered;
          check int "empty fleet turns" 0 view.KE.fleet.KE.turns_total) )
  ; ( "view json carries the response schema"
    , `Quick
    , fun () ->
      with_masc_root (fun root ->
          let view = KE.read_month ~masc_root:root ~month:(today_month ()) |> Result.get_ok in
          match KE.month_view_to_json view with
          | `Assoc fields ->
            (match List.assoc_opt "schema" fields with
             | Some (`String schema) ->
               check string "view schema" "masc.keeper-efficiency/v1" schema
             | other ->
               Alcotest.failf "unexpected schema member: %s"
                 (Yojson.Safe.to_string (Option.value other ~default:`Null)))
          | other ->
            Alcotest.failf "unexpected view json: %s" (Yojson.Safe.to_string other)) )
  ; ( "record_kind strings stay pinned to the ledger's own classifier"
    , `Quick
    , fun () ->
      let classified s expected =
        match (Masc.Keeper_tool_call_log.record_kind_of_string s, expected) with
        | Some Masc.Keeper_tool_call_log.Tool_call, "tool_call" -> true
        | Some Masc.Keeper_tool_call_log.Composition_run, "composition_run" -> true
        | Some Masc.Keeper_tool_call_log.Lifecycle_event, "lifecycle_event" -> true
        | _ -> false
      in
      check bool "tool_call" true (classified "tool_call" "tool_call");
      check bool "composition_run" true (classified "composition_run" "composition_run");
      check bool "lifecycle_event" true (classified "lifecycle_event" "lifecycle_event") )
  ]

let () = run "Keeper_efficiency" [ ("month", month_tests) ]
