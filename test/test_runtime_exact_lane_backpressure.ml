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
  | Some (runtime : Runtime.t) -> runtime.candidate_backpressure
  | None -> failf "runtime %s is not in the catalog" runtime_id

let with_lane f =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Masc_test_deps.with_process_env "AGENT_CORE_MODEL_CATALOG" None @@ fun () ->
  Masc_test_deps.with_process_env "OPENROUTER_API_KEY" (Some "synthetic-no-network") @@ fun () ->
  let root = Filename.temp_dir "exact-lane-backpressure-" "" in
  let previous_runtime = Runtime.For_testing.snapshot () in
  let previous_startup = Runtime_startup_state.get () in
  let previous_catalog = Llm_provider.Model_catalog.global () in
  Fun.protect ~finally:(fun () ->
    Registry.unpublish () |> require_ok "unpublish fixture registry";
    Runtime.For_testing.restore previous_runtime;
    Runtime_startup_state.set previous_startup;
    (match previous_catalog with
     | None -> Llm_provider.Model_catalog.clear_global ()
     | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
    Fs_compat.remove_tree root) @@ fun () ->
  Llm_provider.Model_catalog.clear_global ();
  let path = Filename.concat root "runtime.toml" in
  Fs_compat.save_file path runtime_toml;
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
  f resolved

let slot_ids (resolved : Registry.resolved_lane) =
  List.map (fun (slot : Registry.selected_slot) -> slot.slot_id) resolved.selected_slots

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

let test_resting_slot_goes_behind_and_returns_after_retry_after () =
  with_lane @@ fun resolved ->
  check (list string) "no evidence keeps the declared order" declared
    (slot_ids (Lane.order_at ~now:(Unix.gettimeofday ()) resolved));
  let noted_at = note_rate_limit primary ~retry_after:(Some 30.0) in
  check (list string) "inside the provider's Retry-After the slot goes behind" demoted
    (slot_ids (Lane.order_at ~now:(noted_at +. 1.0) resolved));
  check (list string) "after the Retry-After the slot is back in its place" declared
    (slot_ids (Lane.order_at ~now:(noted_at +. 31.0) resolved))

(* The case the second commit fixed: a 429 with no Retry-After used to keep
   the slot behind until it answered, and a lane whose sibling keeps
   answering never asks it again. *)
let test_unhinted_rate_limit_rests_the_floor_then_returns () =
  with_lane @@ fun resolved ->
  let floor = Env_config_keeper.KeeperKeepalive.rate_limit_backoff_floor_sec in
  let noted_at = note_rate_limit primary ~retry_after:None in
  check (list string) "inside the configured floor the slot goes behind" demoted
    (slot_ids (Lane.order_at ~now:(noted_at +. floor -. 1.0) resolved));
  check (list string) "after the configured floor the slot is back in its place" declared
    (slot_ids (Lane.order_at ~now:(noted_at +. floor +. 1.0) resolved))

let test_provider_hint_outlives_the_fallback_cap () =
  with_lane @@ fun resolved ->
  let cap = Env_config_keeper.KeeperKeepalive.rate_limit_backoff_cap_sec in
  let retry_after = cap +. 3600.0 in
  let noted_at = note_rate_limit primary ~retry_after:(Some retry_after) in
  check (list string) "the fallback cap does not promote the refused slot" demoted
    (slot_ids (Lane.order_at ~now:(noted_at +. cap +. 1.0) resolved));
  check (list string) "the provider release restores declared order" declared
    (slot_ids (Lane.order_at ~now:(noted_at +. retry_after +. 1.0) resolved))

let test_answer_clears_the_rest () =
  with_lane @@ fun resolved ->
  let noted_at = note_rate_limit primary ~retry_after:(Some 30.0) in
  Backpressure.note_candidate_success ~candidate:(candidate primary);
  check (list string) "an answer clears the rest at once" declared
    (slot_ids (Lane.order_at ~now:(noted_at +. 1.0) resolved))

let test_every_slot_resting_keeps_declared_order () =
  with_lane @@ fun resolved ->
  let noted_at = note_rate_limit primary ~retry_after:(Some 30.0) in
  ignore (note_rate_limit secondary ~retry_after:(Some 30.0) : float);
  check (list string) "a lane of resting slots keeps every slot, in declared order"
    declared
    (slot_ids (Lane.order_at ~now:(noted_at +. 1.0) resolved))

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:Fs_compat.clear_fs @@ fun () ->
  run "Exact lane backpressure"
    [ "order", [
        test_case "a rate-limited slot goes behind, then returns after Retry-After" `Quick
          test_resting_slot_goes_behind_and_returns_after_retry_after;
        test_case "an unhinted rate limit rests the configured floor, then returns" `Quick
          test_unhinted_rate_limit_rests_the_floor_then_returns;
        test_case "a provider hint outlives the fallback cap" `Quick
          test_provider_hint_outlives_the_fallback_cap;
        test_case "an answer clears the rest" `Quick test_answer_clears_the_rest;
        test_case "every slot resting keeps the declared order" `Quick
          test_every_slot_resting_keeps_declared_order ] ]
