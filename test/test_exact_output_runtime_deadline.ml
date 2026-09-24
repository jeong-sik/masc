open Alcotest
open Masc

module EO = Agent_core.Exact_output
module Registry = Runtime_exact_output_registry

let require_ok label = function Ok value -> value | Error _ -> fail label
let lane_id = "librarian_exact"
let messages = [ Agent_core.Types.user_msg "Return one JSON object." ]
let requirement =
  EO.make_output_requirement
    ~schema:(`Assoc [ "type", `String "object" ])
    ~minimum_guarantee:EO.Json_syntax

let runtime_toml ?(bindings = [ "probe" ]) ?(default = "probe") ~connect ~body () =
  let deadline key = function
    | None -> ""
    | Some value -> Printf.sprintf "%s = %.1f\n" key value
  in
  Printf.sprintf {|[runtime]
default = "openai-responses.%s"
%s
[providers.openai-responses]
protocol = "openai-compatible-http"
endpoint = "https://api.openai.com"
%s%s
[providers.openai-responses.credentials]
type = "env"
key = "OPENAI_API_KEY"
%s|}
    default
    (String.concat "\n"
       (List.map
          (fun lane -> Printf.sprintf "[runtime.exact_output_lanes.%s]\nslots = [\"openai-responses.probe\"]\nmax_output_tokens = 4096" lane)
          (List.sort_uniq String.compare
             (lane_id :: Server_runtime_bootstrap.mandatory_exact_output_lane_ids))))
    (deadline Runtime_schema.connect_timeout_s_key connect)
    (deadline Runtime_schema.exact_body_timeout_s_key body)
    (String.concat ""
       (List.map
          (fun binding ->
             Printf.sprintf
               "[models.%s]\napi-name = \"gpt-5.6-luna\"\n[openai-responses.%s]\n"
               binding
               binding)
          bindings))

let ready target =
  (match EO.project_request_body ~target ~messages requirement with
   | Ok _ -> ()
   | Error error -> failf "Exact projection: %s" (EO.admission_error_reason error));
  let selected = EO.resolve_target target |> require_ok "resolve frozen credential" in
  match EO.admit ~target:selected ~messages requirement with
  | Ok plan -> plan
  | Error error -> failf "Exact admission: %s" (EO.admission_error_reason error)

let declared_target ~connect ~body : EO.declared_target =
    { target_ref = "openai-responses.probe"
    ; binding =
        Llm_provider.Provider_config.make
          ~kind:Llm_provider.Provider_config.OpenAI_compat
          ~provider_id:"openai-responses"
          ~model_id:"gpt-5.6-luna"
          ~base_url:"https://api.openai.com"
          ~request_path:"/v1/responses"
          ?connect_timeout_s:connect
          ()
    ; credential =
        EO.Credential_resolved (Llm_provider.Secret.of_string "synthetic-no-network")
    ; body_timeout_s = body }

let admitted_declared_target (target : EO.declared_target) =
  let snapshot =
    EO.load_resolver_snapshot
      ~io:{ getenv = (fun name -> Ok (Sys.getenv_opt name)) }
      ~target_binding_policy:EO.Exclude_unbound_targets
      ~catalog:(EO.Embedded_with_targets [ target ]) ()
    |> require_ok "expected declared target snapshot"
  in
  EO.admit_target_ref snapshot target.target_ref
  |> require_ok "expected admitted target"

let expected_plan ~connect ~body =
  admitted_declared_target (declared_target ~connect ~body)
  (* The runtime bootstrap runs this target through a lane that declares
     [max_output_tokens = 4096]; the expected plan must carry the same budget
     or the fingerprints differ for a reason this test is not about. *)
  |> fun admitted -> EO.admitted_target_with_max_tokens admitted 4096
  |> ready

let published_target () =
  let registry = Registry.current () |> require_ok "published registry" in
  match Registry.resolve_lane registry ~lane_id with
  | Ok { selected_slots = [ slot ]; _ } -> slot.admitted_target
  | _ -> fail "expected one admitted Librarian slot"

let with_runtime_fixture f =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env "AGENT_CORE_MODEL_CATALOG" None @@ fun () ->
  Masc_test_deps.with_process_env "OPENAI_API_KEY" (Some "synthetic-no-network") @@ fun () ->
  let root = Filename.temp_dir "exact-runtime-deadline-" "" in
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key (Some root) @@ fun () ->
  Config_dir_resolver.reset ();
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
    Config_dir_resolver.reset ();
    Fs_compat.remove_tree root) @@ fun () ->
  Llm_provider.Model_catalog.clear_global ();
  let path = Filename.concat root "runtime.toml" in
  (* What a server does at boot: load the runtimes, then publish the
     exact-output registry from them. *)
  let boot text =
    Fs_compat.save_file path text;
    (match Runtime.init_default ~config_path:path with
     | Ok () -> ()
     | Error detail -> failf "runtime initialization: %s" detail);
    Server_runtime_bootstrap.For_testing.configure_exact_output_registry ~config_root:root ()
  in
  (* What POST /api/v1/runtime/config/raw does once the text validates. *)
  let save text = Runtime.save_config_text ~runtime_config_path:path text in
  f ~path ~boot ~save

let with_runtime f =
  with_runtime_fixture @@ fun ~path:_ ~boot ~save:_ ->
  let load ~connect ~body =
    boot (runtime_toml ~connect ~body ());
    let runtime = match Runtime.get_runtimes () with
      | [ runtime ] -> runtime | _ -> fail "expected one runtime" in
    check (option (float 0.0)) "declared Exact body deadline" body
      runtime.provider.exact_body_timeout_s;
    (match runtime.Runtime.execution with
     | Runtime_execution.Agent_core config ->
       check (option (float 0.0)) "ordinary connection deadline is unchanged" connect
         config.connect_timeout_s
     | _ -> fail "expected the API runtime");
    let inventory = Server_dashboard_http_runtime_info.runtime_inventory_json () in
    let open Yojson.Safe.Util in
    let entry = match inventory |> member "providers" |> to_list with
      | [ entry ] -> entry | _ -> fail "expected one dashboard runtime" in
    let declared = entry |> member "declared_spec" |> member "provider" in
    check bool "dashboard exposes the declared Exact deadline" true
      ((declared |> member "exact_body_timeout_s") = Json_util.float_opt_to_json body);
    published_target ()
  in
  f load

let test_body_only_declaration_reaches_exact () =
  with_runtime @@ fun load ->
  let connect, body = None, Some 91.5 in
  let actual = load ~connect ~body |> ready in
  check (option (float 0.0)) "body-only plan has no connection deadline" None
    (EO.connect_timeout_s actual);
  check (option (float 0.0)) "body-only plan preserves its total deadline" body
    (EO.body_timeout_s actual);
  check string "bootstrap and direct declared body produce the same plan"
    (EO.plan_fingerprint (expected_plan ~connect ~body)) (EO.plan_fingerprint actual)

let test_deadlines_are_independent_and_frozen () =
  with_runtime @@ fun load ->
  let connect = Some 17.5 in
  let capture body =
    let target = load ~connect ~body in
    let plan = ready target in
    check string "the full frozen plan preserves both declared deadline values"
      (EO.plan_fingerprint (expected_plan ~connect ~body)) (EO.plan_fingerprint plan);
    target, plan
  in
  let first_target, first = capture (Some 91.5) in
  let _, second = capture (Some 55.5) in
  check (option (float 0.0)) "explicit body deadline leaves connection independent" connect
    (EO.connect_timeout_s first);
  check (option (float 0.0)) "explicit body deadline reaches the frozen plan" (Some 91.5)
    (EO.body_timeout_s first);
  check bool "changing only body changes the frozen plan" true
    (EO.plan_fingerprint first <> EO.plan_fingerprint second);
  check string "republishing leaves the captured first target unchanged"
    (EO.plan_fingerprint first) (EO.plan_fingerprint (ready first_target))

let contains ~needle haystack =
  let n = String.length needle
  and h = String.length haystack in
  let rec scan index =
    if index + n > h then false else String.sub haystack index n = needle || scan (index + 1)
  in
  n = 0 || scan 0

let expected_lane_ids =
  List.sort_uniq String.compare
    (lane_id :: Server_runtime_bootstrap.mandatory_exact_output_lane_ids)

let lane_unavailable registry lane =
  match Registry.resolve_lane registry ~lane_id:lane with
  | Error (Registry.No_admitted_lane_slots _) -> true
  | Error (Registry.Exact_lane_unconfigured _) | Ok _ -> false

(* A connect deadline ends at the response headers, so a provider that
   declares only [connect-timeout-s] would read the Exact body with no
   deadline (#36979). Boot loads the file anyway and records the slot as left
   out of every lane, naming it and its provider (#38779). Every lane here
   names only that slot and no cli_slots, so each is emptied: each is
   unavailable on its own, and the registry still publishes because an
   emptied mandatory lane is not required at publication. *)
let test_connect_only_declaration_is_left_out_at_boot () =
  with_runtime_fixture @@ fun ~path ~boot:_ ~save:_ ->
  Fs_compat.save_file path (runtime_toml ~connect:(Some 17.5) ~body:None ());
  (match Runtime.init_default ~config_path:path with
   | Ok () -> ()
   | Error detail -> failf "boot must not refuse a connect-only provider: %s" detail);
  let degradation = Runtime.exact_slot_degradation () in
  check (list string) "one gap per lane"
    expected_lane_ids
    (List.sort String.compare
       (List.map (fun (gap : Runtime.exact_slot_body_deadline_gap) -> gap.lane_id)
          degradation.gaps));
  List.iter
    (fun (gap : Runtime.exact_slot_body_deadline_gap) ->
       check string "the record names the slot" "openai-responses.probe" gap.slot_id;
       check string "the record names the provider" "openai-responses" gap.provider_id)
    degradation.gaps;
  check (list string) "every lane is emptied" expected_lane_ids
    (List.sort String.compare degradation.emptied_lane_ids);
  Server_runtime_bootstrap.For_testing.configure_exact_output_registry ~config_root:root ();
  let registry = Registry.current () |> require_ok "the registry still publishes" in
  List.iter
    (fun lane ->
       check bool (lane ^ " is unavailable on its own") true (lane_unavailable registry lane))
    expected_lane_ids

(* One mandatory lane is all gaps with no cli_slots, the other mandatory lane
   has a keyed slot, and the Librarian lane has one of each. The registry
   publishes; the keyed lane works; the emptied lane alone is unavailable and
   reported; the mixed lane admits the keyed slot and drops the gap slot. *)
let mixed_runtime_toml ~emptied ~keyed =
  Printf.sprintf {|[runtime]
default = "openai-responses.probe"

[runtime.exact_output_lanes.%s]
slots = ["nodeadline.other"]
max_output_tokens = 4096

[runtime.exact_output_lanes.%s]
slots = ["openai-responses.probe"]
max_output_tokens = 4096

[runtime.exact_output_lanes.%s]
slots = ["nodeadline.other", "openai-responses.probe"]
max_output_tokens = 4096

[providers.openai-responses]
protocol = "openai-compatible-http"
endpoint = "https://api.openai.com"
%s = 91.5
[providers.openai-responses.credentials]
type = "env"
key = "OPENAI_API_KEY"
[models.probe]
api-name = "gpt-5.6-luna"
[openai-responses.probe]

[providers.nodeadline]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:9/v1"
[models.other]
api-name = "no-deadline-model"
max-context = 8192
[nodeadline.other]
|}
    emptied
    keyed
    lane_id
    Runtime_schema.exact_body_timeout_s_key

let test_a_lane_emptied_by_gaps_is_unavailable_alone () =
  with_runtime_root @@ fun ~root _load ->
  let emptied, keyed =
    match Server_runtime_bootstrap.mandatory_exact_output_lane_ids with
    | [ emptied; keyed ] -> emptied, keyed
    | _ -> fail "this case is written for two mandatory lanes"
  in
  let path = Filename.concat root "runtime.toml" in
  Fs_compat.save_file path (mixed_runtime_toml ~emptied ~keyed);
  (match Runtime.init_default ~config_path:path with
   | Ok () -> ()
   | Error detail -> failf "boot must not refuse the file: %s" detail);
  let degradation = Runtime.exact_slot_degradation () in
  check (list string) "the emptied lane is reported"
    [ emptied ] degradation.emptied_lane_ids;
  check (list string) "both gap slots are recorded"
    (List.sort String.compare [ emptied; lane_id ])
    (List.sort String.compare
       (List.map (fun (gap : Runtime.exact_slot_body_deadline_gap) -> gap.lane_id)
          degradation.gaps));
  Server_runtime_bootstrap.For_testing.configure_exact_output_registry ~config_root:root ();
  let registry = Registry.current () |> require_ok "the other lanes publish" in
  check bool "the emptied mandatory lane is unavailable" true
    (lane_unavailable registry emptied);
  let selected lane =
    match Registry.resolve_lane registry ~lane_id:lane with
    | Ok { selected_slots; _ } ->
      List.map (fun (slot : Registry.selected_slot) -> slot.slot_id) selected_slots
    | Error _ -> failf "lane %s must resolve" lane
  in
  check (list string) "the keyed mandatory lane works" [ "openai-responses.probe" ]
    (selected keyed);
  check (list string) "the mixed lane admits the keyed slot" [ "openai-responses.probe" ]
    (selected lane_id);
  check (list string) "and drops the gap slot" [ "nodeadline.other" ]
    (List.filter_map
       (fun (slot : Registry.rejected_slot) ->
          if String.equal slot.lane_id lane_id then Some slot.slot_id else None)
       (Registry.rejected_slots registry))

(* Plan admission still refuses a target that reaches it without a body
   deadline -- through a replacement catalog row, or a binding built outside
   runtime.toml. That line is what an operator reads, so it names the
   provider, the key to set and why the connect deadline was not enough;
   "missing_deadline" stays in it as the kind a search finds (#38779). *)
let test_missing_body_deadline_refusal_names_provider_and_key () =
  with_runtime @@ fun _load ->
  let admitted =
    EO.admitted_target_with_max_tokens
      (admitted_declared_target (declared_target ~connect:(Some 17.5) ~body:None))
      4096
  in
  let selected = EO.resolve_target admitted |> require_ok "resolve frozen credential" in
  match EO.admit ~target:selected ~messages requirement with
  | Ok _ -> fail "a target without a body deadline was admitted"
  | Error error ->
    let reason = EO.admission_error_reason error in
    List.iter
      (fun needle ->
         check bool (Printf.sprintf "the refusal says %S" needle) true
           (contains ~needle reason))
      [ "wire_admission_rejected:missing_deadline"
      ; "provider openai-responses declares no whole-request deadline"
      ; Runtime_schema.exact_body_timeout_s_key
      ; Runtime_schema.connect_timeout_s_key
      ; "response headers"
      ]

(* A saved [exact-body-timeout-s] reaches the published Exact target with the
   save, not at the next restart. On 2026-09-24 a key saved at 22:53:59 KST
   answered [applied] while requests kept the boot-time target (#38779). *)
let test_saved_body_deadline_reaches_published_target () =
  with_runtime_fixture @@ fun ~path:_ ~boot ~save ->
  boot (runtime_toml ~connect:None ~body:(Some 91.5) ());
  check (option (float 0.0)) "boot publishes the declared body deadline" (Some 91.5)
    (EO.body_timeout_s (ready (published_target ())));
  (match save (runtime_toml ~connect:None ~body:(Some 55.5) ()) with
   | Ok receipt ->
     (match receipt.Runtime.exact_output_registry with
      | Registry.Registry_replaced -> ()
      | Registry.Registry_unpublished ->
        fail "a save over a published registry reported it unpublished")
   | Error detail -> failf "save refused: %s" detail);
  check (option (float 0.0)) "the saved body deadline reaches the published target"
    (Some 55.5) (EO.body_timeout_s (ready (published_target ())))

(* A save whose text the registry cannot be rebuilt from is refused before the
   write. Keeping the published registry after the write would run requests on
   a binding the file no longer has; withdrawing it would turn the save into
   an outage of every exact lane. Here the text removes the binding every
   mandatory lane names while the lane still names it. *)
let test_save_that_breaks_the_registry_is_refused () =
  with_runtime_fixture @@ fun ~path ~boot ~save ->
  let booted =
    runtime_toml ~bindings:[ "probe"; "other" ] ~connect:None ~body:(Some 91.5) ()
  in
  boot booted;
  let before = Registry.current () |> require_ok "published registry" in
  (match
     save
       (runtime_toml
          ~bindings:[ "other" ]
          ~default:"other"
          ~connect:None
          ~body:(Some 91.5)
          ())
   with
   | Ok _ -> fail "a save that leaves mandatory exact lanes without a target was applied"
   | Error _ -> ());
  check string "the refused save leaves the file as it was" booted (Fs_compat.load_file path);
  let after = Registry.current () |> require_ok "registry after the refused save" in
  check bool "the refused save leaves the published registry in place" true (before == after)

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:Fs_compat.clear_fs @@ fun () ->
  run "Exact runtime deadline"
    [ "declaration", [
        test_case "body-only declaration reaches actual Exact projection" `Quick
          test_body_only_declaration_reaches_exact;
        test_case "connection and body deadlines remain independent and frozen" `Quick
          test_deadlines_are_independent_and_frozen;
        test_case "connect-only declaration is left out at boot" `Quick
          test_connect_only_declaration_is_left_out_at_boot;
        test_case "a lane emptied by gaps is unavailable alone" `Quick
          test_a_lane_emptied_by_gaps_is_unavailable_alone;
        test_case "missing body deadline refusal names provider and key" `Quick
          test_missing_body_deadline_refusal_names_provider_and_key ];
      "config commit", [
        test_case "a saved body deadline reaches the published target" `Quick
          test_saved_body_deadline_reaches_published_target;
        test_case "a save that breaks the registry is refused before the write" `Quick
          test_save_that_breaks_the_registry_is_refused ] ]
