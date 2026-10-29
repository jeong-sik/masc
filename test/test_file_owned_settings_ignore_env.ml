(* A setting the runtime file alone feeds never reads the process environment.

   The probe runs against every such registry row, so a row added later is
   covered without a line here. Each row is first probed while its name is not
   declared: a candidate value that changes what the row's reader returns proves
   the reader consults the environment. The same candidate must then change
   nothing once the loader has declared the file-owned names. *)
open Alcotest

module R = Keeper_runtime_setting_registry

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () -> Unix.putenv name (Option.value previous ~default:""))
    f
;;

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

let declare () =
  Config_boot_overrides.declare_file_owned R.file_owned_env_names
;;

let test_the_environment_does_not_reach_a_file_owned_reader () =
  let informative = ref 0 in
  List.iter
    (fun (row : R.setting) ->
       Config_boot_overrides.reset_for_tests ();
       let baseline = read row in
       let probe =
         List.find_opt
           (fun candidate ->
              with_env row.env_name candidate (fun () -> read row <> baseline))
           (candidates row)
       in
       match probe with
       | None -> ()
       | Some candidate ->
         incr informative;
         declare ();
         with_env row.env_name candidate (fun () ->
           check bool (row.env_name ^ " ignores the process environment") true
             (read row = baseline)))
    file_owned_rows;
  Config_boot_overrides.reset_for_tests ();
  check bool "the probe moved at least one reader before the names were declared" true
    (!informative > 0)
;;

let with_empty_base_path f =
  let base_path = Filename.temp_dir "masc-file-owned" "" in
  with_env "MASC_CONFIG_DIR" "" (fun () ->
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
    with_env row.env_name "from the shell" (fun () ->
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
  with_env "MASC_FILE_OWNED_PROBE_UNDECLARED" "from the shell" (fun () ->
    check (option string) "the environment answers" (Some "from the shell")
      (Env_config_core.raw_value_opt "MASC_FILE_OWNED_PROBE_UNDECLARED"));
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
