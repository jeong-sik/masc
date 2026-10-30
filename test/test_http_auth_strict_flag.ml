(** MASC_HTTP_AUTH_STRICT — the single reader the server enforces with.

    [Env_config.Transport.http_auth_strict_env_enabled] decides whether
    [Server_auth.ensure_strict_http_token_auth] demands workspace auth with
    require_token on every HTTP endpoint. Before the readers were unified it
    matched a case-sensitive spelling set of its own, so TRUE left auth
    non-strict, and a value supplied through the boot overrides was invisible
    to it entirely.

    These cases pin the reader on the spellings where it used to
    disagree with the rest of the system. *)

open Alcotest

let key = "MASC_HTTP_AUTH_STRICT"

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

let enabled () = Env_config.Transport.http_auth_strict_env_enabled ()

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

let expect_malformed_value_rejected ~source f =
  match f () with
  | _ -> failf "%s malformed value must be rejected" source
  | exception Env_config_core.Config_error message ->
      check string
        (source ^ " malformed error")
        (Printf.sprintf "malformed env %s=%S (expected bool)" key "y")
        message
;;

let test_malformed_boot_override_is_rejected () =
  with_boot_override "y" (fun () ->
    expect_malformed_value_rejected ~source:"boot override" enabled)
;;

let test_boot_override_enables_strict_auth () =
  with_boot_override "true" (fun () ->
    check bool "boot override true enforces strict auth" true (enabled ()))
;;

(* The enforcement reader was case-sensitive: TRUE left auth non-strict while
   the rest of the system reported it on. *)
let test_uppercase_true_enables_strict_auth () =
  with_env "TRUE" (fun () ->
    check bool "MASC_HTTP_AUTH_STRICT=TRUE enforces strict auth" true (enabled ()))
;;

let test_malformed_env_is_rejected () =
  with_env "y" (fun () ->
    expect_malformed_value_rejected ~source:"process env" enabled)
;;

let test_canonical_spellings_enable_strict_auth () =
  List.iter
    (fun spelling ->
      with_env spelling (fun () ->
        check bool (Printf.sprintf "%S enforces strict auth" spelling) true
          (enabled ())))
    [ "true"; "1"; "yes"; "on" ]
;;

let test_falsey_spellings_leave_auth_unchanged () =
  List.iter
    (fun spelling ->
      with_env spelling (fun () ->
        check bool (Printf.sprintf "%S leaves auth non-strict" spelling) false
          (enabled ())))
    [ "false"; "0"; "no"; "off" ]
;;

(* An empty value counts as unset and falls to the reader's default, false. *)
let test_absent_defaults_to_false () =
  with_env "" (fun () ->
    check bool "absent leaves auth non-strict" false (enabled ()))
;;

let () =
  Alcotest.run
    "HTTP auth strict flag"
    [ ( "reader behavior"
      , [ test_case "malformed boot override rejected" `Quick
            test_malformed_boot_override_is_rejected
        ; test_case "boot override enables" `Quick
            test_boot_override_enables_strict_auth
        ; test_case "uppercase TRUE enforces" `Quick
            test_uppercase_true_enables_strict_auth
        ; test_case "absent defaults to false" `Quick
            test_absent_defaults_to_false
        ] )
    ; ( "spellings"
      , [ test_case "canonical true spellings enforce" `Quick
            test_canonical_spellings_enable_strict_auth
        ; test_case "false spellings do not" `Quick
            test_falsey_spellings_leave_auth_unchanged
        ; test_case "malformed process env rejected" `Quick
            test_malformed_env_is_rejected
        ] )
    ]
;;
