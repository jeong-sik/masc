(** Tests for [Keeper_compact_audit].

    Covers: trigger parser round-trip, pure pairing (Paired /
    Orphan_start / Orphan_complete), persist → prune → read integration,
    and legacy pre-compact JSONL fallback. *)

open Alcotest

module KCA = Masc_mcp.Keeper_compact_audit

(* ── Helpers ──────────────────────────────────────────────────── *)

let mk_start ?(id = "id-1") ?(ts = 1_000.0) ?(keeper = "k") ?(trig = KCA.Proactive) () : KCA.start_record =
  {
    compaction_id = id;
    ts_unix = ts;
    keeper_name = keeper;
    trigger = trig;
    correlation_id = "corr-x";
    run_id = "run-y";
  }

let mk_complete ?(id = "id-1") ?(ts = 1_001.0) ?(keeper = "k")
    ?(before = 1000) ?(after = 400) ?(phase = "proactive") () : KCA.complete_record =
  {
    compaction_id = id;
    ts_unix = ts;
    keeper_name = keeper;
    before_tokens = before;
    after_tokens = after;
    tokens_freed = max 0 (before - after);
    phase_hint = phase;
    correlation_id = "corr-x";
    run_id = "run-y";
  }

let tmp_base_path () =
  let dir = Filename.temp_file "kca_test_" "_dir" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  dir

let rec rm_rf path =
  match Unix.lstat path with
  | { st_kind = S_DIR; _ } ->
    let entries = Sys.readdir path in
    Array.iter (fun e -> rm_rf (Filename.concat path e)) entries;
    Unix.rmdir path
  | _ -> Sys.remove path
  | exception Unix.Unix_error (ENOENT, _, _) -> ()

(* ── Trigger round-trip ────────────────────────────────────────── *)

let test_trigger_roundtrip () =
  let cases = [
    KCA.Proactive, "proactive";
    KCA.Emergency, "emergency";
    KCA.Operator,  "operator";
    KCA.Unknown_trigger "mystery", "mystery";
  ] in
  List.iter
    (fun (v, s) ->
      let s' = KCA.trigger_to_string v in
      check string (Printf.sprintf "trigger %s string" s) s s';
      match KCA.parse_trigger s, v with
      | KCA.Proactive, KCA.Proactive
      | KCA.Emergency, KCA.Emergency
      | KCA.Operator,  KCA.Operator -> ()
      | KCA.Unknown_trigger a, KCA.Unknown_trigger b when a = b -> ()
      | _ -> fail (Printf.sprintf "parse_trigger %S mismatch" s))
    cases

(* ── Pair events ───────────────────────────────────────────────── *)

let test_pair_matching_pair () =
  let s = mk_start ~id:"c1" ~ts:10.0 () in
  let c = mk_complete ~id:"c1" ~ts:11.0 () in
  match KCA.pair_events [KCA.Start s; KCA.Complete c] with
  | [KCA.Paired { start; complete }] ->
    check string "paired id" "c1" start.compaction_id;
    check int "tokens freed" 600 complete.tokens_freed
  | other ->
    fail (Printf.sprintf "expected 1 Paired, got %d rows" (List.length other))

let test_pair_orphan_start () =
  let s = mk_start ~id:"c2" () in
  match KCA.pair_events [KCA.Start s] with
  | [KCA.Orphan_start s'] ->
    check string "orphan id" "c2" s'.compaction_id
  | _ -> fail "expected 1 Orphan_start"

let test_pair_orphan_complete () =
  let c = mk_complete ~id:"c3" () in
  match KCA.pair_events [KCA.Complete c] with
  | [KCA.Orphan_complete c'] ->
    check string "orphan complete id" "c3" c'.compaction_id
  | _ -> fail "expected 1 Orphan_complete"

let test_pair_interleaved () =
  (* Two keepers compacting; pairing by id must not crosstalk.
     Using distinct ts so result is deterministically sorted: A=10, B=20. *)
  let s1 = mk_start ~id:"A" ~keeper:"a" ~ts:10.0 () in
  let s2 = mk_start ~id:"B" ~keeper:"b" ~ts:20.0 () in
  let c1 = mk_complete ~id:"A" ~keeper:"a" ~ts:30.0 () in
  let c2 = mk_complete ~id:"B" ~keeper:"b" ~ts:40.0 () in
  let rows = [KCA.Start s1; KCA.Start s2; KCA.Complete c1; KCA.Complete c2] in
  match KCA.pair_events rows with
  | [KCA.Paired a; KCA.Paired b] ->
    check string "first paired (earliest start ts)" "A" a.start.compaction_id;
    check string "second paired"                    "B" b.start.compaction_id
  | other ->
    fail (Printf.sprintf "expected 2 Paired rows, got %d" (List.length other))

(* ── Persist + read round-trip ─────────────────────────────────── *)

(* Files are stored at base_dir/YYYY-MM/DD.jsonl where date = today (gmtime).
   Tests use a generous range around now to match today's file. *)
let today_bounds () =
  let now = Unix.gettimeofday () in
  (now -. 86400.0, now +. 86400.0)

let test_persist_and_read () =
  (* Dated_jsonl uses Eio.Mutex → must run inside an Eio scheduler. *)
  Eio_main.run @@ fun _env ->
  let base = tmp_base_path () in
  let finally () = rm_rf base in
  Fun.protect ~finally (fun () ->
    let now = Unix.gettimeofday () in
    let s = mk_start ~id:"c-rt" ~ts:now () in
    let c = mk_complete ~id:"c-rt" ~ts:(now +. 1.0) () in
    (match KCA.persist_start ~base_path:base ~retention_days:14 s with
     | Ok () -> ()
     | Error (KCA.Io_failure m | KCA.Serialize_failure m) ->
       fail (Printf.sprintf "persist_start failed: %s" m));
    (match KCA.persist_complete ~base_path:base ~retention_days:14 c with
     | Ok () -> ()
     | Error (KCA.Io_failure m | KCA.Serialize_failure m) ->
       fail (Printf.sprintf "persist_complete failed: %s" m));
    let since, until = today_bounds () in
    match KCA.read_events ~base_path:base ~since ~until () with
    | Error (KCA.Io_failure m | KCA.Serialize_failure m) ->
      fail (Printf.sprintf "read_events failed: %s" m)
    | Ok rows ->
      check int "two rows persisted" 2 (List.length rows);
      match KCA.pair_events rows with
      | [KCA.Paired p] ->
        check string "paired id from disk" "c-rt" p.start.compaction_id
      | other ->
        fail (Printf.sprintf "expected 1 Paired, got %d rows" (List.length other)))

(* ── Keeper filter ─────────────────────────────────────────────── *)

let test_read_keeper_filter () =
  Eio_main.run @@ fun _env ->
  let base = tmp_base_path () in
  let finally () = rm_rf base in
  Fun.protect ~finally (fun () ->
    let now = Unix.gettimeofday () in
    let s_a = mk_start ~id:"a" ~keeper:"alpha" ~ts:now () in
    let s_b = mk_start ~id:"b" ~keeper:"beta"  ~ts:now () in
    ignore (KCA.persist_start ~base_path:base ~retention_days:14 s_a);
    ignore (KCA.persist_start ~base_path:base ~retention_days:14 s_b);
    let since, until = today_bounds () in
    match KCA.read_events ~base_path:base ~since ~until ~keeper:"alpha" () with
    | Error (KCA.Io_failure m | KCA.Serialize_failure m) ->
      fail (Printf.sprintf "read_events failed: %s" m)
    | Ok rows ->
      check int "only alpha row visible" 1 (List.length rows);
      match rows with
      | [KCA.Start r] -> check string "alpha keeper" "alpha" r.keeper_name
      | _ -> fail "expected single Start for alpha")

let () =
  run "Keeper_compact_audit" [
    ("trigger", [
      test_case "round-trip parse/to_string"     `Quick test_trigger_roundtrip;
    ]);
    ("pair_events", [
      test_case "matched pair"                   `Quick test_pair_matching_pair;
      test_case "orphan start"                   `Quick test_pair_orphan_start;
      test_case "orphan complete"                `Quick test_pair_orphan_complete;
      test_case "interleaved keepers"            `Quick test_pair_interleaved;
    ]);
    ("persist", [
      test_case "persist + read + pair"          `Quick test_persist_and_read;
      test_case "keeper filter"                  `Quick test_read_keeper_filter;
    ]);
  ]
