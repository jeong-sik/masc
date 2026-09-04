(* Phase 1 task 1: the [Remote_ssh] sandbox profile exists, round-trips
   through the string SSOT, defaults to [Network_inherit], and rejects
   [network_mode = "none"] at config load ([remote_ssh_no_network_mode]) —
   the SSH lane is transport-only in Phase 1, so the Docker-parity
   hardening table declares the rejection instead of silently honoring or
   ignoring the flag. Execution itself stays fail-closed until the runner
   lands (Phase 1 task 6). *)

open Alcotest

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  scan 0

let toml_doc_of_string_pairs pairs =
  List.map (fun (k, v) -> k, Keeper_toml_loader.Toml_string v) pairs

let test_profile_roundtrip () =
  check string "to_string" "remote_ssh"
    (Keeper_types_profile_sandbox.sandbox_profile_to_string
       Keeper_types_profile_sandbox.Remote_ssh);
  check (option string) "of_string"
    (Some "remote_ssh")
    (Option.map Keeper_types_profile_sandbox.sandbox_profile_to_string
       (Keeper_types_profile_sandbox.sandbox_profile_of_string "remote_ssh"))

let test_all_profiles_includes_remote_ssh () =
  check bool "listed" true
    (List.exists
       (fun p ->
          Keeper_types_profile_sandbox.sandbox_profile_to_string p = "remote_ssh")
       Keeper_types_profile_sandbox.all_sandbox_profiles)

let test_default_network_mode_is_inherit () =
  check string "network inherit" "inherit"
    (match Keeper_types_profile_sandbox.default_network_mode_for_profile
             Keeper_types_profile_sandbox.Remote_ssh with
     | Keeper_types_profile_sandbox.Network_inherit -> "inherit"
     | Keeper_types_profile_sandbox.Network_none -> "none"
     | Keeper_types_profile_sandbox.Network_policy -> "policy")

let test_network_mode_none_rejected () =
  let doc =
    toml_doc_of_string_pairs
      [ "keeper.sandbox_profile", "remote_ssh"
      ; "keeper.network_mode", "none" ]
  in
  match Masc.Keeper_types_profile_toml_parser.profile_defaults_of_toml doc with
  | Ok _ -> fail "expected rejection"
  | Error msg ->
    check bool "named error" true (contains "remote_ssh_no_network_mode" msg)

let test_network_mode_inherit_accepted () =
  let doc =
    toml_doc_of_string_pairs
      [ "keeper.sandbox_profile", "remote_ssh"
      ; "keeper.network_mode", "inherit" ]
  in
  match Masc.Keeper_types_profile_toml_parser.profile_defaults_of_toml doc with
  | Error msg -> fail msg
  | Ok defaults ->
    check (option string) "profile parsed" (Some "remote_ssh")
      (Option.map Keeper_types_profile_sandbox.sandbox_profile_to_string
         defaults.sandbox_profile)

let test_remote_endpoint_carried () =
  let doc =
    toml_doc_of_string_pairs
      [ "keeper.sandbox_profile", "remote_ssh"
      ; "keeper.remote_endpoint", "build-box" ]
  in
  match Masc.Keeper_types_profile_toml_parser.profile_defaults_of_toml doc with
  | Error msg -> fail msg
  | Ok defaults ->
    check (option string) "endpoint carried" (Some "build-box")
      defaults.remote_endpoint

let gate_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String "remote-ssh-gated"
        ; "trace_id", `String "trace-remote-ssh-gated"
        ])
  with
  | Ok meta -> meta
  | Error err -> fail err

let test_endpoint_missing_rejected () =
  let defaults =
    { Masc.Keeper_types_profile.empty_keeper_profile_defaults with
      manifest_path = Some ".masc/config/keepers/remote-ssh-gated.toml"
    ; sandbox_profile = Some Keeper_types_profile_sandbox.Remote_ssh
    }
  in
  match
    Masc.Keeper_meta_contract.effective_meta_of_profile_defaults
      defaults (gate_meta ())
  with
  | Ok _ -> fail "remote_ssh without remote_endpoint must be rejected"
  | Error msg ->
    check bool "named error" true (contains "remote_ssh_endpoint_missing" msg)

let test_endpoint_present_accepted () =
  let defaults =
    { Masc.Keeper_types_profile.empty_keeper_profile_defaults with
      manifest_path = Some ".masc/config/keepers/remote-ssh-gated.toml"
    ; sandbox_profile = Some Keeper_types_profile_sandbox.Remote_ssh
    ; remote_endpoint = Some "build-box"
    }
  in
  match
    Masc.Keeper_meta_contract.effective_meta_of_profile_defaults
      defaults (gate_meta ())
  with
  | Error msg -> fail msg
  | Ok meta ->
    check string "profile kept" "remote_ssh"
      (Keeper_types_profile_sandbox.sandbox_profile_to_string meta.sandbox_profile)

let test_endpoint_blank_rejected () =
  let reject endpoint =
    let defaults =
      { Masc.Keeper_types_profile.empty_keeper_profile_defaults with
        manifest_path = Some ".masc/config/keepers/remote-ssh-gated.toml"
      ; sandbox_profile = Some Keeper_types_profile_sandbox.Remote_ssh
      ; remote_endpoint = Some endpoint
      }
    in
    match
      Masc.Keeper_meta_contract.effective_meta_of_profile_defaults
        defaults (gate_meta ())
    with
    | Ok _ -> fail "remote_ssh with blank remote_endpoint must be rejected"
    | Error msg ->
      check bool "named error" true (contains "remote_ssh_endpoint_missing" msg)
  in
  reject "";
  reject "   "

(* RFC-0405. [microvm_backend] names which runtime supplies the guest. It sits
   beside [remote_endpoint] because both are keys only one profile reads, and
   both are typos rather than overrides anywhere else. *)
let test_microvm_backend_parses_under_microvm () =
  let doc =
    toml_doc_of_string_pairs
      [ "keeper.sandbox_profile", "microvm"
      ; "keeper.microvm_backend", "microsandbox"
      ]
  in
  match Masc.Keeper_types_profile_toml_parser.profile_defaults_of_toml doc with
  | Error msg -> fail ("a declared backend was rejected: " ^ msg)
  | Ok defaults ->
    (match defaults.microvm_backend with
     | Some Masc.Keeper_microvm_backend.Microsandbox -> ()
     | Some other ->
       failf
         "microsandbox parsed as %s"
         (Masc.Keeper_microvm_backend.to_string other)
     | None -> fail "a declared backend did not reach the defaults")
;;

let test_microvm_backend_requires_microvm () =
  let reject profile_pair =
    let doc =
      toml_doc_of_string_pairs
        (profile_pair @ [ "keeper.microvm_backend", "microsandbox" ])
    in
    match Masc.Keeper_types_profile_toml_parser.profile_defaults_of_toml doc with
    | Ok _ -> fail "microvm_backend outside the microvm profile must be rejected"
    | Error msg ->
      check bool "named error" true
        (contains "microvm_backend_requires_microvm" msg)
  in
  reject [ "keeper.sandbox_profile", "docker" ];
  reject [ "keeper.sandbox_profile", "remote_ssh" ];
  reject []
;;

(* An unknown spelling is refused by name. Falling back to a runtime the
   keeper did not ask for would defeat the key: the point of naming a backend
   is that the isolation is the declared one. *)
let test_an_unknown_backend_is_refused_by_name () =
  let doc =
    toml_doc_of_string_pairs
      [ "keeper.sandbox_profile", "microvm"
      ; "keeper.microvm_backend", "firecracker"
      ]
  in
  match Masc.Keeper_types_profile_toml_parser.profile_defaults_of_toml doc with
  | Ok _ -> fail "an unimplemented runtime must not load"
  | Error msg ->
    check bool "names the key" true (contains "microvm_backend_unknown" msg);
    check bool "names what it would have taken" true (contains "microsandbox" msg)
;;

let test_remote_endpoint_requires_remote_ssh () =
  let reject profile_pair =
    let doc =
      toml_doc_of_string_pairs (profile_pair @ [ "keeper.remote_endpoint", "build-box" ])
    in
    match Masc.Keeper_types_profile_toml_parser.profile_defaults_of_toml doc with
    | Ok _ -> fail "remote_endpoint without remote_ssh profile must be rejected"
    | Error msg ->
      check bool "named error" true
        (contains "remote_endpoint_requires_remote_ssh" msg)
  in
  reject [ "keeper.sandbox_profile", "docker" ];
  (* "local" was this case's second profile until #32078 retired it. The load
     now refuses the value before it ever reaches the remote_endpoint check,
     so the assertion was reading a different error than the one it names.
     microvm is a live profile that is still not remote_ssh. *)
  reject [ "keeper.sandbox_profile", "microvm" ];
  (* Absent profile defaults away from remote_ssh, so the endpoint is still
     rejected. *)
  reject []

let () =
  run "remote_ssh profile"
    [ "profile", [ test_case "roundtrip" `Quick test_profile_roundtrip
                 ; test_case "all_profiles" `Quick test_all_profiles_includes_remote_ssh
                 ; test_case "remote_endpoint carried" `Quick test_remote_endpoint_carried ]
    ; "network", [ test_case "default inherit" `Quick test_default_network_mode_is_inherit
                 ; test_case "none rejected" `Quick test_network_mode_none_rejected
                 ; test_case "inherit accepted" `Quick test_network_mode_inherit_accepted ]
    ; "endpoint", [ test_case "missing rejected" `Quick test_endpoint_missing_rejected
                  ; test_case "blank rejected" `Quick test_endpoint_blank_rejected
                  ; test_case "present accepted" `Quick test_endpoint_present_accepted
                  ; test_case "requires remote_ssh" `Quick
                      test_remote_endpoint_requires_remote_ssh
                  ; Alcotest.test_case "microvm_backend parses under microvm"
                      `Quick test_microvm_backend_parses_under_microvm
                  ; Alcotest.test_case "microvm_backend requires microvm"
                      `Quick test_microvm_backend_requires_microvm
                  ; Alcotest.test_case "an unknown backend is refused by name"
                      `Quick test_an_unknown_backend_is_refused_by_name ] ]
