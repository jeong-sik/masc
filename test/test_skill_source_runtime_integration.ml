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
  let root = repo_root_from (Sys.getcwd ()) in
  let seed = read_file (Filename.concat root "config/runtime.toml") in
  let rec add_legacy_key = function
    | [] -> fail "seed has no [skills] table"
    | "[skills]" :: rest ->
      "[skills]" :: "resource-read-max-bytes = 65536" :: rest
    | line :: rest -> line :: add_legacy_key rest
  in
  String.concat "\n" (add_legacy_key (String.split_on_char '\n' seed))
;;

(* #39269 (d): the shipped seed, read as is, passes the same precondition a
   runtime config save runs. *)
let test_seed_passes_save_precondition () =
  let root = repo_root_from (Sys.getcwd ()) in
  let path = Filename.concat root "config/runtime.toml" in
  match Runtime.validate_config_text ~runtime_config_path:path (read_file path) with
  | Ok () -> ()
  | Error detail -> fail ("seed config/runtime.toml refused by save precondition: " ^ detail)
;;

(* A [skills] table the save and the boot refuse for a reason that stays:
   a non-table [skills.sources]. *)
let rejected_text =
  {|[skills]
sources = "lots"

[runtime]
default = "local.sample"
|}
;;

(* #39269 (b): the 400 a save returns names the key and the file, so a
   one-line surface that cuts the tail still says what to fix. *)
let test_rejected_save_names_key_and_file () =
  match
    Runtime.validate_config_text
      ~runtime_config_path:"/tmp/live/runtime.toml"
      rejected_text
  with
  | Ok () -> fail "save precondition accepted a non-table skills.sources"
  | Error detail ->
    check bool "names the key" true
      (String_util.contains_substring detail "skills.sources must be an array of tables");
    check bool "names the file" true
      (String_util.contains_substring detail "(file: /tmp/live/runtime.toml)")
;;

(* #39269 (a): a [skills] table the boot cannot accept is a WARN with the
   reason and the file, not a bare diagnostic count. *)
let test_boot_warns_with_reason_and_file () =
  let diagnostics =
    match Skill_source_config.parse_text rejected_text with
    | Ok _ -> fail "non-table skills.sources parsed"
    | Error diagnostics -> diagnostics
  in
  let snapshot =
    Skill_catalog_snapshot.config_rejected ~source_text:rejected_text ~diagnostics
  in
  match
    Server_skill_snapshot_runtime.boot_report
      ~runtime_config_path:"/tmp/live/runtime.toml"
      snapshot
  with
  | Server_skill_snapshot_runtime.Boot_warn, line ->
    check bool "reason in WARN" true
      (String_util.contains_substring line "skills.sources must be an array of tables");
    check bool "file in WARN" true
      (String_util.contains_substring line "/tmp/live/runtime.toml")
  | (Boot_info | Boot_error), line -> fail ("rejected Skill config was not a WARN: " ^ line)
;;

(* task-1779 B: a live runtime.toml that still sets the old bound saves, and
   the boot says once that the key is ignored and which file carries it. The
   seed has no such key and says nothing. *)
let test_legacy_bound_saves_and_warns_at_boot () =
  (match
     Runtime.validate_config_text
       ~runtime_config_path:"/tmp/live/runtime.toml"
       over_bound_text
   with
   | Ok () -> ()
   | Error detail -> fail ("legacy resource-read-max-bytes was refused: " ^ detail));
  (match
     Server_skill_snapshot_runtime.boot_notice
       ~runtime_config_path:"/tmp/live/runtime.toml"
       ~source_text:over_bound_text
   with
   | None -> fail "legacy resource-read-max-bytes produced no boot WARN"
   | Some line ->
     check bool "WARN names the ignored value" true
       (String_util.contains_substring
          line
          "[skills] resource-read-max-bytes = 65536 is ignored");
     check bool "WARN names the follow-up" true
       (String_util.contains_substring line "#39284");
     check bool "WARN names the file" true
       (String_util.contains_substring line "(file: /tmp/live/runtime.toml)"));
  let root = repo_root_from (Sys.getcwd ()) in
  let seed = Filename.concat root "config/runtime.toml" in
  check bool "seed has no ignored key" true
    (Option.is_none
       (Server_skill_snapshot_runtime.boot_notice
          ~runtime_config_path:seed
          ~source_text:(read_file seed)))
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
        ; test_case "rejected save names key and file" `Quick
            test_rejected_save_names_key_and_file
        ; test_case "boot warns with reason and file" `Quick
            test_boot_warns_with_reason_and_file
        ; test_case "legacy bound saves and warns at boot" `Quick
            test_legacy_bound_saves_and_warns_at_boot
        ] )
    ]
;;
