(** Regression tests for the keeper memory-health dashboard helper. *)

module Types = Masc.Keeper_memory_os_types
module Io = Masc.Keeper_memory_os_io
module Health = Server_dashboard_http_keeper_memory_health

let test_now = 1_700_000_000.0

(* [Filename.temp_dir] creates the directory atomically. The prior
   temp_file -> remove -> mkdir form left a TOCTOU window where another process
   could claim the path between the remove and the mkdir, which would flake this
   regression gate. *)
let fresh_dir prefix = Filename.temp_dir prefix ""

let fact ?(valid_until = None) ~now claim =
  { Types.claim
  ; Types.category = Types.Fact
  ; Types.claim_kind = None
  ; Types.source = { Types.trace_id = "health-test"; Types.turn = 1; Types.tool_call_id = None }
  ; Types.observed_by = []
  ; Types.first_seen = now
  ; Types.valid_until
  ; Types.last_verified_at = Some now
  ; Types.schema_version = Types.schema_version
  ; Types.claim_id = None
  }
;;

let keeper_ids json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "keepers" fields with
     | Some (`List keepers) ->
       List.filter_map
         (function
           | `Assoc keeper_fields ->
             (match List.assoc_opt "keeper_id" keeper_fields with
              | Some (`String id) -> Some id
              | _ -> None)
           | _ -> None)
         keepers
     | _ -> [])
  | _ -> []
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
  | Some t -> t
  | None -> Alcotest.fail "expected totals object"
;;

let alert_summary json =
  match assoc_field "alert_summary" json with
  | Some s -> s
  | None -> Alcotest.fail "expected alert_summary object"
;;

let keeper_obj id json =
  let keepers =
    match assoc_field "keepers" json with
    | Some (`List ks) -> ks
    | _ -> []
  in
  match
    List.find_opt
      (fun k ->
        match assoc_field "keeper_id" k with
        | Some (`String s) -> String.equal s id
        | _ -> false)
      keepers
  with
  | Some k -> k
  | None -> Alcotest.failf "keeper %S not present in snapshot" id
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
  Eio_main.run
  @@ fun _env ->
  let now = test_now in
  let target_base = fresh_dir "masc-memory-health-target" in
  let ambient_base = fresh_dir "masc-memory-health-ambient" in
  let target_keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:target_base
  in
  let ambient_keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:ambient_base
  in
  Io.rewrite_facts_atomically_for_keepers_dir
    ~keepers_dir:target_keepers_dir
    ~keeper_id:"target"
    [ fact ~now "target workspace fact" ];
  Io.rewrite_facts_atomically_for_keepers_dir
    ~keepers_dir:ambient_keepers_dir
    ~keeper_id:"ambient"
    [ fact ~now "ambient workspace fact" ];
  with_env "MASC_BASE_PATH" ambient_base (fun () ->
    let json = Health.keeper_memory_health_http_json ~base_path:target_base in
    Alcotest.(check (list string)) "explicit base-path keeper ids" [ "target" ] (keeper_ids json))
;;

(* The route computes [now] internally from the wall clock, so the dry-run GC
   TTL check runs against the real current time. Fact horizons are therefore
   pinned to the extremes — far past (always expired) or far future (always
   live) — to stay deterministic without a clock seam. *)

let test_reports_per_keeper_metric_values () =
  Eio_main.run
  @@ fun _env ->
  let now = test_now in
  let base = fresh_dir "masc-memory-health-metrics" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  Io.rewrite_facts_atomically_for_keepers_dir
    ~keepers_dir
    ~keeper_id:"solo"
    [ fact ~now "alpha durable note one"
    ; fact
        ~now
        (* Far-future horizon: serialized [valid_until] is preserved on read,
           so this stays live regardless of the wall clock. *)
        ~valid_until:(Some (now +. 1e12))
        "beta tagged row two"
    ];
  let json = Health.keeper_memory_health_http_json ~base_path:base in
  let k = keeper_obj "solo" json in
  Alcotest.(check int) "facts counted" 2 (int_field "facts" k);
  Alcotest.(check bool) "facts_bytes positive" true (int_field "facts_bytes" k > 0);
  Alcotest.(check int) "no events file: events 0" 0 (int_field "events" k);
  Alcotest.(check int) "no events file: events_bytes 0" 0 (int_field "events_bytes" k);
  Alcotest.(check (float 1e-9))
    "ratio 0 when no events"
    0.0
    (float_field "events_to_facts_ratio" k);
  Alcotest.(check int) "nothing expired" 0 (int_field "ttl_expired_on_disk" k);
  Alcotest.(check int) "no duplicates" 0 (int_field "near_duplicate" k);
  Alcotest.(check int) "no keeper alerts" 0 (List.length (list_field "alerts" k));
  Alcotest.(check int) "totals.facts" 2 (int_field "facts" (totals json));
  Alcotest.(check bool)
    "totals.facts_bytes positive"
    true
    (int_field "facts_bytes" (totals json) > 0);
  Alcotest.(check bool)
    "cadence_counter_entries non-negative"
    true
    (int_field "cadence_counter_entries" json >= 0);
  Alcotest.(check bool)
    "generated_at is present as wall-clock float"
    true
    (float_field "generated_at" json >= 0.0)
;;

let test_health_reports_expiry_and_exact_duplicate_identity () =
  Eio_main.run
  @@ fun _env ->
  let now = test_now in
  let base = fresh_dir "masc-memory-health-gc" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  Io.rewrite_facts_atomically_for_keepers_dir
    ~keepers_dir
    ~keeper_id:"gc"
    [ fact ~now "shared claim row"
    ; fact ~now "shared claim row" (* exact same observation identity *)
    ; fact ~now ~valid_until:(Some (now -. 1.0)) "expired horizon row" (* past TTL *)
    ; fact ~now "live durable row"
    ];
  let json = Health.keeper_memory_health_http_json ~base_path:base in
  let k = keeper_obj "gc" json in
  Alcotest.(check int) "all rows counted on disk" 4 (int_field "facts" k);
  Alcotest.(check int) "one TTL-expired row" 1 (int_field "ttl_expired_on_disk" k);
  Alcotest.(check int) "one duplicate row" 1 (int_field "near_duplicate" k);
  let alerts = list_field "alerts" k in
  Alcotest.(check int) "two keeper alerts" 2 (List.length alerts);
  Alcotest.(check (list string))
    "alert codes"
    [ "ttl_expired_on_disk"; "near_duplicate" ]
    (List.map (string_field "code") alerts);
  Alcotest.(check (list string))
    "alert targets"
    [ "ttl_expired_on_disk"; "near_duplicate" ]
    (List.map (string_field "target") alerts);
  Alcotest.(check (list string))
    "alert labels"
    [ "TTL"; "중복" ]
    (List.map (string_field "label") alerts);
  let summary = alert_summary json in
  Alcotest.(check int) "summary total alerts" 2 (int_field "total_alerts" summary);
  Alcotest.(check int) "summary warn alerts" 2 (int_field "warn_alerts" summary);
  Alcotest.(check int) "summary keepers with alerts" 1 (int_field "keepers_with_alerts" summary);
  Alcotest.(check int) "summary ttl keepers" 1 (int_field "ttl_expired_keepers" summary);
  Alcotest.(check int) "summary duplicate keepers" 1 (int_field "near_duplicate_keepers" summary);
  (* dry_run must NOT rewrite the store: a fresh read still sees all 4 rows. *)
  let reread = Io.read_facts_all_for_keepers_dir ~keepers_dir ~keeper_id:"gc" in
  Alcotest.(check int) "store untouched by dry-run gc" 4 (List.length reread)
;;

let test_sorts_keepers_by_facts_bytes_desc () =
  Eio_main.run
  @@ fun _env ->
  let now = test_now in
  let base = fresh_dir "masc-memory-health-sort" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  Io.rewrite_facts_atomically_for_keepers_dir ~keepers_dir ~keeper_id:"small" [ fact ~now "x" ];
  Io.rewrite_facts_atomically_for_keepers_dir
    ~keepers_dir
    ~keeper_id:"large"
    [ fact ~now "a much longer durable claim row number one"
    ; fact ~now "a much longer durable claim row number two"
    ; fact ~now "a much longer durable claim row number three"
    ];
  let json = Health.keeper_memory_health_http_json ~base_path:base in
  Alcotest.(check (list string))
    "largest facts_bytes first"
    [ "large"; "small" ]
    (keeper_ids json)
;;

let test_empty_store_has_no_keepers_and_zero_totals () =
  Eio_main.run
  @@ fun _env ->
  let base = fresh_dir "masc-memory-health-empty" in
  let json = Health.keeper_memory_health_http_json ~base_path:base in
  Alcotest.(check (list string)) "no keepers" [] (keeper_ids json);
  Alcotest.(check int) "totals.facts zero" 0 (int_field "facts" (totals json));
  Alcotest.(check int) "totals.facts_bytes zero" 0 (int_field "facts_bytes" (totals json))
;;

let test_skips_corrupt_jsonl_keeper () =
  Eio_main.run
  @@ fun _env ->
  let now = test_now in
  let base = fresh_dir "masc-memory-health-corrupt" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  Io.rewrite_facts_atomically_for_keepers_dir
    ~keepers_dir
    ~keeper_id:"good"
    [ fact ~now "valid durable row" ];
  (* A malformed facts.jsonl makes the strict GC read raise; the route must skip
     that keeper rather than abort the whole snapshot (the documented behavior). *)
  let broken_path = Io.facts_path_for_keepers_dir ~keepers_dir ~keeper_id:"broken" in
  Out_channel.with_open_text broken_path (fun oc ->
    Out_channel.output_string oc "{ this is not valid json\n");
  let json = Health.keeper_memory_health_http_json ~base_path:base in
  Alcotest.(check (list string))
    "corrupt keeper skipped, valid one kept"
    [ "good" ]
    (keeper_ids json)
;;

let () =
  Alcotest.run
    "server_dashboard_http_keeper_memory_health"
    [ ( "paths"
      , [ Alcotest.test_case
            "uses explicit request base path instead of ambient resolver"
            `Quick
            test_uses_explicit_base_path_not_ambient_resolver
        ] )
    ; ( "metrics"
      , [ Alcotest.test_case
            "reports per-keeper metric values"
            `Quick
            test_reports_per_keeper_metric_values
        ; Alcotest.test_case
            "dry-run gc reports expired and duplicate rows"
            `Quick
            test_health_reports_expiry_and_exact_duplicate_identity
        ; Alcotest.test_case
            "sorts keepers by facts_bytes descending"
            `Quick
            test_sorts_keepers_by_facts_bytes_desc
        ; Alcotest.test_case
            "empty store yields no keepers and zero totals"
            `Quick
            test_empty_store_has_no_keepers_and_zero_totals
        ; Alcotest.test_case
            "skips a keeper with a corrupt facts.jsonl"
            `Quick
            test_skips_corrupt_jsonl_keeper
        ] )
    ]
