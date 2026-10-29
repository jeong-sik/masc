(* A setting the runtime file alone feeds never reads the process environment.

   The probe runs against every such registry row, so a row added later is
   covered without a line here. Each row is probed from a shell that exports
   nothing for its name. A candidate value that changes what the row's reader
   returns, while the name is not declared, proves the reader consults the
   environment. Once the loader has declared the names, the same environment
   value must change nothing, and the boot store must answer exactly as the
   environment did. *)
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
        ; test_case "a declared name answers from the file only" `Quick
            test_a_declared_name_answers_from_the_file_only
        ; test_case "a name that is not declared still reads the environment" `Quick
            test_a_name_that_is_not_declared_still_reads_the_environment
        ] )
    ]
;;
