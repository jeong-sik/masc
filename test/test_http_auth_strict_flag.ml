(** The flag the operator sees and the flag the server enforces.

    MASC_HTTP_AUTH_STRICT is registered in {!Feature_flag_registry}, which is
    what the flag listing reports, and it decides whether
    [Server_auth.ensure_strict_http_token_auth] demands workspace auth with
    require_token on every HTTP endpoint.

    Those were two different readers. The enforcement side called
    [Sys.getenv_opt] and matched a case-sensitive spelling set of its own, so
    the listing could say the flag was on while the server let unauthenticated
    requests through -- and a value supplied through the boot overrides the
    registry consults was invisible to it entirely.

    These cases pin the two together on the spellings where they used to
    disagree. *)

open Alcotest

module Flag = Feature_flag_registry

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

let enforced () = Env_config.Transport.http_auth_strict_env_enabled ()
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
    expect_malformed_value_rejected ~source:"boot override" enforced)
;;

let test_listing_and_enforcement_agree () =
  List.iter
    (fun spelling ->
      with_env spelling (fun () ->
        check bool
          (Printf.sprintf "%s=%S: listing and enforcement agree" key spelling)
          (listed ())
          (enforced ())))
    [ "true"; "TRUE"; "True"; "1"; "yes"; "on"; "ON"; "false"; "0"; "off"; "" ]
;;

(* The enforcement reader was case-sensitive: TRUE left auth non-strict while
   the listing reported it on. *)
let test_uppercase_true_enables_strict_auth () =
  with_env "TRUE" (fun () ->
    check bool "MASC_HTTP_AUTH_STRICT=TRUE enforces strict auth" true (enforced ()))
;;

let test_malformed_env_is_rejected () =
  with_env "y" (fun () ->
    expect_malformed_value_rejected ~source:"process env" enforced)
;;

let test_canonical_spellings_enable_strict_auth () =
  List.iter
    (fun spelling ->
      with_env spelling (fun () ->
        check bool (Printf.sprintf "%S enforces strict auth" spelling) true
          (enforced ())))
    [ "true"; "1"; "yes"; "on" ]
;;

let test_falsey_spellings_leave_auth_unchanged () =
  List.iter
    (fun spelling ->
      with_env spelling (fun () ->
        check bool (Printf.sprintf "%S leaves auth non-strict" spelling) false
          (enforced ())))
    [ "false"; "0"; "no"; "off" ]
;;

(* An absent variable falls to the registry's declared default, which is the
   value the listing shows when nothing is set. *)
let test_absent_uses_the_registry_default () =
  with_env "" (fun () ->
    check bool "absent matches the listing" (listed ()) (enforced ()))
;;

let () =
  Alcotest.run
    "HTTP auth strict flag"
    [ ( "listing vs enforcement"
      , [ test_case "malformed boot override rejected" `Quick
            test_malformed_boot_override_is_rejected
        ; test_case "agree on every spelling" `Quick
            test_listing_and_enforcement_agree
        ; test_case "uppercase TRUE enforces" `Quick
            test_uppercase_true_enables_strict_auth
        ; test_case "absent uses the registry default" `Quick
            test_absent_uses_the_registry_default
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
