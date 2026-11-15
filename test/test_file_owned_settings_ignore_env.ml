(* A setting the runtime file alone feeds never reads the process environment.

   The probe runs against every such registry row, so a row added later is
   covered without a line here. Each row is probed from a shell that exports
   nothing for its name. A candidate value that changes what the row's reader
   returns, while the name is not declared, proves the reader consults the
   environment. Once the loader has declared the names, the same environment
   value must change nothing, and the boot store must answer exactly as the
   environment did.

   What a value has to mean is judged where the file's text is validated, the
   check that saving, previewing, the deployment check and the boot load share:
   a value its row refuses is an issue under its runtime.toml key, and the load
   stores nothing from that file. *)
open Alcotest

module R = Keeper_runtime_setting_registry

let with_env = Masc_test_deps.with_process_env

let read (row : R.setting) =
  match R.effective_value row with
  | value -> Ok value
  | exception Env_config_core.Config_error message -> Error message
;;

(* Values of the row's own kind. Rows differ in range and in what a string may
   be, so there are several; the first that moves the reader is the probe. *)
let candidates (row : R.setting) =
  match row.value_kind with
  | R.Boolean -> [ "true"; "false" ]
  | R.Integer -> [ "1"; "7"; "100"; "5000"; "86400" ]
  | R.Float -> [ "0.5"; "7.5"; "100.5"; "5000.5" ]
  | R.String -> [ "probe-value"; "http://probe.invalid:1"; "none"; "brave" ]
;;

let file_owned_rows =
  List.filter (fun row -> not (R.reads_process_env row)) R.toml_settings
;;

(* These two readers take the boot store directly, never the environment, so
   no environment value can move them. *)
let store_only_names =
  [ "MASC_KEEPER_MICROVM_MEMORY"; "MASC_KEEPER_MICROVM_CPUS" ]
;;

let declare () =
  Config_boot_overrides.declare_file_owned R.file_owned_env_names
;;

(* [Some name] when the probe moved the reader, so the rule was checked. *)
let probe (row : R.setting) =
  with_env row.env_name None (fun () ->
    Config_boot_overrides.reset_for_tests ();
    let baseline = read row in
    let moves candidate =
      with_env row.env_name (Some candidate) (fun () -> read row <> baseline)
    in
    match List.find_opt moves (candidates row) with
    | None -> None
    | Some candidate ->
      let through_env = with_env row.env_name (Some candidate) (fun () -> read row) in
      declare ();
      with_env row.env_name (Some candidate) (fun () ->
        check bool (row.env_name ^ " ignores the process environment") true
          (read row = baseline));
      Config_boot_overrides.set row.env_name candidate;
      check bool (row.env_name ^ " reads the boot store as it read the environment")
        true (read row = through_env);
      Config_boot_overrides.reset_for_tests ();
      Some row.env_name)
;;

let test_the_environment_does_not_reach_a_file_owned_reader () =
  let probed = List.map (fun row -> row, probe row) file_owned_rows in
  Config_boot_overrides.reset_for_tests ();
  List.iter
    (fun ((row : R.setting), outcome) ->
       if Option.is_none outcome && not (List.mem row.env_name store_only_names)
       then
         failf
           "no candidate moved the reader of %s, so the rule was not checked for it: add a value of its kind"
           row.env_name)
    probed;
  check bool "the probe moved at least one reader" true
    (List.exists (fun (_, outcome) -> Option.is_some outcome) probed)
;;

let with_empty_base_path f =
  let base_path = Filename.temp_dir "masc-file-owned" "" in
  with_env "MASC_CONFIG_DIR" None (fun () ->
    Fun.protect
      ~finally:(fun () -> try Unix.rmdir base_path with Unix.Unix_error _ -> ())
      (fun () -> f base_path))
;;

let test_the_loader_declares_the_file_owned_names () =
  Config_boot_overrides.reset_for_tests ();
  with_empty_base_path (fun base_path ->
    (match Keeper_runtime_config.load_and_apply ~base_path with
     | Ok count -> check int "no runtime.toml, no override" 0 count
     | Error error -> fail (Keeper_runtime_config.load_failure_to_string error));
    check bool "the registry has file-owned rows" true (file_owned_rows <> []);
    List.iter
      (fun (row : R.setting) ->
         check bool (row.env_name ^ " is declared") true
           (Config_boot_overrides.is_file_owned row.env_name))
      file_owned_rows;
    List.iter
      (fun (row : R.setting) ->
         if R.reads_process_env row
         then
           check bool (row.env_name ^ " is not declared") false
             (Config_boot_overrides.is_file_owned row.env_name))
      R.all);
  Config_boot_overrides.reset_for_tests ()
;;

(* A base path whose runtime.toml holds [content]. *)
let with_runtime_toml content f =
  let base_path = Filename.temp_dir "masc-file-owned" "" in
  let masc_dir = Filename.concat base_path ".masc" in
  let config_dir = Filename.concat masc_dir "config" in
  let path = Filename.concat config_dir Config_dir_resolver.runtime_toml_filename in
  Unix.mkdir masc_dir 0o755;
  Unix.mkdir config_dir 0o755;
  let channel = open_out_bin path in
  output_string channel content;
  close_out channel;
  with_env "MASC_CONFIG_DIR" None (fun () ->
    Fun.protect
      ~finally:(fun () ->
        List.iter
          (fun remove -> try remove () with Sys_error _ | Unix.Unix_error _ -> ())
          [ (fun () -> Sys.remove path)
          ; (fun () -> Unix.rmdir config_dir)
          ; (fun () -> Unix.rmdir masc_dir)
          ; (fun () -> Unix.rmdir base_path)
          ])
      (fun () -> f base_path))
;;

(* A [turn] value outside the declared range, so the load fails in validation. *)
let out_of_range_runtime_toml = "[turn]\nstream_idle_timeout_sec = 0\n"

let test_a_load_that_fails_declares_nothing () =
  Config_boot_overrides.reset_for_tests ();
  with_runtime_toml out_of_range_runtime_toml (fun base_path ->
    (match Keeper_runtime_config.load_and_apply ~base_path with
     | Ok _ -> fail "a runtime.toml with an out-of-range value was applied"
     | Error failure ->
       check bool "the load fails in validation" true
         (failure.Keeper_runtime_config.kind = Keeper_runtime_config.Validate));
    List.iter
      (fun (row : R.setting) ->
         check bool (row.env_name ^ " is not declared after a failed load") false
           (Config_boot_overrides.is_file_owned row.env_name))
      file_owned_rows);
  Config_boot_overrides.reset_for_tests ()
;;

let wake_prompt_name = "MASC_KEEPER_AUTONOMOUS_WAKE_PROMPT"
let max_bytes_name = "MASC_KEEPER_METRICS_MAX_BYTES"

let mentions ~affix text =
  let affix_length = String.length affix in
  let rec from index =
    index + affix_length <= String.length text
    && (String.equal (String.sub text index affix_length) affix || from (index + 1))
  in
  from 0
;;

(* Both keys have the type and range their rows declare. The wake prompt's row
   refuses a blank one, and [metrics.max_bytes] is in the same file. *)
let blank_wake_prompt_runtime_toml =
  "[metrics]\nmax_bytes = 4096\n\n[autonomous]\nwake_prompt = \"\"\n"
;;

let test_a_value_its_reader_rejects_fails_the_load () =
  Config_boot_overrides.reset_for_tests ();
  with_runtime_toml blank_wake_prompt_runtime_toml (fun base_path ->
    (match Keeper_runtime_config.load_and_apply ~base_path with
     | Ok _ -> fail "a blank wake prompt was applied"
     | Error failure ->
       check bool "the load fails in validation" true
         (failure.Keeper_runtime_config.kind = Keeper_runtime_config.Validate);
       check bool "the message names the runtime.toml key" true
         (mentions ~affix:"autonomous.wake_prompt" failure.Keeper_runtime_config.message));
    check (option string) "the rejected value is not left in the store" None
      (Config_boot_overrides.get_opt wake_prompt_name);
    check (option string) "a value stored before the rejection is not left either" None
      (Config_boot_overrides.get_opt max_bytes_name);
    check bool "the failed load declares nothing" false
      (Config_boot_overrides.is_file_owned wake_prompt_name));
  Config_boot_overrides.reset_for_tests ()
;;

let test_a_rejected_load_restores_what_the_store_held () =
  Config_boot_overrides.reset_for_tests ();
  Config_boot_overrides.set max_bytes_name "2048";
  with_runtime_toml blank_wake_prompt_runtime_toml (fun base_path ->
    (match Keeper_runtime_config.load_and_apply ~base_path with
     | Ok _ -> fail "a blank wake prompt was applied"
     | Error _ -> ());
    check (option string) "the earlier value is back" (Some "2048")
      (Config_boot_overrides.get_opt max_bytes_name);
    check (option string) "the rejected value is not left" None
      (Config_boot_overrides.get_opt wake_prompt_name));
  Config_boot_overrides.reset_for_tests ()
;;

(* One refused value per row that judges what its value means. The text check
   is the one the dashboard's save and preview, [masc config set] and the
   deployment check call, so a value refused here cannot be written and then
   stop the next boot. *)
let refused_meanings =
  [ "autonomous.wake_prompt", "[autonomous]\nwake_prompt = \"\"\n"
  ; ( "autonomous.wake_prompt"
    , Printf.sprintf
        "[autonomous]\nwake_prompt = \"%s\"\n"
        (String.make (Env_config_keeper.KeeperAutonomous.max_wake_prompt_bytes + 1) 'a') )
  ; "sandbox.microvm_memory", "[sandbox]\nmicrovm_memory = \"8\"\n"
  ; "sandbox.microvm_dns", "[sandbox]\nmicrovm_dns = \"127.0.0.1\"\n"
  ; "web_search.searxng_url", "[web_search]\nsearxng_url = \"ftp://search.example\"\n"
  ; ( "web_search.searxng_url"
    , "[web_search]\nsearxng_url = \"http://user:secret@search.example\"\n" )
  ]
;;

let test_the_text_check_refuses_a_value_its_row_rejects () =
  List.iter
    (fun (key, source) ->
       Config_boot_overrides.reset_for_tests ();
       (match Keeper_runtime_config.validate_source_text source with
        | Error detail -> failf "%s did not parse: %s" key detail
        | Ok report ->
          (match report.Keeper_runtime_config.issues with
           | [ issue ] ->
             check string "the issue is under the runtime.toml key" key
               issue.Keeper_runtime_config.key;
             check bool "the issue refuses the text" true
               (issue.Keeper_runtime_config.severity = Keeper_runtime_config.Error);
             check bool (key ^ ": the reason names no environment variable") false
               (mentions ~affix:"MASC_" issue.Keeper_runtime_config.detail)
           | issues -> failf "%s gave %d issues, not one" key (List.length issues)));
       with_runtime_toml source (fun base_path ->
         match Keeper_runtime_config.load_and_apply ~base_path with
         | Ok _ -> failf "%s was applied" key
         | Error failure ->
           check bool "the load names the same key" true
             (mentions ~affix:key failure.Keeper_runtime_config.message)))
    refused_meanings;
  Config_boot_overrides.reset_for_tests ()
;;

(* Blank is unset for the three rows that have a default to fall back to, and
   the text check agrees with their readers. *)
let test_the_text_check_accepts_what_the_rows_accept () =
  List.iter
    (fun source ->
       match Keeper_runtime_config.validate_source_text source with
       | Error detail -> failf "%S did not parse: %s" source detail
       | Ok report ->
         check bool (source ^ " is accepted") true
           (Keeper_runtime_config.validation_report_is_valid report))
    [ "[autonomous]\nwake_prompt = \"what changed?\"\n"
    ; "[sandbox]\nmicrovm_memory = \"8g\"\nmicrovm_dns = \"168.126.63.1\"\n"
    ; "[sandbox]\nmicrovm_memory = \"\"\nmicrovm_dns = \"\"\n"
    ; "[web_search]\nsearxng_url = \"https://search.example:8443/\"\n"
    ; "[web_search]\nsearxng_url = \"\"\n"
    ]
;;

let test_a_value_its_reader_accepts_stays_applied () =
  Config_boot_overrides.reset_for_tests ();
  with_runtime_toml
    "[metrics]\nmax_bytes = 4096\n\n[autonomous]\nwake_prompt = \"what changed?\"\n"
    (fun base_path ->
       (match Keeper_runtime_config.load_and_apply ~base_path with
        | Ok count -> check int "both keys are applied" 2 count
        | Error failure -> fail (Keeper_runtime_config.load_failure_to_string failure));
       check (option string) "the metrics value is in the store" (Some "4096")
         (Config_boot_overrides.get_opt max_bytes_name);
       check (option string) "the wake prompt is in the store" (Some "what changed?")
         (Config_boot_overrides.get_opt wake_prompt_name);
       check bool "the names stay declared" true
         (Config_boot_overrides.is_file_owned wake_prompt_name));
  Config_boot_overrides.reset_for_tests ()
;;

module Admission = Env_config_keeper.KeeperAdmissionBounds

let admission_key = "turn.admission_max_events"

let admission_runtime_toml value =
  Printf.sprintf "[turn]\nadmission_max_events = %d\n" value
;;

(* One row followed end to end, the turn admission bound. The registry names it
   under [turn], the file's value reaches the intake's reader past another
   value in the environment, and a change takes a restart. A row moved back to
   the environment, a renamed key, or a turn-boundary reload class fails here;
   the probe above skips a row that leaves the file-owned set. *)
let test_the_turn_admission_bound_comes_from_the_file () =
  Config_boot_overrides.reset_for_tests ();
  (match R.find_by_toml_key admission_key with
   | None -> failf "the registry has no row for %s" admission_key
   | Some row ->
     check string "the row is the admission bound's" Admission.max_events_env_key
       row.env_name;
     check bool "the file alone feeds the row" false (R.reads_process_env row);
     check bool "a change takes a restart" true (R.requires_restart row));
  with_env Admission.max_events_env_key (Some "9") (fun () ->
    with_runtime_toml (admission_runtime_toml 7) (fun base_path ->
      (match Keeper_runtime_config.load_and_apply ~base_path with
       | Ok count -> check int "the key is applied" 1 count
       | Error failure -> fail (Keeper_runtime_config.load_failure_to_string failure));
      check int "the reader returns the file's 7, not the environment's 9" 7
        (Admission.max_events ())));
  Config_boot_overrides.reset_for_tests ()
;;

(* The row's range is the reader's own floor and ceiling, so one step past
   either end is a value the load refuses instead of one the reader clamps.
   The validation report gives the reason as a value: the key is this row's
   and the value is out of its range. A key the registry does not know also
   fails the load, with another reason, so the load's failure alone would not
   tell a row that left the file from a value past the range. *)
let test_the_load_refuses_a_turn_admission_bound_outside_its_range () =
  List.iter
    (fun value ->
       Config_boot_overrides.reset_for_tests ();
       let source = admission_runtime_toml value in
       (match Keeper_runtime_config.validate_source_text source with
        | Error detail -> failf "%s = %d did not parse: %s" admission_key value detail
        | Ok report ->
          (match report.Keeper_runtime_config.issues with
           | [ issue ] ->
             check string "the issue is the admission key's" admission_key
               issue.Keeper_runtime_config.key;
             check bool "the value is out of the row's range" true
               (issue.Keeper_runtime_config.kind = Keeper_runtime_config.Out_of_range);
             check bool "the issue refuses the load" true
               (issue.Keeper_runtime_config.severity = Keeper_runtime_config.Error)
           | issues ->
             failf "%s = %d gave %d issues, not one" admission_key value
               (List.length issues)));
       with_runtime_toml source (fun base_path ->
         match Keeper_runtime_config.load_and_apply ~base_path with
         | Ok _ -> failf "%s = %d was applied" admission_key value
         | Error failure ->
           check bool "the load fails in validation" true
             (failure.Keeper_runtime_config.kind = Keeper_runtime_config.Validate)))
    [ Admission.max_events_floor - 1; Admission.max_events_ceiling + 1 ];
  Config_boot_overrides.reset_for_tests ()
;;

let test_a_declared_name_answers_from_the_file_only () =
  match file_owned_rows with
  | [] -> fail "the registry has no file-owned row"
  | row :: _ ->
    Config_boot_overrides.reset_for_tests ();
    declare ();
    with_env row.env_name (Some "from the shell") (fun () ->
      check (option string) "the shell's value is not read" None
        (Env_config_core.raw_value_opt row.env_name);
      check bool "the source is not the environment" true
        (Config_boot_overrides.source row.env_name = Config_boot_overrides.Default);
      Config_boot_overrides.set row.env_name "from the file";
      check (option string) "the file's value answers" (Some "from the file")
        (Env_config_core.raw_value_opt row.env_name);
      check bool "the source is the file" true
        (Config_boot_overrides.source row.env_name = Config_boot_overrides.Boot_override));
    Config_boot_overrides.reset_for_tests ()
;;

let test_a_name_that_is_not_declared_still_reads_the_environment () =
  Config_boot_overrides.reset_for_tests ();
  declare ();
  let name = "MASC_FILE_OWNED_PROBE_UNDECLARED" in
  with_env name (Some "from the shell") (fun () ->
    check (option string) "the environment answers" (Some "from the shell")
      (Env_config_core.raw_value_opt name));
  Config_boot_overrides.reset_for_tests ()
;;

let () =
  run
    "File_owned_settings_ignore_env"
    [ ( "file_owned"
      , [ test_case "the environment does not reach a file-owned reader" `Quick
            test_the_environment_does_not_reach_a_file_owned_reader
        ; test_case "the loader declares the file-owned names" `Quick
            test_the_loader_declares_the_file_owned_names
        ; test_case "a load that fails declares nothing" `Quick
            test_a_load_that_fails_declares_nothing
        ; test_case "a value its reader rejects fails the load" `Quick
            test_a_value_its_reader_rejects_fails_the_load
        ; test_case "a rejected load restores what the store held" `Quick
            test_a_rejected_load_restores_what_the_store_held
        ; test_case "the text check refuses a value its row rejects" `Quick
            test_the_text_check_refuses_a_value_its_row_rejects
        ; test_case "the text check accepts what the rows accept" `Quick
            test_the_text_check_accepts_what_the_rows_accept
        ; test_case "a value its reader accepts stays applied" `Quick
            test_a_value_its_reader_accepts_stays_applied
        ; test_case "the turn admission bound comes from the file" `Quick
            test_the_turn_admission_bound_comes_from_the_file
        ; test_case "the load refuses a turn admission bound outside its range" `Quick
            test_the_load_refuses_a_turn_admission_bound_outside_its_range
        ; test_case "a declared name answers from the file only" `Quick
            test_a_declared_name_answers_from_the_file_only
        ; test_case "a name that is not declared still reads the environment" `Quick
            test_a_name_that_is_not_declared_still_reads_the_environment
        ] )
    ]
;;
