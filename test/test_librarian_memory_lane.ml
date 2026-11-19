(* The Librarian's lane as one value (RFC librarian-call-only-proposes L4):
   equal declarations give equal values, a changed slot window gives another
   value, and the lane rests only when every declared slot is held. No request
   leaves the process. *)
open Alcotest
open Masc
module Registry = Runtime_exact_output_registry
module Lane = Librarian_memory_lane

let require_ok label = function Ok x -> x | Error _ -> fail label

let fast = "openrouter.fast"
let wide = "openrouter.wide"

(* HITL and board attention are declared because bootstrap refuses a
   runtime.toml without both mandatory lanes. *)
let runtime_toml ?(lane = "[runtime.exact_output_lanes.librarian_memory]\nslots = [\"openrouter.fast\", \"openrouter.wide\"]\n")
    ?(wide_context = 400000) () =
  Printf.sprintf {|[runtime]
default = "openrouter.fast"
%s[runtime.exact_output_lanes.board_attention_exact]
slots = ["openrouter.fast"]
[runtime.exact_output_lanes.hitl_auto_judge]
slots = ["openrouter.fast"]
[providers.openrouter]
protocol = "openai-compatible-http"
endpoint = "https://openrouter.ai/api/v1"
connect-timeout-s = 180.0
exact-body-timeout-s = 180.0
[providers.openrouter.credentials]
type = "env"
key = "OPENROUTER_API_KEY"
[models.fast]
api-name = "z-ai/glm-5.3-flash"
tools-support = true
max-context = 128000
[models.wide]
api-name = "deepseek/deepseek-v4-flash"
tools-support = true
max-context = %d
[openrouter.fast]
[openrouter.wide]
|} lane wide_context

let with_registry runtime_text f =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Masc_test_deps.with_process_env "AGENT_CORE_MODEL_CATALOG" None @@ fun () ->
  Masc_test_deps.with_process_env "OPENROUTER_API_KEY" (Some "synthetic-no-network") @@ fun () ->
  let root = Filename.temp_dir "librarian-memory-lane-" "" in
  let previous_runtime = Runtime.For_testing.snapshot () in
  let previous_startup = Runtime_startup_state.get () in
  let previous_catalog = Llm_provider.Catalog_snapshot.current () in
  Fun.protect ~finally:(fun () ->
    Registry.unpublish () |> require_ok "unpublish fixture registry";
    Runtime.For_testing.restore previous_runtime;
    Runtime_startup_state.set previous_startup;
    Llm_provider.Catalog_snapshot.publish previous_catalog;
    Fs_compat.remove_tree root) @@ fun () ->
  Llm_provider.Catalog_snapshot.reset ();
  let path = Filename.concat root "runtime.toml" in
  Fs_compat.save_file path runtime_text;
  Runtime.init_default ~config_path:path |> require_ok "runtime initialization";
  Server_runtime_bootstrap.For_testing.configure_exact_output_registry ~config_root:root ();
  f (Registry.current () |> require_ok "published registry")

let schema = `Assoc [ "type", `String "object" ]
let resolve registry = Lane.resolve ~prompt:"memory prompt" ~answer_schema:schema registry
let value text = with_registry text resolve

let lane_value = testable Lane.pp Lane.equal
let unavailable = testable Lane.pp_unavailable Lane.equal_unavailable
let result = result lane_value unavailable

let windows (lane : Lane.t) = List.map (fun (key : Lane.slot_key) -> key.id, key.window) lane.http

let test_equal_declarations_give_equal_values () =
  let first = value (runtime_toml ()) |> require_ok "first" in
  let second = value (runtime_toml ()) |> require_ok "second" in
  check lane_value "same declaration, same value" first second;
  check (list (pair string int)) "each slot carries its resolved window"
    [ fast, 128000; wide, 400000 ] (windows first)

let test_a_changed_window_gives_another_value () =
  let before = value (runtime_toml ()) |> require_ok "before" in
  let after = value (runtime_toml ~wide_context:350000 ()) |> require_ok "after" in
  check bool "one slot's window changed, so the value changed" false (Lane.equal before after);
  check (list (pair string int)) "only that slot's key changed"
    [ fast, 128000; wide, 350000 ] (windows after)

let test_the_question_side_comes_from_the_declaration () =
  let lane =
    "[runtime.exact_output_lanes.librarian_memory]\nslots = [\"openrouter.fast\"]\nmax_output_tokens = 8192\n"
  in
  let resolved = value (runtime_toml ~lane ()) |> require_ok "resolved" in
  check (option int) "reserve" (Some 8192) resolved.question.max_output_tokens;
  check (list (option int)) "every slot key carries the reserve" [ Some 8192 ]
    (List.map (fun (key : Lane.slot_key) -> key.reserve) resolved.http);
  check string "prompt is the caller's" "memory prompt" resolved.question.prompt

let test_unconfigured_and_off_lanes () =
  check result "no table" (Error Lane.Lane_unconfigured) (value (runtime_toml ~lane:"" ()));
  let off = "[runtime.exact_output_lanes.librarian_memory]\nenabled = false\nslots = [\"openrouter.fast\"]\n" in
  check result "enabled = false" (Error Lane.Lane_off) (value (runtime_toml ~lane:off ()))

let empty_lane : Registry.resolved_lane = { selected_slots = []; cli_slots = [] }

let ordered ?(lane = empty_lane) held_http : Runtime_exact_lane_backpressure.ordered =
  { lane; held_http = List.map (fun slot_id -> { Runtime_exact_lane_backpressure.slot_id; until = 100.0 }) held_http }

let cli ?(walk = []) held : string Runtime_candidate_standing.exact_order =
  { walk; held = List.map (fun id -> id, 100.0) held }

let test_lane_held_only_when_every_slot_is_held () =
  check bool "every HTTP slot held, no CLI" true (Lane.lane_held ~http:(ordered [ fast ]) ~cli:(cli []));
  check bool "only CLI slots, all held" true (Lane.lane_held ~http:(ordered []) ~cli:(cli [ "claude_code.a" ]));
  check bool "a CLI slot may be called" false
    (Lane.lane_held ~http:(ordered [ fast ]) ~cli:(cli ~walk:[ "claude_code.a" ] []));
  check bool "nothing to walk and nothing held is not resting" false
    (Lane.lane_held ~http:(ordered []) ~cli:(cli []));
  with_registry (runtime_toml ()) (fun registry ->
    let lane = Registry.resolve_lane registry ~lane_id:Lane.lane_id |> require_ok "lane" in
    check bool "an HTTP slot may be called" false
      (Lane.lane_held ~http:(ordered ~lane [ wide ]) ~cli:(cli [])))

(* RFC: nothing grows per pass, so no registry keeps a run of this lane and no
   screen offers its run history. *)
let test_the_lane_keeps_no_run_records () =
  let identity = Standalone_lane.run_identity Standalone_lane.Librarian_memory in
  check bool "no run records" false (Lane_run_identity.keeps_run_records identity);
  check bool "the exact run registry has no lane for it" true
    (Option.is_none (Exact_lane_run_registry.lane_of_run_lane identity))

let () =
  run "librarian_memory_lane"
    [ ( "value"
      , [ test_case "equal declarations give equal values" `Quick test_equal_declarations_give_equal_values
        ; test_case "a changed window gives another value" `Quick test_a_changed_window_gives_another_value
        ; test_case "the question side comes from the declaration" `Quick
            test_the_question_side_comes_from_the_declaration
        ; test_case "unconfigured and off lanes" `Quick test_unconfigured_and_off_lanes
        ; test_case "the lane keeps no run records" `Quick test_the_lane_keeps_no_run_records
        ] )
    ; "rest", [ test_case "held only when every slot is held" `Quick test_lane_held_only_when_every_slot_is_held ]
    ]
