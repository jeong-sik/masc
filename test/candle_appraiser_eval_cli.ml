(** Opt-in semantic measurement through the production Candle adapter.
    No server, Goal store, payout worker or Candle ledger is started. *)
open Masc
module A = Candle_appraisal
module J = Candle_json
module Runs = Exact_lane_run_registry
module U = Yojson.Safe.Util
let ( let* ) = Result.bind

type case = { id : string; request : A.request }
let field context = J.field ~context
let goal json =
  let context = "eval Goal" in
  let* fields = J.object_fields ~context json in
  let* title, fields = field context "title" J.as_non_blank fields in
  let* metric, fields = field context "metric" (J.as_nullable J.as_string) fields in
  let* target_value, fields = field context "target_value" (J.as_nullable J.as_string) fields in
  let* () = J.finish ~context fields in
  Ok { A.title; metric; target_value }
let task json =
  let context = "eval Task" in
  let* fields = J.object_fields ~context json in
  let* task_id, fields = field context "task_id" J.as_non_blank fields in
  let* title, fields = field context "title" J.as_non_blank fields in
  let* keeper, fields = field context "keeper" J.as_non_blank fields in
  let* () = J.finish ~context fields in
  Ok { A.task_id; title; keeper }
let request stage json =
  let context = "eval request" in
  let* fields = J.object_fields ~context json in
  let* goal, fields = field context "goal" goal fields in
  let* request, fields = match stage with
    | "grade" -> Ok (A.Grade goal, fields)
    | "relation" ->
      let* task_title, fields = field context "task_title" J.as_non_blank fields in
      Ok (A.Relation {goal;task_title}, fields)
    | "weights" ->
      let* tasks, fields = field context "tasks" (J.as_list task) fields in
      let* keepers, fields = field context "keepers" (J.as_list J.as_non_blank) fields in
      let* weight_max, fields = field context "weight_max" A.as_int fields in
      if tasks=[] || keepers=[] || weight_max < 1
         || List.sort_uniq String.compare keepers <> List.sort String.compare keepers
         || List.exists (fun (task:A.task) -> not (List.mem task.keeper keepers)) tasks
      then Error "weights case must have positive range and uniquely named assignees"
      else Ok (A.Weights {goal;tasks;keepers;weight_max}, fields)
    | _ -> Error ("unknown eval stage: " ^ stage) in
  let* () = J.finish ~context fields in
  Ok request
let case json =
  let context = "eval case" in
  let* fields = J.object_fields ~context json in
  let* id, fields = field context "id" J.as_non_blank fields in
  let* stage, fields = field context "stage" J.as_non_blank fields in
  let* request, fields = field context "input" (request stage) fields in
  (* Expectations are report metadata and never reach the model. *)
  let* _, fields = field context "comparison" (fun value -> Ok value) fields in
  let* _, fields = field context "relation_expectation" (J.as_nullable J.as_string) fields in
  let* () = J.finish ~context fields in
  Ok {id;request}
let get = function Ok value -> value | Error detail -> failwith detail
let load path = In_channel.with_open_bin path In_channel.input_all
let hash text = Digestif.SHA256.(to_hex (digest_string text))
let write_json path json =
  Out_channel.with_open_bin path (fun channel ->
    output_string channel (Yojson.Safe.pretty_to_string json ^ "\n"))
let verify_file plan key path =
  let contents = load path in
  if hash contents <> U.(member key plan |> to_string) then
    failwith ("prepared input changed: " ^ key);
  contents

let run ~base_path ~evidence_path ~execute =
  (match Runtime.exact_output_target_source () with
   | Runtime.Runtime_binding_targets -> ()
   | Runtime.Replacement_catalog_targets _ ->
     failwith "evaluation requires prepared runtime bindings; AGENT_CORE_MODEL_CATALOG is not allowed");
  let plan = Yojson.Safe.from_string (load (Filename.concat base_path "plan.json")) in
  if U.member "schema" plan <> `String "masc.candle_appraiser_eval.v1" then
    failwith "not a prepared Candle appraisal evaluation workspace";
  let config_root = Filename.concat base_path ".masc/config" in
  let config_path = Filename.concat config_root "runtime.toml" in
  let config_text = verify_file plan "runtime_config_sha256" config_path in
  let case_text = verify_file plan "cases_sha256" (Filename.concat base_path "cases.json") in
  let cases = get (J.as_list case (Yojson.Safe.from_string case_text)) in
  let ids = List.map (fun case -> case.id) cases in
  if cases=[] || List.length ids <> List.length (List.sort_uniq String.compare ids) then
    failwith "case ids must be nonempty and unique";
  let trials = U.(member "trials" plan |> to_int) in
  if trials < 1 then failwith "trials must be positive";
  let prompts = Filename.concat base_path "prompts" in
  U.(member "prompt_sha256" plan |> to_assoc) |> List.iter (fun (name, expected) ->
    if Filename.basename name <> name then failwith "prompt name must be a path segment";
    if hash (load (Filename.concat prompts name)) <> U.to_string expected then
      failwith ("prepared prompt changed: " ^ name));
  let parsed = match Runtime_toml.parse_string config_text with
    | Ok parsed -> parsed
    | Error errors -> failwith (String.concat "; " (List.map Runtime_toml.show_parse_error errors)) in
  let runtime_id = U.(member "runtime_id" plan |> to_string) in
  let lane = match parsed.exact_output_lane_decls with
    | [lane] when lane.id = Standalone_lane.to_id Standalone_lane.Candle_appraiser
        && lane.slot_ids @ lane.cli_slot_ids = [runtime_id] -> lane
    | _ -> failwith "evaluation requires exactly one declared Candle appraiser slot" in
  if not execute then (
    print_endline (Yojson.Safe.to_string (`Assoc ["mode",`String "validated_without_model_calls";
      "cases",`Int (List.length cases);"trials",`Int trials;"runtime_id",`String runtime_id])))
  else (
    let expected_commit = U.(member "source_commit" plan |> to_string) in
    (match Build_identity.embedded_commit with
     | Some commit when commit=expected_commit -> ()
     | Some _ | None -> failwith "binary commit does not match the prepared source commit");
    let evidence = if evidence_path="" then Filename.concat base_path "evidence" else evidence_path in
    Unix.mkdir evidence 0o700;
    Unix.putenv Env_config_core.base_path_env_key base_path;
    Unix.putenv Env_config_core.config_dir_env_key config_root;
    Prompt_defaults.init ();
    Prompt_registry.set_markdown_dir prompts;
    Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
    Eio_context.set_env env;
    Eio_context.set_net (Eio.Stdenv.net env);
    Eio_context.set_mono_clock (Eio.Stdenv.mono_clock env);
    Masc_test_deps.init_eio_clock ~sw env;
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Process_eio.init ~cwd_default:(Eio.Stdenv.cwd env)
      ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env);
    ignore (Server_runtime_bootstrap.configure_agent_core_model_catalog_env () : string option);
    get (Runtime.init_default_strict ~config_path);
    let runtimes, _ = Runtime.runtimes_and_media_failover () in
    let catalog = Runtime.exact_output_resolver_catalog ~exact_output_lane_decls:[lane] runtimes in
    let snapshot = Runtime.load_exact_output_resolver_snapshot catalog.catalog_input
      |> Result.map_error Runtime_exact_output_registry.resolver_snapshot_error_to_string |> get in
    ignore (get (Runtime.publish_exact_output_registry ~required_lane_ids:[lane.id] ~lanes:[lane] snapshot)
      : Runtime_exact_output_registry.t);
    let registry = Runs.create ~path:(Filename.concat evidence Runs.storage_filename) () in
    (match Runs.install_global registry with Ok () -> () | Error Runs.Already_installed -> failwith "registry already installed");
    write_json (Filename.concat evidence "metadata.json")
      (`Assoc ["plan",plan;"build",Build_identity.to_yojson (Build_identity.current ());
        "scope",`String "production appraiser judgments only; no Goal or Candle ledger writes"]);
    Out_channel.with_open_bin (Filename.concat evidence "results.jsonl") (fun channel ->
      for trial = 1 to trials do
        List.iter (fun case ->
          let before = List.map (fun (run:Runs.run) -> run.run_id) (Runs.list_runs registry) in
          let identity : A.identity = {goal_id=case.id;
            request_id=Printf.sprintf "eval-%s-%d" case.id trial;verification_run_id="synthetic-eval-verification"} in
          let result = Server_candle_appraiser.run ~base_path ~identity case.request in
          let receipt = match List.filter (fun (run:Runs.run) -> not (List.mem run.run_id before)) (Runs.list_runs registry) with
            | [run] -> (match Runs.get registry ~run_id:run.run_id with Some run -> Runs.run_to_yojson run | None -> failwith "receipt unavailable")
            | _ -> failwith "appraiser did not produce exactly one run receipt" in
          let status, answer = match result with
            | Ok answer -> "ok", A.decision_json answer.decision
            | Error (A.Invalid_response detail) -> "invalid_response", `String detail
            | Error (A.Transport_unavailable detail) -> "transport_unavailable", `String detail in
          let row = `Assoc ["case_id",`String case.id;"trial",`Int trial;"stage",`String (A.stage case.request);
            "status",`String status;"answer",answer;"receipt",receipt] in
          output_string channel (Yojson.Safe.to_string row ^ "\n"); flush channel;
          Printf.printf "%s trial=%d %s\n%!" case.id trial status) cases
      done))

let () =
  Mirage_crypto_rng_unix.use_default ();
  let base_path = ref "" and evidence_path = ref "" and execute = ref false in
  Arg.parse ["--base-path",Arg.Set_string base_path,"Prepared private workspace (required)";
    "--evidence-path",Arg.Set_string evidence_path,"New output directory; defaults to BASE/evidence";
    "--execute",Arg.Set execute,"Make provider calls; without this flag only validate the fixture"]
    (fun arg -> raise (Arg.Bad ("unexpected argument: " ^ arg)))
    "candle_appraiser_eval_cli --base-path DIR [--execute]";
  if !base_path="" then (prerr_endline "--base-path is required"; exit 2);
  try run ~base_path:(Unix.realpath !base_path) ~evidence_path:!evidence_path ~execute:!execute with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> prerr_endline ("candle appraisal eval: " ^ Printexc.to_string exn); exit 1
