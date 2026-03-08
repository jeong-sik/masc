(** test_cache_coherence.ml — Unit tests for MESI cache coherence protocol

    Tests cover:
    - All 16 MESI state transitions
    - L1 cache hit/miss counting
    - Coherent read (L1 → L2 fallback)
    - Coherent write (L1 + invalidation + write-through)
    - LRU eviction
    - Multi-agent snoop behavior
    - Metrics aggregation

    @since Phase 2 — SWARM-RISC *)

open Masc_mcp.Cache_coherence

(* ================================================================ *)
(* Test Helpers                                                      *)
(* ================================================================ *)

let check msg cond =
  if not cond then failwith (Printf.sprintf "FAIL: %s" msg)

let check_eq msg expected actual =
  if expected <> actual then
    failwith (Printf.sprintf "FAIL: %s — expected %s, got %s" msg expected actual)

let check_mesi msg expected actual =
  check_eq msg (mesi_to_string expected) (mesi_to_string actual)

let pass_count = ref 0
let fail_count = ref 0

let run_test name f =
  try
    f ();
    incr pass_count;
    Printf.printf "  ✓ %s\n%!" name
  with e ->
    incr fail_count;
    Printf.printf "  ✗ %s: %s\n%!" name (Printexc.to_string e)

(* ================================================================ *)
(* MESI State Transition Tests (16 transitions)                      *)
(* ================================================================ *)

let test_invalid_local_read () =
  let tr = transition ~current:Invalid ~event:`LocalRead ~agent_id:"a1" ~key:"k" in
  check_mesi "I+Read → E" Exclusive tr.new_state;
  check "bus action is BusRd" (tr.bus_action <> None);
  check "no writeback" (not tr.writeback)

let test_invalid_local_write () =
  let tr = transition ~current:Invalid ~event:`LocalWrite ~agent_id:"a1" ~key:"k" in
  check_mesi "I+Write → M" Modified tr.new_state;
  check "bus action is BusRdX" (tr.bus_action <> None);
  check "no writeback" (not tr.writeback)

let test_shared_local_read () =
  let tr = transition ~current:Shared ~event:`LocalRead ~agent_id:"a1" ~key:"k" in
  check_mesi "S+Read → S" Shared tr.new_state;
  check "no bus action" (tr.bus_action = None);
  check "no writeback" (not tr.writeback)

let test_shared_local_write () =
  let tr = transition ~current:Shared ~event:`LocalWrite ~agent_id:"a1" ~key:"k" in
  check_mesi "S+Write → M" Modified tr.new_state;
  check "bus action is BusInv" (tr.bus_action <> None);
  check "no writeback" (not tr.writeback)

let test_exclusive_local_read () =
  let tr = transition ~current:Exclusive ~event:`LocalRead ~agent_id:"a1" ~key:"k" in
  check_mesi "E+Read → E" Exclusive tr.new_state;
  check "no bus action" (tr.bus_action = None);
  check "no writeback" (not tr.writeback)

let test_exclusive_local_write () =
  let tr = transition ~current:Exclusive ~event:`LocalWrite ~agent_id:"a1" ~key:"k" in
  check_mesi "E+Write → M (silent upgrade)" Modified tr.new_state;
  check "no bus action (silent)" (tr.bus_action = None);
  check "no writeback" (not tr.writeback)

let test_modified_local_read () =
  let tr = transition ~current:Modified ~event:`LocalRead ~agent_id:"a1" ~key:"k" in
  check_mesi "M+Read → M" Modified tr.new_state;
  check "no bus action" (tr.bus_action = None);
  check "no writeback" (not tr.writeback)

let test_modified_local_write () =
  let tr = transition ~current:Modified ~event:`LocalWrite ~agent_id:"a1" ~key:"k" in
  check_mesi "M+Write → M" Modified tr.new_state;
  check "no bus action" (tr.bus_action = None);
  check "no writeback" (not tr.writeback)

let test_modified_snoop_read () =
  let tr = transition ~current:Modified ~event:`SnoopRead ~agent_id:"a1" ~key:"k" in
  check_mesi "M+SnoopRd → S" Shared tr.new_state;
  check "bus action is BusFlush" (tr.bus_action <> None);
  check "writeback required" tr.writeback

let test_exclusive_snoop_read () =
  let tr = transition ~current:Exclusive ~event:`SnoopRead ~agent_id:"a1" ~key:"k" in
  check_mesi "E+SnoopRd → S" Shared tr.new_state;
  check "no writeback (clean)" (not tr.writeback)

let test_shared_snoop_read () =
  let tr = transition ~current:Shared ~event:`SnoopRead ~agent_id:"a1" ~key:"k" in
  check_mesi "S+SnoopRd → S" Shared tr.new_state

let test_invalid_snoop_read () =
  let tr = transition ~current:Invalid ~event:`SnoopRead ~agent_id:"a1" ~key:"k" in
  check_mesi "I+SnoopRd → I" Invalid tr.new_state

let test_modified_snoop_invalidate () =
  let tr = transition ~current:Modified ~event:`SnoopInvalidate ~agent_id:"a1" ~key:"k" in
  check_mesi "M+SnoopInv → I" Invalid tr.new_state;
  check "writeback required (dirty data)" tr.writeback

let test_exclusive_snoop_invalidate () =
  let tr = transition ~current:Exclusive ~event:`SnoopInvalidate ~agent_id:"a1" ~key:"k" in
  check_mesi "E+SnoopInv → I" Invalid tr.new_state;
  check "no writeback (clean)" (not tr.writeback)

let test_shared_snoop_invalidate () =
  let tr = transition ~current:Shared ~event:`SnoopInvalidate ~agent_id:"a1" ~key:"k" in
  check_mesi "S+SnoopInv → I" Invalid tr.new_state

let test_invalid_snoop_invalidate () =
  let tr = transition ~current:Invalid ~event:`SnoopInvalidate ~agent_id:"a1" ~key:"k" in
  check_mesi "I+SnoopInv → I (no-op)" Invalid tr.new_state

(* ================================================================ *)
(* L1 Cache Tests                                                    *)
(* ================================================================ *)

let test_l1_read_miss () =
  let l1 = create_l1 ~capacity:4 "agent-a" in
  let (v, _tr) = l1_read l1 ~key:"missing" in
  check "read miss returns None" (v = None);
  check "miss count is 1" (l1.misses = 1);
  check "hit count is 0" (l1.hits = 0)

let test_l1_write_then_read () =
  let l1 = create_l1 ~capacity:4 "agent-a" in
  let _tr = l1_write l1 ~key:"k1" ~value:"v1" in
  let (v, _tr2) = l1_read l1 ~key:"k1" in
  check "read after write returns Some" (v = Some "v1");
  check "hit count is 1" (l1.hits = 1)

let test_l1_write_state_modified () =
  let l1 = create_l1 ~capacity:4 "agent-a" in
  let tr = l1_write l1 ~key:"k1" ~value:"v1" in
  check_mesi "write on empty → Modified" Modified tr.new_state;
  (* Verify state persisted in the line *)
  match Hashtbl.find_opt l1.lines "k1" with
  | Some line -> check_mesi "line state is Modified" Modified line.state
  | None -> failwith "line not found after write"

let test_l1_eviction () =
  let l1 = create_l1 ~capacity:2 "agent-a" in
  let _ = l1_write l1 ~key:"k1" ~value:"v1" in
  Unix.sleepf 0.01;  (* Ensure different timestamps *)
  let _ = l1_write l1 ~key:"k2" ~value:"v2" in
  Unix.sleepf 0.01;
  let _ = l1_write l1 ~key:"k3" ~value:"v3" in
  (* k1 should have been evicted (oldest) *)
  check "k1 evicted" (Hashtbl.find_opt l1.lines "k1" = None);
  check "k3 present" (Hashtbl.find_opt l1.lines "k3" <> None)

let test_l1_eviction_modified_writeback () =
  let l1 = create_l1 ~capacity:1 "agent-a" in
  let _ = l1_write l1 ~key:"k1" ~value:"v1" in  (* Modified *)
  let _ = l1_write l1 ~key:"k2" ~value:"v2" in  (* Evicts k1 (Modified) → writeback *)
  check "writeback counted" (l1.writebacks = 1)

(* ================================================================ *)
(* Snoop Tests                                                       *)
(* ================================================================ *)

let test_snoop_busrd_on_modified () =
  let l1 = create_l1 ~capacity:4 "agent-a" in
  let _ = l1_write l1 ~key:"k1" ~value:"v1" in  (* Modified *)
  let result = l1_snoop l1 ~msg:(BusRd { key = "k1"; requester = "agent-b" }) in
  match result with
  | Some tr ->
      check_mesi "M → S after snoop read" Shared tr.new_state;
      check "writeback triggered" tr.writeback
  | None -> failwith "snoop should have matched"

let test_snoop_businv_on_shared () =
  let l1 = create_l1 ~capacity:4 "agent-a" in
  let _ = l1_write l1 ~key:"k1" ~value:"v1" in  (* Modified *)
  (* Simulate another agent read → transition to Shared *)
  ignore (l1_snoop l1 ~msg:(BusRd { key = "k1"; requester = "agent-b" }));
  (* Now snoop invalidate *)
  let result = l1_snoop l1 ~msg:(BusInv { key = "k1"; invalidator = "agent-b" }) in
  match result with
  | Some tr ->
      check_mesi "S → I after snoop invalidate" Invalid tr.new_state;
      check "invalidation counted" (l1.invalidations >= 1)
  | None -> failwith "snoop should have matched"

let test_snoop_on_absent_key () =
  let l1 = create_l1 ~capacity:4 "agent-a" in
  let result = l1_snoop l1 ~msg:(BusRd { key = "unknown"; requester = "agent-b" }) in
  check "snoop on absent key returns None" (result = None)

(* ================================================================ *)
(* Coherence Controller Tests                                        *)
(* ================================================================ *)

let test_controller_register () =
  let ctrl = create_controller () in
  register_agent ctrl ~capacity:8 "a1";
  register_agent ctrl ~capacity:8 "a2";
  check "two agents registered" (Hashtbl.length ctrl.agents = 2)

let test_coherent_read_l1_miss_l2_hit () =
  let ctrl = create_controller () in
  register_agent ctrl "a1";
  let l2_data = Hashtbl.create 4 in
  Hashtbl.replace l2_data "k1" "from-l2";
  let l2_fetch key = Hashtbl.find_opt l2_data key in
  let result = coherent_read ctrl ~agent_id:"a1" ~key:"k1" ~l2_fetch in
  check "L1 miss, L2 hit returns value" (result = Some "from-l2");
  (* Second read should hit L1 *)
  let result2 = coherent_read ctrl ~agent_id:"a1" ~key:"k1" ~l2_fetch in
  check "second read hits L1" (result2 = Some "from-l2");
  match Hashtbl.find_opt ctrl.agents "a1" with
  | Some l1 -> check "L1 hit count is 1" (l1.hits = 1)
  | None -> failwith "agent not found"

let test_coherent_read_l1_hit () =
  let ctrl = create_controller () in
  register_agent ctrl "a1";
  let l2_write _k _v = () in
  coherent_write ctrl ~agent_id:"a1" ~key:"k1" ~value:"direct" ~l2_write;
  let l2_fetch _key = None in
  let result = coherent_read ctrl ~agent_id:"a1" ~key:"k1" ~l2_fetch in
  check "L1 hit returns value" (result = Some "direct")

let test_coherent_write_invalidates_others () =
  let ctrl = create_controller () in
  register_agent ctrl "a1";
  register_agent ctrl "a2";
  let l2 = Hashtbl.create 4 in
  let l2_write k v = Hashtbl.replace l2 k v in
  let l2_fetch k = Hashtbl.find_opt l2 k in
  (* a1 writes k1 *)
  coherent_write ctrl ~agent_id:"a1" ~key:"k1" ~value:"v1" ~l2_write;
  (* a2 reads k1 from L2 *)
  let _ = coherent_read ctrl ~agent_id:"a2" ~key:"k1" ~l2_fetch in
  (* a1 writes k1 again → should invalidate a2's copy *)
  coherent_write ctrl ~agent_id:"a1" ~key:"k1" ~value:"v2" ~l2_write;
  (* Check a2's L1 state *)
  let state = get_line_state ctrl ~agent_id:"a2" ~key:"k1" in
  check "a2's k1 invalidated" (state = Some Invalid)

let test_coherent_write_through_to_l2 () =
  let ctrl = create_controller () in
  register_agent ctrl "a1";
  let l2 = Hashtbl.create 4 in
  let l2_write k v = Hashtbl.replace l2 k v in
  coherent_write ctrl ~agent_id:"a1" ~key:"k1" ~value:"written" ~l2_write;
  check "write-through to L2" (Hashtbl.find_opt l2 "k1" = Some "written")

let test_unregistered_agent_falls_through () =
  let ctrl = create_controller () in
  let l2 = Hashtbl.create 4 in
  Hashtbl.replace l2 "k1" "l2-val";
  let l2_fetch k = Hashtbl.find_opt l2 k in
  let result = coherent_read ctrl ~agent_id:"unknown" ~key:"k1" ~l2_fetch in
  check "unregistered agent falls through to L2" (result = Some "l2-val")

(* ================================================================ *)
(* Metrics Tests                                                     *)
(* ================================================================ *)

let test_agent_metrics () =
  let ctrl = create_controller () in
  register_agent ctrl "a1";
  let l2_write _k _v = () in
  let l2_fetch _k = None in
  coherent_write ctrl ~agent_id:"a1" ~key:"k1" ~value:"v1" ~l2_write;
  let _ = coherent_read ctrl ~agent_id:"a1" ~key:"k1" ~l2_fetch in
  match agent_metrics ctrl "a1" with
  | Some m ->
      check "hit rate > 0" (m.l1_hit_rate > 0.0);
      check "total_reads >= 1" (m.total_reads >= 1)
  | None -> failwith "agent metrics not found"

let test_aggregate_metrics () =
  let ctrl = create_controller () in
  register_agent ctrl "a1";
  register_agent ctrl "a2";
  let l2_write _k _v = () in
  coherent_write ctrl ~agent_id:"a1" ~key:"k1" ~value:"v1" ~l2_write;
  coherent_write ctrl ~agent_id:"a2" ~key:"k2" ~value:"v2" ~l2_write;
  let m = aggregate_metrics ctrl in
  check "total_writes is 2" (m.total_writes = 2)

(* ================================================================ *)
(* JSON Serialization Tests                                          *)
(* ================================================================ *)

let test_mesi_to_yojson () =
  check "M → \"M\"" (mesi_to_yojson Modified = `String "M");
  check "E → \"E\"" (mesi_to_yojson Exclusive = `String "E");
  check "S → \"S\"" (mesi_to_yojson Shared = `String "S");
  check "I → \"I\"" (mesi_to_yojson Invalid = `String "I")

let test_mesi_of_string_roundtrip () =
  List.iter (fun state ->
    let s = mesi_to_string state in
    match mesi_of_string s with
    | Some decoded -> check_mesi ("roundtrip " ^ s) state decoded
    | None -> failwith ("mesi_of_string failed for " ^ s)
  ) [Modified; Exclusive; Shared; Invalid]

let test_bus_message_to_yojson () =
  let msg = BusRd { key = "k"; requester = "a1" } in
  let json = bus_message_to_yojson msg in
  match json with
  | `Assoc fields ->
      check "has type field" (List.assoc_opt "type" fields = Some (`String "BusRd"))
  | _ -> failwith "expected Assoc"

let test_metrics_to_yojson () =
  let m = { total_reads = 10; total_writes = 5; l1_hit_rate = 0.75;
            invalidation_count = 2; writeback_count = 1; bus_traffic = 8 } in
  let json = metrics_to_yojson m in
  match json with
  | `Assoc fields ->
      check "has l1_hit_rate" (List.assoc_opt "l1_hit_rate" fields = Some (`Float 0.75))
  | _ -> failwith "expected Assoc"

let test_line_to_yojson () =
  let json = line_to_yojson ("key1", Modified) in
  match json with
  | `Assoc fields ->
      check "has key field" (List.assoc_opt "key" fields = Some (`String "key1"));
      check "has state field" (List.assoc_opt "state" fields = Some (`String "M"))
  | _ -> failwith "expected Assoc"

(* ================================================================ *)
(* Utility Tests                                                     *)
(* ================================================================ *)

let test_list_lines () =
  let ctrl = create_controller () in
  register_agent ctrl "a1";
  let l2_write _k _v = () in
  coherent_write ctrl ~agent_id:"a1" ~key:"k1" ~value:"v1" ~l2_write;
  coherent_write ctrl ~agent_id:"a1" ~key:"k2" ~value:"v2" ~l2_write;
  let lines = list_lines ctrl ~agent_id:"a1" in
  check "two non-Invalid lines" (List.length lines = 2)

let test_unregister_agent () =
  let ctrl = create_controller () in
  register_agent ctrl "a1";
  unregister_agent ctrl "a1";
  check "agent removed" (Hashtbl.length ctrl.agents = 0)

let test_bus_message_to_string () =
  let msg = BusInv { key = "k1"; invalidator = "a1" } in
  let s = bus_message_to_string msg in
  check "contains BusInv" (String.length s > 0 && String.sub s 0 6 = "BusInv")

let test_broadcast_increments_bus_traffic () =
  let ctrl = create_controller () in
  register_agent ctrl "a1";
  register_agent ctrl "a2";
  broadcast_snoop ctrl ~sender:"a1" (BusRd { key = "k"; requester = "a1" });
  check "bus traffic incremented" (ctrl.bus_traffic = 1)

(* ================================================================ *)
(* Tool Dispatch Integration Tests (Phase 2 MCP)                    *)
(* ================================================================ *)

(** Helper: parse dispatch result JSON *)
let dispatch_json tool_name args =
  let (ok, body) = Masc_mcp.Tool_risc.dispatch tool_name args in
  (ok, Yojson.Safe.from_string body)

let json_member key json =
  Yojson.Safe.Util.member key json

let json_string json =
  Yojson.Safe.Util.to_string json

let test_dispatch_cache_write () =
  let args = `Assoc [
    ("agent_id", `String "test-agent-1");
    ("key", `String "greeting");
    ("value", `String "hello world");
  ] in
  let (ok, json) = dispatch_json "masc_risc_cache_write" args in
  check "cache_write ok" ok;
  check "written is true" (json_member "written" json = `Bool true);
  check "state is M" (json_string (json_member "state" json) = "M")

let test_dispatch_cache_read_hit () =
  (* Write first, then read — should hit L1 *)
  let agent = "test-read-hit-agent" in
  let write_args = `Assoc [
    ("agent_id", `String agent);
    ("key", `String "rk1");
    ("value", `String "rv1");
  ] in
  ignore (Masc_mcp.Tool_risc.dispatch "masc_risc_cache_write" write_args);
  let read_args = `Assoc [
    ("agent_id", `String agent);
    ("key", `String "rk1");
  ] in
  let (ok, json) = dispatch_json "masc_risc_cache_read" read_args in
  check "cache_read ok" ok;
  check "value is rv1" (json_string (json_member "value" json) = "rv1");
  check "source is L1_hit" (json_string (json_member "source" json) = "L1_hit")

let test_dispatch_cache_read_miss () =
  let args = `Assoc [
    ("agent_id", `String "fresh-miss-agent");
    ("key", `String "nonexistent");
  ] in
  let (ok, json) = dispatch_json "masc_risc_cache_read" args in
  check "cache_read ok (miss is ok)" ok;
  check "value is null" (json_member "value" json = `Null);
  check "source is miss" (json_string (json_member "source" json) = "miss")

let test_dispatch_cache_status_aggregate () =
  let (ok, json) = dispatch_json "masc_risc_cache_status" (`Assoc []) in
  check "cache_status ok" ok;
  (* Should have aggregate_metrics and registered_agents *)
  check "has aggregate_metrics" (json_member "aggregate_metrics" json <> `Null);
  check "has registered_agents" (json_member "registered_agents" json <> `Null)

let test_dispatch_cache_status_agent_lines () =
  let agent = "status-lines-agent" in
  let write_args = `Assoc [
    ("agent_id", `String agent);
    ("key", `String "sk1");
    ("value", `String "sv1");
  ] in
  ignore (Masc_mcp.Tool_risc.dispatch "masc_risc_cache_write" write_args);
  let args = `Assoc [("agent_id", `String agent)] in
  let (ok, json) = dispatch_json "masc_risc_cache_status" args in
  check "status ok" ok;
  let count = Yojson.Safe.Util.to_int (json_member "line_count" json) in
  check "at least 1 line" (count >= 1)

let test_dispatch_cache_metrics () =
  let (ok, json) = dispatch_json "masc_risc_cache_metrics" (`Assoc []) in
  check "metrics ok" ok;
  check "has aggregate" (json_member "aggregate" json <> `Null)

let test_dispatch_cache_metrics_per_agent () =
  let agent = "metrics-agent" in
  let write_args = `Assoc [
    ("agent_id", `String agent);
    ("key", `String "mk1");
    ("value", `String "mv1");
  ] in
  ignore (Masc_mcp.Tool_risc.dispatch "masc_risc_cache_write" write_args);
  let args = `Assoc [("agent_id", `String agent)] in
  let (ok, json) = dispatch_json "masc_risc_cache_metrics" args in
  check "metrics ok" ok;
  check "has agent_id" (json_string (json_member "agent_id" json) = agent)

let test_dispatch_cross_agent_invalidation () =
  (* Agent A writes key → Agent B reads key → Agent A writes again → Agent B's line should be invalidated *)
  let a = "cross-inv-a" in
  let b = "cross-inv-b" in
  let key = "shared-key" in
  (* A writes *)
  ignore (Masc_mcp.Tool_risc.dispatch "masc_risc_cache_write"
    (`Assoc [("agent_id", `String a); ("key", `String key); ("value", `String "v1")]));
  (* B reads — this populates B's L1 (via L2 stub → miss, but let's write via B too) *)
  ignore (Masc_mcp.Tool_risc.dispatch "masc_risc_cache_write"
    (`Assoc [("agent_id", `String b); ("key", `String key); ("value", `String "v1")]));
  (* Now A writes again — should invalidate B's copy *)
  ignore (Masc_mcp.Tool_risc.dispatch "masc_risc_cache_write"
    (`Assoc [("agent_id", `String a); ("key", `String key); ("value", `String "v2")]));
  (* Check B's line state *)
  let (ok, json) = dispatch_json "masc_risc_cache_status"
    (`Assoc [("agent_id", `String b); ("key", `String key)]) in
  check "status ok" ok;
  let state = json_string (json_member "state" json) in
  check "B's line invalidated" (state = "I")

(* ================================================================ *)
(* Main                                                              *)
(* ================================================================ *)

let () =
  Printf.printf "\n=== Cache Coherence (MESI) Tests ===\n\n";

  Printf.printf "-- MESI State Transitions (16) --\n";
  run_test "I+LocalRead → E" test_invalid_local_read;
  run_test "I+LocalWrite → M" test_invalid_local_write;
  run_test "S+LocalRead → S" test_shared_local_read;
  run_test "S+LocalWrite → M" test_shared_local_write;
  run_test "E+LocalRead → E" test_exclusive_local_read;
  run_test "E+LocalWrite → M" test_exclusive_local_write;
  run_test "M+LocalRead → M" test_modified_local_read;
  run_test "M+LocalWrite → M" test_modified_local_write;
  run_test "M+SnoopRead → S (flush)" test_modified_snoop_read;
  run_test "E+SnoopRead → S" test_exclusive_snoop_read;
  run_test "S+SnoopRead → S" test_shared_snoop_read;
  run_test "I+SnoopRead → I" test_invalid_snoop_read;
  run_test "M+SnoopInvalidate → I (flush)" test_modified_snoop_invalidate;
  run_test "E+SnoopInvalidate → I" test_exclusive_snoop_invalidate;
  run_test "S+SnoopInvalidate → I" test_shared_snoop_invalidate;
  run_test "I+SnoopInvalidate → I" test_invalid_snoop_invalidate;

  Printf.printf "\n-- L1 Cache --\n";
  run_test "L1 read miss" test_l1_read_miss;
  run_test "L1 write then read" test_l1_write_then_read;
  run_test "L1 write state → Modified" test_l1_write_state_modified;
  run_test "L1 eviction (LRU)" test_l1_eviction;
  run_test "L1 eviction writeback on Modified" test_l1_eviction_modified_writeback;

  Printf.printf "\n-- Snoop --\n";
  run_test "Snoop BusRd on Modified → Shared" test_snoop_busrd_on_modified;
  run_test "Snoop BusInv on Shared → Invalid" test_snoop_businv_on_shared;
  run_test "Snoop on absent key → None" test_snoop_on_absent_key;

  Printf.printf "\n-- Coherence Controller --\n";
  run_test "Register agents" test_controller_register;
  run_test "Coherent read: L1 miss, L2 hit" test_coherent_read_l1_miss_l2_hit;
  run_test "Coherent read: L1 hit" test_coherent_read_l1_hit;
  run_test "Coherent write invalidates others" test_coherent_write_invalidates_others;
  run_test "Coherent write-through to L2" test_coherent_write_through_to_l2;
  run_test "Unregistered agent falls through" test_unregistered_agent_falls_through;

  Printf.printf "\n-- Metrics --\n";
  run_test "Agent metrics" test_agent_metrics;
  run_test "Aggregate metrics" test_aggregate_metrics;

  Printf.printf "\n-- JSON Serialization --\n";
  run_test "mesi_to_yojson" test_mesi_to_yojson;
  run_test "mesi_of_string roundtrip" test_mesi_of_string_roundtrip;
  run_test "bus_message_to_yojson" test_bus_message_to_yojson;
  run_test "metrics_to_yojson" test_metrics_to_yojson;
  run_test "line_to_yojson" test_line_to_yojson;

  Printf.printf "\n-- Utilities --\n";
  run_test "list_lines" test_list_lines;
  run_test "unregister_agent" test_unregister_agent;
  run_test "bus_message_to_string" test_bus_message_to_string;
  run_test "broadcast increments bus_traffic" test_broadcast_increments_bus_traffic;

  Printf.printf "\n-- Tool Dispatch (Phase 2 MCP integration) --\n";
  run_test "dispatch cache_write" test_dispatch_cache_write;
  run_test "dispatch cache_read hit" test_dispatch_cache_read_hit;
  run_test "dispatch cache_read miss" test_dispatch_cache_read_miss;
  run_test "dispatch cache_status aggregate" test_dispatch_cache_status_aggregate;
  run_test "dispatch cache_status agent lines" test_dispatch_cache_status_agent_lines;
  run_test "dispatch cache_metrics" test_dispatch_cache_metrics;
  run_test "dispatch cache_metrics per-agent" test_dispatch_cache_metrics_per_agent;
  run_test "dispatch cache_write invalidates cross-agent" test_dispatch_cross_agent_invalidation;

  Printf.printf "\n=== Results: %d passed, %d failed ===\n\n" !pass_count !fail_count;
  if !fail_count > 0 then exit 1
