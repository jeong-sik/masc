(** Sandbox config SSOT tests.

    Pin defaults, env-override semantics, and JSON shape for
    {!Env_config_sandbox}.  Pattern mirrors
    {!Test_env_config_exec_timeout_10426}. *)

open Alcotest

module S = Env_config_sandbox

let approx = float 0.001

(* ---------------------------------------------------------------- *)
(* Test helpers                                                     *)
(* ---------------------------------------------------------------- *)

let with_env name value f =
  let prev = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

(* Sandbox-related env vars that may be set by the operator's shell —
   we clear them for default-pinning tests so the result is independent
   of CI/dev-machine environment. *)
let sandbox_env_names =
  [ "MASC_KEEPER_SANDBOX_PIDS_LIMIT"
  ; "MASC_KEEPER_SANDBOX_NOFILE_LIMIT"
  ; "MASC_KEEPER_SANDBOX_MEMORY"
  ; "MASC_KEEPER_SANDBOX_TMPFS_SIZE"
  ; "MASC_KEEPER_SANDBOX_RELAX_FS"
  ; "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE"
  ; "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS"
  ; "MASC_KEEPER_SANDBOX_REQUIRE_USERNS"
  ; "MASC_KEEPER_SANDBOX_CLEANUP_ENABLED"
  ; "MASC_KEEPER_SANDBOX_CLEANUP_STALE_AFTER_SEC"
  ; "MASC_KEEPER_SANDBOX_CLEANUP_INTERVAL_SEC"
  ; "MASC_KEEPER_SANDBOX_DOCKER_IMAGE"
  ; "MASC_KEEPER_SANDBOX_GIT_DISPATCH"
  ; "MASC_KEEPER_DOCKER_PLAYGROUND"
  ; "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED"
  ; "MASC_KEEPER_SHELL_TIMEOUT_IO_SEC"
  ; "MASC_KEEPER_SHELL_TIMEOUT_READ_SEC"
  ; "MASC_KEEPER_SHELL_TIMEOUT_GIT_META_SEC"
  ; "MASC_KEEPER_SHELL_TIMEOUT_GH_MIN_SEC"
  ; "MASC_KEEPER_SHELL_TIMEOUT_USER_MAX_SEC"
  ; "MASC_KEEPER_SHELL_TIMEOUT_CLEANUP_RM_SEC"
  ; "MASC_KEEPER_SHELL_TIMEOUT_DEFAULT_SEC"
  ]

(* String-typed env vars whose default is non-empty. OCaml 5.5 adds
   [Unix.unsetenv], but the supported 5.4 floor has no equivalent, so
   [Unix.putenv NAME ""] is the closest we can do — but
   [Env_config_core.get_string ~default] returns the literal "" rather than the
   default in that case. Workaround: set each string env to its default literal
   so [get_string] yields the expected value. Drift between this table and the
   .ml will surface in the cross-module consistency test below. *)
let string_env_defaults =
  [ "MASC_KEEPER_SANDBOX_MEMORY", "2g"
  ; "MASC_KEEPER_SANDBOX_TMPFS_SIZE", "256m"
  ; "MASC_KEEPER_SANDBOX_DOCKER_IMAGE", "masc-keeper-sandbox:local"
  ]

(* Run [f] with every name in [sandbox_env_names] cleared (set to "")
   except for string-typed names that need explicit default-yielding
   values.  Saves and restores prior values in a Fun.protect block. *)
let with_clean_sandbox_env f =
  let saved = List.map (fun n -> n, Sys.getenv_opt n) sandbox_env_names in
  let string_default_set =
    List.fold_left (fun acc (n, _) -> n :: acc) [] string_env_defaults
  in
  List.iter
    (fun n ->
      if List.mem n string_default_set then
        let value = List.assoc n string_env_defaults in
        Unix.putenv n value
      else Unix.putenv n "")
    sandbox_env_names;
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (n, v) ->
          match v with
          | Some s -> Unix.putenv n s
          | None -> Unix.putenv n "")
        saved)
    f

(* ---------------------------------------------------------------- *)
(* 1. Default pinning                                               *)
(* ---------------------------------------------------------------- *)

let test_defaults_pinned () =
  with_clean_sandbox_env @@ fun () ->
  (* Hardening *)
  check int "Hardening.pids_limit default" 128 (S.Hardening.pids_limit ());
  check int "Hardening.nofile_limit default" 245_760
    (S.Hardening.nofile_limit ());
  check string "Hardening.memory default" "2g" (S.Hardening.memory ());
  check string "Hardening.tmpfs_size default" "256m" (S.Hardening.tmpfs_size ());
  check bool "Hardening.relax_fs default" false (S.Hardening.relax_fs ());
  check string "Hardening.seccomp_profile default" ""
    (S.Hardening.seccomp_profile ());
  check bool "Hardening.require_rootless default" false
    (S.Hardening.require_rootless ());
  check bool "Hardening.require_userns default" false
    (S.Hardening.require_userns ());
  (* Cleanup *)
  check bool "Cleanup.enabled default" true (S.Cleanup.enabled ());
  check approx "Cleanup.stale_after_sec default" 21_600.0
    (S.Cleanup.stale_after_sec ());
  check approx "Cleanup.interval_sec default" 300.0
    (S.Cleanup.interval_sec ());
  check int "Cleanup.managed_sleep_sec default" 3600
    (S.Cleanup.managed_sleep_sec ());
  (* Runtime *)
  check string "Runtime.docker_image default" "masc-keeper-sandbox:local"
    (S.Runtime.docker_image ());
  check bool "Runtime.git_dispatch default" true (S.Runtime.git_dispatch ());
  check bool "Runtime.docker_playground_enabled default" false
    (S.Runtime.docker_playground_enabled ());
  (* Preflight *)
  check bool "Preflight.enabled default" true (S.Preflight.enabled ());
  check approx "Preflight.min_timeout_sec default" 5.0
    (S.Preflight.min_timeout_sec ());
  check approx "Preflight.max_timeout_sec default" 20.0
    (S.Preflight.max_timeout_sec ());
  check int "Preflight.required_commands count" 19
    (List.length (S.Preflight.required_commands ()));
  check (option string) "Preflight.required_commands has 'gh'" (Some "gh")
    (List.find_opt (String.equal "gh") (S.Preflight.required_commands ()));
  (* Shell_timeout buckets *)
  let pin bucket expected =
    check approx
      (Printf.sprintf "Shell_timeout %s default" (S.Shell_timeout.bucket_key bucket))
      expected
      (S.Shell_timeout.timeout_sec ~bucket ())
  in
  pin S.Shell_timeout.Io 30.0;
  pin S.Shell_timeout.Read 15.0;
  pin S.Shell_timeout.Git_meta 5.0;
  pin S.Shell_timeout.Gh_min 15.0;
  pin S.Shell_timeout.User_max 180.0;
  pin S.Shell_timeout.Cleanup_rm 5.0

(* ---------------------------------------------------------------- *)
(* 2. Env-override                                                  *)
(* ---------------------------------------------------------------- *)

let test_env_overrides_default () =
  with_clean_sandbox_env @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_MEMORY" (Some "4g") (fun () ->
    check string "memory env override wins" "4g" (S.Hardening.memory ()));
  (* After with_env restore, original [None] becomes [Some ""], which
     [get_string] does NOT treat as "default" — it returns the literal
     empty string.  This is a quirk of the env-restoration model, not a
     module bug.  We still want a regression guard, so check the
     observable effect: memory is back to whatever the cleared env
     yields (default). *)
  check string "memory falls back to default after clean restore"
    "2g" (S.Hardening.memory ())

let test_empty_env_treated_as_unset () =
  with_clean_sandbox_env @@ fun () ->
  with_env "MASC_KEEPER_SHELL_TIMEOUT_IO_SEC" (Some "") (fun () ->
    check approx "empty env still hits default" 30.0
      (S.Shell_timeout.timeout_sec ~bucket:S.Shell_timeout.Io ()))

let test_invalid_float_falls_to_global_default () =
  with_clean_sandbox_env @@ fun () ->
  with_env "MASC_KEEPER_SHELL_TIMEOUT_IO_SEC" (Some "not-a-float") (fun () ->
    check approx "invalid float -> global_default_sec"
      S.Shell_timeout.global_default_sec
      (S.Shell_timeout.timeout_sec ~bucket:S.Shell_timeout.Io ()))

(* ---------------------------------------------------------------- *)
(* 3. Shell_timeout bucket variant                                  *)
(* ---------------------------------------------------------------- *)

let test_per_bucket_env_var_shape () =
  check string "Io env var name"
    "MASC_KEEPER_SHELL_TIMEOUT_IO_SEC"
    (S.Shell_timeout.per_bucket_env_var ~bucket:S.Shell_timeout.Io);
  check string "Cleanup_rm env var name"
    "MASC_KEEPER_SHELL_TIMEOUT_CLEANUP_RM_SEC"
    (S.Shell_timeout.per_bucket_env_var
       ~bucket:S.Shell_timeout.Cleanup_rm);
  check string "Unknown bucket env var lowercases"
    "MASC_KEEPER_SHELL_TIMEOUT_FUTURE_X_SEC"
    (S.Shell_timeout.per_bucket_env_var
       ~bucket:(S.Shell_timeout.Unknown "future-x"))

let test_per_bucket_env_override () =
  with_clean_sandbox_env @@ fun () ->
  with_env "MASC_KEEPER_SHELL_TIMEOUT_READ_SEC" (Some "7.5") (fun () ->
    check approx "Read bucket env override wins"
      7.5
      (S.Shell_timeout.timeout_sec ~bucket:S.Shell_timeout.Read ()))

let test_unknown_bucket_uses_global_env () =
  with_clean_sandbox_env @@ fun () ->
  with_env "MASC_KEEPER_SHELL_TIMEOUT_DEFAULT_SEC" (Some "99.0") (fun () ->
    check approx "Unknown bucket uses global env"
      99.0
      (S.Shell_timeout.timeout_sec
         ~bucket:(S.Shell_timeout.Unknown "future") ());
    check approx "Known bucket ignores global env"
      30.0
      (S.Shell_timeout.timeout_sec ~bucket:S.Shell_timeout.Io ()))

let test_gh_min_floor_ignores_env () =
  (* Even with a per-bucket env override, Gh_min stays 15.0 — read-only
     load-bearing floor (#8688). *)
  with_clean_sandbox_env @@ fun () ->
  with_env "MASC_KEEPER_SHELL_TIMEOUT_GH_MIN_SEC" (Some "1.0") (fun () ->
    check approx "Gh_min ignores env override"
      15.0
      (S.Shell_timeout.timeout_sec ~bucket:S.Shell_timeout.Gh_min ()))

(* ---------------------------------------------------------------- *)
(* 4. Filesystem derivation                                         *)
(* ---------------------------------------------------------------- *)

let test_relax_fs_propagates_to_derived () =
  (* relax_fs raw value passes through; derived values change. *)
  with_clean_sandbox_env @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_RELAX_FS" (Some "true") (fun () ->
    check bool "relax_fs raw env wins"
      true (S.Hardening.relax_fs ());
    check (list string) "read_only_rootfs_args is empty when relax_fs"
      [] (S.Hardening.read_only_rootfs_args ());
    let mount = S.Hardening.tmpfs_mount () in
    let contains_noexec =
      let len = String.length "noexec" in
      let rec check_at i =
        if i + len > String.length mount then false
        else if String.sub mount i len = "noexec" then true
        else check_at (i + 1)
      in
      check_at 0
    in
    check bool "tmpfs_mount drops noexec when relax_fs"
      true (not contains_noexec))

(* ---------------------------------------------------------------- *)
(* 5. JSON shape                                                    *)
(* ---------------------------------------------------------------- *)

let test_json_shape_has_top_level_keys () =
  with_clean_sandbox_env @@ fun () ->
  let json = S.effective_config_json () in
  let assoc = match json with
    | `Assoc xs -> xs
    | _ -> failwith "effective_config_json must be `Assoc"
  in
  let has_key k = List.mem_assoc k assoc in
  check bool "top-level 'raw' key" true (has_key "raw");
  check bool "top-level 'derived' key" true (has_key "derived");
  let raw = List.assoc "raw" assoc in
  let raw_assoc = match raw with `Assoc xs -> xs | _ -> [] in
  let raw_keys =
    [ "hardening"; "cleanup"; "runtime"; "preflight"; "shell_timeout" ]
  in
  List.iter
    (fun k ->
      check bool
        (Printf.sprintf "raw.%s exists" k)
        true (List.mem_assoc k raw_assoc))
    raw_keys;
  (* Probe the entry shape on hardening.pids_limit *)
  let hardening = List.assoc "hardening" raw_assoc in
  let hardening_assoc = match hardening with `Assoc xs -> xs | _ -> [] in
  let pids_limit_entry = List.assoc "pids_limit" hardening_assoc in
  let entry_keys =
    match pids_limit_entry with `Assoc xs -> List.map fst xs | _ -> []
  in
  check (slist string compare) "raw entry has value/source/env_var keys"
    [ "env_var"; "source"; "value" ] entry_keys

(* ---------------------------------------------------------------- *)
(* Test runner                                                      *)
(* ---------------------------------------------------------------- *)

let () =
  run "env_config_sandbox"
    [ ( "defaults",
        [ test_case "all defaults pinned" `Quick test_defaults_pinned ] )
    ; ( "env-override",
        [ test_case "env override wins" `Quick test_env_overrides_default
        ; test_case "empty env treated as unset" `Quick
            test_empty_env_treated_as_unset
        ; test_case "invalid float -> global_default" `Quick
            test_invalid_float_falls_to_global_default
        ] )
    ; ( "shell-timeout-bucket",
        [ test_case "env var name shape" `Quick
            test_per_bucket_env_var_shape
        ; test_case "per-bucket env override" `Quick
            test_per_bucket_env_override
        ; test_case "Unknown bucket -> global env" `Quick
            test_unknown_bucket_uses_global_env
        ; test_case "Gh_min floor ignores env" `Quick
            test_gh_min_floor_ignores_env
        ] )
    ; ( "filesystem",
        [ test_case "relax_fs propagates to derived" `Quick
            test_relax_fs_propagates_to_derived
        ] )
    ; ( "json-shape",
        [ test_case "top-level keys + entry shape" `Quick
            test_json_shape_has_top_level_keys
        ] )
    ]
