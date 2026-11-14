open Alcotest
open Masc
module Registry = Runtime_exact_output_registry
module Backpressure = Runtime_candidate_backpressure
module Lane = Runtime_exact_lane_backpressure

let require_ok label = function Ok x -> x | Error _ -> fail label

let primary = "openrouter.primary"
let secondary = "openrouter.secondary"

(* Two HTTP slots on one lane, each its own runtime and therefore its own
   backpressure cell. HITL is declared too because bootstrap refuses a
   runtime.toml without both mandatory lanes. No request leaves the process. *)
let runtime_toml = {|[runtime]
default = "openrouter.primary"
[runtime.exact_output_lanes.board_attention_exact]
slots = ["openrouter.primary", "openrouter.secondary"]
[runtime.exact_output_lanes.hitl_auto_judge]
slots = ["openrouter.primary", "openrouter.secondary"]
[providers.openrouter]
protocol = "openai-compatible-http"
endpoint = "https://openrouter.ai/api/v1"
connect-timeout-s = 180.0
exact-body-timeout-s = 180.0
[providers.openrouter.credentials]
type = "env"
key = "OPENROUTER_API_KEY"
[models.primary]
api-name = "z-ai/glm-5.3-flash"
tools-support = true
[models.secondary]
api-name = "deepseek/deepseek-v4-flash"
tools-support = true
[openrouter.primary]
[openrouter.secondary]
|}

let candidate runtime_id =
  match Runtime.get_runtime_by_id runtime_id with
  | Some (runtime : Runtime_instance.t) -> runtime.candidate_backpressure
  | None -> failf "runtime %s is not in the catalog" runtime_id

let with_lane_config ?(runtime_text = runtime_toml) f =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Masc_test_deps.with_process_env "AGENT_CORE_MODEL_CATALOG" None @@ fun () ->
  Masc_test_deps.with_process_env "OPENROUTER_API_KEY" (Some "synthetic-no-network") @@ fun () ->
  let root = Filename.temp_dir "exact-lane-backpressure-" "" in
  let previous_runtime = Runtime.For_testing.snapshot () in
  let previous_startup = Runtime_startup_state.get () in
  let previous_catalog = Llm_provider.Catalog_snapshot.current () in
  Fun.protect ~finally:(fun () ->
    Registry.unpublish () |> require_ok "unpublish fixture registry";
    Runtime.For_testing.restore previous_runtime;
    Runtime_startup_state.set previous_startup;
    (Llm_provider.Catalog_snapshot.publish previous_catalog);
    Fs_compat.remove_tree root) @@ fun () ->
  (Llm_provider.Catalog_snapshot.reset ());
  let path = Filename.concat root "runtime.toml" in
  Fs_compat.save_file path runtime_text;
  Runtime.init_default ~config_path:path |> require_ok "runtime initialization";
  Server_runtime_bootstrap.For_testing.configure_exact_output_registry ~config_root:root ();
  let registry = Registry.current () |> require_ok "published registry" in
  let resolved =
    Registry.resolve_lane registry ~lane_id:"board_attention_exact"
    |> require_ok "resolved lane"
  in
  (* A re-initialised catalog keeps an unchanged row's backpressure cell
     (Runtime.preserve_candidate), so a rest one test left would leak into
     the next. Every test starts from empty cells. *)
  List.iter
    (fun runtime_id -> Backpressure.note_candidate_success ~candidate:(candidate runtime_id))
    [ primary; secondary ];
  f ~path resolved

let with_lane f = with_lane_config (fun ~path:_ resolved -> f resolved)

let slot_ids (resolved : Registry.resolved_lane) =
  List.map (fun (slot : Registry.selected_slot) -> slot.slot_id) resolved.selected_slots

(* What the lane will call, in walk order. *)
let walked (ordered : Lane.ordered) = slot_ids ordered.lane

(* What the lane holds, with the time each one waits for. *)
let held (ordered : Lane.ordered) =
  List.map (fun (slot : Lane.held_slot) -> slot.slot_id, slot.until) ordered.held_http

let held_ids ordered = List.map fst (held ordered)

(* The rate limit's own stamp, so every [now] below is a distance from it. *)
let note_rate_limit runtime_id ~retry_after =
  let candidate = candidate runtime_id in
  Backpressure.note_rate_limit ~candidate ~retry_after;
  match
    Backpressure.candidate_backpressure ~now:(Unix.gettimeofday ()) ~candidate
  with
  | Some
      { Backpressure.rate_limit =
          Some (Backpressure.Unknown_scope_rate_limit { noted_at; _ })
      ; _
      } -> noted_at
  | Some { Backpressure.rate_limit = None; _ } | None ->
    failf "rate limit on %s was not recorded" runtime_id

let declared = [ primary; secondary ]
let demoted = [ secondary; primary ]

(* RFC-exact-lane-waits-for-a-stated-reset R1: a Retry-After is a time the
   provider stated, so the lane does not call the slot before it. Before this
   rule the slot only went behind, and a lane whose sibling also refused
   called it inside the provider's own Retry-After. *)
let test_retry_after_holds_the_slot_until_its_time () =
  with_lane @@ fun resolved ->
  let fresh = Lane.order_at ~now:(Unix.gettimeofday ()) resolved in
  check (list string) "no evidence walks the declared order" declared (walked fresh);
  check (list string) "and holds nothing" [] (held_ids fresh);
  let noted_at = note_rate_limit primary ~retry_after:(Some 30.0) in
  let inside = Lane.order_at ~now:(noted_at +. 1.0) resolved in
  check (list string) "inside the provider's Retry-After the slot is not walked"
    [ secondary ] (walked inside);
  check (list (pair string (float 0.0))) "it is held until the stated time"
    [ primary, noted_at +. 30.0 ] (held inside);
  let at_time = Lane.order_at ~now:(noted_at +. 30.0) resolved in
  check (list string) "at the stated time the slot is walked in its place" declared
    (walked at_time);
  check (list string) "and no longer held" [] (held_ids at_time)

(* A 429 with no Retry-After states no time: the floor is a rest MASC chose,
   so the slot only goes behind for it (R2). *)
let test_unhinted_rate_limit_rests_the_floor_then_returns () =
  with_lane @@ fun resolved ->
  let floor = Env_config_keeper.KeeperKeepalive.rate_limit_backoff_floor_sec in
  let noted_at = note_rate_limit primary ~retry_after:None in
  let inside = Lane.order_at ~now:(noted_at +. floor -. 1.0) resolved in
  check (list string) "inside the configured floor the slot goes behind" demoted
    (walked inside);
  check (list string) "and is not held" [] (held_ids inside);
  check (list string) "after the configured floor the slot is back in its place" declared
    (walked (Lane.order_at ~now:(noted_at +. floor +. 1.0) resolved))

let test_provider_hint_outlives_the_fallback_cap () =
  with_lane @@ fun resolved ->
  let cap = Env_config_keeper.KeeperKeepalive.rate_limit_backoff_cap_sec in
  let retry_after = cap +. 3600.0 in
  let noted_at = note_rate_limit primary ~retry_after:(Some retry_after) in
  check (list string) "the fallback cap does not release the refused slot"
    [ primary ] (held_ids (Lane.order_at ~now:(noted_at +. cap +. 1.0) resolved));
  check (list string) "the provider release restores declared order" declared
    (walked (Lane.order_at ~now:(noted_at +. retry_after +. 1.0) resolved))

let test_answer_clears_the_rest () =
  with_lane @@ fun resolved ->
  let noted_at = note_rate_limit primary ~retry_after:(Some 30.0) in
  Backpressure.note_candidate_success ~candidate:(candidate primary);
  let ordered = Lane.order_at ~now:(noted_at +. 1.0) resolved in
  check (list string) "an answer clears the rest at once" declared (walked ordered);
  check (list string) "and holds nothing" [] (held_ids ordered)

(* R4: a lane whose every slot waits for a stated time walks none of them,
   and still names each one with its time, in declared order. *)
let test_every_slot_held_walks_none () =
  with_lane @@ fun resolved ->
  let noted_at = note_rate_limit primary ~retry_after:(Some 30.0) in
  let secondary_noted_at = note_rate_limit secondary ~retry_after:(Some 60.0) in
  let ordered = Lane.order_at ~now:(noted_at +. 1.0) resolved in
  check (list string) "a lane of held slots walks none" [] (walked ordered);
  check (list (pair string (float 0.0))) "and names every slot with its own time"
    [ primary, noted_at +. 30.0; secondary, secondary_noted_at +. 60.0 ]
    (held ordered)

let with_quota_window f =
  Runtime_quota_window.reset_for_testing ();
  Fun.protect ~finally:Runtime_quota_window.reset_for_testing f

let runtime_scope id =
  match Runtime.get_runtime_by_id id with
  | Some runtime -> Runtime_instance.quota_scope_of_runtime runtime
  | None -> fail ("missing runtime scope " ^ id)

(* The loop the RFC measured (section 1.1): the lane's account had a stated
   reset, and every run called it again. A stated reset now holds every slot
   on that account until the reset; an observation without a reset still
   only moves them back (R2). Where a slot also has its own Retry-After, the
   later time wins. A success on the account does not lift the reset: the
   success can belong to a call admitted before the statement (a Muse turn
   states its reset mid-turn, then answers). *)
let test_stated_account_reset_holds_every_slot_on_it () =
  with_lane @@ fun resolved ->
  with_quota_window @@ fun () ->
  let scope = runtime_scope primary in
  check bool "the declared slots share one account" true
    (Runtime_quota_window.scope_equal scope (runtime_scope secondary));
  let now = Unix.gettimeofday () in
  Runtime_quota_window.note_observed_exhausted ~source:Runtime_quota_window.Provider_quota_refused ~scope;
  let observed = Lane.order_at ~now resolved in
  check (list string) "an observation without a reset walks every slot" declared
    (walked observed);
  check (list string) "and holds none" [] (held_ids observed);
  let resets_at = now +. 3600.0 in
  Runtime_quota_window.note_exhausted ~source:Runtime_quota_window.Provider_quota_refused ~scope ~resets_at;
  let noted_at = note_rate_limit primary ~retry_after:(Some 7200.0) in
  let stated = Lane.order_at ~now resolved in
  check (list string) "a stated reset walks no slot on that account" [] (walked stated);
  check (list (pair string (float 0.0)))
    "each slot waits for the later of the reset and its own Retry-After"
    [ primary, noted_at +. 7200.0; secondary, resets_at ]
    (held stated);
  Backpressure.note_candidate_success ~candidate:(candidate primary);
  Runtime_quota_window.note_succeeded ~scope;
  check (list string) "a success leaves the stated reset holding every slot" declared
    (held_ids (Lane.order_at ~now resolved));
  check (list string) "at the stated reset itself every slot is walked" declared
    (walked (Lane.order_at ~now:resets_at resolved));
  check (list string) "once the stated times pass every slot is walked again" declared
    (walked (Lane.order_at ~now:(noted_at +. 7200.0) resolved))

let test_unchanged_save_shares_pressure_cell () =
  with_lane_config @@ fun ~path _resolved ->
  let original = candidate primary in
  Runtime.save_config_text ~runtime_config_path:path runtime_toml
    |> require_ok "save unchanged binding" |> ignore;
  let current = candidate primary in
  let registry = Registry.current () |> require_ok "replacement registry" in
  let resolved = Registry.resolve_lane registry ~lane_id:"board_attention_exact"
    |> require_ok "replacement lane" in
  let slot = List.hd resolved.Registry.selected_slots in
  let observation = match slot.runtime_observation with
    | Some observation -> observation
    | None -> fail "runtime binding must carry an observation" in
  check bool "unchanged binding keeps original pressure" true (original == current);
  check bool "replacement registry shares live Keeper pressure" true
    (observation.candidate == current);
  check int "full replacement catalog cannot inherit runtime cells" 0
    (List.length (Runtime.exact_output_runtime_observations
      ~origin:(Runtime.Replacement_catalog_targets { path = "fixture" })
      (fst (Runtime.runtimes_and_media_failover ()))))

let test_rebound_account_observation env ~rate_limited () =
  let module Exact = Agent_core.Exact_output in
  let module Fixture = Exact_output_fixture in
  Eio.Switch.run @@ fun sw ->
  let behavior =
    if rate_limited then
      Fixture.Reply_with (fun _ _ -> `Too_many_requests, "{\"error\":{\"message\":\"rate limited\"}}")
    else Fixture.Reply (Fixture.openai_response (`Assoc ["ok", `Bool true]))
  in
  let server = Fixture.start_server ~sw ~net:env#net ~clock:env#clock behavior in
  let runtime_text =
    String.concat server.base_url
      (Str.split_delim (Str.regexp_string "https://openrouter.ai/api/v1") runtime_toml)
  in
  with_lane_config ~runtime_text @@ fun ~path resolved ->
  let old_candidate = candidate primary in
  let slot = List.hd resolved.Registry.selected_slots in
  let first = Exact.make_flow_candidate ~id:slot.slot_id ~admitted_target:slot.admitted_target
    |> require_ok "freeze old candidate" in
  let requirement = Exact.make_output_requirement
    ~schema:(`Assoc ["type", `String "object"]) ~minimum_guarantee:Exact.Json_syntax in
  let snapshot = Exact.snapshot_flow ~first ~rest:[]
    ~messages:[Llm_provider.Types.user_msg "return JSON"] requirement
    |> require_ok "freeze old flow" in
  let attempt = Exact.start_flow ~admission_class:Llm_provider.Admission_class.Standard snapshot |> require_ok "start old flow" in
  Masc_test_deps.with_process_env "OPENROUTER_API_KEY" (Some "synthetic-rebound-account")
    (fun () -> Runtime.save_config_text ~runtime_config_path:path runtime_text
      |> require_ok "rebind same runtime ID" |> ignore);
  let new_candidate = candidate primary in
  check bool "changed account owns a different pressure cell" false
    (old_candidate == new_candidate);
  if not rate_limited then (
    Backpressure.note_rate_limit ~candidate:old_candidate ~retry_after:(Some 30.0);
    Backpressure.note_rate_limit ~candidate:new_candidate ~retry_after:(Some 30.0));
  let result = Exact.execute_flow_once ~net:env#net ~clock:env#clock
    ~before_measurement_dispatch:(fun _ -> Ok ())
    ~on_measurement_terminal:(fun _ -> Ok ()) ~before_dispatch:(fun _ -> Ok ())
    ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
    ~validate:(fun _ -> Exact.Accept ()) attempt in
  check bool "fixture returned expected outcome" (not rate_limited) (Result.is_ok result);
  Lane.observe ~resolved result;
  let limited candidate =
    match Backpressure.candidate_backpressure ~now:(Unix.gettimeofday ()) ~candidate with
    | Some { Backpressure.rate_limit = Some _; _ } -> true
    | Some { Backpressure.rate_limit = None; _ } | None -> false
  in
  check bool "old result updates original account" rate_limited (limited old_candidate);
  check bool "old result preserves new account" (not rate_limited) (limited new_candidate);
  check int "one real generation request" 1 (Atomic.get server.posts)

let execute_first_slot env (resolved : Registry.resolved_lane) ~validate =
  let module Exact = Agent_core.Exact_output in
  let slot = List.hd resolved.selected_slots in
  let first = Exact.make_flow_candidate ~id:slot.slot_id ~admitted_target:slot.admitted_target
    |> require_ok "freeze actual HTTP candidate" in
  let requirement = Exact.make_output_requirement
    ~schema:(`Assoc ["type",`String "object"]) ~minimum_guarantee:Exact.Json_syntax in
  let snapshot = Exact.snapshot_flow ~first ~rest:[]
    ~messages:[Llm_provider.Types.user_msg "return JSON"] requirement
    |> require_ok "freeze actual HTTP flow" in
  let attempt = Exact.start_flow ~admission_class:Llm_provider.Admission_class.Standard snapshot
    |> require_ok "start actual HTTP flow" in
  Exact.execute_flow_once ~net:env#net ~clock:env#clock
    ~before_measurement_dispatch:(fun _ -> Ok ())
    ~on_measurement_terminal:(fun _ -> Ok ()) ~before_dispatch:(fun _ -> Ok ())
    ~before_advance:(fun ~failed:_ ~next:_ -> Ok ()) ~validate attempt

let with_http_observation_fixture ?(unreachable=false) env behavior f =
  Eio.Switch.run @@ fun sw ->
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock behavior in
  let endpoint = if unreachable then "http://127.0.0.1:1" else server.base_url in
  let runtime_text = String.concat endpoint
    (Str.split_delim (Str.regexp_string "https://openrouter.ai/api/v1") runtime_toml) in
  with_lane_config ~runtime_text @@ fun ~path:_ resolved ->
  Runtime_quota_window.reset_for_testing ();
  Fun.protect ~finally:Runtime_quota_window.reset_for_testing @@ fun () ->
  f ~server resolved

let test_http_payment_records_account_and_provider_reset env () =
  List.iter (fun retry_after ->
    let body = Yojson.Safe.to_string (`Assoc ["error",`Assoc
      (match retry_after with
       | None -> ["message",`String "account cannot pay"]
       | Some seconds -> ["retry_after",`Float seconds])]) in
    with_http_observation_fixture env
      (Exact_output_fixture.Reply_with (fun _ _ -> `Payment_required,body))
      (fun ~server resolved ->
        let before = Unix.gettimeofday () in
        let result = execute_first_slot env resolved
          ~validate:(fun _ -> Agent_core.Exact_output.Accept ()) in
        check bool "actual payment refusal ends the single-candidate flow" true (Result.is_error result);
        Lane.observe ~resolved result;
        let after = Unix.gettimeofday () in
        let scope = runtime_scope primary in
        check bool "the declared slots share account quota authority" true
          (Runtime_quota_window.scope_equal scope (runtime_scope secondary));
        check bool "HTTP 402 records the shared account fact" true
          (Runtime_quota_window.is_exhausted ~scope:(runtime_scope secondary) ~now:after);
        (match retry_after,Runtime_quota_window.active_until ~scope ~now:after with
         | None,None -> ()
         | Some seconds,Some reset ->
           check bool "actual provider reset is preserved without a fallback cap" true
             (reset >= before +. seconds && reset <= after +. seconds)
         | None,Some _ | Some _,None -> fail "402 reset was invented or discarded");
        check bool "payment refusal creates no candidate rate or fake Fleet owner" true
          (Option.is_none (Backpressure.candidate_backpressure ~now:after ~candidate:(candidate primary)));
        let ordered = Lane.order_at ~now:after resolved in
        (match retry_after with
         | None ->
           check (list string) "an undated refusal walks both siblings in declared order"
             declared (walked ordered);
           check (list string) "and holds neither" [] (held_ids ordered)
         | Some _ ->
           check (list string) "a stated reset holds both siblings in declared order"
             declared (held_ids ordered);
           check (list string) "and walks neither" [] (walked ordered));
        check int "one actual HTTP generation refusal" 1 (Atomic.get server.posts)))
    [None;Some 3600.0]

let test_http_answer_clears_undated_account_before_semantic_validation env () =
  List.iter (fun (reject,stated_reset) ->
    with_http_observation_fixture env
      (Exact_output_fixture.Reply (Exact_output_fixture.openai_response (`Assoc ["ok",`Bool true])))
      (fun ~server resolved ->
        let scope = runtime_scope primary in
        let reset = Unix.gettimeofday () +. 3600.0 in
        if stated_reset then Runtime_quota_window.note_exhausted ~source:Runtime_quota_window.Provider_quota_refused ~scope ~resets_at:reset
        else Runtime_quota_window.note_observed_exhausted ~source:Runtime_quota_window.Provider_quota_refused ~scope;
        Backpressure.note_rate_limit ~candidate:(candidate primary) ~retry_after:(Some 180.0);
        Backpressure.note_failed_attempt ~candidate:(candidate primary) ~failure:Server_error
          ~recorded_by:(Backpressure.keeper_recorder ~keeper_name:"exact-answer-fixture");
        let result = execute_first_slot env resolved ~validate:(fun _ ->
          if reject then Agent_core.Exact_output.Reject_and_advance "domain rejected the answer"
          else Agent_core.Exact_output.Accept ()) in
        check bool "actual response has the expected semantic result" (not reject) (Result.is_ok result);
        Lane.observe ~resolved result;
        let now = Unix.gettimeofday () in
        check bool "actual answer clears candidate rate and old Fleet mark" true
          (Option.is_none (Backpressure.candidate_backpressure ~now ~candidate:(candidate primary)));
        check bool "answer clears undated quota and preserves a stated window" stated_reset
          (Runtime_quota_window.is_exhausted ~scope ~now);
        if stated_reset then
          check (option (float 0.0)) "stated reset remains exact" (Some reset)
            (Runtime_quota_window.active_until ~scope ~now);
        check int "semantic validation never dispatches another candidate" 1 (Atomic.get server.posts)))
    [false,false;true,false;false,true]

(* The real HTTP attempt supplies all receipt, candidate and flow evidence.
   Only its public failure cause is replaced with a typed Hard_quota port;
   the loopback provider itself did not return that typed transport result. *)
let test_typed_quota_uses_actual_generation_dispatch_receipt env () =
  List.iter (fun unreachable ->
    with_http_observation_fixture ~unreachable env
      (Exact_output_fixture.Reply_with (fun _ _ -> `Service_unavailable,"unavailable"))
      (fun ~server resolved ->
        let module Exact = Agent_core.Exact_output in
        let result = execute_first_slot env resolved ~validate:(fun _ -> Exact.Accept ()) in
        let substituted = match result with
          | Error (Exact.Flow_execution_terminal
              {cause=Exact.Flow_exact_execution_failed {candidate;cause;evidence};prior_rejections}) ->
            let dispatch = Exact.flow_evidence_generation_dispatch evidence in
            check bool "actual evidence has the expected dispatch fact" (not unreachable)
              (match dispatch with Exact.Generation_dispatch_started -> true | Exact.No_generation_dispatch -> false);
            check int "the actual receipt retains its generation count" (if unreachable then 0 else 1)
              (Exact.receipt_dispatch_count cause.receipt);
            let cause = {cause with Exact.cause=Exact.Completion_failed
              {error=Llm_provider.Http_client.ProviderFailure
                 {kind=Hard_quota {retry_after=None};message="typed quota fixture port"};dispatch}} in
            Error (Exact.Flow_execution_terminal
              {cause=Exact.Flow_exact_execution_failed {candidate;cause;evidence};prior_rejections})
          | Ok _ | Error (Exact.Flow_execution_terminal
              {cause=(Exact.Flow_attempt_already_started _ | Exact.Flow_attempt_start_failed _
                | Exact.Flow_measurement_start_failed _ | Exact.Flow_before_measurement_dispatch_callback_failed _
                | Exact.Flow_measurement_terminal_callback_failed _ | Exact.Flow_before_dispatch_callback_failed _
                | Exact.Flow_before_advance_callback_failed _ | Exact.Flow_candidates_exhausted _);_})
          | Error (Exact.Flow_semantic_candidates_exhausted _) ->
            fail "fixture did not produce an actual generation failure receipt" in
        Lane.observe ~resolved substituted;
        check bool "only dispatched typed quota records account authority" (not unreachable)
          (Runtime_quota_window.is_exhausted ~scope:(runtime_scope primary) ~now:(Unix.gettimeofday ()));
        check bool "typed quota creates no ownerless Fleet failure" true
          (Option.is_none (Backpressure.candidate_backpressure ~now:(Unix.gettimeofday ())
             ~candidate:(candidate primary)));
        check int "observed dispatch count agrees with actual server requests" (if unreachable then 0 else 1)
          (Atomic.get server.posts)))
    [false;true]

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:Fs_compat.clear_fs @@ fun () ->
  run "Exact lane backpressure"
    [ "order", [
        test_case "a Retry-After holds the slot until its time" `Quick
          test_retry_after_holds_the_slot_until_its_time;
        test_case "an unhinted rate limit rests the configured floor, then returns" `Quick
          test_unhinted_rate_limit_rests_the_floor_then_returns;
        test_case "a provider hint outlives the fallback cap" `Quick
          test_provider_hint_outlives_the_fallback_cap;
        test_case "an answer clears the rest" `Quick test_answer_clears_the_rest;
        test_case "a lane of held slots walks none" `Quick test_every_slot_held_walks_none;
        test_case "a stated account reset holds every slot on it" `Quick
          test_stated_account_reset_holds_every_slot_on_it ];
      "account rebind", [
        test_case "unchanged save preserves shared registry pressure" `Quick
          test_unchanged_save_shares_pressure_cell;
        test_case "old refusal does not rate-limit new account" `Quick
          (test_rebound_account_observation env ~rate_limited:true);
        test_case "old success does not clear new account rest" `Quick
          (test_rebound_account_observation env ~rate_limited:false) ];
      "HTTP account observations", [
        test_case "actual payment refusal records account and provider reset" `Quick
          (test_http_payment_records_account_and_provider_reset env);
        test_case "actual answer clears undated quota before semantic validation" `Quick
          (test_http_answer_clears_undated_account_before_semantic_validation env);
        test_case "typed quota port respects actual generation dispatch receipts" `Quick
          (test_typed_quota_uses_actual_generation_dispatch_receipt env) ] ]
