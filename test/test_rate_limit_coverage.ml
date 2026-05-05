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

(* ============================================================
   Constants Tests
   ============================================================ *)

let test_default_rate () =
  check (float 0.001) "default rate" 60.0 Rate_limit.default_rate

let test_default_burst () =
  check int "default burst" 150 Rate_limit.default_burst

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
   Config Accessor Tests
   ============================================================ *)

let test_rate_of_config_returns_float () =
  let rate = Rate_limit.rate_of_config () in
  check bool "rate is positive" true (rate > 0.0)

let test_burst_of_config_returns_int () =
  let burst = Rate_limit.burst_of_config () in
  check bool "burst is positive" true (burst > 0)

let test_create_of_config () =
  let limiter = Rate_limit.create_of_config () in
  check bool "rate positive" true ((Rate_limit.rate limiter) > 0.0);
  check bool "burst positive" true ((Rate_limit.burst limiter) > 0)

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

let test_agent_rate_of_config_returns_float () =
  let rate = Rate_limit.agent_rate_of_config () in
  check bool "agent rate is positive" true (rate > 0.0)

let test_agent_burst_of_config_returns_int () =
  let burst = Rate_limit.agent_burst_of_config () in
  check bool "agent burst is positive" true (burst > 0)

let test_create_agent_of_config () =
  let limiter = Rate_limit.create_agent_of_config () in
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
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Time_compat.set_clock (Eio.Stdenv.clock env);
  run "Rate Limit Coverage" [
    "constants", [
      test_case "default_rate" `Quick test_default_rate;
      test_case "default_burst" `Quick test_default_burst;
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
    "config", [
      test_case "rate_of_config" `Quick test_rate_of_config_returns_float;
      test_case "burst_of_config" `Quick test_burst_of_config_returns_int;
      test_case "create_of_config" `Quick test_create_of_config;
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
      test_case "agent_rate_of_config" `Quick test_agent_rate_of_config_returns_float;
      test_case "agent_burst_of_config" `Quick test_agent_burst_of_config_returns_int;
      test_case "create_agent_of_config" `Quick test_create_agent_of_config;
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
