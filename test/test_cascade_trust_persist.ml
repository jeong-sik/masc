(** Unit tests for [Cascade_trust_persist].

    Verifies the snapshot-to-JSONL contract without spinning a real
    fiber: each test creates a temp base_path, mutates the global
    [Cascade_health_tracker] via the public record_* API, calls
    [snapshot_now], then re-reads the JSONL and asserts the shape.

    Test isolation: tests share [Cascade_health_tracker.global], so
    each test uses a unique [provider_key] prefix to avoid cross-talk.
    [reset_for_testing ()] clears the persist module's store cache
    between tests so each gets a fresh [Dated_jsonl.t]. *)

open Alcotest
module H = Masc_mcp.Cascade_health_tracker
module P = Masc_mcp.Cascade_trust_persist

let kind value = H.error_kind_of_string value

let temp_base_path () =
  let dir = Filename.temp_file "cascade-trust-persist-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  dir

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

(* [Dated_jsonl.append] uses [Eio.Mutex] internally, which requires the
   [Cancel.Get_context] effect handler installed by [Eio_main.run].
   Wrap each test in an Eio runtime so [snapshot_now] is callable.
   Production callers spawn from within [Eio.Fiber.fork ~sw], so this
   is a test-environment concern only. *)
let with_temp_base f =
  let dir = temp_base_path () in
  P.reset_for_testing ();
  Fun.protect
    ~finally:(fun () ->
      P.reset_for_testing ();
      rm_rf dir)
    (fun () -> Eio_main.run (fun _env -> f dir))

let read_all_jsonl_in dir : Yojson.Safe.t list =
  let cascade_dir = Filename.concat dir "cascade_trust" in
  if not (Sys.file_exists cascade_dir) then []
  else
    let lines = ref [] in
    let rec walk path =
      if Sys.is_directory path then
        Sys.readdir path
        |> Array.iter (fun name -> walk (Filename.concat path name))
      else if Filename.check_suffix path ".jsonl" then
        let ic = open_in path in
        Fun.protect
          ~finally:(fun () -> close_in_noerr ic)
          (fun () ->
            try
              while true do
                lines := input_line ic :: !lines
              done
            with End_of_file -> ())
    in
    walk cascade_dir;
    List.rev_map Yojson.Safe.from_string !lines

let member key json = Yojson.Safe.Util.member key json

let to_list_exn = function
  | `List xs -> xs
  | _ -> fail "expected JSON list"

let to_string_exn = function
  | `String s -> s
  | _ -> fail "expected JSON string"

(* ── Tests ─────────────────────────────────────── *)

let test_snapshot_writes_jsonl_record () =
  with_temp_base (fun dir ->
    P.snapshot_now ~base_path:dir;
    match read_all_jsonl_in dir with
    | [] -> fail "snapshot_now produced no JSONL record"
    | _ :: _ -> ())

let test_snapshot_record_has_ts_and_providers () =
  with_temp_base (fun dir ->
    P.snapshot_now ~base_path:dir;
    match read_all_jsonl_in dir with
    | [] -> fail "no record"
    | record :: _ ->
      (match member "ts" record with
       | `Float _ -> ()
       | _ -> fail "ts must be float");
      (match member "providers" record with
       | `List _ -> ()
       | _ -> fail "providers must be list"))

let test_snapshot_includes_recorded_provider () =
  with_temp_base (fun dir ->
    let key = "test_persist_includes:" ^ string_of_int (Random.bits ()) in
    H.record_failure H.global ~provider_key:key
      ~error_kind:(kind "failure") ~error_reason:"boom" ();
    P.snapshot_now ~base_path:dir;
    match read_all_jsonl_in dir with
    | [] -> fail "no record"
    | record :: _ ->
      let providers = to_list_exn (member "providers" record) in
      let found =
        List.exists
          (fun p ->
            match member "provider_key" p with
            | `String k -> String.equal k key
            | _ -> false)
          providers
      in
      check bool "recorded provider appears in snapshot" true found)

let test_snapshot_provider_record_shape () =
  with_temp_base (fun dir ->
    let key = "test_persist_shape:" ^ string_of_int (Random.bits ()) in
    H.record_failure H.global ~provider_key:key
      ~error_kind:(kind "timeout") ~error_reason:"deadline" ();
    P.snapshot_now ~base_path:dir;
    match read_all_jsonl_in dir with
    | [] -> fail "no record"
    | record :: _ ->
      let providers = to_list_exn (member "providers" record) in
      match
        List.find_opt
          (fun p ->
            match member "provider_key" p with
            | `String k -> String.equal k key
            | _ -> false)
          providers
      with
      | None -> fail "missing recorded provider"
      | Some p ->
        let required_fields =
          [ "provider_key"
          ; "success_rate"
          ; "consecutive_failures"
          ; "in_cooldown"
          ; "events_in_window"
          ; "rejected_in_window"
          ; "top_fingerprints"
          ; "last_failure_at"
          ; "trust_score"
          ]
        in
        List.iter
          (fun field ->
            match member field p with
            | `Null when field = "last_failure_at" -> ()
            | `Null -> fail (Printf.sprintf "field %s missing" field)
            | _ -> ())
          required_fields;
        let fps = to_list_exn (member "top_fingerprints" p) in
        check bool "top_fingerprints non-empty after failure"
          true (fps <> []);
        match fps with
        | first :: _ ->
          let fp_str = to_string_exn (member "fingerprint" first) in
          check bool "fingerprint kind prefix preserved"
            true
            (String.length fp_str >= String.length "timeout"
             && String.sub fp_str 0 (String.length "timeout") = "timeout")
        | [] -> fail "unreachable")

let test_two_snapshots_produce_two_records () =
  with_temp_base (fun dir ->
    P.snapshot_now ~base_path:dir;
    P.snapshot_now ~base_path:dir;
    let records = read_all_jsonl_in dir in
    check int "two snapshot calls → two JSONL records"
      2 (List.length records))

let test_snapshot_does_not_throw_on_empty_tracker () =
  with_temp_base (fun dir ->
    (* Brand-new tracker scope: even if global has data from earlier
       tests, the call must not raise. *)
    P.snapshot_now ~base_path:dir;
    match read_all_jsonl_in dir with
    | [] -> fail "expected at least one record"
    | _ -> ())

let () =
  Random.self_init ();
  run "cascade_trust_persist"
    [ ( "snapshot"
      , [ test_case "writes a JSONL record" `Quick
            test_snapshot_writes_jsonl_record
        ; test_case "record has ts + providers" `Quick
            test_snapshot_record_has_ts_and_providers
        ; test_case "recorded provider appears" `Quick
            test_snapshot_includes_recorded_provider
        ; test_case "provider record has expected shape" `Quick
            test_snapshot_provider_record_shape
        ; test_case "two calls → two records" `Quick
            test_two_snapshots_produce_two_records
        ; test_case "no throw on empty tracker" `Quick
            test_snapshot_does_not_throw_on_empty_tracker
        ] )
    ]
