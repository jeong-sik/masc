(* The Librarian's lane as one value (RFC librarian-call-only-proposes L4):
   equal declarations give equal values, a changed slot window gives another
   value, an HTTP slot keeps the window frozen with its target, a slot whose
   window cannot be read leaves no value, and the lane rests only when every
   slot is held. No request leaves the process. *)
open Alcotest
open Masc
module Registry = Runtime_exact_output_registry
module Backpressure = Runtime_candidate_backpressure
module Lane = Librarian_memory_lane

let require_ok label = function Ok x -> x | Error _ -> fail label

let fast = "openrouter.fast"
let wide = "openrouter.wide"
let cli = "claude_code.claude-sonnet-5"

let default_lane =
  "[runtime.exact_output_lanes.librarian_memory]\n\
   slots = [\"openrouter.fast\", \"openrouter.wide\"]\n\
   max_output_tokens = 8192\n"

(* HITL and board attention are declared because bootstrap refuses a
   runtime.toml without both mandatory lanes. The official client never runs:
   no test here walks the lane. [cli_binding] is the whole official-client
   binding table, so a test can leave that runtime out. *)
let runtime_toml
      ?(lane = default_lane)
      ?(wide_context = 400000)
      ?(fast_binding = "")
      ?(cli_binding = "[claude_code.\"claude-sonnet-5\"]\nmax-concurrent = 1")
      ()
  =
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
[providers.claude_code]
protocol = "claude-code"
command = "/usr/bin/true"
is-non-interactive = true
[models.fast]
api-name = "z-ai/glm-5.3-flash"
tools-support = true
max-context = 128000
[models.wide]
api-name = "deepseek/deepseek-v4-flash"
tools-support = true
max-context = %d
[models."claude-sonnet-5"]
api-name = "claude-sonnet-5"
max-context = 200000
tools-support = true
streaming = true
turn-timeout-s = 0
[openrouter.fast]
%s
[openrouter.wide]
%s
|} lane wide_context fast_binding cli_binding

let init_runtime path =
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error detail -> failf "runtime initialization: %s" detail

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
  init_runtime path;
  Server_runtime_bootstrap.For_testing.configure_exact_output_registry ~config_root:root ();
  f ~root (Registry.current () |> require_ok "published registry")

let schema = `Assoc [ "type", `String "object" ]
let schemas = { Lane.range = schema; item_alone = schema; room = schema }
(* The lane value alone: what these cases compare. *)
let resolve registry =
  Result.map fst (Lane.resolve ~prompt:"memory prompt" ~answer_schemas:schemas registry)
;;
let value text = with_registry text (fun ~root:_ registry -> resolve registry)

let lane_value = testable Lane.pp Lane.equal
let unavailable = testable Lane.pp_unavailable Lane.equal_unavailable
let result = result lane_value unavailable

let windows keys = List.map (fun (key : Lane.slot_key) -> key.id, key.window) keys

let test_equal_declarations_give_equal_values () =
  let first = value (runtime_toml ()) |> require_ok "first" in
  let second = value (runtime_toml ()) |> require_ok "second" in
  check lane_value "same declaration, same value" first second;
  check (list (pair string int)) "each slot carries its resolved window"
    [ fast, 128000; wide, 400000 ] (windows first.http)

let test_a_changed_window_gives_another_value () =
  let before = value (runtime_toml ()) |> require_ok "before" in
  let after = value (runtime_toml ~wide_context:350000 ()) |> require_ok "after" in
  check bool "one slot's window changed, so the value changed" false (Lane.equal before after);
  check (list (pair string int)) "only that slot's key changed"
    [ fast, 128000; wide, 350000 ] (windows after.http)

(* The binding's own [max-context] comes before the model's. *)
let test_the_binding_window_comes_first () =
  let resolved = value (runtime_toml ~fast_binding:"max-context = 64000" ()) |> require_ok "resolved" in
  check (list (pair string int)) "the binding's window" [ fast, 64000; wide, 400000 ] (windows resolved.http)

(* A later runtime table does not move an HTTP slot's window: the target and
   its window were frozen together when the registry was published. *)
let test_an_http_window_is_the_one_frozen_with_its_target () =
  with_registry (runtime_toml ()) (fun ~root registry ->
    let path = Filename.concat root "runtime-later.toml" in
    Fs_compat.save_file path (runtime_toml ~wide_context:350000 ());
    init_runtime path;
    let resolved = resolve registry |> require_ok "resolved" in
    check (list (pair string int)) "the windows of the publication" [ fast, 128000; wide, 400000 ]
      (windows resolved.http))

let lane_decl ?(max_output_tokens = Some 8192) ?(cli_slot_ids = []) slot_ids
  : Runtime_schema.exact_output_lane_decl =
  { owner = Runtime_schema.Builtin Standalone_lane.Librarian_memory
  ; enabled = true
  ; slot_ids
  ; cli_slot_ids
  ; max_output_tokens
  ; thinking = None
  }

(* The same resolver snapshot under other declarations, with no runtime
   observation beside any target: a replacement catalog's shape. *)
let republish registry lane =
  match Registry.publish ~lanes:[ lane ] (Registry.resolver_snapshot registry) with
  | Ok registry -> registry
  | Error error -> failf "republish: %s" (Registry.publication_error_to_string error)

let test_the_first_slot_without_a_window_names_the_lane_unknown () =
  with_registry (runtime_toml ()) (fun ~root:_ registry ->
    check result "the first slot in declared order"
      (Error (Lane.Window_unknown { slot = fast }))
      (resolve (republish registry (lane_decl [ fast; wide ]))))

(* A CLI slot reads the active table, as its call does. *)
let test_a_cli_slot_without_a_runtime_leaves_no_value () =
  let lane =
    "[runtime.exact_output_lanes.librarian_memory]\n\
     slots = [\"openrouter.fast\"]\n\
     cli_slots = [\"claude_code.claude-sonnet-5\"]\n\
     max_output_tokens = 8192\n"
  in
  with_registry (runtime_toml ~lane ()) (fun ~root registry ->
    let path = Filename.concat root "runtime-without-cli.toml" in
    Fs_compat.save_file path (runtime_toml ~cli_binding:"" ());
    init_runtime path;
    check result "the CLI slot has no window" (Error (Lane.Window_unknown { slot = cli }))
      (resolve registry))

let test_a_lane_with_no_admitted_slot () =
  with_registry (runtime_toml ()) (fun ~root:_ registry ->
    check result "every declared slot was rejected" (Error Lane.No_admitted_slots)
      (resolve (republish registry (lane_decl [ "openrouter.absent" ]))))

let test_a_table_without_a_reserve () =
  with_registry (runtime_toml ()) (fun ~root:_ registry ->
    check result "no max_output_tokens" (Error Lane.Reserve_undeclared)
      (resolve (republish registry (lane_decl ~max_output_tokens:None [ fast ]))))

let test_the_question_side_comes_from_the_declaration () =
  let lane =
    "[runtime.exact_output_lanes.librarian_memory]\n\
     slots = [\"openrouter.fast\"]\n\
     cli_slots = [\"claude_code.claude-sonnet-5\"]\n\
     max_output_tokens = 8192\n"
  in
  let resolved = value (runtime_toml ~lane ()) |> require_ok "resolved" in
  check int "reserve" 8192 resolved.question.max_output_tokens;
  check (list int) "an HTTP target carries the reserve" [ 8192 ]
    (List.filter_map
       (fun (key : Lane.slot_key) ->
          match key.target with
          | Lane.Http { reserve; _ } -> Some reserve
          | Lane.Cli _ -> None)
       resolved.http);
  check string "prompt is the caller's" "memory prompt" resolved.question.prompt;
  match resolved.cli with
  | [ { id; target = Lane.Cli { runtime_id; api_name }; window } ] ->
    check string "CLI slot id" cli id;
    check string "the runtime it calls" cli runtime_id;
    check string "the model it starts" "claude-sonnet-5" api_name;
    check int "its window" 200000 window
  | keys -> failf "expected one CLI key, got %d" (List.length keys)

let test_unconfigured_and_off_lanes () =
  check result "no table" (Error Lane.Lane_unconfigured) (value (runtime_toml ~lane:"" ()));
  let off =
    "[runtime.exact_output_lanes.librarian_memory]\nenabled = false\nslots = [\"openrouter.fast\"]\n"
  in
  check result "enabled = false" (Error Lane.Lane_off) (value (runtime_toml ~lane:off ()))

(* RFC: nothing grows per pass, so no registry keeps a run of this lane and no
   screen offers its run history. *)
let test_the_lane_keeps_no_run_records () =
  let identity = Standalone_lane.run_identity Standalone_lane.Librarian_memory in
  check bool "no run records" false (Lane_run_identity.keeps_run_records identity);
  check bool "the exact run registry has no lane for it" true
    (Option.is_none (Exact_lane_run_registry.lane_of_run_lane identity))

let empty_lane : Registry.resolved_lane = { selected_slots = []; cli_slots = [] }

let ordered ?(lane = empty_lane) held_http : Runtime_exact_lane_backpressure.ordered =
  { lane; held_http = List.map (fun slot_id -> { Runtime_exact_lane_backpressure.slot_id; until = 100.0 }) held_http }

let cli_order ?(walk = []) held : string Runtime_candidate_standing.exact_order =
  { walk; held = List.map (fun id -> id, 100.0) held }

let held_until = Runtime_exact_lane_backpressure.held_until

let test_held_only_when_every_slot_is_held () =
  check (option (float 0.0)) "every HTTP slot held, no CLI" (Some 100.0)
    (held_until (ordered [ fast ]) ~cli:(cli_order []));
  check (option (float 0.0)) "only CLI slots, all held" (Some 100.0)
    (held_until (ordered []) ~cli:(cli_order [ cli ]));
  check (option (float 0.0)) "a CLI slot may be called" None
    (held_until (ordered [ fast ]) ~cli:(cli_order ~walk:[ cli ] []));
  check (option (float 0.0)) "nothing to walk and nothing held is not resting" None
    (held_until (ordered []) ~cli:(cli_order []))

let note_rate_limit runtime_id =
  match Runtime.get_runtime_by_id runtime_id with
  | Some (runtime : Runtime_instance.t) ->
    Backpressure.note_rate_limit ~candidate:runtime.candidate_backpressure ~retry_after:(Some 30.0)
  | None -> failf "runtime %s is not in the catalog" runtime_id

let clear runtime_id =
  match Runtime.get_runtime_by_id runtime_id with
  | Some (runtime : Runtime_instance.t) ->
    Backpressure.note_candidate_success ~candidate:runtime.candidate_backpressure
  | None -> failf "runtime %s is not in the catalog" runtime_id

(* Both orders are read at one [now]: the lane rests while each declared slot
   is inside its provider's stated time, and walks again once one is not. *)
let test_lane_held_reads_both_orders_at_one_time () =
  with_registry (runtime_toml ()) (fun ~root:_ registry ->
    let lane = Registry.resolve_lane registry ~lane_id:Lane.lane_id |> require_ok "lane" in
    List.iter clear [ fast; wide ];
    let now = Unix.gettimeofday () in
    check bool "nothing held" false (Lane.lane_held ~now lane);
    note_rate_limit fast;
    check bool "one slot may still be called" false (Lane.lane_held ~now:(now +. 1.0) lane);
    note_rate_limit wide;
    check bool "every slot held" true (Lane.lane_held ~now:(now +. 1.0) lane);
    check bool "after the stated time the lane walks again" false
      (Lane.lane_held ~now:(now +. 120.0) lane);
    List.iter clear [ fast; wide ])

let () =
  run "librarian_memory_lane"
    [ ( "value"
      , [ test_case "equal declarations give equal values" `Quick test_equal_declarations_give_equal_values
        ; test_case "a changed window gives another value" `Quick test_a_changed_window_gives_another_value
        ; test_case "the binding window comes first" `Quick test_the_binding_window_comes_first
        ; test_case "an HTTP window is the one frozen with its target" `Quick
            test_an_http_window_is_the_one_frozen_with_its_target
        ; test_case "the first slot without a window names the lane unknown" `Quick
            test_the_first_slot_without_a_window_names_the_lane_unknown
        ; test_case "a CLI slot without a runtime leaves no value" `Quick
            test_a_cli_slot_without_a_runtime_leaves_no_value
        ; test_case "a lane with no admitted slot" `Quick test_a_lane_with_no_admitted_slot
        ; test_case "a table without a reserve" `Quick test_a_table_without_a_reserve
        ; test_case "the question side comes from the declaration" `Quick
            test_the_question_side_comes_from_the_declaration
        ; test_case "unconfigured and off lanes" `Quick test_unconfigured_and_off_lanes
        ; test_case "the lane keeps no run records" `Quick test_the_lane_keeps_no_run_records
        ] )
    ; ( "rest"
      , [ test_case "held only when every slot is held" `Quick test_held_only_when_every_slot_is_held
        ; test_case "lane_held reads both orders at one time" `Quick
            test_lane_held_reads_both_orders_at_one_time
        ] )
    ]
