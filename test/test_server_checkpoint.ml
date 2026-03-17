(** Test Server_checkpoint — save/load/parse round-trip *)

open Masc_mcp

let passed = ref 0
let failed = ref 0

let test name fn =
  try
    fn ();
    incr passed;
    Printf.printf "  PASS  %s\n%!" name
  with e ->
    incr failed;
    Printf.printf "  FAIL  %s: %s\n%!" name (Printexc.to_string e)

(* ── Test: JSON round-trip ─────────────────────── *)

let () = test "empty checkpoint round-trip" (fun () ->
  let c = Server_checkpoint.empty () in
  let json = Server_checkpoint.to_json c in
  match Server_checkpoint.of_json json with
  | Some c2 ->
      assert (c2.version = 1);
      assert (List.length c2.agents = 0);
      assert (c2.task_summary.total = 0);
      assert (c2.sentinel_started_at = None);
      assert (c2.keeper_timeouts = [])
  | None -> failwith "of_json returned None"
)

let () = test "full checkpoint round-trip" (fun () ->
  let c : Server_checkpoint.checkpoint = {
    version = 1;
    timestamp = 1700000000.0;
    agents = [
      { name = "claude"; last_seen = 1700000000.0 };
      { name = "gemini"; last_seen = 1699999000.0 };
    ];
    task_summary = { total = 10; pending = 3; active = 2; done_count = 5 };
    sentinel_started_at = Some 1699990000.0;
    guardian_started_at = Some 1699990100.0;
    governance_pending = ["merge-pr-42"; "deploy-v2"];
    keeper_timeouts = [
      { keeper_name = "dreamer"; timeout_until = 1700001000.0; reason = "rate-limited" };
    ];
    circuit_breaker_open = ["flaky-service"];
  } in
  let json = Server_checkpoint.to_json c in
  match Server_checkpoint.of_json json with
  | Some c2 ->
      assert (List.length c2.agents = 2);
      assert ((List.hd c2.agents).name = "claude");
      assert (c2.task_summary.total = 10);
      assert (c2.task_summary.pending = 3);
      assert (c2.sentinel_started_at = Some 1699990000.0);
      assert (c2.guardian_started_at = Some 1699990100.0);
      assert (List.length c2.governance_pending = 2);
      assert (List.length c2.keeper_timeouts = 1);
      assert ((List.hd c2.keeper_timeouts).keeper_name = "dreamer");
      assert (List.length c2.circuit_breaker_open = 1)
  | None -> failwith "of_json returned None"
)

(* ── Test: version check ──────────────────────── *)

let () = test "rejects unknown version" (fun () ->
  let json = `Assoc [("version", `Int 99)] in
  assert (Server_checkpoint.of_json json = None)
)

let () = test "rejects non-object" (fun () ->
  assert (Server_checkpoint.of_json (`String "nope") = None)
)

(* ── Test: file save/load round-trip ──────────── *)

let () = test "save and load from file" (fun () ->
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ()) "masc-test-checkpoint" in
  (try Unix.mkdir tmp_dir 0o755 with Unix.Unix_error _ -> ());
  Unix.putenv "MASC_BASE_PATH" tmp_dir;
  let c : Server_checkpoint.checkpoint = {
    version = 1;
    timestamp = Time_compat.now ();
    agents = [{ name = "test-agent"; last_seen = Time_compat.now () }];
    task_summary = { total = 5; pending = 2; active = 1; done_count = 2 };
    sentinel_started_at = Some (Time_compat.now ());
    guardian_started_at = None;
    governance_pending = [];
    keeper_timeouts = [];
    circuit_breaker_open = [];
  } in
  (match Server_checkpoint.save c with
   | Ok () -> ()
   | Error msg -> failwith ("save failed: " ^ msg));
  match Server_checkpoint.load () with
  | Some loaded ->
      assert (List.length loaded.agents = 1);
      assert ((List.hd loaded.agents).name = "test-agent");
      assert (loaded.task_summary.total = 5)
  | None -> failwith "load returned None"
)

(* ── Test: keeper timeout filtering ───────────── *)

let () = test "active_keeper_timeouts filters expired" (fun () ->
  let now = Time_compat.now () in
  let c : Server_checkpoint.checkpoint = {
    version = 1;
    timestamp = now;
    agents = [];
    task_summary = { total = 0; pending = 0; active = 0; done_count = 0 };
    sentinel_started_at = None;
    guardian_started_at = None;
    governance_pending = [];
    keeper_timeouts = [
      { keeper_name = "expired"; timeout_until = now -. 100.0; reason = "old" };
      { keeper_name = "active"; timeout_until = now +. 100.0; reason = "new" };
    ];
    circuit_breaker_open = [];
  } in
  let active = Server_checkpoint.active_keeper_timeouts c in
  assert (List.length active = 1);
  assert ((List.hd active).keeper_name = "active")
)

(* ── Test: staleness check ────────────────────── *)

let () = test "is_stale detects old checkpoints" (fun () ->
  let c : Server_checkpoint.checkpoint = {
    (Server_checkpoint.empty ()) with
    timestamp = Time_compat.now () -. 7200.0;  (* 2 hours ago *)
  } in
  assert (Server_checkpoint.is_stale ~max_age_s:3600.0 c);
  assert (not (Server_checkpoint.is_stale ~max_age_s:10000.0 c))
)

(* ── Summary ──────────────────────────────────── *)

let () =
  Printf.printf "\nServer_checkpoint tests: %d passed, %d failed\n%!" !passed !failed;
  if !failed > 0 then exit 1
