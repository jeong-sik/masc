(** Explicit synthetic false-no-change evaluation. No Memory mutation or
    range consumption occurs; received answers use the production preflight. *)
open Masc
module P = Typesafeai_librarian_preflight
module M = Keeper_memory_os_types
let ( let* ) = Result.bind
let ( let+ ) result f = Result.map f result

type expectation = Must_generate | May_keep
type case = { id : string; expectation : expectation; current : M.fact list; messages : string list }
type classification = False_no_change | Required_generation_preserved | No_change_control | Unnecessary_generation | Not_measured
let classification_name = function
  | False_no_change -> "false_no_change"
  | Required_generation_preserved -> "required_generation_preserved"
  | No_change_control -> "no_change_control"
  | Unnecessary_generation -> "unnecessary_generation"
  | Not_measured -> "not_measured"

let strings = function
  | `List values ->
    let rec loop = function
      | [] -> Ok []
      | `String text :: rest when String.trim text <> "" -> let+ rest = loop rest in text :: rest
      | _ -> Error "messages must contain nonblank strings" in
    loop values
  | _ -> Error "messages must be an array"

let parse_case ~fact_observed_at json =
  let* id = Tui_decode_fields.required_string_field json "id" in
  let* () = if String.trim id = "" then Error "blank case ID" else Ok () in
  let* expected = Tui_decode_fields.required_string_field json "expectation" in
  let* expectation = match expected with
    | "must_generate" -> Ok Must_generate | "may_keep" -> Ok May_keep
    | _ -> Error "unknown case expectation" in
  let* current = Tui_decode_fields.required_list_field json "current" in
  let rec facts = function
    | [] -> Ok []
    | json :: rest ->
      let* claim = Tui_decode_fields.required_string_field json "claim" in
      let* () = if String.trim claim = "" then Error "blank claim" else Ok () in
      let* category = Tui_decode_fields.required_string_field json "category" in
      let* category = match M.category_of_string category with Some category -> Ok category | None -> Error "invalid category" in
      let fact = M.observed ~claim ~category ~now:fact_observed_at
        ~origin:{M.kind=M.Authored; trace_id=id} in
      let+ rest = facts rest in fact :: rest in
  let* current = facts current in
  let* raw = Tui_decode_fields.required_member json "messages" in
  let* messages = strings raw in
  let* () = if messages = [] then Error "empty source" else Ok () in
  Ok {id;expectation;current;messages}

let parse_dataset ~fact_observed_at json =
  let* provenance = Tui_decode_fields.required_string_field json "provenance" in
  let* () = if provenance = "synthetic" then Ok () else Error "only explicit synthetic cases are accepted" in
  let* values = Tui_decode_fields.required_list_field json "cases" in
  let rec loop seen = function
    | [] -> Ok []
    | json :: rest ->
      let* case = parse_case ~fact_observed_at json in
      let* () = if List.mem case.id seen then Error "duplicate case ID" else Ok () in
      let+ rest = loop (case.id :: seen) rest in case :: rest in
  let* cases = loop [] values in
  if cases = [] then Error "empty dataset" else Ok cases

let classify expectation observation = match observation.P.outcome with
  | P.Judged (_, judgment) ->
    (match expectation, judgment.choice with
     | Must_generate, P.Keep_current -> False_no_change
     | Must_generate, (P.Needs_generation | P.Uncertain) -> Required_generation_preserved
     | May_keep, P.Keep_current -> No_change_control
     | May_keep, (P.Needs_generation | P.Uncertain) -> Unnecessary_generation)
  | P.Awaiting_answer | P.Skipped _ | P.Ineligible _ | P.Question_unavailable _
  | P.Failed _ | P.Invalid_answer _ -> Not_measured

let run () =
  let input = ref "" and output = ref "" and config = ref "" and prompts = ref "" and keeper = ref "" in
  Arg.parse
    ["--input", Arg.Set_string input, "Synthetic corpus JSON";
     "--output", Arg.Set_string output, "New private report file";
     "--config", Arg.Set_string config, "Explicit runtime TOML (preflight opt-in required)";
     "--prompt-dir", Arg.Set_string prompts, "Candidate config/prompts directory; persisted overrides are not loaded";
     "--keeper", Arg.Set_string keeper, "Keeper identity whose configured exclusion applies"]
    (fun value -> raise (Arg.Bad ("unexpected argument " ^ value)))
    "masc-librarian-preflight-eval --input FILE --output FILE --config FILE --prompt-dir DIR --keeper NAME";
  let* () = if List.exists (fun value -> String.trim !value = "") [input;output;config;prompts;keeper]
    then Error "all five options are required" else Ok () in
  let* keeper_identity = match Keeper_identity.Keeper_id.of_string !keeper with
    | Some identity -> Ok identity | None -> Error "invalid keeper identity" in
  let keeper_id = Keeper_identity.Keeper_id.to_string keeper_identity in
  let input_path = Config_dir_resolver.absolute_path !input in
  let output_path = Config_dir_resolver.absolute_path !output in
  let* () = match Fs_compat.exact_path_kind ~follow:false output_path with
    | Fs_compat.Exact_missing -> Ok () | _ -> Error "output must be a new file" in
  (* Equal, recent fact ages avoid making a refresh look like a semantic win. *)
  let fact_observed_at = Time_compat.now () in
  let keeper_instructions = "" in
  let* bytes, cases = try
    let bytes = In_channel.with_open_bin input_path In_channel.input_all in
    let+ cases = parse_dataset ~fact_observed_at (Yojson.Safe.from_string bytes) in bytes, cases
    with Sys_error detail | Yojson.Json_error detail -> Error detail in
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
  let rec prepare = function
    | [] -> Ok []
    | case :: rest ->
      let inp : Keeper_librarian.input =
        {turn_ref=Ids.Turn_ref.make ~trace_id:case.id ~absolute_turn:1;
         keeper_id=keeper_identity; keeper_instructions;
         current=Some {Keeper_librarian.facts=case.current};
         working_context=Keeper_librarian_context.empty;
         messages=List.map (fun text -> Agent_core.Types.make_message
           ~metadata:(Keeper_input_speaker.metadata (Keeper_input_speaker.Person Keeper_input_speaker.Owner))
           ~role:Agent_core.Types.User [Agent_core.Types.Text text]) case.messages;
         historical_task_contexts=[]; goal_context=Keeper_librarian.No_task;
         tool_observations=[]; counterpart_observations=[]} in
      let* variables = Keeper_librarian_runtime.librarian_prompt_variables inp in
      let* _, prompt = Prompt_registry.resolve_and_render_prompt_template "librarian" variables in
      let+ rest = prepare rest in (case, prompt) :: rest in
  let* requests = prepare cases in
  let identity = Build_identity.current () in
  let nullable = function None -> `Null | Some value -> `String value in
  let observations = ref [] in
  let report () = `Assoc
    ["schema", `String "masc.librarian-preflight-adversarial.v1";
     "provenance", `String "synthetic";
     "binary_commit", nullable identity.binary_commit;
     "executable_sha256", nullable identity.executable_sha256;
     "input_sha256", `String Digestif.SHA256.(to_hex (digest_string bytes));
     "fact_observed_at", `Float fact_observed_at;
     "keeper_instructions", `String keeper_instructions;
     "prompt_mode", `String "candidate_directory_no_persisted_overrides";
     "config_revision", `String (Runtime.config_source_revision_to_string config_observation.source_revision);
     "memory_mutated", `Bool false; "range_consumed", `Bool false;
     "goal_completion", `String "not_established";
     "samples", `List (List.map (fun (case, prompt) ->
       let observation = List.assoc_opt case.id !observations in
       `Assoc ["id", `String case.id;
               "expectation", `String (match case.expectation with Must_generate -> "must_generate" | May_keep -> "may_keep");
               "rendered_prompt", `String prompt;
               "classification", `String (classification_name (Option.fold ~none:Not_measured ~some:(classify case.expectation) observation));
               "observation", Option.fold ~none:`Null ~some:P.to_yojson observation]) requests)] in
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
      let save id observation =
        observations := (id, observation) :: List.remove_assoc id !observations;
        Keeper_fs.save_bytes_durable_atomic output_path (encode ())
        |> Result.map_error Keeper_fs.durable_write_error_to_string in
      let rec loop = function
        | [] -> Ok ()
        | (case, prompt) :: rest ->
          let observe observation = match save case.id observation with
            | Ok () -> () | Error detail -> raise (Sys_error detail) in
          let observation = P.assess ~observe ~clock:env#clock ~keeper_id ~eligible:true ~prompt () in
          let* () = save case.id observation in loop rest in
      let* () = loop requests in
      let classifications = List.map (fun (case, _) ->
        classify case.expectation (List.assoc case.id !observations)) requests in
      let count value = List.length (List.filter ((=) value) classifications) in
      print_endline (Yojson.Safe.to_string (`Assoc
        ["output_path", `String output_path;
         "false_no_change", `Int (count False_no_change);
         "not_measured", `Int (count Not_measured);
         "unnecessary_generation", `Int (count Unnecessary_generation);
         "quality_scope", `String "synthetic corpus only"]));
      Ok (if count False_no_change = 0 && count Not_measured = 0 then 0 else 1))))

let () =
  let result = try run () with
    | Sys_error detail | Env_config_core.Config_error detail -> Error detail in
  match result with Ok code -> exit code | Error detail -> prerr_endline detail; exit 2
