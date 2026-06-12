(** Regression: a recovered running keeper must not keep surfacing a stale
    [last_proactive_reason] as [diagnostic.last_error].

    Before the fix, [keeper_diagnostic_json] read the persisted error snapshot
    unconditionally, while [classify_keeper_quiet_reason] suppressed it via the
    supersede guard. The two fields disagreed, so the dashboard "이전 오류"
    badge (sourced from [diagnostic.last_error]) survived server restarts — the
    persisted snapshot is reloaded verbatim and never reset.

    Production shape matters here: keepers do NOT publish an external
    agent-registry record ([.masc/agents/<agent_name>.json] is absent), so the
    real [agent_status] passed in is [{exists=false}]. The supersede therefore
    has to fire on the keeper's OWN signal — a turn completed after the
    erroring proactive cycle ([usage.last_turn_ts] > [proactive_rt.last_ts]).
    The tests pin both: the keeper-self path with the production [{exists=false}]
    status, and the external-registry path for non-keeper participants.

    The error reason modelled here is the deleted tool-retry-budget bug
    (#20624): "Tool retry budget exhausted after 2/2 retries". *)

open Masc

let error_reason = "unified:error:Tool retry budget exhausted after 2/2 retries"

(* Fixed epochs. The erroring proactive cycle is at [proactive_error_ts]; a
   later keeper turn is at [later_turn_ts]. *)
let proactive_error_ts = 1_780_994_419.0 (* ~2026-06-09T08:40Z, echo's real error *)
let later_turn_ts = 1_781_022_342.0 (* ~2026-06-09T16:25Z, echo's real last turn *)
let now_ts = 1_781_100_000.0

(* Local member access avoids pulling yojson in as a direct dune dependency;
   yojson values are plain polymorphic variants. *)
let string_member key json =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String s) -> Some s
      | _ -> None)
  | _ -> None
;;

let nullable_string_member key json =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String s) -> Some s
      | Some `Null | None -> None
      | _ -> None)
  | _ -> None
;;

let meta_with_persisted_error ~proactive_ts ~last_turn_ts =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ ("name", `String "stalekeeper")
        ; ("agent_name", `String "keeper-stalekeeper-agent")
        ; ("trace_id", `String "trace-stalekeeper")
        ; ("runtime_id", `String "ollama_cloud.deepseek-v4-flash")
        ; ("last_proactive_outcome", `String "error")
        ; ("last_proactive_reason", `String error_reason)
        ; ("last_proactive_ts", `Float proactive_ts)
        ; ("last_turn_ts", `Float last_turn_ts)
        ; ("total_turns", `Int 5)
        ; ("proactive_count_total", `Int 5)
        ])
  with
  | Ok meta -> meta
  | Error err -> Alcotest.failf "meta_of_json_fixture failed: %s" err
;;

(* The real agent_status a keeper gets: no agent-registry file -> exists=false. *)
let keeper_agent_status = `Assoc [ ("exists", `Bool false) ]

(* A non-keeper participant that publishes a fresh live agent record. *)
let external_live_agent_status ~last_seen =
  `Assoc
    [ ("exists", `Bool true)
    ; ("status", `String "idle")
    ; ("last_seen_ago_s", `Float 5.0)
    ; ("last_seen", `String last_seen)
    ]
;;

let last_error_of_diagnostic ~meta ~agent_status ~keepalive_running =
  Keeper_status_runtime.keeper_diagnostic_json
    ~meta
    ~agent_status
    ~keepalive_running
    ~history_items:[]
    ~now_ts
  |> string_member "last_error"
;;

let diagnostic_of ~meta ~agent_status ~keepalive_running =
  Keeper_status_runtime.keeper_diagnostic_json
    ~meta
    ~agent_status
    ~keepalive_running
    ~history_items:[]
    ~now_ts
;;

(* Production case: keeper (exists=false agent_status) that turned after its
   erroring proactive cycle. This is the case that previously kept showing
   "이전 오류" across restarts and that the external-signal-only guard could
   never clear. *)
let test_keeper_self_progress_hides_stale_error () =
  let meta =
    meta_with_persisted_error ~proactive_ts:proactive_error_ts ~last_turn_ts:later_turn_ts
  in
  Alcotest.(check (option string))
    "keeper turned after the proactive error -> last_error suppressed"
    None
    (last_error_of_diagnostic ~meta ~agent_status:keeper_agent_status ~keepalive_running:true)
;;

(* Fresh error: the erroring proactive cycle IS the latest turn (timestamps
   equal). Nothing has happened since, so the error is the keeper's current
   state and must stay visible. *)
let test_fresh_error_stays_visible () =
  let meta =
    meta_with_persisted_error ~proactive_ts:proactive_error_ts ~last_turn_ts:proactive_error_ts
  in
  Alcotest.(check (option string))
    "error is the latest turn -> last_error retains the reason"
    (Some error_reason)
    (last_error_of_diagnostic ~meta ~agent_status:keeper_agent_status ~keepalive_running:true)
;;

(* Offline keeper: no keepalive, guard cannot fire, error remains ("최근 오류"). *)
let test_offline_keeper_keeps_error () =
  let meta =
    meta_with_persisted_error ~proactive_ts:proactive_error_ts ~last_turn_ts:later_turn_ts
  in
  Alcotest.(check (option string))
    "offline keeper -> last_error retains the reason"
    (Some error_reason)
    (last_error_of_diagnostic ~meta ~agent_status:keeper_agent_status ~keepalive_running:false)
;;

(* External-registry path (non-keeper participant): a fresh live presence newer
   than all recorded activity supersedes even without keeper self-progress. *)
let test_external_live_signal_hides_stale_error () =
  let meta =
    meta_with_persisted_error ~proactive_ts:proactive_error_ts ~last_turn_ts:proactive_error_ts
  in
  let agent_status = external_live_agent_status ~last_seen:"2026-06-09T16:00:00Z" in
  Alcotest.(check (option string))
    "fresh external live signal -> last_error suppressed"
    None
    (last_error_of_diagnostic ~meta ~agent_status ~keepalive_running:true)
;;

(* Keepers run as supervised fibers and do not normally publish a separate
   [.masc/agents/<agent>.json] record. A live keepalive loop is therefore the
   stronger liveness signal; missing agent-registry state must not make the
   dashboard report the keeper as offline/recovering. *)
let test_keepalive_without_agent_record_is_healthy () =
  let meta =
    meta_with_persisted_error
      ~proactive_ts:(now_ts -. 300.0)
      ~last_turn_ts:(now_ts -. 120.0)
  in
  let diagnostic =
    diagnostic_of ~meta ~agent_status:keeper_agent_status ~keepalive_running:true
  in
  Alcotest.(check (option string))
    "keepalive-running keeper without agent record is healthy"
    (Some "healthy")
    (string_member "health_state" diagnostic);
  Alcotest.(check (option string))
    "missing agent record is not a quiet reason for live keeper fibers"
    None
    (nullable_string_member "quiet_reason" diagnostic)
;;

let () =
  Alcotest.run
    "keeper_diagnostic_stale_last_error"
    [ ( "supersede of persisted proactive error"
      , [ Alcotest.test_case
            "keeper self-progress hides stale error"
            `Quick
            test_keeper_self_progress_hides_stale_error
        ; Alcotest.test_case
            "fresh error stays visible"
            `Quick
            test_fresh_error_stays_visible
        ; Alcotest.test_case
            "offline keeper keeps error"
            `Quick
            test_offline_keeper_keeps_error
        ; Alcotest.test_case
            "external live signal hides stale error"
            `Quick
            test_external_live_signal_hides_stale_error
        ; Alcotest.test_case
            "keepalive without agent record is healthy"
            `Quick
            test_keepalive_without_agent_record_is_healthy
        ] )
    ]
;;
