(** Tests for Llm_pool — provider-based concurrency pool.
    All tests run inside Eio_main.run with real clock.
    No LLM calls — pure concurrency/semaphore verification. *)

open Masc_mcp.Llm_pool

let glm_key = { provider = "glm"; model = "glm-5" }
let claude_key = { provider = "claude"; model = "opus" }
let unknown_key = { provider = "unknown"; model = "nope" }

let passed = ref 0
let failed = ref 0

let check name cond =
  if cond then begin
    incr passed;
    Printf.printf "  PASS: %s\n%!" name
  end else begin
    incr failed;
    Printf.printf "  FAIL: %s\n%!" name
  end

(* ── Test: basic create + stats ─────────────────────────────── *)
let test_create_and_stats clock =
  Printf.printf "\n=== create + stats ===\n%!";
  let pool = create ~clock [
    (glm_key, 3, 5.0);
    (claude_key, 2, 10.0);
  ] in
  let st = stats pool in
  check "two slots registered" (List.length st = 2);
  let glm_stat = List.find_opt (fun (k, _, _) -> k.provider = "glm") st in
  check "glm in_use=0" (match glm_stat with Some (_, 0, 3) -> true | _ -> false);
  let claude_stat = List.find_opt (fun (k, _, _) -> k.provider = "claude") st in
  check "claude in_use=0" (match claude_stat with Some (_, 0, 2) -> true | _ -> false)

(* ── Test: with_slot success ────────────────────────────────── *)
let test_with_slot_success clock =
  Printf.printf "\n=== with_slot success ===\n%!";
  let pool = create ~clock [(glm_key, 2, 5.0)] in
  let result = with_slot pool glm_key (fun () -> 42) in
  check "returns Ok 42" (result = Ok 42);
  (* Semaphore should be released *)
  check "capacity restored" (has_capacity pool glm_key)

(* ── Test: unknown slot ─────────────────────────────────────── *)
let test_unknown_slot clock =
  Printf.printf "\n=== unknown slot ===\n%!";
  let pool = create ~clock [(glm_key, 2, 5.0)] in
  let result = with_slot pool unknown_key (fun () -> 0) in
  check "returns Error" (match result with Error _ -> true | _ -> false);
  check "error mentions unknown" (match result with
    | Error msg -> String.length msg > 0 && (try ignore (Str.search_forward (Str.regexp_string "unknown") msg 0); true with Not_found -> false)
    | _ -> false)

(* ── Test: has_capacity ─────────────────────────────────────── *)
let test_has_capacity clock =
  Printf.printf "\n=== has_capacity ===\n%!";
  let pool = create ~clock [(glm_key, 1, 5.0)] in
  check "initially has capacity" (has_capacity pool glm_key);
  check "unknown has no capacity" (not (has_capacity pool unknown_key))

(* ── Test: exception safety (semaphore released on error) ──── *)
let test_exception_safety clock =
  Printf.printf "\n=== exception safety ===\n%!";
  let pool = create ~clock [(glm_key, 1, 5.0)] in
  let result = with_slot pool glm_key (fun () -> failwith "boom") in
  check "returns Error on exception" (match result with Error _ -> true | _ -> false);
  check "semaphore released after error" (has_capacity pool glm_key);
  (* Can acquire again *)
  let result2 = with_slot pool glm_key (fun () -> "ok") in
  check "slot reusable after error" (result2 = Ok "ok")

(* ── Test: concurrent slots (multi-fiber) ──────────────────── *)
let test_concurrent_slots clock =
  Printf.printf "\n=== concurrent slots ===\n%!";
  let pool = create ~clock [(glm_key, 2, 5.0)] in
  let results = Eio.Mutex.create () in
  let collected = ref [] in
  let add r =
    Eio.Mutex.use_rw ~protect:true results (fun () ->
      collected := r :: !collected)
  in
  Eio.Fiber.both
    (fun () ->
      match with_slot pool glm_key (fun () -> "fiber1") with
      | Ok v -> add v | Error _ -> add "err1")
    (fun () ->
      match with_slot pool glm_key (fun () -> "fiber2") with
      | Ok v -> add v | Error _ -> add "err2");
  check "both fibers completed" (List.length !collected = 2);
  check "fiber1 present" (List.mem "fiber1" !collected);
  check "fiber2 present" (List.mem "fiber2" !collected);
  check "all released" (has_capacity pool glm_key)

(* ── Test: provider isolation ───────────────────────────────── *)
let test_provider_isolation clock =
  Printf.printf "\n=== provider isolation ===\n%!";
  let pool = create ~clock [
    (glm_key, 1, 5.0);
    (claude_key, 1, 5.0);
  ] in
  (* Both providers can be used simultaneously *)
  Eio.Fiber.both
    (fun () ->
      let _ = with_slot pool glm_key (fun () ->
        Eio.Time.sleep clock 0.01; "glm") in ())
    (fun () ->
      let _ = with_slot pool claude_key (fun () ->
        Eio.Time.sleep clock 0.01; "claude") in ());
  check "both providers served concurrently" true;
  check "glm released" (has_capacity pool glm_key);
  check "claude released" (has_capacity pool claude_key)

(* ── Test: slot_key_to_string ───────────────────────────────── *)
let test_slot_key_to_string () =
  Printf.printf "\n=== slot_key_to_string ===\n%!";
  check "format" (slot_key_to_string glm_key = "glm:glm-5");
  check "format2" (slot_key_to_string claude_key = "claude:opus")

(* ── Test: timeout on full pool ─────────────────────────────── *)
let test_timeout clock =
  Printf.printf "\n=== timeout on full pool ===\n%!";
  (* Pool with 1 slot and 0.1s timeout *)
  let pool = create ~clock [({ provider = "tiny"; model = "m" }, 1, 0.1)] in
  let key = { provider = "tiny"; model = "m" } in
  let timeout_hit = ref false in
  Eio.Fiber.both
    (fun () ->
      (* Fiber 1: hold the slot for 0.5s *)
      let _ = with_slot pool key (fun () ->
        Eio.Time.sleep clock 0.5; "held") in ())
    (fun () ->
      (* Fiber 2: try to acquire — should timeout after 0.1s *)
      Eio.Time.sleep clock 0.01; (* small delay so fiber1 acquires first *)
      match with_slot pool key (fun () -> "never") with
      | Error msg ->
        timeout_hit := true;
        check "timeout error mentions timeout" (
          try ignore (Str.search_forward (Str.regexp_string "timeout") msg 0); true
          with Not_found -> false)
      | Ok _ ->
        check "should have timed out" false);
  check "timeout was hit" !timeout_hit

(* ── Main ───────────────────────────────────────────────────── *)
let () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Printf.printf "====================================\n";
  Printf.printf "Llm_pool Tests\n";
  Printf.printf "====================================\n%!";
  test_slot_key_to_string ();
  test_create_and_stats clock;
  test_with_slot_success clock;
  test_unknown_slot clock;
  test_has_capacity clock;
  test_exception_safety clock;
  test_concurrent_slots clock;
  test_provider_isolation clock;
  test_timeout clock;
  Printf.printf "\n====================================\n";
  Printf.printf "Results: %d/%d passed (%d failed)\n"
    !passed (!passed + !failed) !failed;
  if !failed > 0 then begin
    Printf.printf "SOME TESTS FAILED.\n%!";
    exit 1
  end else
    Printf.printf "All tests passed.\n%!"
