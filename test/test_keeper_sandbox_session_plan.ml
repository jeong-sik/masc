(** RFC-0070 Phase 3e (e) — tests for [Keeper_sandbox_session_plan].

    Pure: same request inputs ⇒ identical plan. Asserts the
    deterministic content the v2.3 pure/edge table specifies — the
    7-label set (and that PID/started_at are NOT in it), the workspace +
    identity mount specs, the identity-file [(path, content)] pairs, the
    4 hardcoded env overrides, the nofile ulimit. *)

open Alcotest
open Masc_mcp

let plan () =
  match
    Keeper_sandbox_session_plan.of_request
      ~turn_id:7
      ~attempt:0
      ~meta_name:"alice"
      ~image:"ubuntu:22.04"
      ~container_root:"/keeper/alice"
      ~base_path:"/srv/masc"
      ~container_kind:"turn"
      ~network_mode:Keeper_types.Network_none
      ~host_root:"/var/masc/alice"
      ~uid:1234
      ~gid:5678
      ()
  with
  | Ok p -> p
  | Error _ -> failwith "test fixture: of_request unexpectedly failed"
;;

let test_deterministic () =
  let a = plan () in
  let b = plan () in
  check bool "same inputs ⇒ equal plans" true (Keeper_sandbox_session_plan.equal a b)
;;

let test_invalid_meta_name () =
  match
    Keeper_sandbox_session_plan.of_request
      ~turn_id:1
      ~attempt:0
      ~meta_name:""
      ~image:"x"
      ~container_root:"/r"
      ~base_path:"/b"
      ~container_kind:"turn"
      ~network_mode:Keeper_types.Network_none
      ~host_root:"/h"
      ~uid:1
      ~gid:1
      ()
  with
  | Error (Keeper_sandbox_session_plan.Invalid_meta_name "") -> ()
  | _ -> fail "empty meta_name should be Invalid_meta_name \"\""
;;

let test_invalid_host_root () =
  match
    Keeper_sandbox_session_plan.of_request
      ~turn_id:1
      ~attempt:0
      ~meta_name:"k"
      ~image:"x"
      ~container_root:"/r"
      ~base_path:"/b"
      ~container_kind:"turn"
      ~network_mode:Keeper_types.Network_none
      ~host_root:""
      ~uid:1
      ~gid:1
      ()
  with
  | Error (Keeper_sandbox_session_plan.Invalid_host_root "") -> ()
  | _ -> fail "empty host_root should be Invalid_host_root \"\""
;;

let test_mounts_workspace_then_identity () =
  let p = plan () in
  check
    (list string)
    "workspace volume first, then passwd then group identity mounts"
    [ "/var/masc/alice:/keeper/alice:rw"
    ; "/var/masc/alice/.docker-identity/passwd:/etc/passwd:ro"
    ; "/var/masc/alice/.docker-identity/group:/etc/group:ro"
    ]
    (Keeper_sandbox_session_plan.mounts p)
;;

let test_identity_files_content () =
  let p = plan () in
  check
    (list (pair string string))
    "identity files: deterministic content from uid/gid"
    [ ( "/var/masc/alice/.docker-identity/passwd"
      , "root:x:0:0:root:/root:/bin/sh\nkeeper:x:1234:5678:MASC Keeper:/tmp:/bin/sh\n" )
    ; "/var/masc/alice/.docker-identity/group", "root:x:0:\nkeeper:x:5678:\n"
    ]
    (Keeper_sandbox_session_plan.identity_files p)
;;

let test_env_overrides () =
  let p = plan () in
  check
    (list (pair string string))
    "4 hardcoded env vars, no host inheritance"
    [ "HOME", "/tmp"; "USER", "keeper"; "LOGNAME", "keeper"; "SHELL", "/bin/sh" ]
    (Keeper_sandbox_session_plan.env_overrides p)
;;

let test_env_overrides_extra () =
  match
    Keeper_sandbox_session_plan.of_request
      ~turn_id:1
      ~attempt:0
      ~meta_name:"k"
      ~image:"x"
      ~container_root:"/r"
      ~base_path:"/b"
      ~container_kind:"turn"
      ~network_mode:Keeper_types.Network_none
      ~host_root:"/h"
      ~uid:1
      ~gid:1
      ~extra_env:[ "FOO", "bar" ]
      ()
  with
  | Ok p ->
    check
      (list (pair string string))
      "extra_env appended after the 4 defaults"
      [ "HOME", "/tmp"
      ; "USER", "keeper"
      ; "LOGNAME", "keeper"
      ; "SHELL", "/bin/sh"
      ; "FOO", "bar"
      ]
      (Keeper_sandbox_session_plan.env_overrides p)
  | Error _ -> fail "of_request with extra_env failed"
;;

let test_labels_seven_deterministic_no_pid () =
  let p = plan () in
  let labels = Keeper_sandbox_session_plan.labels p in
  let keys = List.map fst labels in
  check int "exactly 5 labels (no ttl_sec given)" 5 (List.length labels);
  check bool "owner_pid NOT present (edge-only)" false
    (List.mem "masc.mcp.owner_pid" keys);
  check bool "started_at NOT present (edge-only)" false
    (List.mem "masc.mcp.started_at" keys);
  check bool "component label present" true (List.mem "masc.mcp.component" keys);
  check bool "keeper label present" true (List.mem "masc.mcp.keeper" keys);
  (* the keeper label value is sanitized meta_name *)
  check (option string) "keeper label = sanitized meta_name"
    (Some "alice")
    (List.assoc_opt "masc.mcp.keeper" labels);
  check (option string) "network label = sanitized network_mode_to_string"
    (Some "none")
    (List.assoc_opt "masc.mcp.network" labels)
;;

let test_labels_ttl_sec () =
  match
    Keeper_sandbox_session_plan.of_request
      ~turn_id:1
      ~attempt:0
      ~meta_name:"k"
      ~image:"x"
      ~container_root:"/r"
      ~base_path:"/b"
      ~container_kind:"turn"
      ~network_mode:Keeper_types.Network_none
      ~host_root:"/h"
      ~uid:1
      ~gid:1
      ~ttl_sec:90.0
      ()
  with
  | Ok p ->
    check (option string) "ttl_sec label = %.0f"
      (Some "90")
      (List.assoc_opt "masc.mcp.ttl_sec" (Keeper_sandbox_session_plan.labels p))
  | Error _ -> fail "of_request with ttl_sec failed"
;;

let test_static_fields () =
  let p = plan () in
  check bool "cap_drop_all" true (Keeper_sandbox_session_plan.cap_drop_all p);
  check bool "no_new_privileges" true (Keeper_sandbox_session_plan.no_new_privileges p);
  check (option (pair int int)) "user = (uid, gid)"
    (Some (1234, 5678)) (Keeper_sandbox_session_plan.user p);
  check (option string) "workdir = container_root"
    (Some "/keeper/alice") (Keeper_sandbox_session_plan.workdir p);
  check string "startup_command = idle loop"
    "trap : TERM INT; while :; do sleep 3600; done"
    (Keeper_sandbox_session_plan.startup_command p);
  (match Keeper_sandbox_session_plan.seccomp_profile p with
   | Keeper_sandbox_session_plan.Seccomp_default -> ()
   | _ -> fail "seccomp_profile should default to Seccomp_default");
  (match Keeper_sandbox_session_plan.ulimits p with
   | [ { name = "nofile"; soft; hard } ] when soft = hard -> ()
   | _ -> fail "ulimits should be a single nofile=N:N entry")
;;

let () =
  run
    "Keeper_sandbox_session_plan (RFC-0070 Phase 3e e)"
    [ ( "construction"
      , [ test_case "deterministic — same inputs ⇒ equal" `Quick test_deterministic
        ; test_case "empty meta_name → Invalid_meta_name" `Quick test_invalid_meta_name
        ; test_case "empty host_root → Invalid_host_root" `Quick test_invalid_host_root
        ] )
    ; ( "mounts + identity"
      , [ test_case "workspace then identity mounts" `Quick test_mounts_workspace_then_identity
        ; test_case "identity file content from uid/gid" `Quick test_identity_files_content
        ] )
    ; ( "env"
      , [ test_case "4 hardcoded overrides" `Quick test_env_overrides
        ; test_case "extra_env appended" `Quick test_env_overrides_extra
        ] )
    ; ( "labels"
      , [ test_case "7 deterministic, no PID/started_at" `Quick test_labels_seven_deterministic_no_pid
        ; test_case "ttl_sec label when given" `Quick test_labels_ttl_sec
        ] )
    ; ( "static fields"
      , [ test_case "cap_drop / no_new_priv / user / workdir / startup / seccomp / ulimit"
            `Quick
            test_static_fields
        ] )
    ]
;;
