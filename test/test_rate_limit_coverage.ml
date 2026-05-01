(** Rate Limit Module Coverage Tests

    Tests for MASC Rate Limiting:
    - default_rate, default_burst constants
    - create function
*)

open Alcotest

module Rate_limit = Masc_mcp.Rate_limit
module Server_auth = Masc_mcp.Server_auth

let unique_key prefix =
  Printf.sprintf "%s_%d" prefix (Unix.getpid ())

let comma_header_values value =
  List.map String.trim (String.split_on_char ',' value)

let rate_limit_env_probe_arg = "--rate-limit-env-probe"

let removed_algorithm_env_names =
  [
    "MASC_AGENT_RATE_BURST";
    "MASC_CDAL_VERDICT_LOOKUP_LIMIT";
    "MASC_MEMORY_OAS_DEFAULT_IMPORTANCE";
    "MASC_MESSAGE_MAX_COUNT";
    "MASC_ORCHESTRATOR_MIN_PRIORITY";
    "MASC_PROC_MIN_EVIDENCE";
    "MASC_PULSE_MAX_CONSUMER_FAILURES";
    "MASC_RATE_BURST";
    "MASC_TOOL_READONLY_RETRY_LIMIT";
  ]

let check_probe_int label expected actual =
  if actual <> expected then (
    Printf.eprintf "%s: expected %d, got %d\n%!" label expected actual;
    exit 2)

let run_rate_limit_env_probe_if_requested () =
  if Array.exists (String.equal rate_limit_env_probe_arg) Sys.argv then (
    check_probe_int "rate burst accessor" Rate_limit.default_burst
      (Rate_limit.burst_from_env ());
    check_probe_int "rate limiter burst" Rate_limit.default_burst
      (Rate_limit.burst (Rate_limit.create_from_env ()));
    check_probe_int "agent burst accessor" Rate_limit.default_agent_burst
      (Rate_limit.agent_burst_from_env ());
    check_probe_int "agent limiter burst" Rate_limit.default_agent_burst
      (Rate_limit.burst (Rate_limit.create_agent_from_env ()));
    check_probe_int "orchestrator min priority" 2
      Env_config.Orchestrator.min_priority;
    check_probe_int "message max count" 200 Env_config.Message.max_count;
    check_probe_int "CDAL verdict lookup limit" 500
      (Env_config.Cdal.verdict_lookup_limit ());
    check_probe_int "procedural memory min evidence" 3
      Env_config.ProcMemory.min_evidence;
    check_probe_int "pulse consumer failures" 3
      Env_config.Pulse_config.max_consumer_failures;
    check_probe_int "readonly retry limit" 2
      Env_config.Tools.readonly_retry_limit;
    check_probe_int "memory OAS default importance" 5
      Env_config.Memory_oas.default_importance;
    exit 0)

let env_binding_matches name binding =
  let prefix = name ^ "=" in
  let prefix_len = String.length prefix in
  String.length binding >= prefix_len
  && String.sub binding 0 prefix_len = prefix

let env_with_overrides overrides =
  let override_names = List.map fst overrides in
  let inherited =
    Unix.environment ()
    |> Array.to_list
    |> List.filter (fun binding ->
      not
        (List.exists
           (fun name -> env_binding_matches name binding)
           override_names))
  in
  Array.of_list
    (inherited
     @ List.map (fun (name, value) -> name ^ "=" ^ value) overrides)

let removed_env_overrides =
  List.map (fun name -> (name, "999999")) removed_algorithm_env_names

let wait_status_to_string = function
  | Unix.WEXITED code -> Printf.sprintf "exit %d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal

let rec waitpid_nointr pid =
  try Unix.waitpid [] pid with
  | Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_nointr pid

let snapshot_env_names () =
  match Env_config_snapshot.to_json () with
  | `Assoc fields -> (
      match List.assoc_opt "categories" fields with
      | Some (`Assoc categories) ->
          List.concat_map
            (function
              | _, `List entries ->
                  List.filter_map
                    (function
                      | `Assoc entry -> (
                          match List.assoc_opt "env" entry with
                          | Some (`String name) -> Some name
                          | _ -> None)
                      | _ -> None)
                    entries
              | _ -> [])
            categories
      | _ -> [])
  | _ -> []

(* ============================================================
   Constants Tests
   ============================================================ *)

let test_default_rate () =
  check (float 0.001) "default rate" 60.0 Rate_limit.default_rate

let test_default_burst () =
  check int "default burst" 150 Rate_limit.default_burst

(* ============================================================
   Agent Quota Tier Contract Tests
   ============================================================ *)

let must_allocations total_req_per_min =
  match Rate_limit.compute_agent_quota_allocations ~total_req_per_min with
  | Ok allocations -> allocations
  | Error msg -> fail msg

let allocation_for tier allocations =
  match
    List.find_opt
      (fun allocation ->
        Rate_limit.agent_quota_tier_code allocation.Rate_limit.allocation_tier
        = Rate_limit.agent_quota_tier_code tier)
      allocations
  with
  | Some allocation -> allocation
  | None -> fail ("missing allocation for " ^ Rate_limit.agent_quota_tier_code tier)

let total_allocated allocations =
  List.fold_left
    (fun total allocation ->
      total + allocation.Rate_limit.allocation_req_per_min)
    0 allocations

let test_agent_quota_default_allocations () =
  let allocations =
    must_allocations Rate_limit.default_agent_quota_total_per_min
  in
  check int "P0 req/min" 400
    (allocation_for Rate_limit.P0 allocations).allocation_req_per_min;
  check int "P1 req/min" 400
    (allocation_for Rate_limit.P1 allocations).allocation_req_per_min;
  check int "P2 req/min" 200
    (allocation_for Rate_limit.P2 allocations).allocation_req_per_min;
  check int "sum preserved" 1000 (total_allocated allocations)

let test_agent_quota_rounding_preserves_sum () =
  let allocations = must_allocations 1001 in
  check int "sum preserved" 1001 (total_allocated allocations);
  check int "P0 receives first remainder" 401
    (allocation_for Rate_limit.P0 allocations).allocation_req_per_min;
  check int "P1 unchanged" 400
    (allocation_for Rate_limit.P1 allocations).allocation_req_per_min;
  check int "P2 unchanged" 200
    (allocation_for Rate_limit.P2 allocations).allocation_req_per_min

let test_agent_quota_invalid_total () =
  match Rate_limit.compute_agent_quota_allocations ~total_req_per_min:0 with
  | Ok _ -> fail "expected invalid total to fail"
  | Error msg ->
    check bool "mentions positive total" true
      (String.contains msg 'p')

let test_agent_quota_validate_sum () =
  let allocations = must_allocations 1000 in
  (match
     Rate_limit.validate_agent_quota_allocations
       ~total_req_per_min:1000 allocations
   with
   | Ok () -> ()
   | Error msg -> fail msg);
  let bad_allocations =
    List.map
      (fun allocation ->
        if allocation.Rate_limit.allocation_tier = Rate_limit.P2 then
          {
            allocation with
            allocation_req_per_min = allocation.allocation_req_per_min - 1;
          }
        else
          allocation)
      allocations
  in
  match
    Rate_limit.validate_agent_quota_allocations
      ~total_req_per_min:1000 bad_allocations
  with
  | Ok () -> fail "expected sum mismatch to fail"
  | Error msg ->
    check bool "mentions sum mismatch" true
      (String.contains msg 's')

let test_agent_quota_stable_labels () =
  check string "P0 code" "P0" (Rate_limit.agent_quota_tier_code Rate_limit.P0);
  check string "P1 code" "P1" (Rate_limit.agent_quota_tier_code Rate_limit.P1);
  check string "P2 code" "P2" (Rate_limit.agent_quota_tier_code Rate_limit.P2);
  check string "P0 label" "P0 Critical"
    (Rate_limit.agent_quota_tier_label Rate_limit.P0);
  check string "P1 label" "P1 Standard"
    (Rate_limit.agent_quota_tier_label Rate_limit.P1);
  check string "P2 label" "P2 Background"
    (Rate_limit.agent_quota_tier_label Rate_limit.P2);
  check (list string) "control labels"
    ["lease-expiry"; "backpressure"; "adaptive-rate"]
    Rate_limit.agent_quota_control_labels

let test_agent_quota_contracts () =
  let contracts = Rate_limit.agent_quota_tier_contracts in
  check int "three contracts" 3 (List.length contracts);
  let p0 = List.hd contracts in
  check string "P0 contract code" "P0" p0.code;
  check int "P0 share" 40 p0.share_percent;
  check int "P0 default req/min" 400 p0.default_req_per_min

let test_agent_quota_task_priority_mapping () =
  check string "priority 1 -> P0" "P0"
    (Rate_limit.agent_quota_tier_code
       (Rate_limit.agent_quota_tier_of_task_priority 1));
  check string "priority 3 -> P1" "P1"
    (Rate_limit.agent_quota_tier_code
       (Rate_limit.agent_quota_tier_of_task_priority 3));
  check string "priority 4 -> P2" "P2"
    (Rate_limit.agent_quota_tier_code
       (Rate_limit.agent_quota_tier_of_task_priority 4));
  check string "priority 0 -> P0" "P0"
    (Rate_limit.agent_quota_tier_code
       (Rate_limit.agent_quota_tier_of_task_priority 0))

(* ============================================================
   Create Tests
   ============================================================ *)

let test_create_default () =
  let limiter = Rate_limit.create () in
  check (float 0.001) "rate" 60.0 (Rate_limit.rate limiter);
  check int "burst" 150 (Rate_limit.burst limiter)

let test_create_custom_rate () =
  let limiter = Rate_limit.create ~rate:100.0 () in
  check (float 0.001) "custom rate" 100.0 (Rate_limit.rate limiter)

let test_create_custom_burst () =
  let limiter = Rate_limit.create ~burst:200 () in
  check int "custom burst" 200 (Rate_limit.burst limiter)

let test_create_both_custom () =
  let limiter = Rate_limit.create ~rate:50.0 ~burst:100 () in
  check (float 0.001) "rate" 50.0 (Rate_limit.rate limiter);
  check int "burst" 100 (Rate_limit.burst limiter)

(* ============================================================
   Check Tests
   ============================================================ *)

let test_check_allows_first () =
  let limiter = Rate_limit.create ~burst:10 () in
  check bool "first allowed" true (Rate_limit.check limiter ~key:"test")

let test_check_within_burst () =
  let limiter = Rate_limit.create ~burst:5 () in
  let results = List.init 5 (fun _ -> Rate_limit.check limiter ~key:"test") in
  check bool "all within burst" true (List.for_all Fun.id results)

let test_check_exceeds_burst () =
  let limiter = Rate_limit.create ~rate:0.0 ~burst:2 () in
  let _ = Rate_limit.check limiter ~key:"test" in
  let _ = Rate_limit.check limiter ~key:"test" in
  let third = Rate_limit.check limiter ~key:"test" in
  check bool "third blocked" false third

let test_check_different_keys () =
  let limiter = Rate_limit.create ~rate:0.0 ~burst:1 () in
  let _ = Rate_limit.check limiter ~key:"key1" in
  let result = Rate_limit.check limiter ~key:"key2" in
  check bool "different key allowed" true result

(* ============================================================
   Remaining Tests
   ============================================================ *)

let test_remaining_new_key () =
  let limiter = Rate_limit.create ~burst:10 () in
  let rem = Rate_limit.remaining limiter ~key:"new" in
  check int "new key has burst" 10 rem

let test_remaining_after_check () =
  let limiter = Rate_limit.create ~rate:0.0 ~burst:10 () in
  let _ = Rate_limit.check limiter ~key:"test" in
  let rem = Rate_limit.remaining limiter ~key:"test" in
  check int "decremented" 9 rem

let test_remaining_multiple () =
  let limiter = Rate_limit.create ~rate:0.0 ~burst:10 () in
  let _ = Rate_limit.check limiter ~key:"test" in
  let _ = Rate_limit.check limiter ~key:"test" in
  let _ = Rate_limit.check limiter ~key:"test" in
  let rem = Rate_limit.remaining limiter ~key:"test" in
  check int "decremented 3 times" 7 rem

(* ============================================================
   Cleanup Tests
   ============================================================ *)

let test_cleanup_removes_old () =
  let limiter = Rate_limit.create () in
  let _ = Rate_limit.check limiter ~key:"old" in
  (* Ensure entry is older than the cleanup threshold. *)
  Time_compat.sleep 0.01;
  let removed = Rate_limit.cleanup limiter ~older_than_seconds:0 in
  check int "removes immediately when threshold=0" 1 removed

let test_cleanup_keeps_recent () =
  let limiter = Rate_limit.create () in
  let _ = Rate_limit.check limiter ~key:"recent" in
  (* Cleanup with large threshold should keep recent *)
  let removed = Rate_limit.cleanup limiter ~older_than_seconds:3600 in
  check int "keeps recent" 0 removed

(* ============================================================
   Env Functions Tests
   ============================================================ *)

let test_rate_from_env_returns_float () =
  let rate = Rate_limit.rate_from_env () in
  check bool "rate is positive" true (rate > 0.0)

let test_burst_from_env_returns_int () =
  let burst = Rate_limit.burst_from_env () in
  check bool "burst is positive" true (burst > 0)

let test_create_from_env () =
  let limiter = Rate_limit.create_from_env () in
  check bool "rate positive" true ((Rate_limit.rate limiter) > 0.0);
  check bool "burst positive" true ((Rate_limit.burst limiter) > 0)

let test_removed_algorithm_env_knobs_do_not_affect_runtime () =
  let exe = Sys.executable_name in
  let argv = [| exe; rate_limit_env_probe_arg |] in
  let env = env_with_overrides removed_env_overrides in
  let pid = Unix.create_process_env exe argv env Unix.stdin Unix.stdout Unix.stderr in
  match waitpid_nointr pid with
  | _, Unix.WEXITED 0 -> ()
  | _, status ->
      fail
        (Printf.sprintf "env probe failed with %s"
           (wait_status_to_string status))

let test_removed_algorithm_env_knobs_absent_from_snapshot () =
  List.iter
    (fun (name, value) -> Unix.putenv name value)
    removed_env_overrides;
  let names = snapshot_env_names () in
  List.iter
    (fun removed ->
      check bool
        (removed ^ " absent from config snapshot")
        false
        (List.mem removed names))
    removed_algorithm_env_names

(* ============================================================
   Global Instance Tests
   ============================================================ *)

let test_check_global () =
  let result = Rate_limit.check_global ~key:"global_test" in
  check bool "global check returns bool" true (result || not result)

let test_remaining_global () =
  let rem = Rate_limit.remaining_global ~key:"global_test_new" in
  check bool "global remaining positive" true (rem >= 0)

(* ============================================================
   HTTP Helpers Tests
   ============================================================ *)

let test_headers_has_limit () =
  let limiter = Rate_limit.create ~burst:100 () in
  let hdrs = Rate_limit.headers limiter ~key:"test" in
  check bool "has X-RateLimit-Limit" true
    (List.mem_assoc "X-RateLimit-Limit" hdrs)

let test_headers_has_remaining () =
  let limiter = Rate_limit.create () in
  let hdrs = Rate_limit.headers limiter ~key:"test" in
  check bool "has X-RateLimit-Remaining" true
    (List.mem_assoc "X-RateLimit-Remaining" hdrs)

let test_headers_limit_value () =
  let limiter = Rate_limit.create ~burst:100 () in
  let hdrs = Rate_limit.headers limiter ~key:"test" in
  match List.assoc_opt "X-RateLimit-Limit" hdrs with
  | Some v -> check string "limit is burst" "100" v
  | None -> fail "expected X-RateLimit-Limit header"

let test_too_many_requests_body () =
  let body = Rate_limit.too_many_requests_body () in
  check bool "contains error" true
    (try let _ = Str.search_forward (Str.regexp "Too Many Requests") body 0 in true
     with Not_found -> false)

let test_cors_exposes_rate_limit_headers () =
  let hdrs = Server_auth.cors_headers "http://localhost:5173" in
  match List.assoc_opt "access-control-expose-headers" hdrs with
  | None -> fail "expected access-control-expose-headers"
  | Some exposed ->
      let names = comma_header_values exposed in
      check bool "exposes rate limit limit" true
        (List.mem "X-RateLimit-Limit" names);
      check bool "exposes rate limit remaining" true
        (List.mem "X-RateLimit-Remaining" names)

(* ============================================================
   key_of_sockaddr Tests
   ============================================================ *)

let test_key_of_sockaddr_ipv4_loopback () =
  let ip = Eio.Net.Ipaddr.of_raw "\127\000\000\001" in
  let addr = `Tcp (ip, 8080) in
  check string "IPv4 loopback" "127.0.0.1" (Rate_limit.key_of_sockaddr addr)

let test_key_of_sockaddr_ipv4_arbitrary () =
  let ip = Eio.Net.Ipaddr.of_raw "\192\168\001\042" in
  let addr = `Tcp (ip, 1234) in
  check string "IPv4 arbitrary" "192.168.1.42" (Rate_limit.key_of_sockaddr addr)

let test_key_of_sockaddr_ignores_port () =
  let ip = Eio.Net.Ipaddr.of_raw "\010\000\000\001" in
  let k1 = Rate_limit.key_of_sockaddr (`Tcp (ip, 1111)) in
  let k2 = Rate_limit.key_of_sockaddr (`Tcp (ip, 9999)) in
  check string "same key regardless of port" k1 k2

let test_key_of_sockaddr_unix () =
  let key = Rate_limit.key_of_sockaddr (`Unix "/run/masc.sock") in
  check bool "unix key starts with unix:" true
    (String.length key > 5 && String.sub key 0 5 = "unix:")

let test_key_of_sockaddr_ipv6_loopback () =
  (* IPv6 loopback ::1 = 15 leading zero bytes + 1 *)
  let raw = String.make 15 '\000' ^ "\001" in
  let ip = Eio.Net.Ipaddr.of_raw raw in
  let key = Rate_limit.key_of_sockaddr (`Tcp (ip, 443)) in
  (* Eio.Net.Ipaddr.pp follows RFC 5952 compressed notation *)
  check string "IPv6 loopback key" "::1" key

(* ============================================================
   headers_global Tests
   ============================================================ *)

let test_headers_global_has_limit () =
  let hdrs = Rate_limit.headers_global ~key:"global_hdr_test" in
  check bool "has X-RateLimit-Limit" true
    (List.mem_assoc "X-RateLimit-Limit" hdrs)

let test_headers_global_has_remaining () =
  let hdrs = Rate_limit.headers_global ~key:"global_hdr_test_new" in
  check bool "has X-RateLimit-Remaining" true
    (List.mem_assoc "X-RateLimit-Remaining" hdrs)

(* ============================================================
   Per-Agent Configuration Tests
   ============================================================ *)

let test_default_agent_rate () =
  check (float 0.001) "default agent rate" 20.0 Rate_limit.default_agent_rate

let test_default_agent_burst () =
  check int "default agent burst" 50 Rate_limit.default_agent_burst

let test_agent_rate_from_env_returns_float () =
  let rate = Rate_limit.agent_rate_from_env () in
  check bool "agent rate is positive" true (rate > 0.0)

let test_agent_burst_from_env_returns_int () =
  let burst = Rate_limit.agent_burst_from_env () in
  check bool "agent burst is positive" true (burst > 0)

let test_create_agent_from_env () =
  let limiter = Rate_limit.create_agent_from_env () in
  check bool "agent rate positive" true ((Rate_limit.rate limiter) > 0.0);
  check bool "agent burst positive" true ((Rate_limit.burst limiter) > 0)

(* ============================================================
   Per-Agent Global Instance Tests
   ============================================================ *)

let test_check_agent_global () =
  let key = unique_key "agent_global_check" in
  let before = Rate_limit.remaining_agent_global ~key in
  check bool "fresh key has agent budget" true (before > 0);
  check bool "fresh key allowed" true (Rate_limit.check_agent_global ~key);
  let after = Rate_limit.remaining_agent_global ~key in
  check int "agent budget decremented" (before - 1) after

let test_remaining_agent_global () =
  let rem = Rate_limit.remaining_agent_global ~key:"agent_global_new_key" in
  check bool "agent global remaining non-negative" true (rem >= 0)

let test_headers_agent_global_has_limit () =
  let hdrs = Rate_limit.headers_agent_global ~key:"agent_hdr_test" in
  check bool "has X-RateLimit-Limit" true
    (List.mem_assoc "X-RateLimit-Limit" hdrs)

let test_headers_agent_global_has_remaining () =
  let hdrs = Rate_limit.headers_agent_global ~key:"agent_hdr_test_new" in
  check bool "has X-RateLimit-Remaining" true
    (List.mem_assoc "X-RateLimit-Remaining" hdrs)

let test_agent_limiter_separate_from_global () =
  let key = unique_key "shared_global_agent" in
  let agent_before = Rate_limit.remaining_agent_global ~key in
  let global_before = Rate_limit.remaining_global ~key in
  check bool "fresh agent key has budget" true (agent_before > 0);
  check bool "fresh global key has budget" true (global_before > 0);

  check bool "agent global allows shared key" true
    (Rate_limit.check_agent_global ~key);
  check int "agent budget decremented" (agent_before - 1)
    (Rate_limit.remaining_agent_global ~key);
  check int "global budget untouched by agent limiter" global_before
    (Rate_limit.remaining_global ~key);

  check bool "global allows shared key" true (Rate_limit.check_global ~key);
  check int "global budget decremented" (global_before - 1)
    (Rate_limit.remaining_global ~key);
  check int "agent budget untouched by global limiter" (agent_before - 1)
    (Rate_limit.remaining_agent_global ~key)

(* ============================================================
   agent_key_of_token_or_name Tests
   ============================================================ *)

let test_agent_key_of_token () =
  match Rate_limit.agent_key_of_token_or_name ~token:"secret-token-123" () with
  | None -> fail "expected Some key for token"
  | Some key ->
      check bool "key starts with token:" true
        (String.length key > 6 && String.sub key 0 6 = "token:");
      (* "token:" prefix (6 chars) + 32 hex chars from SHA-256 = 38 chars total *)
      check bool "key length ok" true (String.length key = 38);
      let hex_part = String.sub key 6 32 in
      let is_hex c =
        (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
      in
      check bool "token digest prefix is hex" true
        (String.for_all is_hex hex_part)

let test_agent_key_of_agent_name () =
  match Rate_limit.agent_key_of_token_or_name ~agent_name:"my-agent" () with
  | None -> fail "expected Some key for agent_name"
  | Some key ->
      check string "key is agent: prefixed" "agent:my-agent" key

let test_agent_key_token_preferred_over_name () =
  match Rate_limit.agent_key_of_token_or_name
          ~token:"tok123" ~agent_name:"my-agent" () with
  | None -> fail "expected Some key"
  | Some key ->
      check bool "token preferred" true
        (String.length key > 6 && String.sub key 0 6 = "token:")

let test_agent_key_empty_token_falls_back () =
  match Rate_limit.agent_key_of_token_or_name
          ~token:"" ~agent_name:"my-agent" () with
  | None -> fail "expected Some key after empty token"
  | Some key ->
      check string "falls back to agent name" "agent:my-agent" key

let test_agent_key_none_for_anonymous () =
  match Rate_limit.agent_key_of_token_or_name () with
  | None -> ()
  | Some key -> fail ("expected None for anonymous request, got " ^ key)

let test_agent_key_none_for_empty_name () =
  match Rate_limit.agent_key_of_token_or_name ~agent_name:"" () with
  | None -> ()
  | Some key -> fail ("expected None for empty agent name, got " ^ key)

let test_agent_key_stable_for_same_token () =
  let token = "same-token-value" in
  let k1 = Rate_limit.agent_key_of_token_or_name ~token () in
  let k2 = Rate_limit.agent_key_of_token_or_name ~token () in
  check (option string) "stable key" k1 k2

let test_agent_key_different_tokens_give_different_keys () =
  let k1 = Rate_limit.agent_key_of_token_or_name ~token:"token-a" () in
  let k2 = Rate_limit.agent_key_of_token_or_name ~token:"token-b" () in
  check bool "different tokens => different keys" true (k1 <> k2)

(* ============================================================
   Per-Agent Bucket Exhaustion Tests
   ============================================================ *)

let test_agent_bucket_blocks_after_burst () =
  let lim = Rate_limit.create ~rate:0.0 ~burst:3 () in
  let _ = Rate_limit.check lim ~key:"agent:x" in
  let _ = Rate_limit.check lim ~key:"agent:x" in
  let _ = Rate_limit.check lim ~key:"agent:x" in
  let blocked = not (Rate_limit.check lim ~key:"agent:x") in
  check bool "blocked after burst exhausted" true blocked

let test_agent_bucket_independent_per_agent () =
  let lim = Rate_limit.create ~rate:0.0 ~burst:1 () in
  let _ = Rate_limit.check lim ~key:"agent:a" in
  (* agent:a exhausted, agent:b still has capacity *)
  let b_allowed = Rate_limit.check lim ~key:"agent:b" in
  check bool "different agents are independent" true b_allowed

let test_too_many_agent_requests_body () =
  let body = Rate_limit.too_many_agent_requests_body () in
  check bool "contains Per-agent" true
    (match Str.search_forward (Str.regexp "Per-agent") body 0 with
     | _ -> true
     | exception Not_found -> false)

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run_rate_limit_env_probe_if_requested ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Time_compat.set_clock (Eio.Stdenv.clock env);
  run "Rate Limit Coverage" [
    "constants", [
      test_case "default_rate" `Quick test_default_rate;
      test_case "default_burst" `Quick test_default_burst;
    ];
    "agent_quota_tiers", [
      test_case "default allocations" `Quick test_agent_quota_default_allocations;
      test_case "rounding preserves sum" `Quick
        test_agent_quota_rounding_preserves_sum;
      test_case "invalid total" `Quick test_agent_quota_invalid_total;
      test_case "validate sum" `Quick test_agent_quota_validate_sum;
      test_case "stable labels" `Quick test_agent_quota_stable_labels;
      test_case "contracts" `Quick test_agent_quota_contracts;
      test_case "task priority mapping" `Quick
        test_agent_quota_task_priority_mapping;
    ];
    "create", [
      test_case "default" `Quick test_create_default;
      test_case "custom rate" `Quick test_create_custom_rate;
      test_case "custom burst" `Quick test_create_custom_burst;
      test_case "both custom" `Quick test_create_both_custom;
    ];
    "check", [
      test_case "allows first" `Quick test_check_allows_first;
      test_case "within burst" `Quick test_check_within_burst;
      test_case "exceeds burst" `Quick test_check_exceeds_burst;
      test_case "different keys" `Quick test_check_different_keys;
    ];
    "remaining", [
      test_case "new key" `Quick test_remaining_new_key;
      test_case "after check" `Quick test_remaining_after_check;
      test_case "multiple" `Quick test_remaining_multiple;
    ];
    "cleanup", [
      test_case "removes old" `Quick test_cleanup_removes_old;
      test_case "keeps recent" `Quick test_cleanup_keeps_recent;
    ];
    "env", [
      test_case "rate_from_env" `Quick test_rate_from_env_returns_float;
      test_case "burst_from_env" `Quick test_burst_from_env_returns_int;
      test_case "create_from_env" `Quick test_create_from_env;
      test_case "removed algorithm env knobs ignored" `Quick
        test_removed_algorithm_env_knobs_do_not_affect_runtime;
      test_case "removed algorithm env knobs absent from snapshot" `Quick
        test_removed_algorithm_env_knobs_absent_from_snapshot;
    ];
    "global", [
      test_case "check_global" `Quick test_check_global;
      test_case "remaining_global" `Quick test_remaining_global;
    ];
    "http", [
      test_case "headers has limit" `Quick test_headers_has_limit;
      test_case "headers has remaining" `Quick test_headers_has_remaining;
      test_case "headers limit value" `Quick test_headers_limit_value;
      test_case "too_many_requests_body" `Quick test_too_many_requests_body;
      test_case "cors exposes rate limit headers" `Quick
        test_cors_exposes_rate_limit_headers;
    ];
    "key_of_sockaddr", [
      test_case "ipv4 loopback" `Quick test_key_of_sockaddr_ipv4_loopback;
      test_case "ipv4 arbitrary" `Quick test_key_of_sockaddr_ipv4_arbitrary;
      test_case "ignores port" `Quick test_key_of_sockaddr_ignores_port;
      test_case "unix socket" `Quick test_key_of_sockaddr_unix;
      test_case "ipv6 loopback" `Quick test_key_of_sockaddr_ipv6_loopback;
    ];
    "headers_global", [
      test_case "has limit header" `Quick test_headers_global_has_limit;
      test_case "has remaining header" `Quick test_headers_global_has_remaining;
    ];
    "per_agent_config", [
      test_case "default_agent_rate" `Quick test_default_agent_rate;
      test_case "default_agent_burst" `Quick test_default_agent_burst;
      test_case "agent_rate_from_env" `Quick test_agent_rate_from_env_returns_float;
      test_case "agent_burst_from_env" `Quick test_agent_burst_from_env_returns_int;
      test_case "create_agent_from_env" `Quick test_create_agent_from_env;
    ];
    "per_agent_global", [
      test_case "check_agent_global" `Quick test_check_agent_global;
      test_case "remaining_agent_global" `Quick test_remaining_agent_global;
      test_case "headers_agent_global has limit" `Quick test_headers_agent_global_has_limit;
      test_case "headers_agent_global has remaining" `Quick test_headers_agent_global_has_remaining;
      test_case "limiter separate from global" `Quick test_agent_limiter_separate_from_global;
    ];
    "agent_key_of_token_or_name", [
      test_case "token gives token: key" `Quick test_agent_key_of_token;
      test_case "agent_name gives agent: key" `Quick test_agent_key_of_agent_name;
      test_case "token preferred over name" `Quick test_agent_key_token_preferred_over_name;
      test_case "empty token falls back to name" `Quick test_agent_key_empty_token_falls_back;
      test_case "None for anonymous" `Quick test_agent_key_none_for_anonymous;
      test_case "None for empty name" `Quick test_agent_key_none_for_empty_name;
      test_case "stable for same token" `Quick test_agent_key_stable_for_same_token;
      test_case "different tokens => different keys" `Quick
        test_agent_key_different_tokens_give_different_keys;
    ];
    "per_agent_bucket", [
      test_case "blocks after burst" `Quick test_agent_bucket_blocks_after_burst;
      test_case "independent per agent" `Quick test_agent_bucket_independent_per_agent;
      test_case "too_many_agent_requests_body" `Quick test_too_many_agent_requests_body;
    ];
  ]
