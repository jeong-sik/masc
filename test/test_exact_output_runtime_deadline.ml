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
  Server_runtime_bootstrap.For_testing.configure_exact_output_registry
    ~config_root:(Filename.dirname path)
    ();
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
  with_runtime_fixture @@ fun ~path ~boot:_ ~save:_ ->
  let emptied, keyed =
    match Server_runtime_bootstrap.mandatory_exact_output_lane_ids with
    | [ emptied; keyed ] -> emptied, keyed
    | _ -> fail "this case is written for two mandatory lanes"
  in
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
  Server_runtime_bootstrap.For_testing.configure_exact_output_registry
    ~config_root:(Filename.dirname path)
    ();
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
  let saved = runtime_toml ~connect:None ~body:(Some 55.5) () in
  let save_replacing label =
    match save saved with
    | Ok receipt ->
      (match receipt.Runtime.exact_output_registry with
       | Runtime.Exact_output_registry_replaced
           { origin = Runtime.Runtime_binding_targets } -> ()
       | Runtime.Exact_output_registry_replaced
           { origin = Runtime.Replacement_catalog_targets _ }
       | Runtime.Exact_output_registry_unpublished
       | Runtime.Exact_output_registry_kept _ ->
         failf "%s: the receipt does not name a registry rebuilt from the bindings" label)
    | Error detail -> failf "%s: save refused: %s" label detail
  in
  save_replacing "first save";
  check (option (float 0.0)) "the saved body deadline reaches the published target"
    (Some 55.5) (EO.body_timeout_s (ready (published_target ())));
  (* Saving the same text again rebuilds the registry from the same catalog,
     so its generation does not move. *)
  let fingerprint () =
    Registry.current ()
    |> require_ok "published registry"
    |> Registry.catalog_generation_fingerprint
  in
  let first = fingerprint () in
  save_replacing "second save of the same text";
  check string "the same text keeps the catalog generation" first (fingerprint ())

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
  check bool "the refused save leaves the published registry in place" true (before == after);
  (* The preview runs the commit's registry decision, so it refuses too. *)
  match
    Runtime.validate_config_text
      ~runtime_config_path:path
      (runtime_toml ~bindings:[ "other" ] ~default:"other" ~connect:None ~body:(Some 91.5) ())
  with
  | Ok () -> fail "the preview promised a save the commit refuses"
  | Error _ -> ()

(* When the file on disk does not rebuild the registry either, the fault is
   not the new text's: the save goes through, the published registry stays,
   and the receipt says it was kept. Refusing would block every keeper
   assignment until someone edits the file by hand. *)
let test_save_over_a_file_that_already_breaks_the_registry_keeps_it () =
  with_runtime_fixture @@ fun ~path ~boot ~save ->
  boot (runtime_toml ~bindings:[ "probe"; "other" ] ~connect:None ~body:(Some 91.5) ());
  let before = Registry.current () |> require_ok "published registry" in
  let broken body =
    runtime_toml ~bindings:[ "other" ] ~default:"other" ~connect:None ~body:(Some body) ()
  in
  (* Written behind the server's back, as a hand edit would be. *)
  Fs_compat.save_file path (broken 91.5);
  let next = broken 55.5 in
  (match Runtime.validate_config_text ~runtime_config_path:path next with
   | Ok () -> ()
   | Error detail -> failf "the preview refused a save the commit accepts: %s" detail);
  (match save next with
   | Ok receipt ->
     (match receipt.Runtime.exact_output_registry with
      | Runtime.Exact_output_registry_kept
          { reason = Registry.Required_lane_unavailable _ } -> ()
      | Runtime.Exact_output_registry_kept { reason } ->
        failf "kept for an unexpected reason: %s"
          (Registry.publication_error_to_string reason)
      | Runtime.Exact_output_registry_replaced _
      | Runtime.Exact_output_registry_unpublished ->
        fail "the receipt claims a registry the text does not rebuild")
   | Error detail -> failf "a save over an already broken file was refused: %s" detail);
  check string "the save reaches the file" next (Fs_compat.load_file path);
  let after = Registry.current () |> require_ok "registry after the save" in
  check bool "the published registry is kept" true (before == after)

let degradation_status () =
  Runtime.startup_degradation_to_yojson
    ~exact_slots:(Runtime.exact_slot_degradation ())
    (Runtime.startup_degradation ())
  |> Yojson.Safe.Util.member "status"
  |> Yojson.Safe.Util.to_string

let selected_slot_ids registry lane =
  match Registry.resolve_lane registry ~lane_id:lane with
  | Ok { selected_slots; _ } ->
    List.map (fun (slot : Registry.selected_slot) -> slot.slot_id) selected_slots
  | Error _ -> []

let first_mandatory_lane () =
  match Server_runtime_bootstrap.mandatory_exact_output_lane_ids with
  | lane :: _ -> lane
  | [] -> fail "no mandatory exact-output lane"

let require_replaced label (receipt : Runtime.config_commit_receipt) =
  match receipt.exact_output_registry with
  | Runtime.Exact_output_registry_replaced { origin = Runtime.Runtime_binding_targets } -> ()
  | Runtime.Exact_output_registry_replaced { origin = Runtime.Replacement_catalog_targets _ }
  | Runtime.Exact_output_registry_unpublished
  | Runtime.Exact_output_registry_kept _ ->
    failf "%s: the receipt does not name a registry rebuilt from the bindings" label

(* Boot with a provider that has only [connect-timeout-s]: every lane is all
   gaps, so every lane is emptied and excused, and the registry publishes
   with each lane unavailable. Saving the key rebuilds the registry in the
   same commit: the emptied mandatory lane is required again and admitted,
   and the startup report goes back to ok (#38779). *)
let test_saving_the_key_restores_an_emptied_mandatory_lane () =
  with_runtime_fixture @@ fun ~path:_ ~boot ~save ->
  let mandatory = first_mandatory_lane () in
  boot (runtime_toml ~connect:(Some 17.5) ~body:None ());
  let booted = Registry.current () |> require_ok "a gap-only boot publishes" in
  check bool "the emptied mandatory lane is unavailable" true
    (lane_unavailable booted mandatory);
  check string "the startup report is degraded" "degraded" (degradation_status ());
  (match save (runtime_toml ~connect:(Some 17.5) ~body:(Some 91.5) ()) with
   | Ok receipt -> require_replaced "saving the key" receipt
   | Error detail -> failf "saving the key was refused: %s" detail);
  let saved = Registry.current () |> require_ok "registry after the save" in
  check (list string) "the mandatory lane admits the keyed slot"
    [ "openai-responses.probe" ] (selected_slot_ids saved mandatory);
  check (option (float 0.0)) "the Librarian target carries the saved deadline"
    (Some 91.5) (EO.body_timeout_s (ready (published_target ())));
  check int "no gap is left" 0 (List.length (Runtime.exact_slot_body_deadline_gaps ()));
  check string "the startup report is ok in the same commit" "ok" (degradation_status ())

(* The Librarian lane has a gap slot and a keyed slot; the mandatory lanes are
   keyed. A save that does not touch the gap keeps it: the startup report
   still names it and the rebuilt registry still leaves the slot out. *)
let gap_beside_keyed_toml ?(probe = true) ?(trailer = "") () =
  let mandatory_lanes =
    String.concat "\n"
      (List.map
         (fun lane ->
            Printf.sprintf
              "[runtime.exact_output_lanes.%s]\nslots = [\"openai-responses.probe\"]\nmax_output_tokens = 4096\n"
              lane)
         Server_runtime_bootstrap.mandatory_exact_output_lane_ids)
  in
  Printf.sprintf {|[runtime]
default = "%s"

%s
[runtime.exact_output_lanes.%s]
slots = ["nokey.other", "openai-responses.probe"]
max_output_tokens = 4096

[providers.openai-responses]
protocol = "openai-compatible-http"
endpoint = "https://api.openai.com"
%s = 91.5
[providers.openai-responses.credentials]
type = "env"
key = "OPENAI_API_KEY"
%s
[providers.nokey]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:9/v1"
[models.other]
api-name = "no-deadline-model"
max-context = 8192
[models.other.capabilities]
supports-response-format-json = true
supports-structured-output = true
[nokey.other]
%s|}
    (if probe then "openai-responses.probe" else "nokey.other")
    mandatory_lanes
    lane_id
    Runtime_schema.exact_body_timeout_s_key
    (if probe then "[models.probe]\napi-name = \"gpt-5.6-luna\"\n[openai-responses.probe]\n" else "")
    trailer

let test_an_unrelated_save_keeps_an_existing_gap () =
  with_runtime_fixture @@ fun ~path:_ ~boot ~save ->
  boot (gap_beside_keyed_toml ());
  let gap_slots () =
    List.map
      (fun (gap : Runtime.exact_slot_body_deadline_gap) -> gap.lane_id, gap.slot_id)
      (Runtime.exact_slot_body_deadline_gaps ())
  in
  check (list (pair string string)) "boot records the gap" [ lane_id, "nokey.other" ]
    (gap_slots ());
  (match save (gap_beside_keyed_toml ~trailer:"# an unrelated edit\n" ()) with
   | Ok receipt -> require_replaced "an unrelated save" receipt
   | Error detail -> failf "a save that keeps an existing gap was refused: %s" detail);
  check (list (pair string string)) "the startup report still names the gap"
    [ lane_id, "nokey.other" ] (gap_slots ());
  check string "the startup report stays degraded" "degraded" (degradation_status ());
  let registry = Registry.current () |> require_ok "registry after the save" in
  check (list string) "the rebuilt Librarian lane admits only the keyed slot"
    [ "openai-responses.probe" ] (selected_slot_ids registry lane_id);
  check bool "the gap slot stays out of the rebuilt registry" true
    (List.exists
       (fun (slot : Registry.rejected_slot) ->
          String.equal slot.lane_id lane_id && String.equal slot.slot_id "nokey.other")
       (Registry.rejected_slots registry))

(* The file on disk has only gaps as faults, so it rebuilds the registry. A
   text that breaks the registry -- the keyed binding every mandatory lane
   names is gone -- is this text's fault and is refused. *)
let test_a_break_over_a_gap_only_file_is_refused () =
  with_runtime_fixture @@ fun ~path ~boot ~save ->
  let booted = gap_beside_keyed_toml () in
  boot booted;
  let before = Registry.current () |> require_ok "published registry" in
  (match save (gap_beside_keyed_toml ~probe:false ()) with
   | Ok _ -> fail "a text that empties the mandatory lanes was committed"
   | Error _ -> ());
  check string "the file is unchanged" booted (Fs_compat.load_file path);
  let after = Registry.current () |> require_ok "registry after the refusal" in
  check bool "the registry is unchanged" true (before == after)

(* A save that adds a gap is refused through the writer itself, before
   anything is written. *)
let test_a_save_that_adds_a_gap_is_refused () =
  with_runtime_fixture @@ fun ~path ~boot ~save ->
  let booted = runtime_toml ~connect:(Some 17.5) ~body:(Some 91.5) () in
  boot booted;
  (match save (runtime_toml ~connect:(Some 17.5) ~body:None ()) with
   | Ok _ -> fail "a save that adds a gap was committed"
   | Error detail ->
     check bool "the refusal names the key" true
       (contains ~needle:Runtime_schema.exact_body_timeout_s_key detail));
  check string "the file is unchanged" booted (Fs_compat.load_file path)

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
          test_save_that_breaks_the_registry_is_refused;
        test_case "a save over a file that already breaks the registry keeps it" `Quick
          test_save_over_a_file_that_already_breaks_the_registry_keeps_it;
        test_case "saving the key restores an emptied mandatory lane" `Quick
          test_saving_the_key_restores_an_emptied_mandatory_lane;
        test_case "an unrelated save keeps an existing gap" `Quick
          test_an_unrelated_save_keeps_an_existing_gap;
        test_case "a break over a gap-only file is refused" `Quick
          test_a_break_over_a_gap_only_file_is_refused;
        test_case "a save that adds a gap is refused" `Quick
          test_a_save_that_adds_a_gap_is_refused ] ]
