(* RFC-0374 probe_surface.

   The cases below are the ones the 2026-08-12 audit actually hit. Each spent a
   real keeper turn to learn something the descriptor table already knew, so
   each is also a statement about what the probe lane is for. *)

open Alcotest

module Probe = Masc.Keeper_capability_probe
module Descriptor = Masc.Keeper_tool_descriptor
module Runner = Runtime_agent_core_runner
module Turn_driver = Masc.Keeper_turn_driver

let verdict = testable (Fmt.of_to_string Probe.verdict_to_string) ( = )

(* A tool the audit used as its Board probe and saw called on healthy
   runtimes. Asserted against a literal, not against another call into the
   projection -- computing the expectation with the function under test would
   make this an identity. *)
let test_board_list_is_projected () =
  check
    verdict
    "masc_board_list reaches the model"
    (Probe.Projected { model_facing_name = "masc_board_list" })
    (Probe.probe_surface ~tool:"masc_board_list")
;;

(* masc_status was in the first probe set and scored 0 everywhere. The audit
   read that as a runtime failure for several turns before finding the tool is
   operator-only (#26924) -- it was never on the keeper surface to begin with.
   probe_surface answers this without a turn. *)
let test_operator_only_is_not_a_runtime_failure () =
  check
    verdict
    "masc_status is withheld from the keeper model"
    Probe.Operator_only
    (Probe.probe_surface ~tool:"masc_status")
;;

(* Same shape, different cause: masc_tasks is the transport name and the
   capability reaches the model as keeper_tasks_list. Probing masc_tasks
   measures the alias policy, so the two must not collapse into one verdict. *)
let test_transport_alias_names_its_projection () =
  match Probe.probe_surface ~tool:"masc_tasks" with
  | Probe.Aliased { projected_by } ->
    check string "masc_tasks is projected by keeper_tasks_list" "keeper_tasks_list" projected_by
  | other ->
    failf "expected an alias verdict for masc_tasks, got: %s" (Probe.verdict_to_string other)
;;

let test_alias_target_is_itself_projected () =
  check
    verdict
    "the alias target reaches the model under its own name"
    (Probe.Projected { model_facing_name = "keeper_tasks_list" })
    (Probe.probe_surface ~tool:"keeper_tasks_list")
;;

let test_unknown_name_is_not_a_silent_negative () =
  check
    verdict
    "an undeclared name is reported as undeclared"
    Probe.Not_a_descriptor
    (Probe.probe_surface ~tool:"masc_definitely_not_a_tool")
;;

(* Karma was one of the seven categories the audit was asked to measure and the
   only one it could not: the keeper has no read path to it. That is a surface
   gap, and the probe should say so instead of leaving the caller to infer it
   from a runtime that never calls anything. *)
let test_karma_has_no_keeper_read_path () =
  List.iter
    (fun tool ->
      check
        verdict
        (tool ^ " is not on the keeper surface")
        Probe.Not_a_descriptor
        (Probe.probe_surface ~tool))
    [ "masc_karma"; "masc_karma_list"; "keeper_karma" ]
;;

(* The load-bearing agreement: probe_surface must not have its own opinion
   about what reaches the model. Every name the real surface publishes has to
   come back Projected under that same name, and nothing else may. *)
let test_agrees_with_the_surface_it_reports_on () =
  let published = Probe.model_facing_names () in
  check bool "the surface is non-empty" true (published <> []);
  List.iter
    (fun name ->
      check
        verdict
        (name ^ " round-trips through probe_surface")
        (Probe.Projected { model_facing_name = name })
        (Probe.probe_surface ~tool:name))
    published;
  let projected_but_unpublished =
    Descriptor.all_descriptors ()
    |> List.filter_map (fun (d : Descriptor.t) ->
      match Probe.probe_surface ~tool:d.public_name with
      | Probe.Projected { model_facing_name } when not (List.mem model_facing_name published)
        -> Some model_facing_name
      | Probe.Projected _
      | Probe.Not_a_descriptor
      | Probe.Operator_only
      | Probe.Aliased _
      | Probe.Withheld_by_schema_error _ -> None)
  in
  check
    (list string)
    "probe_surface projects nothing the surface does not publish"
    []
    projected_but_unpublished
;;

(* A descriptor withheld for a broken schema is a defect, not a policy, and the
   audit's outcome vocabulary had nowhere to put it. Assert the surface is
   currently clean so the day one appears it shows up here rather than as an
   unexplained zero on some runtime. *)
let test_no_descriptor_is_withheld_by_a_schema_error () =
  let withheld =
    Descriptor.all_descriptors ()
    |> List.filter_map (fun (d : Descriptor.t) ->
      match Descriptor.model_schema_errors d with
      | [] -> None
      | errors -> Some (Printf.sprintf "%s: %s" d.public_name (String.concat "; " errors)))
  in
  check (list string) "no descriptor has schema errors" [] withheld
;;


(* probe_invocation, offline. Every case below returns before any provider
   call, which is the point: the errors that can be decided without spending a
   turn must be decided without spending one. *)

let dummy_now () = 0.0

let invocation_error =
  testable (Fmt.of_to_string Probe.invocation_error_to_string) ( = )

let probe_offline ~runtime_id ~tool =
  (* sw/net are never forced on these paths. Eio.Switch.run gives a real
     switch; the net resource is only reached after the lane and surface
     checks pass, and no case here passes both. *)
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      Probe.probe_invocation
        ~sw
        ~net:(Eio.Stdenv.net env)
        ~now:dummy_now
        ~runtime_id
        ~tool
        ~prompt:"probe"
        ()))
;;

let test_operator_only_costs_no_turn () =
  match probe_offline ~runtime_id:"ollama_cloud.deepseek-v4-flash" ~tool:"masc_status" with
  | Error (Probe.Not_on_surface Probe.Operator_only) -> ()
  | Ok inv -> failf "expected a surface refusal, got: %s" (Probe.invocation_to_string inv)
  | Error e -> failf "expected Not_on_surface Operator_only, got: %s" (Probe.invocation_error_to_string e)
;;

let test_unknown_runtime_is_named () =
  match probe_offline ~runtime_id:"not.a.runtime" ~tool:"masc_board_list" with
  | Error (Probe.Unresolvable_runtime _) -> ()
  | Ok inv -> failf "expected an unresolvable runtime, got: %s" (Probe.invocation_to_string inv)
  | Error e -> failf "expected Unresolvable_runtime, got: %s" (Probe.invocation_error_to_string e)
;;

(* The lane guard needs a producer, not just a constructor: without it an
   official-client runtime would be probed over HTTP and the answer would
   describe a path that runtime never takes.

   The default unit-test environment pins MASC_BASE_PATH="" and resolves no
   official-client runtime at all, so iterating the ambient fleet asserts
   nothing -- an earlier draft of this test did exactly that and a mutation
   removing the whole guard still passed. The fixture below loads a runtime
   whose execution is an official-client lane, which is what makes the guard
   reachable. *)
let official_client_runtime_toml ~cli_path ~oauth_source =
  Printf.sprintf
    {|[providers.antigravity]
protocol = "antigravity-cli"
command = %S
is-non-interactive = true
timeout-s = 30.0

[providers.antigravity.credentials]
type = "file"
path = %S

[models.gemini]
api-name = "gemini-fixture"
max-context = 128000

[antigravity.gemini]

[runtime]
default = "antigravity.gemini"
|}
    cli_path
    oauth_source
;;

let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc
;;

let probe_antigravity_offline ~runtime_id ~tool =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      Probe.probe_antigravity_invocation
        ~sw
        ~net:(Eio.Stdenv.net env)
        ~secure_random:(Eio.Stdenv.secure_random env)
        ~mgr:(Eio.Stdenv.process_mgr env)
        ~clock:(Eio.Stdenv.clock env)
        ~fs:(Eio.Stdenv.fs env)
        ~base_path:(Sys.getcwd ())
        ~now:dummy_now
        ~runtime_id
        ~tool
        ~prompt:"probe"
        ()))
;;

(* Same shape as [probe_offline]: every case below is refused before the vendor
   client would be spawned, so [mgr]/[cwd] are real handles that stay unused. *)
let probe_official_client_offline ~runtime_id ~tool =
  Eio_main.run (fun env ->
    Probe.probe_official_client_invocation
      ~mgr:(Eio.Stdenv.process_mgr env)
      ~clock:(Eio.Stdenv.clock env)
      ~fs:(Eio.Stdenv.fs env)
      ~base_path:(Sys.getcwd ())
      ~now:dummy_now
      ~runtime_id
      ~tool
      ~prompt:"probe"
      ())
;;

let test_lane_guard_refuses_an_official_client_runtime () =
  let base = Filename.temp_file "probe-lane" ".d" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  let cli_path = Filename.concat base "fake-cli" in
  write_file cli_path "#!/bin/sh\nexit 0\n";
  Unix.chmod cli_path 0o700;
  let oauth_source = Filename.concat base "oauth-token" in
  write_file oauth_source "operator-oauth-fixture";
  Unix.chmod oauth_source 0o600;
  let runtime_path = Filename.concat base "runtime.toml" in
  write_file runtime_path (official_client_runtime_toml ~cli_path ~oauth_source);
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
      (match Runtime.init_default ~config_path:runtime_path with
       | Ok () -> ()
       | Error e -> failf "fixture config rejected: %s" e);
      (* Control: the fixture must actually produce an official-client lane,
         or this test is back to asserting nothing. *)
      (match Runtime.get_runtime_by_id "antigravity.gemini" with
       | Some { execution = Runtime_execution.Antigravity_cli _; _ } -> ()
       | Some rt ->
         failf "fixture resolved the wrong lane: %s" (Runtime_execution.label rt.Runtime.execution)
       | None -> fail "fixture runtime did not resolve");
      match probe_offline ~runtime_id:"antigravity.gemini" ~tool:"masc_board_list" with
      | Error (Probe.Not_agent_core_lane _) -> ()
      | Ok inv -> failf "an official-client runtime was probed over HTTP: %s" (Probe.invocation_to_string inv)
      | Error e -> failf "expected Not_agent_core_lane, got: %s" (Probe.invocation_error_to_string e))
;;

(* The seed overlay is what makes the probe's request match a keeper turn's.
   Without it agentworld-35b-a3b scored 0/12 while actually calling the tool
   every time: an absent enable_thinking makes Backend_ollama omit the wire
   [think] field, the model's chat template defaults to thinking-on, and the
   call arrives as prose past the budget (masc#28473).

   Built from a bare provider config so removing the overlay in the probe would
   leave these red -- asserting against Runtime_inference output would make the
   expectation a restatement of the function under test. *)
let bare_config () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Ollama
    ~model_id:"agentworld:UD-Q4_K_XL"
    ~base_url:"http://127.0.0.1:11434"
    ()
;;

let show_bool_opt = function
  | None -> "None"
  | Some b -> Printf.sprintf "Some %b" b
;;

let bool_opt = testable (Fmt.of_to_string show_bool_opt) ( = )

(* Any id that resolves no declared seed: the agreement under test is between
   the two functions, and a runtime whose seed came from config would make the
   loop assert the same triple three times. *)
let bool_opts = [ Some true; Some false; None ]

let test_declared_thinking_off_reaches_the_config () =
  let seed =
    { Runtime_inference.thinking_budget = None
    ; thinking_enabled = Some false
    ; preserve_thinking = None
    }
  in
  let out = Runner.apply_inference_seed ~seed (bare_config ()) in
  (* Some false, not None: None is what omits the wire field. *)
  check bool_opt "declared thinking-off reaches the request" (Some false) out.enable_thinking
;;

let test_declared_thinking_on_reaches_the_config () =
  let seed =
    { Runtime_inference.thinking_budget = None
    ; thinking_enabled = Some true
    ; preserve_thinking = Some true
    }
  in
  let out = Runner.apply_inference_seed ~seed (bare_config ()) in
  check bool_opt "declared thinking-on reaches the request" (Some true) out.enable_thinking;
  check bool_opt "preserve_thinking rides along" (Some true) out.preserve_thinking
;;

let test_undeclared_seed_leaves_the_binding_alone () =
  let seed =
    { Runtime_inference.thinking_budget = None
    ; thinking_enabled = None
    ; preserve_thinking = None
    }
  in
  let base = { (bare_config ()) with Llm_provider.Provider_config.enable_thinking = Some true } in
  let out = Runner.apply_inference_seed ~seed base in
  check bool_opt "an absent seed does not clear the binding" (Some true) out.enable_thinking
;;

(* The pin the review asked for (#28530): seed application now exists twice —
   [Runner.apply_inference_seed] on the probe path and
   [Keeper_turn_driver.For_testing.attempt_inference_policy] on the turn path.
   Two implementations of "what does this runtime actually send" is the shape of
   the defect this PR fixes, so their agreement is asserted rather than assumed.

   Both are driven from the same runtime id, because the turn path resolves the
   seed itself — handing the probe a synthetic seed the turn path never sees
   would compare two different questions. The binding is what varies, over every
   declaration combination, which is also where the disagreement lives: an
   undeclared seed axis leaves the turn path writing [None] and the probe path
   keeping the binding's value. *)
let seed_free_runtime_id = "masc-test-no-such-runtime"

let test_probe_and_turn_agree_on_the_seed () =
  let seed = Runtime_inference.for_runtime ~name:seed_free_runtime_id in
  List.iter
    (fun binding_enable ->
      List.iter
        (fun binding_preserve ->
          let binding =
            { (bare_config ()) with
              Llm_provider.Provider_config.enable_thinking = binding_enable
            ; preserve_thinking = binding_preserve
            }
          in
          let probe = Runner.apply_inference_seed ~seed binding in
          let turn =
            Turn_driver.For_testing.attempt_inference_policy
              ~runtime_id:seed_free_runtime_id
              ~fallback_enable_thinking:binding_enable
              ()
          in
          let label field =
            Printf.sprintf
              "%s: binding(enable=%s preserve=%s)"
              field
              (show_bool_opt binding_enable)
              (show_bool_opt binding_preserve)
          in
          check bool_opt (label "enable_thinking")
            turn.attempt_enable_thinking probe.enable_thinking;
          check bool_opt (label "preserve_thinking")
            turn.attempt_preserve_thinking probe.preserve_thinking)
        bool_opts)
    bool_opts
;;

(* Antigravity is the lane the official-client probe still cannot answer, and
   the refusal has to name why: its entry point takes no tool list, so its
   surface exists only once the per-turn MCP bridge is up. Answering from the
   descriptor table instead would report advertisement as consumption, which is
   the exact mistake F1 of the 2026-08-12 audit was. *)
(* detail_of_http_error must keep the Unknown_provider_failure reason: it
   carries the raw exception (the 2026-08-16 probe read five cloud
   providers as rejected because No_default_generator was rendered as a
   bare "unclassified transport exception"). *)
let test_detail_keeps_unknown_failure_reason () =
  let detail =
    Probe.detail_of_http_error
      (Llm_provider.Http_client.ProviderFailure
         { kind =
             Llm_provider.Http_client.Unknown_provider_failure
               { reason = Some "Mirage_crypto_rng.No_default_generator" }
         ; message = "unclassified transport exception"
         })
  in
  Alcotest.(check string)
    "reason survives"
    "provider failure: unclassified transport exception \
     (Mirage_crypto_rng.No_default_generator)"
    detail;
  let bare =
    Probe.detail_of_http_error
      (Llm_provider.Http_client.ProviderFailure
         { kind = Llm_provider.Http_client.Unknown_provider_failure { reason = None }
         ; message = "unclassified transport exception"
         })
  in
  Alcotest.(check string)
    "reasonless failure stays bare"
    "provider failure: unclassified transport exception"
    bare

let test_official_client_probe_refuses_antigravity () =
  let base = Filename.temp_file "probe-agy" ".d" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  let cli_path = Filename.concat base "fake-cli" in
  write_file cli_path "#!/bin/sh\nexit 0\n";
  Unix.chmod cli_path 0o700;
  let oauth_source = Filename.concat base "oauth-token" in
  write_file oauth_source "operator-oauth-fixture";
  Unix.chmod oauth_source 0o600;
  let runtime_path = Filename.concat base "runtime.toml" in
  write_file runtime_path (official_client_runtime_toml ~cli_path ~oauth_source);
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
      (match Runtime.init_default ~config_path:runtime_path with
       | Ok () -> ()
       | Error e -> failf "fixture config rejected: %s" e);
      (* Control: without this the test would pass on a fixture that never
         produced an antigravity lane at all. *)
      (match Runtime.get_runtime_by_id "antigravity.gemini" with
       | Some { execution = Runtime_execution.Antigravity_cli _; _ } -> ()
       | Some rt ->
         failf
           "fixture resolved the wrong lane: %s"
           (Runtime_execution.label rt.Runtime.execution)
       | None -> fail "fixture runtime did not resolve");
      match
        probe_official_client_offline
          ~runtime_id:"antigravity.gemini"
          ~tool:"masc_board_list"
      with
      | Error (Probe.Tools_only_via_mcp_bridge label) ->
        check bool "names the lane it redirected" true (String.length label > 0);
        check bool "points at the probe that publishes the bridge" true
          (String_util.contains_substring
             (Probe.invocation_error_to_string
                (Probe.Tools_only_via_mcp_bridge label))
             "probe_antigravity_invocation")
      | Ok inv ->
        failf
          "antigravity was probed without its MCP bridge: %s"
          (Probe.invocation_to_string inv)
      | Error e ->
        failf
          "expected Tools_only_via_mcp_bridge, got: %s"
          (Probe.invocation_error_to_string e))
;;

(* The mirror of the existing lane guard. Two entry points that spawn different
   machinery must each refuse the other's lane, or a caller reaching for the
   wrong one gets a plausible answer to a question it did not ask. *)
let test_official_client_probe_refuses_an_agent_core_runtime () =
  let base = Filename.temp_file "probe-ac" ".d" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  let runtime_path = Filename.concat base "runtime.toml" in
  write_file
    runtime_path
    "[providers.local]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [local.sample]\n\
     max-request-body-bytes = 65536\n\
     \n\
     [runtime]\n\
     default = \"local.sample\"\n";
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
      (match Runtime.init_default ~config_path:runtime_path with
       | Ok () -> ()
       | Error e -> failf "fixture config rejected: %s" e);
      (match Runtime.get_runtime_by_id "local.sample" with
       | Some { execution = Runtime_execution.Agent_core _; _ } -> ()
       | Some rt ->
         failf
           "fixture resolved the wrong lane: %s"
           (Runtime_execution.label rt.Runtime.execution)
       | None -> fail "fixture runtime did not resolve");
      match
        probe_official_client_offline ~runtime_id:"local.sample" ~tool:"masc_board_list"
      with
      | Error (Probe.Not_official_client_lane _) -> ()
      | Ok inv ->
        failf
          "an Agent Core runtime was probed by spawning a client: %s"
          (Probe.invocation_to_string inv)
      | Error e ->
        failf
          "expected Not_official_client_lane, got: %s"
          (Probe.invocation_error_to_string e))
;;

(* The antigravity entry point publishes an MCP bridge and copies credentials
   into a HOME, so pointing it at a lane that declares its tools directly would
   do that work for a question it cannot answer. Guarded before any of it. *)
let test_antigravity_probe_refuses_a_direct_tool_lane () =
  let base = Filename.temp_file "probe-agy-guard" ".d" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  let runtime_path = Filename.concat base "runtime.toml" in
  write_file
    runtime_path
    "[providers.local]\n\
     protocol = \"openai-compatible-http\"\n\
     endpoint = \"http://127.0.0.1:1/v1\"\n\
     \n\
     [models.sample]\n\
     api-name = \"sample\"\n\
     max-context = 1024\n\
     \n\
     [local.sample]\n\
     max-request-body-bytes = 65536\n\
     \n\
     [runtime]\n\
     default = \"local.sample\"\n";
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
      (match Runtime.init_default ~config_path:runtime_path with
       | Ok () -> ()
       | Error e -> failf "fixture config rejected: %s" e);
      match
        probe_antigravity_offline ~runtime_id:"local.sample" ~tool:"masc_board_list"
      with
      | Error (Probe.Not_antigravity_lane _) -> ()
      | Ok inv ->
        failf
          "a direct-tool lane went through the bridge probe: %s"
          (Probe.invocation_to_string inv)
      | Error e ->
        failf
          "expected Not_antigravity_lane, got: %s"
          (Probe.invocation_error_to_string e))
;;

(* A tool the surface withholds costs no spawn on this lane either. *)
let test_official_client_probe_declines_an_operator_only_tool () =
  match
    probe_official_client_offline ~runtime_id:"anything" ~tool:"keeper_operator_note"
  with
  | Error (Probe.Not_on_surface _) -> ()
  | Ok inv -> failf "an operator-only tool spawned a client: %s" (Probe.invocation_to_string inv)
  | Error e ->
    failf "expected Not_on_surface, got: %s" (Probe.invocation_error_to_string e)
;;

let () =
  run
    "keeper_capability_probe"
    [ ( "probe_surface"
      , [ test_case "board_list is projected" `Quick test_board_list_is_projected
        ; test_case "operator-only is distinguished" `Quick test_operator_only_is_not_a_runtime_failure
        ; test_case "transport alias names its projection" `Quick test_transport_alias_names_its_projection
        ; test_case "alias target is projected" `Quick test_alias_target_is_itself_projected
        ; test_case "unknown name is explicit" `Quick test_unknown_name_is_not_a_silent_negative
        ; test_case "karma has no read path" `Quick test_karma_has_no_keeper_read_path
        ] )
    ; ( "agreement with the surface"
      , [ test_case "round-trips every published name" `Quick test_agrees_with_the_surface_it_reports_on
        ; test_case "no schema-withheld descriptor" `Quick test_no_descriptor_is_withheld_by_a_schema_error
        ] )
    ; ( "probe_invocation (offline)"
      , [ test_case "operator-only costs no turn" `Quick test_operator_only_costs_no_turn
        ; test_case "unknown runtime is named" `Quick test_unknown_runtime_is_named
        ; test_case "lane guard refuses an official-client runtime" `Quick test_lane_guard_refuses_an_official_client_runtime
        ] )
    ; ( "inference seed overlay"
      , [ test_case "declared thinking-off reaches the request" `Quick test_declared_thinking_off_reaches_the_config
        ; test_case "declared thinking-on reaches the request" `Quick test_declared_thinking_on_reaches_the_config
        ; test_case "absent seed leaves the binding alone" `Quick test_undeclared_seed_leaves_the_binding_alone
        ; test_case "probe and turn agree on every declaration combination" `Quick
            test_probe_and_turn_agree_on_the_seed
        ] )
    ; ( "provider error rendering"
      , [ test_case "unknown-failure reason survives into detail" `Quick
            test_detail_keeps_unknown_failure_reason
        ] )
    ; ( "probe_official_client_invocation (offline)"
      , [ test_case "antigravity is refused with its reason" `Quick
            test_official_client_probe_refuses_antigravity
        ; test_case "lane guard refuses an Agent Core runtime" `Quick
            test_official_client_probe_refuses_an_agent_core_runtime
        ; test_case "operator-only costs no spawn" `Quick
            test_official_client_probe_declines_an_operator_only_tool
        ] )
    ; ( "probe_antigravity_invocation (offline)"
      , [ test_case "lane guard refuses a direct-tool lane" `Quick
            test_antigravity_probe_refuses_a_direct_tool_lane
        ] )
    ]
;;
