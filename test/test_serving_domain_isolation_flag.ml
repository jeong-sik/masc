(** Unit tests for MASC_SERVING_DOMAIN_ENABLED and
    Env_config.Transport.serving_domain_enabled (RFC-0204 Phase 3). *)

open Alcotest

module Flag = Feature_flag_registry

let key = "MASC_SERVING_DOMAIN_ENABLED"

let with_env value f =
  let saved = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match saved with
      | Some previous -> Unix.putenv key previous
      | None -> Unix.unsetenv key)
    f
;;

let enabled () = Env_config.Transport.serving_domain_enabled ()
let listed () = Flag.get_bool key

let with_boot_override value f =
  let saved_env = Sys.getenv_opt key in
  let saved_override = Config_boot_overrides.get_opt key in
  Unix.unsetenv key;
  Config_boot_overrides.set key value;
  Fun.protect
    ~finally:(fun () ->
      (match saved_override with
       | Some previous -> Config_boot_overrides.set key previous
       | None -> Config_boot_overrides.clear key);
      match saved_env with
      | Some previous -> Unix.putenv key previous
      | None -> Unix.unsetenv key)
    f
;;

let test_default_is_enabled () =
  let saved_env = Sys.getenv_opt key in
  Unix.unsetenv key;
  Fun.protect
    ~finally:(fun () ->
      match saved_env with
      | Some previous -> Unix.putenv key previous
      | None -> Unix.unsetenv key)
    (fun () ->
      check bool "default is enabled in Transport reader" true (enabled ());
      check bool "default is enabled in registry listing" true (listed ()))
;;

let test_env_disables_serving_domain () =
  List.iter
    (fun spelling ->
      with_env spelling (fun () ->
        check bool
          (Printf.sprintf "env %s disables serving domain" spelling)
          false
          (enabled ());
        check bool
          (Printf.sprintf "registry listing matches env %s" spelling)
          false
          (listed ())))
    [ "0"; "false"; "False"; "FALSE"; "no"; "off" ]
;;

let test_env_enables_serving_domain () =
  List.iter
    (fun spelling ->
      with_env spelling (fun () ->
        check bool
          (Printf.sprintf "env %s enables serving domain" spelling)
          true
          (enabled ());
        check bool
          (Printf.sprintf "registry listing matches env %s" spelling)
          true
          (listed ())))
    [ "1"; "true"; "True"; "TRUE"; "yes"; "on" ]
;;

let test_boot_override_controls_flag () =
  with_boot_override "0" (fun () ->
    check bool "boot override 0 disables" false (enabled ());
    check bool "boot override 0 listed as disabled" false (listed ()));
  with_boot_override "1" (fun () ->
    check bool "boot override 1 enables" true (enabled ());
    check bool "boot override 1 listed as enabled" true (listed ()))
;;

let () =
  run
    "serving_domain_isolation_flag"
    [ ( "serving_domain_flag"
      , [ test_case "default is enabled" `Quick test_default_is_enabled
        ; test_case "env disables serving domain" `Quick test_env_disables_serving_domain
        ; test_case "env enables serving domain" `Quick test_env_enables_serving_domain
        ; test_case "boot override controls flag" `Quick test_boot_override_controls_flag
        ] )
    ]
;;