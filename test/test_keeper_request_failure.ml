(** A failed keeper request is a value.

    This suite pins three things: which constructor each producer's input maps
    to, that the codec is symmetric and refuses everything it does not write,
    and that a summary is one line whatever the leaf text contains. *)

module Krf = Keeper_request_failure
module Kie = Keeper_internal_error
module Keeper_registry_types = Masc.Keeper_registry_types

let cause_testable =
  Alcotest.testable
    (fun fmt cause ->
       Format.pp_print_string fmt (Yojson.Safe.to_string (Krf.to_yojson { Krf.cause })))
    (fun left right ->
       Yojson.Safe.equal
         (Krf.to_yojson { Krf.cause = left })
         (Krf.to_yojson { Krf.cause = right }))
;;

let summary_of cause = Krf.summary { Krf.cause }

(* ------------------------------------------------------------------ *)
(* Producer -> constructor                                             *)
(* ------------------------------------------------------------------ *)

let network_error kind message =
  Agent_core.Error.Api (Agent_core.Retry.NetworkError { message; kind })
;;

let test_api_network_becomes_provider_network () =
  Alcotest.check
    cause_testable
    "an agent-core transport failure names the transport"
    (Krf.Provider_network
       { provider = None
       ; kind = Llm_provider.Http_client.Connection_refused
       ; detail = "refused"
       })
    (Krf.of_core_error
       (network_error Llm_provider.Http_client.Connection_refused "refused")).Krf.cause
;;

(* RFC #52028 §2.3: a connection that did not open keeps its own cause, so the
   stored failure says the request was not sent. *)
let test_api_connect_failed_becomes_provider_connect_failed () =
  Alcotest.check
    cause_testable
    "an agent-core connect failure names the connection that did not open"
    (Krf.Provider_connect_failed
       { provider = None
       ; kind = Llm_provider.Http_client.Connection_refused
       ; detail = "refused"
       })
    (Krf.of_core_error
       (Agent_core.Error.Api
          (Agent_core.Retry.Connect_failed
             { message = "refused"; kind = Llm_provider.Http_client.Connection_refused })))
      .Krf.cause
;;

let test_provider_connect_failed_keeps_its_provider () =
  Alcotest.check
    cause_testable
    "a provider connect failure keeps the provider that failed"
    (Krf.Provider_connect_failed
       { provider = Some "glm"
       ; kind = Llm_provider.Http_client.Dns_failure
       ; detail = "no such host"
       })
    (Krf.of_core_error
       (Agent_core.Error.Provider
          (Llm_provider.Error.Connect_failed
             { provider = "glm"
             ; kind = Llm_provider.Http_client.Dns_failure
             ; detail = "no such host"
             })))
      .Krf.cause
;;

let test_provider_network_keeps_its_provider () =
  Alcotest.check
    cause_testable
    "a provider transport failure keeps the provider that failed"
    (Krf.Provider_network
       { provider = Some "codex_app_server"
       ; kind = Llm_provider.Http_client.End_of_file
       ; detail = "stdout closed"
       })
    (Krf.of_core_error
       (Agent_core.Error.Provider
          (Llm_provider.Error.NetworkError
             { provider = "codex_app_server"
             ; kind = Llm_provider.Http_client.End_of_file
             ; detail = "stdout closed"
             ; timeout_phase = None
             })))
      .Krf.cause
;;

let test_context_overflow_carries_the_window () =
  Alcotest.check
    cause_testable
    "a context overflow carries the window, not the provider diagnostic"
    (Krf.Context_overflow { limit = Some 200_000 })
    (Krf.of_core_error
       (Agent_core.Error.Api
          (Agent_core.Retry.ContextOverflow
             { limit = Some 200_000; message = "empty completion" })))
      .Krf.cause
;;

let test_api_rate_limit_keeps_the_stated_wait () =
  Alcotest.check
    cause_testable
    "an agent-core rate limit keeps the wait the provider stated and its own text"
    (Krf.Provider_rate_limited
       { provider = None; retry_after = Some 12.5; detail = "concurrent requests" })
    (Krf.of_core_error
       (Agent_core.Error.Api
          (Agent_core.Retry.RateLimited
             { message = "concurrent requests"; retry_after = Some 12.5 })))
      .Krf.cause
;;

let test_rate_limit_without_a_stated_wait_stays_empty () =
  Alcotest.check
    cause_testable
    "a rate limit that stated no wait carries none, whatever its text says"
    (Krf.Provider_rate_limited
       { provider = Some "glm"; retry_after = None; detail = "try again in 30 seconds" })
    (Krf.of_core_error
       (Agent_core.Error.Provider
          (Llm_provider.Error.RateLimit
             { provider = "glm"; retry_after = None; detail = "try again in 30 seconds" })))
      .Krf.cause
;;

let test_provider_rate_limit_keeps_its_provider () =
  Alcotest.check
    cause_testable
    "a provider rate limit keeps the provider and the wait"
    (Krf.Provider_rate_limited
       { provider = Some "ollama_cloud"; retry_after = Some 3.; detail = "slow down" })
    (Krf.of_core_error
       (Agent_core.Error.Provider
          (Llm_provider.Error.RateLimit
             { provider = "ollama_cloud"; retry_after = Some 3.; detail = "slow down" })))
      .Krf.cause
;;

let test_rate_limit_keeps_integer_wire_wait () =
  let encoded = `Assoc [ "cause", `Assoc [
    "kind", `String "provider_rate_limited";
    "provider", `Null; "retry_after", `Int 12; "detail", `String "x" ]] in
  match Krf.of_yojson encoded with
  | Error detail -> Alcotest.fail detail
  | Ok failure ->
    Alcotest.check cause_testable "integer wire waits use the canonical cause"
      (Krf.Provider_rate_limited { provider = None; retry_after = Some 12.; detail = "x" })
      failure.Krf.cause
;;

(* The wait appears in the sentence when one was reported and is left out when
   none was; the provider's own text follows, joined to one line. The wording
   itself is not pinned. *)
let test_rate_limit_summary_shows_the_wait_only_when_reported () =
  let contains text part = String_util.contains_substring text part in
  let with_wait =
    summary_of
      (Krf.Provider_rate_limited
         { provider = Some "glm"; retry_after = Some 12.5; detail = "slow\ndown" })
  in
  let without_wait =
    summary_of
      (Krf.Provider_rate_limited
         { provider = Some "glm"; retry_after = None; detail = "slow\ndown" })
  in
  Alcotest.check Alcotest.bool "the stated wait is in the summary" true
    (contains with_wait "12.5");
  Alcotest.check Alcotest.bool "no wait is invented when none was stated" false
    (contains without_wait "retry after");
  Alcotest.check Alcotest.bool "the provider's text survives on one line" true
    (contains with_wait "slow down" && contains without_wait "slow down");
  Alcotest.check Alcotest.bool "a long wait is not written in exponent form" false
    (contains
       (summary_of
          (Krf.Provider_rate_limited
             { provider = None; retry_after = Some 2_592_000.; detail = "weekly limit" }))
       "e+")
;;

let test_carried_masc_error_stays_a_masc_value () =
  let masc_error =
    Kie.Host_stopped_turn
      { runtime_id = "claude_code.claude-sonnet-5"; stop = Kie.Host_graceful_shutdown }
  in
  Alcotest.check
    cause_testable
    "a MASC error on the carrier is lifted back, not re-rendered"
    (Krf.Masc masc_error)
    (Krf.of_core_error (Kie.core_error_of_masc_internal_error masc_error)).Krf.cause
;;

let test_unnamed_agent_core_failure_stays_core () =
  match (Krf.of_core_error (Agent_core.Error.Internal "boom")).Krf.cause with
  | Krf.Core core ->
    Alcotest.check
      Alcotest.string
      "the residual arm keeps agent-core's own text"
      "boom"
      core.Keeper_request_failure_core.message
  | _ -> Alcotest.fail "a plain agent-core internal failure must project to Core"
;;

let test_operator_interrupt_detail_is_the_typed_summary () =
  (* One sentence for the interrupt: the registry's detail and the chat row
     read the same value. *)
  Alcotest.check
    Alcotest.string
    "the registry detail is the typed summary"
    (summary_of Krf.Operator_cancelled)
    Keeper_registry_types.operator_interrupt_detail
;;

(* ------------------------------------------------------------------ *)
(* Summary                                                             *)
(* ------------------------------------------------------------------ *)

let test_a_summary_is_one_line () =
  let cause = Krf.Runtime_selection_failed { detail = "first\nsecond\rthird" } in
  Alcotest.check
    Alcotest.string
    "line breaks inside leaf text become spaces"
    "first second third"
    (summary_of cause)
;;

let test_a_raised_summary_names_its_site_and_is_one_line () =
  let cause =
    Krf.Raised { site = Krf.Stream_submit; exn = "Failure(\"a\nb\rc\")" }
  in
  let summary = summary_of cause in
  Alcotest.check
    Alcotest.bool
    "the site is named"
    true
    (String.length summary > 0
     && not (String.exists (function '\n' | '\r' -> true | _ -> false) summary))
;;

let test_a_masc_summary_without_one_keeps_the_envelope () =
  (* Two kinds answer [None] on purpose until the row carries the value;
     the pane reads the envelope back to draw its badge, so the
     summary must still be that envelope. *)
  let masc_error =
    Kie.Runtime_connection_closed
      { runtime_id = "codex_app_server"; detail = "stdout closed"; turn_accepted = false }
  in
  Alcotest.check
    Alcotest.string
    "the envelope survives a kind with no summary"
    (Agent_core.Error.to_string (Kie.core_error_of_masc_internal_error masc_error))
    (summary_of (Krf.Masc masc_error))
;;

(* ------------------------------------------------------------------ *)
(* Codec                                                               *)
(* ------------------------------------------------------------------ *)

let every_cause =
  [ Krf.Core
      (Keeper_request_failure_core.of_core_error (Agent_core.Error.Internal "boom"))
  ; Krf.Masc (Kie.Receipt_persistence_failed { detail = "disk full" })
  ; Krf.Provider_network
      { provider = Some "ollama_cloud"
      ; kind = Llm_provider.Http_client.Dns_failure
      ; detail = "no such host"
      }
  ; Krf.Provider_network
      { provider = None; kind = Llm_provider.Http_client.Unknown; detail = "" }
  ; Krf.Provider_network
      { provider = Some "glm"; kind = Llm_provider.Http_client.Unreachable; detail = "" }
  ; Krf.Provider_connect_failed
      { provider = Some "glm"; kind = Llm_provider.Http_client.Tls_error; detail = "handshake" }
  ; Krf.Provider_connect_failed
      { provider = None; kind = Llm_provider.Http_client.Dns_failure; detail = "" }
  ; Krf.Provider_rate_limited
      { provider = Some "ollama_cloud"; retry_after = Some 12.5; detail = "concurrent requests" }
  ; Krf.Provider_rate_limited
      { provider = None; retry_after = None; detail = "no wait stated" }
  ; Krf.Provider_rate_limited
      { provider = Some "ollama_cloud"; retry_after = Some 12.5; detail = "slow down" }
  ; Krf.Provider_rate_limited { provider = None; retry_after = None; detail = "" }
  ; Krf.Provider_rate_limited
      { provider = Some "glm"; retry_after = None; detail = "two\nlines" }
  ; Krf.Provider_rate_limited
      { provider = None; retry_after = Some 0.; detail = "limit resets now" }
  ; Krf.Context_overflow { limit = Some 128_000 }
  ; Krf.Context_overflow { limit = None }
  ; Krf.Input_capacity
  ; Krf.Operator_cancelled
  ; Krf.Server_not_initialized
  ; Krf.Server_restarted
  ; Krf.Dispatch_unavailable
  ; Krf.Keeper_meta_unresolved { keeper = "aria"; detail = "keeper not found: aria" }
  ; Krf.Keeper_not_registered { keeper = "aria" }
  ; Krf.Invocation_rejected { detail = "keeper name is empty" }
  ; Krf.Chat_identity_mismatch
  ; Krf.Turn_resources_unavailable
      { resource = Krf.Registry_entry_missing; detail = "no entry" }
  ; Krf.Turn_resources_unavailable
      { resource = Krf.Registry_entry_unhealthy; detail = "stale pid" }
  ; Krf.Runtime_selection_failed { detail = "no runtime for lane" }
  ; Krf.Turn_continuation_unpersisted
      { stage = Krf.Continuation_load; detail = "decode failed" }
  ; Krf.Turn_continuation_unpersisted { stage = Krf.Gate_suspend; detail = "no slot" }
  ; Krf.Turn_continuation_unpersisted
      { stage = Krf.Runtime_continuation_defer; detail = "write failed" }
  ; Krf.Turn_continuation_unpersisted
      { stage = Krf.Checkpoint_retain; detail = "no receipt" }
  ; Krf.User_row_unpersisted { detail = "append failed" }
  ; Krf.Gate_session_full
      { approval_id = "approval-1"
      ; runtime_id = "claude_code"
      ; session_id = "session-1"
      ; recovery_id = "00000000-0000-4000-8000-000000000001"
      ; activity = Kie.No_activity_observed
      }
  ; Krf.Gate_session_full
      { approval_id = "approval-2"
      ; runtime_id = "codex"
      ; session_id = "thread-1"
      ; recovery_id = "00000000-0000-4000-8000-000000000002"
      ; activity = Kie.Activity_observed
      }
  ; Krf.Reply_contract_rejected { field = Krf.Reply_payload; detail = "not an object" }
  ; Krf.Reply_contract_rejected { field = Krf.Turn_outcome; detail = "missing" }
  ; Krf.Reply_contract_rejected { field = Krf.Turn_ref; detail = "invalid" }
  ; Krf.Reply_contract_rejected
      { field = Krf.External_effect_target; detail = "unknown target" }
  ; Krf.No_visible_reply { stage = Krf.Terminal_projection; had_blocks = false }
  ; Krf.No_visible_reply { stage = Krf.Queued_delivery; had_blocks = true }
  ; Krf.Raised { site = Krf.Stream_dispatch; exn = "Not_found" }
  ; Krf.Raised { site = Krf.Stream_streaming_call; exn = "Not_found" }
  ; Krf.Raised { site = Krf.Stream_turn_body; exn = "Not_found" }
  ; Krf.Raised { site = Krf.Stream_submit; exn = "Not_found" }
  ; Krf.Provider_auth_required { provider = Some "claude_code"; detail = "sign in required" }
  ; Krf.Provider_auth_required { provider = None; detail = "missing session" }
  ; Krf.Provider_key_refused { provider = "claude_code"; detail = "HTTP 401 invalid x-api-key" }
  ; Krf.Provider_quota_exhausted
      { provider = Some "claude_code"; retry_after = Some 120.0; detail = "quota spent" }
  ; Krf.Provider_quota_exhausted { provider = None; retry_after = None; detail = "out of quota" }
  ; Krf.Provider_spawn_refused { provider = "codex_app_server"; detail = "executable not found" }
  ; Krf.Provider_timeout
      { provider = Some "claude_code"; phase = Some "response_idle"; detail = "timed out" }
  ; Krf.Provider_timeout { provider = None; phase = None; detail = "timed out" }
  ; Krf.Configuration_refused { field = "model"; detail = "invalid config" }
  ]
  @ List.map (fun refusal -> Krf.Account_refused refusal) Keeper_account_refusal.all
;;

let test_every_constructor_round_trips () =
  List.iter
    (fun cause ->
       let failure = { Krf.cause } in
       match Krf.of_yojson (Krf.to_yojson failure) with
       | Ok decoded -> Alcotest.check cause_testable "round trip" cause decoded.Krf.cause
       | Error detail -> Alcotest.fail ("round trip refused its own output: " ^ detail))
    every_cause
;;

let test_every_constructor_has_a_one_line_summary () =
  List.iter
    (fun cause ->
       let summary = summary_of cause in
       if String.trim summary = ""
       then Alcotest.fail "a cause with no summary leaves the operator nothing";
       if String.exists (function '\n' | '\r' -> true | _ -> false) summary
       then Alcotest.fail ("summary spans lines: " ^ summary))
    every_cause
;;

let refused what json =
  match Krf.of_yojson json with
  | Ok _ -> Alcotest.fail (what ^ " was accepted")
  | Error _ -> ()
;;

let test_the_decoder_refuses_what_it_does_not_write () =
  refused "an unknown kind" (`Assoc [ "cause", `Assoc [ "kind", `String "vibes" ] ]);
  refused
    "a missing field"
    (`Assoc [ "cause", `Assoc [ "kind", `String "keeper_not_registered" ] ]);
  refused
    "an extra field"
    (`Assoc
       [ ( "cause"
         , `Assoc
             [ "kind", `String "server_restarted"; "detail", `String "why" ] )
       ]);
  refused
    "a field of the wrong type"
    (`Assoc
       [ ( "cause"
         , `Assoc
             [ "kind", `String "no_visible_reply"
             ; "stage", `String "queued_delivery"
             ; "had_blocks", `String "true"
             ] )
       ]);
  refused
    "an unknown labelled value"
    (`Assoc
       [ ( "cause"
         , `Assoc
             [ "kind", `String "turn_continuation_unpersisted"
             ; "stage", `String "somewhere_else"
             ; "detail", `String "x"
             ] )
       ]);
  refused
    "a stated wait of the wrong type"
    (`Assoc
       [ ( "cause"
         , `Assoc
             [ "kind", `String "provider_rate_limited"
             ; "provider", `Null
             ; "retry_after", `String "12"
             ; "detail", `String "x"
             ] )
       ]);
  refused "an extra top-level field"
    (`Assoc
       [ "cause", `Assoc [ "kind", `String "input_capacity" ]
       ; "summary", `String "derived state does not belong on the wire"
       ]);
  refused "a cause that is not an object" (`Assoc [ "cause", `String "input_capacity" ]);
  refused "a failure that is not an object" (`String "input_capacity")
;;

let contains_sub haystack needle =
  let hlen = String.length haystack and nlen = String.length needle in
  if nlen = 0 then true
  else
    let rec loop i =
      if i + nlen > hlen then false
      else if String.sub haystack i nlen = needle then true
      else loop (i + 1)
    in
    loop 0
;;

let test_failure_kind_wire_round_trip () =
  List.iter
    (fun kind ->
       let wire = Krf.Failure_kind.to_wire kind in
       match Krf.Failure_kind.of_wire wire with
       | Some decoded ->
         Alcotest.(check bool) ("wire round-trip " ^ wire) true
           (Krf.Failure_kind.equal kind decoded)
       | None -> Alcotest.fail ("failed to decode own failure_kind wire label: " ^ wire))
    Krf.Failure_kind.all;
  Alcotest.(check bool) "unknown wire label is None" true
    (Option.is_none (Krf.Failure_kind.of_wire "unknown_kind"))
;;

let test_split_failure_kinds_stay_distinct () =
  let check label expected cause =
    let actual = Krf.failure_kind_of_cause cause in
    Alcotest.(check string) label
      (Krf.Failure_kind.to_wire expected)
      (Krf.Failure_kind.to_wire actual)
  in
  check "auth error -> not_signed_in"
    Krf.Failure_kind.Not_signed_in
    (Krf.of_core_error
       (Agent_core.Error.Provider
          (Llm_provider.Error.AuthError { provider = "claude_code"; detail = "expired" })))
      .Krf.cause;
  check "key refused -> key_refused"
    Krf.Failure_kind.Key_refused
    (Krf.of_core_error
       (Keeper_provider_refusal.core_error
          (Keeper_provider_refusal.Key_refused { provider = "claude_code"; detail = "401" })))
      .Krf.cause;
  check "key file missing -> key_unusable"
    Krf.Failure_kind.Key_unusable
    (Krf.Account_refused (Keeper_account_refusal.Key_unusable Keeper_account_refusal.Key_missing));
  check "hard quota -> no_quota"
    Krf.Failure_kind.No_quota
    (Krf.of_core_error
       (Agent_core.Error.Provider
          (Llm_provider.Error.HardQuota
             { provider = "claude_code"; retry_after = None; detail = "spent" })))
      .Krf.cause;
  check "timeout -> silent"
    Krf.Failure_kind.Silent
    (Krf.of_core_error
       (Agent_core.Error.Provider
          (Llm_provider.Error.Timeout
             { provider = "claude_code"; timeout_phase = None; detail = "idle" })))
      .Krf.cause;
  check "spawn refused -> not_started"
    Krf.Failure_kind.Not_started
    (Krf.of_core_error
       (Keeper_provider_refusal.core_error
          (Keeper_provider_refusal.Spawn_refused { provider = "codex_app_server"; detail = "enoent" })))
      .Krf.cause;
  check "unknown keeper -> turn_refused"
    Krf.Failure_kind.Turn_refused
    (Krf.Account_refused Keeper_account_refusal.Unknown_keeper);
  check "runtime reassigned -> runtime_reassigned"
    Krf.Failure_kind.Runtime_reassigned
    (Krf.Account_refused Keeper_account_refusal.Runtime_reassigned);
  check "zone uncertain -> server_unavailable"
    Krf.Failure_kind.Server_unavailable
    (Krf.Account_refused Keeper_account_refusal.Authorization_zone_uncertain);
  check "pat expired -> turn_refused"
    Krf.Failure_kind.Turn_refused
    (Krf.Account_refused Keeper_account_refusal.Pat_expired);
  check "config error -> configuration_refused"
    Krf.Failure_kind.Configuration_refused
    (Krf.of_core_error
       (Agent_core.Error.Config (Agent_core.Error.InvalidConfig { field = "model"; detail = "bad" })))
      .Krf.cause;
  check "operator interrupt -> cancelled"
    Krf.Failure_kind.Cancelled
    Krf.Operator_cancelled;
  check "no visible reply -> no_visible_reply"
    Krf.Failure_kind.No_visible_reply
    (Krf.No_visible_reply { stage = Krf.Queued_delivery; had_blocks = false })
;;

let test_account_refused_driver_and_redaction () =
  let check_no_leak label text =
    List.iter
      (fun forbidden ->
         if contains_sub text forbidden then
           Alcotest.failf "%s leaked %S in %S" label forbidden text)
      [ "/Users/"; "/tmp/"; "/private/"; "/var/"; "/home/"; ".masc/"; "sk-ant-" ]
  in
  List.iter
    (fun refusal ->
       let summary = summary_of (Krf.Account_refused refusal) in
       check_no_leak ("account refusal " ^ Keeper_account_refusal.to_wire refusal) summary)
    Keeper_account_refusal.all;
  let core_err =
    Masc.Keeper_turn_driver.account_refused
      (Runtime_account_access.Home_unresolved "/Users/alice/.masc/accounts/p1/home")
  in
  let projected = Krf.of_core_error core_err in
  Alcotest.check cause_testable "Home_unresolved stays typed without path"
    (Krf.Account_refused Keeper_account_refusal.Account_home_unresolved)
    projected.Krf.cause;
  check_no_leak "projected Home_unresolved summary" (Krf.summary projected);
  let dirty =
    "failed reading file:///Users/alice/repo/.masc/accounts/p1/key and file:///tmp/secret.txt with \
     sk-ant-api03-verysecretkeyvalue123456 on https://api.example.com/v1/messages and \
     profile://alice/workspace/item\nnext"
  in
  let scrubbed = Krf.sanitize_person_text dirty in
  check_no_leak "sanitize_person_text" scrubbed;
  Alcotest.(check bool) "URLs stay intact" true
    (contains_sub scrubbed "https://api.example.com/v1/messages");
  Alcotest.(check bool) "profile:// scheme suffix is not treated as file://" true
    (contains_sub scrubbed "profile://alice/workspace/item");
  Alcotest.(check bool) "newlines collapsed" false
    (String.contains scrubbed '\n')
;;

let test_a_nested_masc_error_is_an_object_not_a_string () =
  let failure =
    { Krf.cause = Krf.Masc (Kie.Receipt_persistence_failed { detail = "disk full" }) }
  in
  match Krf.to_yojson failure with
  | `Assoc [ ("cause", `Assoc fields) ] ->
    (match List.assoc_opt "error" fields with
     | Some (`Assoc _) -> ()
     | Some _ | None ->
       Alcotest.fail "a nested MASC error must be written as the object it is")
  | _ -> Alcotest.fail "a failure is a one-field object"
;;

let () =
  Alcotest.run
    "keeper request failure"
    [ ( "producer to constructor"
      , [ Alcotest.test_case
            "an agent-core transport failure"
            `Quick
            test_api_network_becomes_provider_network
        ; Alcotest.test_case
            "a provider transport failure"
            `Quick
            test_provider_network_keeps_its_provider
        ; Alcotest.test_case
            "an agent-core connect failure"
            `Quick
            test_api_connect_failed_becomes_provider_connect_failed
        ; Alcotest.test_case
            "a provider connect failure"
            `Quick
            test_provider_connect_failed_keeps_its_provider
        ; Alcotest.test_case
            "a context overflow"
            `Quick
            test_context_overflow_carries_the_window
        ; Alcotest.test_case
            "an agent-core rate limit keeps the stated wait"
            `Quick
            test_api_rate_limit_keeps_the_stated_wait
        ; Alcotest.test_case
            "a rate limit with no stated wait carries none"
            `Quick
            test_rate_limit_without_a_stated_wait_stays_empty
        ; Alcotest.test_case
            "a provider rate limit keeps its provider and wait"
            `Quick
            test_provider_rate_limit_keeps_its_provider
        ; Alcotest.test_case
            "an integer wait on the canonical wire"
            `Quick
            test_rate_limit_keeps_integer_wire_wait
        ; Alcotest.test_case
            "a rate limit summary shows the wait only when reported"
            `Quick
            test_rate_limit_summary_shows_the_wait_only_when_reported
        ; Alcotest.test_case
            "a carried MASC error"
            `Quick
            test_carried_masc_error_stays_a_masc_value
        ; Alcotest.test_case
            "an agent-core failure with no arm of its own"
            `Quick
            test_unnamed_agent_core_failure_stays_core
        ; Alcotest.test_case
            "the operator interrupt detail"
            `Quick
            test_operator_interrupt_detail_is_the_typed_summary
        ; Alcotest.test_case
            "split failure kinds stay distinct"
            `Quick
            test_split_failure_kinds_stay_distinct
        ; Alcotest.test_case
            "account refusal carriage and redaction"
            `Quick
            test_account_refused_driver_and_redaction
        ] )
    ; ( "summary"
      , [ Alcotest.test_case "one line" `Quick test_a_summary_is_one_line
        ; Alcotest.test_case
            "a caught exception"
            `Quick
            test_a_raised_summary_names_its_site_and_is_one_line
        ; Alcotest.test_case
            "a MASC kind with no summary"
            `Quick
            test_a_masc_summary_without_one_keeps_the_envelope
        ; Alcotest.test_case
            "every constructor answers"
            `Quick
            test_every_constructor_has_a_one_line_summary
        ] )
    ; ( "codec"
      , [ Alcotest.test_case
            "every constructor round trips"
            `Quick
            test_every_constructor_round_trips
        ; Alcotest.test_case
            "failure kind wire round trips"
            `Quick
            test_failure_kind_wire_round_trip
        ; Alcotest.test_case
            "strict decoding"
            `Quick
            test_the_decoder_refuses_what_it_does_not_write
        ; Alcotest.test_case
            "a nested MASC error"
            `Quick
            test_a_nested_masc_error_is_an_object_not_a_string
        ] )
    ]
;;
