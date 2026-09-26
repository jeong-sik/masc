open Alcotest
open Masc

let runtime_with_skills =
  {|[skills]
resource-read-max-bytes = 16384

[[skills.sources]]
id = "project"
anchor = "base-path"
path = ".agents/skills"
access = "read-only"

[providers.local]
protocol = "ollama-http"
endpoint = "http://127.0.0.1:11434"

[models.sample]
api-name = "sample"
max-context = 1024

[local.sample]

[runtime]
default = "local.sample"
|}
;;

let test_skills_namespace_is_not_a_provider () =
  match Runtime_toml.parse_string runtime_with_skills with
  | Error errors ->
    fail
      (String.concat
         "; "
         (List.map
            (fun (error : Runtime_toml.parse_error) ->
               error.path ^ ": " ^ error.message)
            errors))
  | Ok config ->
    check int "one provider" 1 (List.length config.Runtime_schema.providers);
    check int "one binding" 1 (List.length config.Runtime_schema.bindings)
;;

let test_runtime_save_precondition_rejects_skill_config () =
  let malformed =
    runtime_with_skills
    ^ "\n[[skills.sources]]\nid = \"broken\"\nanchor = \"base-path\"\npath = \"../escape\"\naccess = \"read-only\"\n"
  in
  match
    Runtime.validate_config_text
      ~runtime_config_path:"/tmp/runtime.toml"
      malformed
  with
  | Ok () -> fail "runtime save precondition accepted malformed Skill source"
  | Error detail ->
    check bool
      "Skill path diagnostic"
      true
      (String_util.contains_substring detail "skills.sources[1].path")
;;

let rec repo_root_from dir =
  if Sys.file_exists (Filename.concat dir "dune-project")
  then dir
  else (
    let parent = Filename.dirname dir in
    if String.equal parent dir
    then fail "could not locate repository root"
    else repo_root_from parent)
;;

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))
;;

let over_bound_text =
  {|[skills]
resource-read-max-bytes = 65536

[[skills.sources]]
id = "project"
anchor = "base-path"
path = ".agents/skills"
access = "read-only"

[providers.local]
protocol = "ollama-http"
endpoint = "http://127.0.0.1:11434"

[models.sample]
api-name = "sample"
max-context = 1024

[local.sample]

[runtime]
default = "local.sample"
|}
;;

(* #39269 (d): the shipped seed, read as is, passes the same precondition a
   runtime config save runs. #39040 tightened the bound and the seed together;
   this pins that they stay together. *)
let test_seed_passes_save_precondition () =
  let root = repo_root_from (Sys.getcwd ()) in
  let path = Filename.concat root "config/runtime.toml" in
  match Runtime.validate_config_text ~runtime_config_path:path (read_file path) with
  | Ok () -> ()
  | Error detail -> fail ("seed config/runtime.toml refused by save precondition: " ^ detail)
;;

(* #39269 (b): the 400 a save returns names the key and the file first, so a
   one-line surface that cuts the tail still says what to fix. *)
let test_over_bound_save_names_key_and_file () =
  match
    Runtime.validate_config_text
      ~runtime_config_path:"/tmp/live/runtime.toml"
      over_bound_text
  with
  | Ok () -> fail "save precondition accepted a bound over the inline boundary"
  | Error detail ->
    check bool "names the key and value" true
      (String_util.contains_substring detail "[skills] resource-read-max-bytes = 65536");
    check bool "names the fix" true
      (String_util.contains_substring
         detail
         (Printf.sprintf "set it to %d or less" Common.max_tool_result_wire_bytes));
    check bool "names the file" true
      (String_util.contains_substring detail "(file: /tmp/live/runtime.toml)")
;;

let with_workspace_dir prefix f =
  let base_path = Filename.temp_file prefix "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  Fun.protect ~finally:(fun () -> Unix.rmdir base_path) (fun () -> f base_path)
;;

(* The Server lines one publication wrote that name [path], oldest first, read
   from the in-memory ring the dashboard log API serves. *)
let logged_by ~path publish =
  let since_seq =
    match Log.Ring.recent ~limit:1 () with
    | [] -> -1
    | entry :: _ -> entry.Log.Ring.seq
  in
  (match publish () with
   | Skill_catalog_snapshot_service.Published _ -> ()
   | Unchanged _ | Workspace_retired -> fail "fixture config was not published");
  Log.Ring.recent ~since_seq ~order:`Oldest_first ~module_filter:"Server" ()
  |> List.filter (fun (entry : Log.Ring.entry) ->
    String_util.contains_substring entry.message ("(file: " ^ path ^ ")"))
;;

let refresh ~base_path ~path text () =
  match
    Server_skill_snapshot_runtime.refresh_from_observation
      ~base_path
      (Runtime.config_observation ~path text)
  with
  | Ok publication -> publication
  | Error error -> fail (Server_skill_snapshot_runtime.error_to_string error)
;;

let levels entries =
  List.map (fun (entry : Log.Ring.entry) -> Log.level_to_string entry.level) entries
;;

(* #39269 (a): a [skills] table the boot cannot accept is a WARN with the
   reason and the file, not a bare diagnostic count. Boot's is the first
   publication, and the publication logs it. *)
let test_boot_warns_with_reason_and_file () =
  with_workspace_dir "skill-boot-" @@ fun base_path ->
  let path = Filename.concat base_path "runtime.toml" in
  match logged_by ~path (refresh ~base_path ~path over_bound_text) with
  | [ entry ] ->
    check string "a rejected first publication warns" "WARN" (Log.level_to_string entry.level);
    check bool "reason in WARN" true
      (String_util.contains_substring entry.message "[skills] resource-read-max-bytes = 65536")
  | entries -> fail (Printf.sprintf "a rejected boot wrote %d lines" (List.length entries))
;;

(* #39269: every publisher reaches the one publish point -- boot, a runtime
   config save, and the Skill refresh route, the Skill editor and Keeper Skill
   publication, which reread runtime.toml from disk. A hand edit the runtime
   config API never saw can empty the catalog after boot, and the line that
   says it ended is what an outage is measured by. Each change of config state
   is logged once; a publication that keeps the state logs nothing. *)
let test_publication_logs_each_config_state_change_once () =
  with_workspace_dir "skill-reread-" @@ fun base_path ->
  let path = Filename.concat base_path "runtime.toml" in
  let publish text = levels (logged_by ~path (refresh ~base_path ~path text)) in
  check (list string) "the first publication says the catalog is ready" [ "INFO" ]
    (publish runtime_with_skills);
  check (list string) "a reread rejection warns once" [ "WARN" ] (publish over_bound_text);
  check (list string) "a rejected reread that stays rejected writes nothing" []
    (publish ("# edited\n" ^ over_bound_text));
  check (list string) "configuring the catalog again is logged once" [ "INFO" ]
    (publish runtime_with_skills)
;;

(* The unreadable arm: nothing Skills can use was read, so every Keeper's
   catalog is empty, and the line names the detail and the file. *)
let test_unreadable_publication_is_an_error () =
  with_workspace_dir "skill-unreadable-" @@ fun base_path ->
  let path = Filename.concat base_path "runtime.toml" in
  let detail = "fixture read failed" in
  let workspace =
    match Skill_catalog_snapshot_service.workspace_of_base_path ~base_path with
    | Ok workspace -> workspace
    | Error _ -> fail "fixture workspace was rejected"
  in
  let unreadable () =
    Skill_catalog_snapshot_service.refresh
      ~workspace
      ~user_home:None
      ~read_config:(fun () -> Skill_catalog_snapshot_service.Config_unreadable { path; detail })
  in
  (match logged_by ~path unreadable with
   | [ entry ] ->
     check string "an unreadable configuration is an error" "ERROR"
       (Log.level_to_string entry.level);
     check bool "the error names the detail" true
       (String_util.contains_substring entry.message detail)
   | entries -> fail (Printf.sprintf "an unreadable publication wrote %d lines" (List.length entries)));
  check (list string) "a readable configuration after it is logged once" [ "INFO" ]
    (levels (logged_by ~path (refresh ~base_path ~path runtime_with_skills)))
;;

let () =
  run
    "skill_source_runtime_integration"
    [ ( "runtime"
      , [ test_case "skills namespace is reserved" `Quick
            test_skills_namespace_is_not_a_provider
        ; test_case "save validates Skill sources" `Quick
            test_runtime_save_precondition_rejects_skill_config
        ; test_case "seed passes save precondition" `Quick
            test_seed_passes_save_precondition
        ; test_case "over-bound save names key and file" `Quick
            test_over_bound_save_names_key_and_file
        ; test_case "boot warns with reason and file" `Quick
            test_boot_warns_with_reason_and_file
        ; test_case "publication logs each config state change once" `Quick
            test_publication_logs_each_config_state_change_once
        ; test_case "unreadable publication is an error" `Quick
            test_unreadable_publication_is_an_error
        ] )
    ]
;;
