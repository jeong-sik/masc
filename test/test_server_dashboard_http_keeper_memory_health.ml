(** Regression tests for current Memory OS fleet-health projection. *)

module Types = Masc.Keeper_memory_os_types
module Current = Masc.Keeper_memory_os_current
module Metrics = Masc.Otel_metric_store
module KeeperMetrics = Keeper_metrics
module Health = Server_dashboard_http_keeper_memory_health

let test_now = 1_700_000_000.0
let fresh_dir prefix = Filename.temp_dir prefix ""

let fact ?(claim_id = "fact") claim : Types.fact =
  { claim
  ; category = Types.Fact
  ; source = { trace_id = "health-test"; turn = 1; tool_call_id = None }
  ; first_seen = test_now
  ; last_verified_at = Some test_now
  ; claim_id = Some claim_id
  }
;;

let source =
  { Current.kind = Current.Librarian
  ; trace_id = "health-test"
  ; generation = 1
  }
;;

let require_ok = function
  | Ok value -> value
  | Error detail -> Alcotest.fail detail
;;

let write_snapshot ~keepers_dir ~keeper_id facts =
  Fs_compat.mkdir_p keepers_dir;
  let expected_revision =
    match Current.read_for_keepers_dir ~keepers_dir ~keeper_id with
    | Ok None -> None
    | Ok (Some snapshot) -> Some snapshot.revision
    | Error detail -> Alcotest.fail detail
  in
  Current.replace
    ~keepers_dir
    ~keeper_id
    ~expected_revision
    ~now:test_now
    ~source
    ~summary:"current memory"
    ~facts
    ~open_items:[]
    ~constraints:[]
    ~preserved_tool_refs:[]
    ()
  |> require_ok
;;

let assoc_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let int_field name json =
  match assoc_field name json with
  | Some (`Int n) -> n
  | _ -> Alcotest.failf "expected int field %S" name
;;

let float_field name json =
  match assoc_field name json with
  | Some (`Float f) -> f
  | Some (`Int n) -> float_of_int n
  | _ -> Alcotest.failf "expected float field %S" name
;;

let string_field name json =
  match assoc_field name json with
  | Some (`String s) -> s
  | _ -> Alcotest.failf "expected string field %S" name
;;

let list_field name json =
  match assoc_field name json with
  | Some (`List xs) -> xs
  | _ -> Alcotest.failf "expected list field %S" name
;;

let totals json =
  match assoc_field "totals" json with
  | Some value -> value
  | None -> Alcotest.fail "expected totals object"
;;

let alert_summary json =
  match assoc_field "alert_summary" json with
  | Some value -> value
  | None -> Alcotest.fail "expected alert_summary object"
;;

let keeper_ids json =
  list_field "keepers" json
  |> List.filter_map (fun keeper ->
    match assoc_field "keeper_id" keeper with
    | Some (`String id) -> Some id
    | _ -> None)
;;

let keeper_obj id json =
  match
    list_field "keepers" json
    |> List.find_opt (fun keeper ->
      match assoc_field "keeper_id" keeper with
      | Some (`String candidate) -> String.equal id candidate
      | _ -> false)
  with
  | Some keeper -> keeper
  | None -> Alcotest.failf "keeper %S missing" id
;;

let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv name (Option.value old ~default:"");
      Config_dir_resolver.reset ())
    f
;;

let test_uses_explicit_base_path_not_ambient_resolver () =
  let target_base = fresh_dir "masc-memory-health-target" in
  let ambient_base = fresh_dir "masc-memory-health-ambient" in
  let target_keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:target_base
  in
  let ambient_keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:ambient_base
  in
  ignore
    (write_snapshot
       ~keepers_dir:target_keepers_dir
       ~keeper_id:"target"
       [ fact "target fact" ]);
  ignore
    (write_snapshot
       ~keepers_dir:ambient_keepers_dir
       ~keeper_id:"ambient"
       [ fact "ambient fact" ]);
  with_env "MASC_BASE_PATH" ambient_base (fun () ->
    let json = Health.keeper_memory_health_http_json ~base_path:target_base in
    Alcotest.(check (list string)) "explicit base path" [ "target" ] (keeper_ids json))
;;

let test_reports_revision_snapshot_bytes_and_latest_delta () =
  let base = fresh_dir "masc-memory-health-current" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  let first = fact ~claim_id:"a" "A" in
  let changed = fact ~claim_id:"a" "A revised" in
  let second = fact ~claim_id:"b" "B" in
  ignore (write_snapshot ~keepers_dir ~keeper_id:"solo" [ first ]);
  ignore (write_snapshot ~keepers_dir ~keeper_id:"solo" [ changed; second ]);
  let json = Health.keeper_memory_health_http_json ~base_path:base in
  let keeper = keeper_obj "solo" json in
  Alcotest.(check string)
    "schema"
    "keeper.memory_os.current_health.v1"
    (string_field "schema" json);
  Alcotest.(check int) "revision" 2 (int_field "revision" keeper);
  Alcotest.(check int) "facts" 2 (int_field "facts" keeper);
  Alcotest.(check bool) "snapshot bytes" true (int_field "snapshot_bytes" keeper > 0);
  Alcotest.(check int) "added" 2 (int_field "added" keeper);
  Alcotest.(check int) "removed" 1 (int_field "removed" keeper);
  Alcotest.(check int) "no alerts" 0 (List.length (list_field "alerts" keeper));
  Alcotest.(check int) "total facts" 2 (int_field "facts" (totals json));
  Alcotest.(check bool) "generated_at" true (float_field "generated_at" json >= 0.0)
;;

let test_reports_librarian_lane_busy_alert () =
  let base = fresh_dir "masc-memory-health-lane" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  let keeper_id = "lane-" ^ Filename.basename base in
  ignore (write_snapshot ~keepers_dir ~keeper_id [ fact "lane fact" ]);
  Metrics.inc_counter
    KeeperMetrics.(to_string MemoryLaneCoalesced)
    ~labels:[ "keeper", keeper_id; "lane", "librarian" ]
    ~delta:3.0
    ();
  let json = Health.keeper_memory_health_http_json ~base_path:base in
  let keeper = keeper_obj keeper_id json in
  Alcotest.(check int) "busy count" 3 (int_field "librarian_lane_busy" keeper);
  let alerts = list_field "alerts" keeper in
  Alcotest.(check (list string))
    "alert code"
    [ "librarian_lane_busy" ]
    (List.map (string_field "code") alerts);
  Alcotest.(check int)
    "summary busy keepers"
    1
    (int_field "librarian_lane_busy_keepers" (alert_summary json))
;;

let test_corrupt_snapshot_is_visible_as_read_error () =
  let base = fresh_dir "masc-memory-health-corrupt" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  ignore (write_snapshot ~keepers_dir ~keeper_id:"good" [ fact "good fact" ]);
  let broken_path =
    Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"broken"
  in
  Fs_compat.save_file broken_path {|{"schema":"wrong"}|};
  let json = Health.keeper_memory_health_http_json ~base_path:base in
  Alcotest.(check (list string))
    "both keepers stay visible"
    [ "broken"; "good" ]
    (keeper_ids json |> List.sort String.compare);
  let broken = keeper_obj "broken" json in
  Alcotest.(check (list string))
    "read alert"
    [ "snapshot_read_error" ]
    (list_field "alerts" broken |> List.map (string_field "code"));
  Alcotest.(check int) "total read errors" 1 (int_field "read_errors" (totals json))
;;

let test_sorts_by_snapshot_bytes_and_handles_empty_store () =
  let base = fresh_dir "masc-memory-health-sort" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  ignore (write_snapshot ~keepers_dir ~keeper_id:"small" [ fact "x" ]);
  ignore
    (write_snapshot
       ~keepers_dir
       ~keeper_id:"large"
       [ fact ~claim_id:"a" "a much longer current memory claim"
       ; fact ~claim_id:"b" "another much longer current memory claim"
       ]);
  let json = Health.keeper_memory_health_http_json ~base_path:base in
  Alcotest.(check (list string))
    "largest snapshot first"
    [ "large"; "small" ]
    (keeper_ids json);
  let empty_base = fresh_dir "masc-memory-health-empty" in
  let empty = Health.keeper_memory_health_http_json ~base_path:empty_base in
  Alcotest.(check (list string)) "empty keepers" [] (keeper_ids empty);
  Alcotest.(check int) "empty bytes" 0 (int_field "snapshot_bytes" (totals empty))
;;

let () =
  Alcotest.run
    "server_dashboard_http_keeper_memory_health"
    [ ( "current snapshot"
      , [ Alcotest.test_case "explicit base path" `Quick
            test_uses_explicit_base_path_not_ambient_resolver
        ; Alcotest.test_case "revision bytes and delta" `Quick
            test_reports_revision_snapshot_bytes_and_latest_delta
        ; Alcotest.test_case "librarian lane busy alert" `Quick
            test_reports_librarian_lane_busy_alert
        ; Alcotest.test_case "corrupt snapshot visible" `Quick
            test_corrupt_snapshot_is_visible_as_read_error
        ; Alcotest.test_case "sort and empty store" `Quick
            test_sorts_by_snapshot_bytes_and_handles_empty_store
        ] )
    ]
;;
