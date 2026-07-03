(* Per-keeper LLM runtime routing via runtime.toml [[runtime.assignments]].

   persona⊥{model,runtime}: runtime.toml is the sole SSOT for keeper→runtime
   assignment, keyed by keeper name.  [Keeper_meta_contract.runtime_id_of_meta]
   resolves a keeper's assignment via [Runtime.runtime_id_for_keeper] so it
   reaches the turn driver; an unassigned keeper falls through to
   [[runtime].default]; and the driver's [Runtime.get_runtime_by_id] returns
   [None] for an id that does not materialize, so dispatch fails fast (no silent
   substitution — RFC-0206 §2.1).

   This is the SAME runtime source as
   [Keeper_runtime.effective_declarative_runtime_id] (declare/status), which
   delegates to [runtime_id_of_meta], so there is one surface — the dispatcher
   and the reconcile change-detector cannot disagree by construction. *)

open Alcotest
open Masc
module J = Yojson.Safe.Util
module KMC = Keeper_meta_contract

(* Test hermeticity: runtime capability checks resolve through the OAS
   [Model_catalog], which is loaded once (memoized via Atomic) from the
   [OAS_MODEL_CATALOG] env var. Production seeds this in
   server_runtime_bootstrap. Set at module top so it precedes the first
   [global ()] access regardless of test ordering, and only when unset so an
   external/CI value is honored. *)
let () =
  match Sys.getenv_opt "OAS_MODEL_CATALOG" with
  | Some _ -> ()
  | None ->
    Unix.putenv "OAS_MODEL_CATALOG" (Masc_test_deps.source_path "oas-models.toml")

(* ---- temp config-dir + keeper TOML fixtures
   (helper shape mirrors test_keeper_runtime_denylist.ml) ---- *)

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then begin
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path
;;

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;

let write_file path content =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc content)
;;

let with_model_catalog_content content f =
  let path = Filename.temp_file "runtime-thinking-oas-models" ".toml" in
  Fun.protect
    ~finally:(fun () ->
      Llm_provider.Model_catalog.clear_global ();
      try Sys.remove path with
      | _ -> ())
    (fun () ->
      write_file path content;
      match Llm_provider.Model_catalog.load_file path with
      | Error msg -> Alcotest.failf "test OAS model catalog should load: %s" msg
      | Ok catalog ->
        Llm_provider.Model_catalog.set_global catalog;
        f ())
;;

let string_contains haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0 then true
  else
    let rec loop index =
      index + needle_len <= haystack_len
      &&
      (String.equal (String.sub haystack index needle_len) needle
       || loop (index + 1))
    in
    loop 0
;;

(* Point MASC_CONFIG_DIR at an isolated temp dir and reset the resolver cache so
   the new value takes effect; restore the prior value on exit. *)
let with_config_dir f =
  with_temp_dir "runtime-per-keeper-routing-config" @@ fun config_dir ->
  let original = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      (match original with
       | Some value -> Unix.putenv "MASC_CONFIG_DIR" value
       | None -> Unix.putenv "MASC_CONFIG_DIR" "");
      Config_dir_resolver.reset ())
    (fun () ->
      Unix.putenv "MASC_CONFIG_DIR" config_dir;
      Config_dir_resolver.reset ();
      f config_dir)
;;

let make_meta name : KMC.keeper_meta =
  let json =
    `Assoc
      [ "name", `String name
      ; "trace_id", `String ("test-trace-" ^ name)
      ; "goal", `String "test goal"
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m -> m
  | Error e -> failwith ("meta_of_json failed: " ^ e)
;;

(* Runtime config materializing two bindings: the default ["runpod_mtp.qwen"]
   and ["openai.gpt"] (used to prove [get_runtime_by_id] resolution).

   persona⊥{model,runtime}: per-keeper routing is declared in
   [[runtime.assignments]] (runtime.toml SSOT), keyed by keeper name — NOT in
   keeper TOML.  [routingtest]/[budgettest] route to the non-default
   [openai.gpt]; an unassigned keeper falls to [runtime].default. *)
let runtime_config =
  {|
[runtime]
default = "runpod_mtp.qwen"

[runtime.assignments]
routingtest = "openai.gpt"
budgettest = "openai.gpt"

[providers.runpod_mtp]
display-name = "RunPod"
protocol = "openai-compatible-http"
endpoint = "https://runpod.example/v1"

[providers.openai]
display-name = "OpenAI"
protocol = "openai-compatible-http"
endpoint = "https://api.openai.example/v1"

[models.qwen]
api-name = "qwen"
max-context = 128000
tools-support = true
streaming = true

[models.gpt]
api-name = "gpt"
max-context = 64000
tools-support = true
streaming = true

[models.gpt.capabilities]
supports-response-format-json = true
supports-structured-output = true

[runpod_mtp.qwen]
is-default = true
max-concurrent = 4

[openai.gpt]
is-default = true
max-concurrent = 1
|}
;;

let runtime_config_openai_default =
  {|
[runtime]
default = "openai.gpt"

[providers.runpod_mtp]
display-name = "RunPod"
protocol = "openai-compatible-http"
endpoint = "https://runpod.example/v1"

[providers.openai]
display-name = "OpenAI"
protocol = "openai-compatible-http"
endpoint = "https://api.openai.example/v1"

[models.qwen]
api-name = "qwen"
max-context = 128000
tools-support = true
streaming = true

[models.gpt]
api-name = "gpt"
max-context = 64000
tools-support = true
streaming = true

[models.gpt.capabilities]
supports-response-format-json = true
supports-structured-output = true

[runpod_mtp.qwen]
is-default = true
max-concurrent = 4

[openai.gpt]
is-default = true
max-concurrent = 1
  |}
;;

let runtime_structured_judge_model_catalog =
  {|
[[models]]
id_prefix = "gpt"
base = "openai_chat"
max_context_tokens = 64000
supports_tools = true
supports_structured_output = true
|}
;;

let runtime_route_model_catalog =
  {|
[[models]]
id_prefix = "openai_compat/qwen"
base = "openai_chat"
max_context_tokens = 128000
supports_tools = true
supports_native_streaming = true

[[models]]
id_prefix = "openai_compat/gpt"
base = "openai_chat"
max_context_tokens = 64000
supports_tools = true
supports_response_format_json = true
supports_structured_output = true
supports_native_streaming = true
|}
;;

let with_runtime_file f =
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
    (fun () ->
       with_model_catalog_content runtime_route_model_catalog @@ fun () ->
       with_temp_dir "runtime-per-keeper-routing-runtime" @@ fun dir ->
       let path = Filename.concat dir "runtime.toml" in
       write_file path runtime_config;
       (match Runtime.init_default ~config_path:path with
        | Ok () -> ()
        | Error msg -> Alcotest.failf "runtime init_default failed: %s" msg);
       f path)
;;

let with_runtime_initialized f =
  with_runtime_file (fun _path -> f ())
;;

(* ---- the per-keeper selection actually reaches the dispatcher ---- *)

let test_assignment_drives_runtime_id_of_meta () =
  with_runtime_initialized (fun () ->
    (* [routingtest] is assigned [openai.gpt] in [[runtime.assignments]]. *)
    Alcotest.(check string)
      "assigned keeper dispatches to its runtime.toml assignment, not the global default"
      "openai.gpt"
      (KMC.runtime_id_of_meta (make_meta "routingtest")))
;;

let test_runtime_assignment_writer_updates_runtime_toml () =
  with_runtime_file (fun path ->
    (match
       Runtime.set_runtime_id_for_keeper
         ~runtime_config_path:path
         ~keeper_name:"routingtest"
         ~runtime_id:"runpod_mtp.qwen"
         ()
     with
     | Ok () -> ()
     | Error msg -> Alcotest.failf "set_runtime_id_for_keeper failed: %s" msg);
    Alcotest.(check bool)
      "runtime.toml assignment rewritten"
      true
      (string_contains
         (Fs_compat.load_file path)
         "\"routingtest\" = \"runpod_mtp.qwen\"");
    Alcotest.(check (option string))
      "in-process assignment cache refreshed"
      (Some "runpod_mtp.qwen")
      (Runtime.runtime_id_for_keeper "routingtest");
    Alcotest.(check string)
      "meta runtime resolver sees updated assignment"
      "runpod_mtp.qwen"
      (KMC.runtime_id_of_meta (make_meta "routingtest")))
;;

let test_runtime_inventory_surfaces_assignment_governance () =
  with_runtime_initialized (fun () ->
    let json = Server_dashboard_http_runtime_info.runtime_inventory_json () in
    let governance = J.member "assignment_governance" json in
    Alcotest.(check string)
      "schema"
      "masc.runtime_assignment_governance.v1"
      (governance |> J.member "schema" |> J.to_string);
    Alcotest.(check string)
      "status"
      "degraded"
      (governance |> J.member "status" |> J.to_string);
    Alcotest.(check int)
      "assignment count"
      2
      (governance |> J.member "assignment_count" |> J.to_int);
    Alcotest.(check int)
      "assigned runtime count"
      1
      (governance |> J.member "assigned_runtime_count" |> J.to_int);
    Alcotest.(check int)
      "default assignment count"
      0
      (governance |> J.member "default_assignment_count" |> J.to_int);
    Alcotest.(check bool)
      "operator action required"
      true
      (governance |> J.member "operator_action_required" |> J.to_bool);
    Alcotest.(check bool)
      "single runtime warning"
      true
      (string_contains
         (Yojson.Safe.to_string governance)
         "single_runtime_assignment_pin"))
;;

let test_runtime_assignment_writer_rejects_unknown_runtime_without_write () =
  with_runtime_file (fun path ->
    let before = Fs_compat.load_file path in
    (match
       Runtime.set_runtime_id_for_keeper
         ~runtime_config_path:path
         ~keeper_name:"routingtest"
         ~runtime_id:"missing.runtime"
         ()
     with
     | Ok () -> Alcotest.fail "expected unknown runtime assignment to fail"
     | Error msg ->
       Alcotest.(check bool)
         "error mentions unresolved assignment"
         true
         (string_contains msg "missing.runtime"));
    Alcotest.(check string)
      "runtime.toml unchanged after validation failure"
      before
      (Fs_compat.load_file path);
    Alcotest.(check (option string))
      "in-process assignment cache unchanged"
      (Some "openai.gpt")
      (Runtime.runtime_id_for_keeper "routingtest"))
;;

let test_runtime_assignment_writer_clears_assignment () =
  with_runtime_file (fun path ->
    (match Runtime.clear_runtime_id_for_keeper ~runtime_config_path:path ~keeper_name:"routingtest" () with
     | Ok () -> ()
     | Error msg -> Alcotest.failf "clear_runtime_id_for_keeper failed: %s" msg);
    Alcotest.(check bool)
      "runtime.toml assignment removed"
      false
      (string_contains (Fs_compat.load_file path) "routingtest");
    Alcotest.(check (option string))
      "in-process assignment cache cleared"
      None
      (Runtime.runtime_id_for_keeper "routingtest"))
;;

let test_runtime_route_writer_updates_default () =
  with_runtime_file (fun path ->
    (match Runtime.set_runtime_default ~runtime_config_path:path ~runtime_id:"openai.gpt" () with
     | Ok () -> ()
     | Error msg -> Alcotest.failf "set_runtime_default failed: %s" msg);
    Alcotest.(check bool)
      "runtime.toml default rewritten"
      true
      (string_contains (Fs_compat.load_file path) "default = \"openai.gpt\"");
    Alcotest.(check string)
      "runtime cache default refreshed"
      "openai.gpt"
      (Runtime.get_default_runtime_id ()))
;;

let test_runtime_route_writer_rejects_unknown_default_without_write () =
  with_runtime_file (fun path ->
    let before = Fs_compat.load_file path in
    (match Runtime.set_runtime_default ~runtime_config_path:path ~runtime_id:"missing.runtime" () with
     | Ok () -> Alcotest.fail "expected unknown default runtime to fail"
     | Error msg ->
       Alcotest.(check bool)
         "error mentions unresolved default"
         true
         (string_contains msg "missing.runtime"));
    Alcotest.(check string)
      "runtime.toml unchanged after validation failure"
      before
      (Fs_compat.load_file path);
    Alcotest.(check string)
      "runtime cache unchanged"
      "runpod_mtp.qwen"
      (Runtime.get_default_runtime_id ()))
;;

let test_runtime_route_writer_clears_optional_librarian () =
  with_runtime_file (fun path ->
    (match Runtime.set_runtime_librarian ~runtime_config_path:path ~runtime_id:(Some "openai.gpt") () with
     | Ok () -> ()
     | Error msg -> Alcotest.failf "set_runtime_librarian failed: %s" msg);
    Alcotest.(check (option string))
      "librarian set"
      (Some "openai.gpt")
      (Runtime.librarian_runtime_id ());
    (match Runtime.set_runtime_librarian ~runtime_config_path:path ~runtime_id:None () with
     | Ok () -> ()
     | Error msg -> Alcotest.failf "clear runtime librarian failed: %s" msg);
    Alcotest.(check bool)
      "runtime.toml librarian removed"
      false
      (string_contains (Fs_compat.load_file path) "librarian");
    Alcotest.(check (option string))
      "librarian cache cleared"
      None
      (Runtime.librarian_runtime_id ()))
;;

let test_runtime_route_writer_updates_media_failover () =
  with_runtime_file (fun path ->
    (match
       Runtime.set_runtime_media_failover
         ~runtime_config_path:path
         ~runtime_ids:[ "openai.gpt"; "runpod_mtp.qwen" ]
         ()
     with
     | Ok () -> ()
     | Error msg -> Alcotest.failf "set_runtime_media_failover failed: %s" msg);
    Alcotest.(check (list string))
      "media failover cache"
      [ "openai.gpt"; "runpod_mtp.qwen" ]
      (Runtime.media_failover ());
    Alcotest.(check bool)
      "runtime.toml media_failover persisted"
      true
      (string_contains
         (Fs_compat.load_file path)
         "media_failover = [\"openai.gpt\", \"runpod_mtp.qwen\"]");
    (match
       Runtime.set_runtime_media_failover
         ~runtime_config_path:path
         ~runtime_ids:[]
         ()
     with
     | Ok () -> ()
     | Error msg -> Alcotest.failf "clear runtime media_failover failed: %s" msg);
    Alcotest.(check (list string))
      "media failover cleared"
      []
      (Runtime.media_failover ());
    Alcotest.(check bool)
      "runtime.toml media_failover explicitly empty"
      true
      (string_contains (Fs_compat.load_file path) "media_failover = []"))
;;

let test_runtime_route_writer_clears_optional_structured_judge () =
  with_model_catalog_content runtime_structured_judge_model_catalog @@ fun () ->
  with_runtime_file (fun path ->
    (match
       Runtime.set_runtime_structured_judge
         ~runtime_config_path:path
         ~runtime_id:(Some "openai.gpt")
         ()
     with
     | Ok () -> ()
     | Error msg -> Alcotest.failf "set_runtime_structured_judge failed: %s" msg);
    Alcotest.(check (option string))
      "structured judge set"
      (Some "openai.gpt")
      (Runtime.structured_judge_runtime_id ());
    (match
       Runtime.set_runtime_structured_judge ~runtime_config_path:path ~runtime_id:None ()
     with
     | Ok () -> ()
     | Error msg -> Alcotest.failf "clear runtime structured_judge failed: %s" msg);
    Alcotest.(check bool)
      "runtime.toml structured_judge removed"
      false
      (string_contains (Fs_compat.load_file path) "structured_judge");
    Alcotest.(check (option string))
      "structured judge cache cleared"
      None
      (Runtime.structured_judge_runtime_id ()))
;;

let test_runtime_config_text_loads_runtime_toml () =
  with_runtime_file (fun path ->
    match Runtime.load_config_text ~runtime_config_path:path () with
    | Error msg -> Alcotest.failf "load_config_text failed: %s" msg
    | Ok (loaded_path, source_text) ->
      Alcotest.(check string) "loaded path" path loaded_path;
      Alcotest.(check string) "loaded source text" runtime_config source_text)
;;

let test_runtime_config_text_save_reloads_runtime_cache () =
  with_runtime_file (fun path ->
    (match
       Runtime.save_config_text
         ~runtime_config_path:path
         runtime_config_openai_default
     with
     | Ok () -> ()
     | Error msg -> Alcotest.failf "save_config_text failed: %s" msg);
    Alcotest.(check string)
      "runtime.toml raw source saved exactly"
      runtime_config_openai_default
      (Fs_compat.load_file path);
    Alcotest.(check string)
      "runtime cache reloaded"
      "openai.gpt"
      (Runtime.get_default_runtime_id ()))
;;

let test_runtime_config_text_save_rejects_invalid_without_write () =
  with_runtime_file (fun path ->
    let before = Fs_compat.load_file path in
    (match
       Runtime.save_config_text
         ~runtime_config_path:path
         "[runtime]\ndefault = \"missing.runtime\"\n"
     with
     | Ok () -> Alcotest.fail "expected invalid raw runtime.toml to fail"
     | Error msg ->
       Alcotest.(check bool)
         "error mentions unresolved default"
         true
         (string_contains msg "missing.runtime"));
    Alcotest.(check string)
      "runtime.toml unchanged after raw validation failure"
      before
      (Fs_compat.load_file path);
    Alcotest.(check string)
      "runtime cache unchanged"
      "runpod_mtp.qwen"
      (Runtime.get_default_runtime_id ()))
;;

let test_runtime_id_tool_arg_is_not_removed_keeper_arg () =
  match
    Keeper_types_profile.reject_removed_keeper_input_keys
      ~tool_name:"masc_keeper_up"
      (`Assoc [ "runtime_id", `String "openai.gpt" ])
  with
  | Ok () -> ()
  | Error msg ->
    Alcotest.failf "runtime_id dashboard patch arg should be accepted: %s" msg
;;

let test_undeclared_keeper_falls_to_default () =
  with_config_dir (fun _config_dir ->
    with_runtime_initialized (fun () ->
      (* no keepers/nobody.toml → runtime_id = None → [runtime].default *)
      Alcotest.(check string)
        "undeclared keeper dispatches to [runtime].default"
        (Runtime.get_default_runtime_id ())
        (KMC.runtime_id_of_meta (make_meta "nobody"))))
;;

(* ---- driver dispatch lookup: resolve, or fail fast ---- *)

let test_get_runtime_by_id_resolves_and_fails_fast () =
  with_runtime_initialized (fun () ->
    Alcotest.(check (option string))
      "known id resolves to its runtime"
      (Some "openai.gpt")
      (Option.map
         (fun (rt : Runtime.t) -> rt.Runtime.id)
         (Runtime.get_runtime_by_id "openai.gpt"));
    Alcotest.(check (option string))
      "unknown id resolves to None (driver fails fast, no default substitution)"
      None
      (Option.map
         (fun (rt : Runtime.t) -> rt.Runtime.id)
         (Runtime.get_runtime_by_id "bogus.binding")))
;;

(* ---- rerank resolver: resolve the requested runtime, or fail fast ----

   Audit F8: [Runtime_oas_runner.resolve_runtime_providers] used to discard
   [runtime_id] and always return the default runtime, silently substituting
   an operator-overridable id (MASC_KEEPER_LLM_RERANK_RUNTIME on the LLM
   rerank path).  It must resolve the requested id via the RFC-0207 catalog
   and return [Error] on an unknown id — never the default runtime. *)

let provider_base_url_of_runtime_id runtime_id =
  match Runtime.get_runtime_by_id runtime_id with
  | Some rt -> rt.Runtime.provider_config.Llm_provider.Provider_config.base_url
  | None -> Alcotest.failf "fixture runtime %s missing from catalog" runtime_id
;;

let test_rerank_resolver_resolves_requested_runtime () =
  with_runtime_initialized (fun () ->
    (* Known non-default id resolves to that runtime's provider, not the
       default's. *)
    (match
       Runtime_oas_runner.resolve_runtime_providers ~runtime_id:"openai.gpt" ()
     with
     | Error msg -> Alcotest.failf "expected openai.gpt to resolve: %s" msg
     | Ok [ provider ] ->
       Alcotest.(check string)
         "resolved provider belongs to the requested runtime"
         (provider_base_url_of_runtime_id "openai.gpt")
         provider.Llm_provider.Provider_config.base_url
     | Ok providers ->
       Alcotest.failf "expected exactly one provider, got %d" (List.length providers));
    (* Empty id resolves the default runtime. *)
    match Runtime_oas_runner.resolve_runtime_providers ~runtime_id:"" () with
    | Error msg -> Alcotest.failf "expected empty id to resolve default: %s" msg
    | Ok [ provider ] ->
      Alcotest.(check string)
        "empty id resolves the default runtime's provider"
        (provider_base_url_of_runtime_id (Runtime.get_default_runtime_id ()))
        provider.Llm_provider.Provider_config.base_url
    | Ok providers ->
      Alcotest.failf "expected exactly one provider, got %d" (List.length providers))
;;

let test_rerank_resolver_errors_on_unknown_runtime_id () =
  with_runtime_initialized (fun () ->
    match
      Runtime_oas_runner.resolve_runtime_providers ~runtime_id:"bogus.binding" ()
    with
    | Ok _ ->
      Alcotest.fail
        "unknown runtime id must return Error, not the default runtime \
         (silent substitution)"
    | Error msg ->
      Alcotest.(check bool)
        "error names the unknown runtime id"
        true
        (string_contains msg "bogus.binding"))
;;

let test_context_budget_uses_selected_runtime () =
  with_runtime_initialized (fun () ->
    let default_budget =
      Keeper_context_runtime.resolve_max_context_resolution
        ~requested_override:None
        [ "runpod_mtp.qwen" ]
    in
    let selected_budget =
      Keeper_context_runtime.resolve_max_context_resolution
        ~requested_override:None
        [ "openai.gpt" ]
    in
    Alcotest.(check int)
      "default runtime budget"
      128000
      default_budget.Keeper_context_runtime.effective_budget;
    Alcotest.(check int)
      "selected runtime budget"
      64000
      selected_budget.Keeper_context_runtime.effective_budget)
;;

(* Production path: [resolve_max_context_resolution_of_meta] must budget against
   the keeper's routed runtime (openai.gpt = 64000), NOT [runtime].default
   (runpod_mtp.qwen = 128000).  Without prepending [runtime_id_of_meta], the
   projection labels (global, runtime-id-agnostic) would size against the
   default and admit oversized prompts for a per-keeper routed runtime. *)
let test_of_meta_budgets_against_routed_runtime () =
  with_runtime_initialized (fun () ->
    (* [budgettest] is assigned [openai.gpt] in [[runtime.assignments]]. *)
    let res =
      Keeper_context_runtime.resolve_max_context_resolution_of_meta
        (make_meta "budgettest")
    in
    Alcotest.(check int)
      "of_meta budgets against routed runtime (openai.gpt=64000), not default (128000)"
      64000
      res.Keeper_context_runtime.effective_budget)
;;

let test_turn_budget_uses_routed_runtime () =
  with_runtime_initialized (fun () ->
    (* [budgettest] is assigned [openai.gpt] in [[runtime.assignments]]. *)
    let budget =
      Keeper_turn_runtime_budget.resolved_max_context_for_turn
        ~meta:(make_meta "budgettest")
    in
    Alcotest.(check int)
      "turn budget uses routed runtime, not runtime-id-agnostic labels"
      64000
      budget)
;;

(* ---- per-model thinking gate: runtime.toml [thinking-support] drives the
   keeper thinking seed via [Runtime_inference.for_runtime] ----

   The keeper turn loop ([Keeper_run_tools_hooks]) treats the seed's
   [thinking_enabled] as the runtime model's explicit policy: [Some false]
   forces thinking off, [Some true] enables thinking even when the global
   default is off, and [None] leaves the caller policy unchanged. *)

let runtime_config_thinking =
  {|
[runtime]
default = "ollama_cloud.think"

[providers.ollama_cloud]
display-name = "Ollama Cloud"
protocol = "openai-compatible-http"
endpoint = "https://ollama.example/v1"

[models.think]
api-name = "think"
max-context = 128000
tools-support = true
thinking-support = true
preserve-thinking = true
streaming = true

[models.nothink]
api-name = "nothink"
max-context = 128000
tools-support = true
thinking-support = false
streaming = true

[models.thinkdefault]
api-name = "qwen36-35b-a3b-mtp"
max-context = 128000
tools-support = true
thinking-support = true
streaming = true

[models.thinkexplicitoff]
api-name = "qwen36-35b-a3b-mtp"
max-context = 128000
tools-support = true
thinking-support = true
preserve-thinking = false
streaming = true

[models.smallout]
api-name = "reasoning-small-out"
max-context = 128000
tools-support = true
thinking-support = true
streaming = true

[models.bigout]
api-name = "reasoning-big-out"
max-context = 1000000
tools-support = true
thinking-support = true
streaming = true

[ollama_cloud.think]
is-default = true
max-concurrent = 1

[ollama_cloud.nothink]
max-concurrent = 1

[ollama_cloud.thinkdefault]
max-concurrent = 1

[ollama_cloud.thinkexplicitoff]
max-concurrent = 1

[ollama_cloud.smallout]
max-concurrent = 1

[ollama_cloud.bigout]
max-concurrent = 1
|}
;;

let runtime_thinking_model_catalog =
  {|
[[models]]
id_prefix = "openai_compat/qwen36-35b-a3b-mtp"
base = "openai_chat"
max_context_tokens = 131072
supports_tools = true
supports_tool_choice = true
supports_reasoning = true
supports_extended_thinking = true
supports_reasoning_budget = true
thinking_control_format = "chat_template_kwargs"
preserve_thinking_control_format = "chat_template_kwargs_preserve_thinking"
supports_native_streaming = true

[[models]]
id_prefix = "openai_compat/reasoning-small-out"
base = "openai_chat"
max_context_tokens = 131072
max_output_tokens = 4096
supports_tools = true
supports_reasoning = true
supports_extended_thinking = true
supports_native_streaming = true

[[models]]
id_prefix = "openai_compat/reasoning-big-out"
base = "openai_chat"
max_context_tokens = 1000000
max_output_tokens = 200000
supports_tools = true
supports_reasoning = true
supports_extended_thinking = true
supports_native_streaming = true
|}
;;

let with_runtime_thinking f =
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  with_temp_dir "runtime-thinking-gate" @@ fun dir ->
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
    (fun () ->
      with_model_catalog_content runtime_thinking_model_catalog @@ fun () ->
      let path = Filename.concat dir "runtime.toml" in
      write_file path runtime_config_thinking;
      (match Runtime.init_default ~config_path:path with
       | Ok () -> ()
       | Error msg -> Alcotest.failf "runtime init_default failed: %s" msg);
      f ())
;;

let test_thinking_support_true_enables_thinking_and_preserves () =
  with_runtime_thinking (fun () ->
    let seed = Runtime_inference.for_runtime ~name:"ollama_cloud.think" in
    Alcotest.(check (option bool))
      "thinking-support true emits Some true"
      (Some true)
      seed.Runtime_inference.thinking_enabled;
    Alcotest.(check (option bool))
      "preserve-thinking true emits Some true"
      (Some true)
      seed.Runtime_inference.preserve_thinking)
;;

let test_thinking_support_true_leaves_preserve_unset () =
  with_runtime_thinking (fun () ->
    let seed = Runtime_inference.for_runtime ~name:"ollama_cloud.thinkdefault" in
    Alcotest.(check (option bool))
      "OAS request-side preserve capability does not auto-enable preserve"
      None
      seed.Runtime_inference.preserve_thinking)
;;

let test_explicit_preserve_false_overrides_capability_default () =
  with_runtime_thinking (fun () ->
    let seed = Runtime_inference.for_runtime ~name:"ollama_cloud.thinkexplicitoff" in
    Alcotest.(check (option bool))
      "explicit preserve-thinking=false remains Some false"
      (Some false)
      seed.Runtime_inference.preserve_thinking)
;;

let test_thinking_support_false_forces_off () =
  with_runtime_thinking (fun () ->
    let seed = Runtime_inference.for_runtime ~name:"ollama_cloud.nothink" in
    Alcotest.(check (option bool))
      "non-thinking model emits Some false (capability gate forces thinking off)"
      (Some false)
      seed.Runtime_inference.thinking_enabled)
;;

let test_thinking_unknown_runtime_defers () =
  with_runtime_thinking (fun () ->
    let seed = Runtime_inference.for_runtime ~name:"bogus.binding" in
    Alcotest.(check (option bool))
      "unknown runtime id emits None (no per-model signal)"
      None
      seed.Runtime_inference.thinking_enabled)
;;

let test_seed_of_thinking_support_gate_contract () =
  Alcotest.(check (option bool))
    "Some false -> force thinking off"
    (Some false)
    (Runtime_inference.seed_of_thinking_support (Some false)).Runtime_inference.thinking_enabled;
  Alcotest.(check (option bool))
    "Some true -> enable thinking"
    (Some true)
    (Runtime_inference.seed_of_thinking_support (Some true)).Runtime_inference.thinking_enabled;
  Alcotest.(check (option bool))
    "None -> leave caller policy unchanged"
    None
    (Runtime_inference.seed_of_thinking_support None).Runtime_inference.thinking_enabled
;;

(* ---- reasoning max_tokens resolution: [Runtime_inference.resolve_max_tokens]
   sizes a reasoning turn from the model's declared output ceiling (OAS catalog),
   bounded above by the operational [reasoning_turn_max_tokens] (32768). A
   reasoning runtime with no catalog ceiling keeps the caller fallback (the bound
   is never the request value on its own); non-reasoning runtimes keep the caller
   fallback. Regression guard for the thinking_only + stop_reason=max_tokens
   truncation (live fleet 2026-06-30). ----

   The fallback sentinel (8192) mirrors the keeper path's flat default and is
   distinct from every reasoning result asserted below, so a test failure
   pinpoints which branch regressed. *)
let fallback_sentinel () = 8192

let test_resolve_max_tokens_reasoning_defers_to_caps_not_fallback () =
  with_runtime_thinking (fun () ->
    (* qwen36-35b-a3b-mtp declares no explicit [max_output_tokens], so its
       capability inherits the provider base ceiling (16384). The reasoning path
       defers to that OAS-owned ceiling — NOT the flat keeper fallback (8192).
       Raising this runtime to the 32768 operational bound is a catalog change
       (declare a higher max_output_tokens), per the OAS-owns-the-value split. *)
    Alcotest.(check int)
      "reasoning runtime defers to its OAS capability ceiling (16384 base), \
       above the 8192 keeper fallback"
      16384
      (Runtime_inference.resolve_max_tokens
         ~runtime_id:"ollama_cloud.thinkdefault"
         ~fallback:fallback_sentinel))
;;

let test_resolve_max_tokens_non_reasoning_uses_fallback () =
  with_runtime_thinking (fun () ->
    Alcotest.(check int)
      "non-reasoning runtime keeps the caller fallback unchanged"
      8192
      (Runtime_inference.resolve_max_tokens
         ~runtime_id:"ollama_cloud.nothink"
         ~fallback:fallback_sentinel))
;;

let test_resolve_max_tokens_reasoning_small_ceiling_respected () =
  with_runtime_thinking (fun () ->
    Alcotest.(check int)
      "reasoning runtime whose declared ceiling is below the operational bound \
       keeps its smaller ceiling (never request more than the provider accepts)"
      4096
      (Runtime_inference.resolve_max_tokens
         ~runtime_id:"ollama_cloud.smallout"
         ~fallback:fallback_sentinel))
;;

let test_resolve_max_tokens_reasoning_big_ceiling_clamped () =
  with_runtime_thinking (fun () ->
    Alcotest.(check int)
      "reasoning runtime whose declared ceiling exceeds the operational bound is \
       clamped to the bound (runaway guard)"
      32768
      (Runtime_inference.resolve_max_tokens
         ~runtime_id:"ollama_cloud.bigout"
         ~fallback:fallback_sentinel))
;;

let test_resolve_max_tokens_unknown_runtime_uses_fallback () =
  with_runtime_thinking (fun () ->
    Alcotest.(check int)
      "unknown runtime id falls through to the caller fallback (fail-safe)"
      8192
      (Runtime_inference.resolve_max_tokens
         ~runtime_id:"bogus.binding"
         ~fallback:fallback_sentinel))
;;

let test_resolve_max_tokens_reasoning_no_capability_falls_back () =
  with_runtime_thinking (fun () ->
    (* [ollama_cloud.think]'s model api-name is absent from the OAS catalog, so
       its capability projection has no max_output_tokens even though
       runtime.toml marks it thinking-support=true. A reasoning runtime with no
       declared ceiling must NOT jump to the operational bound — without a known
       provider ceiling, requesting 32768 could exceed what the provider accepts
       and turn the thinking truncation into a max_tokens rejection. It keeps the
       caller fallback (the budget increase is gated on an OAS-declared ceiling). *)
    Alcotest.(check int)
      "reasoning runtime with no catalog ceiling keeps the fallback, does not \
       jump to the operational bound"
      8192
      (Runtime_inference.resolve_max_tokens
         ~runtime_id:"ollama_cloud.think"
         ~fallback:fallback_sentinel))
;;

let test_max_output_tokens_accessor_projects_catalog () =
  with_runtime_thinking (fun () ->
    Alcotest.(check (option int))
      "explicitly declared catalog ceiling is projected verbatim"
      (Some 200000)
      (Runtime.max_output_tokens_of_runtime_id "ollama_cloud.bigout");
    Alcotest.(check (option int))
      "catalog row without max_output_tokens inherits the provider base ceiling"
      (Some 16384)
      (Runtime.max_output_tokens_of_runtime_id "ollama_cloud.thinkdefault");
    Alcotest.(check (option int))
      "reasoning runtime whose model is absent from the catalog projects None"
      None
      (Runtime.max_output_tokens_of_runtime_id "ollama_cloud.think");
    Alcotest.(check (option int))
      "unknown runtime id projects None (no capability record)"
      None
      (Runtime.max_output_tokens_of_runtime_id "bogus.binding"))
;;

(* ---- materialize-failure diagnostics ----

   Regression guard for the kimi.kimi-for-coding boot-fatal (2026-07-03): a
   [messages-http] provider binding cannot be materialized into a
   provider_config (the runtime adapter only builds openai-compatible / ollama
   configs), so it is dropped from the runtime list. An assignment targeting it
   used to report the misleading "[runtime.assignments].ramarama = ... not found
   among N runtimes" — pointing the operator at a typo that does not exist — when
   the real cause is that the binding was defined but failed to materialize.
   Behavior is unchanged (the binding is still excluded, fail-closed); only the
   diagnostic must name the materialize failure. A genuine typo (an id that is
   not a defined binding at all) must still report "not found among N runtimes". *)

(* [ramarama] is assigned [kimi.kimi-for-coding], a defined binding whose
   provider uses protocol messages-http (no adapter provider_config path). The
   default [openai.gpt] materializes so validation reaches the assignment. *)
let runtime_config_messages_http_assignment =
  {|
[runtime]
default = "openai.gpt"

[runtime.assignments]
ramarama = "kimi.kimi-for-coding"

[providers.openai]
display-name = "OpenAI"
protocol = "openai-compatible-http"
endpoint = "https://api.openai.example/v1"

[providers.kimi]
display-name = "Kimi"
protocol = "messages-http"
endpoint = "https://api.moonshot.example/anthropic"

[models.gpt]
api-name = "gpt"
max-context = 64000
tools-support = true
streaming = true

[models.kimi-for-coding]
api-name = "kimi-for-coding"
max-context = 128000
tools-support = true
streaming = true

[openai.gpt]
is-default = true
max-concurrent = 1

[kimi.kimi-for-coding]
max-concurrent = 1
|}
;;

(* [ramarama] is assigned [bogus.binding], which names no declared binding at
   all — the genuine operator-typo case whose "not found among N runtimes"
   message must be preserved. *)
let runtime_config_typo_assignment =
  {|
[runtime]
default = "openai.gpt"

[runtime.assignments]
ramarama = "bogus.binding"

[providers.openai]
display-name = "OpenAI"
protocol = "openai-compatible-http"
endpoint = "https://api.openai.example/v1"

[models.gpt]
api-name = "gpt"
max-context = 64000
tools-support = true
streaming = true

[openai.gpt]
is-default = true
max-concurrent = 1
|}
;;

let load_list_error content =
  with_temp_dir "runtime-materialize-diag" @@ fun dir ->
  let path = Filename.concat dir "runtime.toml" in
  write_file path content;
  match Runtime.load_list ~config_path:path with
  | Ok _ ->
    Alcotest.fail "expected load_list to reject the assignment; got Ok"
  | Error msg -> msg
;;

let test_assignment_materialize_failure_surfaces_reason () =
  let msg = load_list_error runtime_config_messages_http_assignment in
  Alcotest.(check bool)
    "error names the assignment target binding"
    true
    (string_contains msg "kimi.kimi-for-coding");
  Alcotest.(check bool)
    "error states the binding was defined but not materialized"
    true
    (string_contains msg "could not be materialized as a runtime");
  Alcotest.(check bool)
    "error names the unmapped protocol (messages-http)"
    true
    (string_contains msg "messages-http");
  Alcotest.(check bool)
    "error explains the adapter cannot build a provider_config"
    true
    (string_contains msg "cannot build a provider_config");
  Alcotest.(check bool)
    "error does NOT fall back to the misleading bare not-found wording"
    false
    (string_contains msg "not found among")
;;

let test_assignment_typo_keeps_not_found () =
  let msg = load_list_error runtime_config_typo_assignment in
  Alcotest.(check bool)
    "genuine typo names the unresolved id"
    true
    (string_contains msg "bogus.binding");
  Alcotest.(check bool)
    "genuine typo keeps the original not-found-among-runtimes wording"
    true
    (string_contains msg "not found among");
  Alcotest.(check bool)
    "genuine typo is not mislabeled as a materialize failure"
    false
    (string_contains msg "could not be materialized")
;;

let () =
  Alcotest.run
    "runtime_per_keeper_routing"
    [ ( "runtime-assignment routing"
      , [ Alcotest.test_case
            "[runtime.assignments] drives runtime_id_of_meta"
            `Quick
            test_assignment_drives_runtime_id_of_meta
        ; Alcotest.test_case
            "unassigned keeper falls to [runtime].default"
            `Quick
            test_undeclared_keeper_falls_to_default
        ; Alcotest.test_case
            "dashboard runtime assignment writes runtime.toml and refreshes cache"
            `Quick
            test_runtime_assignment_writer_updates_runtime_toml
        ; Alcotest.test_case
            "dashboard runtime inventory exposes assignment governance"
            `Quick
            test_runtime_inventory_surfaces_assignment_governance
        ; Alcotest.test_case
            "unknown assignment is rejected before runtime.toml write"
            `Quick
            test_runtime_assignment_writer_rejects_unknown_runtime_without_write
        ; Alcotest.test_case
            "dashboard runtime assignment clear validates and refreshes cache"
            `Quick
            test_runtime_assignment_writer_clears_assignment
        ; Alcotest.test_case
            "dashboard runtime route writer updates default"
            `Quick
            test_runtime_route_writer_updates_default
        ; Alcotest.test_case
            "unknown default route is rejected before runtime.toml write"
            `Quick
            test_runtime_route_writer_rejects_unknown_default_without_write
        ; Alcotest.test_case
            "dashboard runtime route writer clears optional librarian"
            `Quick
            test_runtime_route_writer_clears_optional_librarian
        ; Alcotest.test_case
            "dashboard runtime route writer updates media_failover"
            `Quick
            test_runtime_route_writer_updates_media_failover
        ; Alcotest.test_case
            "dashboard runtime route writer clears optional structured judge"
            `Quick
            test_runtime_route_writer_clears_optional_structured_judge
        ; Alcotest.test_case
            "dashboard raw runtime.toml load returns full source"
            `Quick
            test_runtime_config_text_loads_runtime_toml
        ; Alcotest.test_case
            "dashboard raw runtime.toml save validates and reloads cache"
            `Quick
            test_runtime_config_text_save_reloads_runtime_cache
        ; Alcotest.test_case
            "dashboard raw runtime.toml save rejects invalid source before write"
            `Quick
            test_runtime_config_text_save_rejects_invalid_without_write
        ; Alcotest.test_case
            "runtime_id API arg is not rejected as a removed keeper arg"
            `Quick
            test_runtime_id_tool_arg_is_not_removed_keeper_arg
        ] )
    ; ( "driver lookup"
      , [ Alcotest.test_case
            "get_runtime_by_id resolves known / fails fast on unknown"
            `Quick
            test_get_runtime_by_id_resolves_and_fails_fast
        ; Alcotest.test_case
            "rerank resolver resolves the requested runtime (audit F8)"
            `Quick
            test_rerank_resolver_resolves_requested_runtime
        ; Alcotest.test_case
            "rerank resolver errors on unknown runtime id, no default substitution"
            `Quick
            test_rerank_resolver_errors_on_unknown_runtime_id
        ; Alcotest.test_case
            "context budget uses selected runtime max-context"
            `Quick
            test_context_budget_uses_selected_runtime
        ; Alcotest.test_case
            "of_meta budgets against the routed runtime (production path)"
            `Quick
            test_of_meta_budgets_against_routed_runtime
        ; Alcotest.test_case
            "turn budget uses the routed runtime"
            `Quick
            test_turn_budget_uses_routed_runtime
        ] )
    ; ( "per-model thinking gate"
      , [ Alcotest.test_case
            "thinking-support=true enables thinking and preserve-thinking"
            `Quick
            test_thinking_support_true_enables_thinking_and_preserves
        ; Alcotest.test_case
            "request-side preserve capability stays policy-neutral"
            `Quick
            test_thinking_support_true_leaves_preserve_unset
        ; Alcotest.test_case
            "explicit preserve-thinking=false stays explicit"
            `Quick
            test_explicit_preserve_false_overrides_capability_default
        ; Alcotest.test_case
            "thinking-support=false forces thinking off (Some false)"
            `Quick
            test_thinking_support_false_forces_off
        ; Alcotest.test_case
            "unknown runtime id defers (None)"
            `Quick
            test_thinking_unknown_runtime_defers
        ; Alcotest.test_case
            "seed_of_thinking_support gate contract (pure)"
            `Quick
            test_seed_of_thinking_support_gate_contract
        ] )
    ; ( "reasoning max_tokens resolution"
      , [ Alcotest.test_case
            "reasoning runtime defers to OAS capability ceiling, not fallback"
            `Quick
            test_resolve_max_tokens_reasoning_defers_to_caps_not_fallback
        ; Alcotest.test_case
            "non-reasoning runtime -> caller fallback"
            `Quick
            test_resolve_max_tokens_non_reasoning_uses_fallback
        ; Alcotest.test_case
            "reasoning runtime, ceiling below bound -> ceiling respected"
            `Quick
            test_resolve_max_tokens_reasoning_small_ceiling_respected
        ; Alcotest.test_case
            "reasoning runtime, ceiling above bound -> clamped to bound"
            `Quick
            test_resolve_max_tokens_reasoning_big_ceiling_clamped
        ; Alcotest.test_case
            "unknown runtime id -> caller fallback"
            `Quick
            test_resolve_max_tokens_unknown_runtime_uses_fallback
        ; Alcotest.test_case
            "reasoning runtime with no catalog ceiling -> fallback, not bound"
            `Quick
            test_resolve_max_tokens_reasoning_no_capability_falls_back
        ; Alcotest.test_case
            "max_output_tokens_of_runtime_id projects catalog ceiling"
            `Quick
            test_max_output_tokens_accessor_projects_catalog
        ] )
    ; ( "materialize-failure diagnostics"
      , [ Alcotest.test_case
            "assignment to an unmaterializable binding surfaces the reason"
            `Quick
            test_assignment_materialize_failure_surfaces_reason
        ; Alcotest.test_case
            "assignment typo keeps the not-found-among-runtimes message"
            `Quick
            test_assignment_typo_keeps_not_found
        ] )
    ]
;;
