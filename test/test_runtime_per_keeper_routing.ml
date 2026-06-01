(* RFC-0207 — per-keeper LLM runtime routing via [runtime_id].

   A keeper's keepers/<name>.toml [runtime_id = "provider.model"] is the single
   surface for choosing its runtime.  [Keeper_meta_contract.runtime_id_of_meta]
   resolves that selection (cached by
   [Keeper_types_profile.load_keeper_profile_defaults]) so it reaches the turn
   driver; an undeclared keeper falls through to [[runtime].default]; and the
   driver's [Runtime.get_runtime_by_id] returns [None] for an id that does not
   materialize, so dispatch fails fast (no silent substitution — RFC-0206 §2.1).

   This is the SAME declarative runtime source as
   [Keeper_runtime.effective_declarative_runtime_id] (declare/status), so there
   is one surface — the dispatcher and the reconcile change-detector cannot
   disagree. *)

open Alcotest
open Masc_mcp
module KMC = Keeper_meta_contract

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

let write_keeper_toml config_dir name body =
  let keepers_dir = Filename.concat config_dir "keepers" in
  (try Unix.mkdir keepers_dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  write_file (Filename.concat keepers_dir (name ^ ".toml")) body
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
   and ["openai.gpt"] (used to prove [get_runtime_by_id] resolution). *)
let runtime_config =
  {|
[runtime]
default = "runpod_mtp.qwen"

[providers.runpod_mtp]
display-name = "RunPod"
protocol = "provider_d-http"
endpoint = "https://runpod.example/v1"

[providers.openai]
display-name = "OpenAI"
protocol = "provider_d-http"
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

[runpod_mtp.qwen]
is-default = true
max-concurrent = 4

[openai.gpt]
is-default = true
max-concurrent = 1
|}
;;

let with_runtime_initialized f =
  with_temp_dir "runtime-per-keeper-routing-runtime" @@ fun dir ->
  let path = Filename.concat dir "keeper_runtime.toml" in
  write_file path runtime_config;
  (match Runtime.init_default ~config_path:path with
   | Ok () -> ()
   | Error msg -> Alcotest.failf "runtime init_default failed: %s" msg);
  f ()
;;

(* ---- the per-keeper selection actually reaches the dispatcher ---- *)

let test_runtime_id_drives_runtime_id_of_meta () =
  with_config_dir (fun config_dir ->
    write_keeper_toml config_dir "routingtest" {|[keeper]
goal = "route to a non-default provider-model"
runtime_id = "openai.gpt"
|};
    Alcotest.(check string)
      "declared keeper dispatches to its [runtime_id], not the global default"
      "openai.gpt"
      (KMC.runtime_id_of_meta (make_meta "routingtest")))
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
  with_config_dir (fun config_dir ->
    write_keeper_toml config_dir "budgettest" {|[keeper]
goal = "route to a smaller-context runtime"
runtime_id = "openai.gpt"
|};
    with_runtime_initialized (fun () ->
      let res =
        Keeper_context_runtime.resolve_max_context_resolution_of_meta
          (make_meta "budgettest")
      in
      Alcotest.(check int)
        "of_meta budgets against routed runtime (openai.gpt=64000), not default (128000)"
        64000
        res.Keeper_context_runtime.effective_budget))
;;

let test_turn_budget_uses_routed_runtime () =
  with_config_dir (fun config_dir ->
    write_keeper_toml config_dir "budgettest" {|[keeper]
goal = "route to a smaller-context runtime"
runtime_id = "openai.gpt"
|};
    with_runtime_initialized (fun () ->
      let budget =
        Keeper_turn_runtime_budget.resolved_max_context_for_turn
          ~meta:(make_meta "budgettest")
          []
      in
      Alcotest.(check int)
        "turn budget uses routed runtime even when projected labels are empty"
        64000
        budget))
;;

let () =
  Alcotest.run
    "runtime_per_keeper_routing"
    [ ( "runtime-id routing"
      , [ Alcotest.test_case
            "[runtime_id] drives runtime_id_of_meta"
            `Quick
            test_runtime_id_drives_runtime_id_of_meta
        ; Alcotest.test_case
            "undeclared keeper falls to [runtime].default"
            `Quick
            test_undeclared_keeper_falls_to_default
        ] )
    ; ( "driver lookup"
      , [ Alcotest.test_case
            "get_runtime_by_id resolves known / fails fast on unknown"
            `Quick
            test_get_runtime_by_id_resolves_and_fails_fast
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
    ]
;;
