(** Replays recorded Librarian runs whose JEV preflight was attempted, with
    the request the production preflight sends now. Reads exact-lane run
    payloads only: no Memory mutation, range consumption or run
    registration occurs. *)
open Masc
module P = Typesafeai_librarian_preflight
let ( let* ) = Result.bind

type recorded =
  { run : string
  ; keeper_id : string
  ; status : string
  ; decision : string option
  ; variables : (string * string) list
  }

(* The recorded preflight statuses that sent a request to JEV. *)
let attempted_statuses = [ "judged"; "failed" ]

let read_json path =
  try Ok (Yojson.Safe.from_file path) with
  | Sys_error detail | Yojson.Json_error detail -> Error detail

let payload_file dir ~prefix =
  match List.filter (String.starts_with ~prefix) (Array.to_list (Sys.readdir dir)) with
  | [ name ] -> Some (Filename.concat dir name)
  | [] | _ :: _ :: _ -> None

let string_member name json =
  match Yojson.Safe.Util.member name json with
  | `String value -> Some value
  | _ -> None

let variables_of json =
  match Yojson.Safe.Util.(json |> member "actual_input" |> member "rendered_prompt_variables") with
  | `Assoc fields ->
    List.fold_right
      (fun (name, value) acc ->
         let* acc = acc in
         match value with
         | `String text -> Ok ((name, text) :: acc)
         | _ -> Error (name ^ " is not a string"))
      fields
      (Ok [])
  | _ -> Error "no rendered_prompt_variables"

(* [None] for a run whose recorded preflight never reached JEV. *)
let recorded_of_dir dir =
  match payload_file dir ~prefix:"input-", payload_file dir ~prefix:"output-" with
  | None, _ | _, None -> Ok None
  | Some input_path, Some output_path ->
    let* output = read_json output_path in
    let preflight = Yojson.Safe.Util.member "jev_preflight" output in
    (match string_member "status" preflight with
     | Some status when List.mem status attempted_statuses ->
       let* input = read_json input_path in
       let* variables = variables_of input in
       (match List.assoc_opt "keeper_id" variables with
        | None -> Error (dir ^ ": no keeper_id variable")
        | Some keeper_id ->
          Ok (Some { run = Filename.basename dir; keeper_id; status
                   ; decision = string_member "decision" preflight; variables }))
     | Some _ | None -> Ok None)

let recorded_runs ~payloads ~limit =
  let dirs =
    Sys.readdir payloads |> Array.to_list
    |> List.filter (String.starts_with ~prefix:"librarian-exact-")
    |> List.sort String.compare
    |> List.map (Filename.concat payloads)
  in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | _ when List.length acc >= limit -> Ok (List.rev acc)
    | dir :: rest ->
      let* found = recorded_of_dir dir in
      loop (Option.fold ~none:acc ~some:(fun run -> run :: acc) found) rest
  in
  loop [] dirs

let outcome_key (t : P.t) =
  match t.outcome with
  | P.Judged (_, judgment) -> "judged/" ^ P.decision_label judgment.choice
  | P.Failed _ -> "failed"
  | P.Invalid_answer _ -> "invalid_answer"
  | P.Question_unavailable _ -> "question_unavailable"
  | P.Skipped _ -> "skipped"
  | P.Ineligible _ -> "ineligible"
  | P.Awaiting_answer -> "awaiting_answer"

let recorded_key run =
  match run.decision with
  | Some decision -> run.status ^ "/" ^ decision
  | None -> run.status

let run () =
  let payloads = ref "" and output = ref "" and config = ref "" and prompts = ref ""
  and limit = ref max_int in
  Arg.parse
    ["--payloads", Arg.Set_string payloads, "Exact-lane run payload directory";
     "--output", Arg.Set_string output, "New private report file";
     "--config", Arg.Set_string config, "Explicit runtime TOML (preflight opt-in required)";
     "--prompt-dir", Arg.Set_string prompts, "Candidate config/prompts directory; persisted overrides are not loaded";
     "--limit", Arg.Set_int limit, "Replay at most this many runs"]
    (fun value -> raise (Arg.Bad ("unexpected argument " ^ value)))
    "masc_librarian_preflight_replay --payloads DIR --output FILE --config FILE --prompt-dir DIR [--limit N]";
  let* () = if List.exists (fun value -> String.trim !value = "") [payloads;output;config;prompts]
    then Error "--payloads, --output, --config and --prompt-dir are required" else Ok () in
  let output_path = Config_dir_resolver.absolute_path !output in
  let* () = match Fs_compat.exact_path_kind ~follow:false output_path with
    | Fs_compat.Exact_missing -> Ok () | _ -> Error "output must be a new file" in
  let* runs = recorded_runs ~payloads:(Config_dir_resolver.absolute_path !payloads) ~limit:!limit in
  let* config_observation =
    try
      let (_ : string option) = Server_runtime_bootstrap.configure_agent_core_model_catalog_env () in
      Runtime.load_config_observation
        ~runtime_config_path:(Config_dir_resolver.absolute_path !config) ()
    with Env_config_core.Config_error detail -> Error detail in
  let* _ = Runtime.init_default_degraded_observation config_observation
    |> Result.map_error Runtime.strict_init_error_to_string in
  Prompt_registry.set_markdown_dir (Config_dir_resolver.absolute_path !prompts);
  Prompt_defaults.init ();
  let* requests =
    List.fold_right
      (fun run acc ->
         let* acc = acc in
         let* _, request =
           Prompt_registry.resolve_and_render_prompt_template "librarian"
             (Keeper_librarian_runtime.preflight_prompt_variables run.variables)
         in
         Ok ((run, request) :: acc))
      runs (Ok [])
  in
  let identity = Build_identity.current () in
  let nullable = function None -> `Null | Some value -> `String value in
  let observations = ref [] in
  let report () = `Assoc
    ["schema", `String "masc.librarian-preflight-replay.v1";
     "provenance", `String "recorded_runs";
     "binary_commit", nullable identity.binary_commit;
     "executable_sha256", nullable identity.executable_sha256;
     "prompt_mode", `String "candidate_directory_no_persisted_overrides";
     "config_revision", `String (Runtime.config_source_revision_to_string config_observation.source_revision);
     "memory_mutated", `Bool false; "range_consumed", `Bool false;
     "samples", `List (List.map (fun (run, request) ->
       `Assoc ["run", `String run.run; "keeper_id", `String run.keeper_id;
               "recorded", `String (recorded_key run);
               "recorded_current_memory_bytes",
               `Int (String.length (Option.value ~default:""
                 (List.assoc_opt Keeper_librarian.current_memory_variable run.variables)));
               "request_bytes", `Int (String.length request);
               "request_sha256", `String Digestif.SHA256.(to_hex (digest_string request));
               "observation", Option.fold ~none:`Null ~some:P.to_yojson
                 (List.assoc_opt run.run !observations)]) requests)] in
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    Eio_context.set_env env; Eio_context.set_switch sw;
    Eio_context.set_net env#net; Eio_context.set_clock env#clock;
    Eio_context.set_mono_clock env#mono_clock; Fs_compat.set_fs env#fs;
    Masc_http_client.with_scoped_pool ~sw ~env (fun () ->
      let encode () = Yojson.Safe.pretty_to_string (report ()) ^ "\n" in
      let* () = Eio.Path.with_open_dir Eio.Path.(env#fs / Filename.dirname output_path) (fun parent ->
        Fs_compat.create_capability_file_exclusive ~parent ~leaf:(Filename.basename output_path)
          ~permissions:0o600 (encode ()))
        |> Result.map_error Fs_compat.capability_write_error_to_string in
      let save run observation =
        observations := (run.run, observation) :: List.remove_assoc run.run !observations;
        Keeper_fs.save_bytes_durable_atomic output_path (encode ())
        |> Result.map_error Keeper_fs.durable_write_error_to_string in
      let rec loop = function
        | [] -> Ok ()
        | (run, request) :: rest ->
          let observation = P.assess ~clock:env#clock ~keeper_id:run.keeper_id ~eligible:true
            ~request:(fun () -> Ok request) () in
          let* () = save run observation in loop rest in
      let* () = loop requests in
      let pairs = List.map (fun (run, _) ->
        recorded_key run, outcome_key (List.assoc run.run !observations)) requests in
      let counts = List.sort_uniq compare pairs |> List.map (fun pair ->
        pair, List.length (List.filter (( = ) pair) pairs)) in
      print_endline (Yojson.Safe.to_string (`Assoc
        ["output_path", `String output_path;
         "replayed", `Int (List.length requests);
         "recorded_to_replayed", `List (List.map (fun ((recorded, replayed), count) ->
           `Assoc ["recorded", `String recorded; "replayed", `String replayed; "count", `Int count])
           counts)]));
      Ok 0)))

let () =
  let result = try run () with
    | Sys_error detail | Env_config_core.Config_error detail -> Error detail in
  match result with Ok code -> exit code | Error detail -> prerr_endline detail; exit 2
