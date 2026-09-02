let contains haystack needle =
  let pattern = Str.regexp_string needle in
  try
    ignore (Str.search_forward pattern haystack 0);
    true
  with Not_found -> false

let observed =
  Yojson.Safe.from_string
    {|{
      "name": "alpha",
      "keeper_last_error": null,
      "sandbox_live": {
        "keeper": "alpha",
        "sandbox_profile": "docker",
        "configured_network_mode": "inherit",
        "effective_mode": "oneshot_or_managed_inherit",
        "managed_container_kind": "managed",
        "containers": [],
        "preflight": null,
        "container_error": null,
        "why_no_container": "no visible managed sandbox container; network_mode=inherit uses one-shot Docker containers on sandboxed tool calls, and those containers still mount the keeper playground"
      }
    }|}

let render json =
  match
    Masc_tui_keeper_sandbox.decode
      ~sanitize:Masc.Tui_decode.sanitize_terminal_text
      json
  with
  | Error detail -> Alcotest.fail detail
  | Ok reading ->
    Masc_tui_keeper_sandbox.view_lines ~width:64 reading
    |> String.concat "\n"

let test_declared_effective_observed_flow () =
  let rendered = render observed in
  List.iter
    (fun needle ->
      Alcotest.(check bool) needle true (contains rendered needle))
    [ "sandbox flow"
    ; "Declared"
    ; "docker / network inherit"
    ; "Effective"
    ; "oneshot_or_managed_inherit"
    ; "Observed"
    ; "0 observed"
    ; "Why no"
    ; "one-shot"
    ; "Docker"
    ; "containers"
    ]

let test_live_container_and_errors_are_visible () =
  let json =
    Yojson.Safe.from_string
      {|{
        "keeper_last_error": "previous launch failed",
        "sandbox_live": {
          "sandbox_profile": "docker",
          "configured_network_mode": "none",
          "effective_mode": "managed_running",
          "managed_container_kind": "managed",
          "containers": [{
            "id": "abc123",
            "name": "masc-alpha",
            "image": "masc/sandbox:latest",
            "status": "Up 2 minutes",
            "running": true,
            "created_at": "2026-09-02T04:51:29Z",
            "keeper_name": "alpha",
            "container_kind": "managed",
            "network_label": "none",
            "owner_pid": 4242,
            "started_at": 1.0,
            "ttl_sec": 60.0,
            "cpus": 4,
            "memory_bytes": 2147483648,
            "hostname": "masc-alpha",
            "ipv4_address": "192.168.64.64/24",
            "ipv6_address": "fd00::64/64",
            "gateway": "192.168.64.1"
          }],
          "resource_config": {
            "memory": "2g",
            "cpus": "4",
            "work_volume_size": "256g",
            "build_volume_size": "128g",
            "pids_limit": null,
            "tmpfs_size": null
          },
          "paths": {
            "host_workspace": "/base/.masc/playground/alpha",
            "guest_home": null,
            "guest_workspace": "/masc-work/alpha",
            "guest_config": "/tmp/masc-runtime/.masc/config",
            "guest_work_volume": "/masc-work",
            "guest_build_volume": "/masc-build"
          },
          "container_error": "docker list partial",
          "why_no_container": null
        }
      }|}
  in
  let rendered = render json in
  List.iter
    (fun needle ->
      Alcotest.(check bool) needle true (contains rendered needle))
    [ "1 observed · 1 running"
    ; "masc-alpha"
    ; "abc123"
    ; "pid 4242"
    ; "created 2026-09-02T04:51:29Z"
    ; "4 CPU"
    ; "2.0 GiB"
    ; "192.168.64.64/24"
    ; "192.168.64.1"
    ; "resources"
    ; "work 256g"
    ; "paths"
    ; "/base/.masc/playground/alpha"
    ; "/masc-work/alpha"
    ; "/tmp/masc-runtime/.masc/config"
    ; "not observed"
    ; "press l"
    ; "press t"
    ; "docker list partial"
    ; "previous launch failed"
    ]

let test_hostile_text_is_sanitized_before_state () =
  let json =
    Yojson.Safe.from_string
      {|{
        "sandbox_live": {
          "effective_mode": "before\u001b]8;;https://bad.invalid\u0007after",
          "containers": []
        }
      }|}
  in
  let rendered = render json in
  Alcotest.(check bool) "raw escape is absent" false (contains rendered "\027]8");
  Alcotest.(check bool) "escaped control remains inspectable" true
    (contains rendered "\\x1B")

let test_missing_live_observation_fails_closed () =
  match
    Masc_tui_keeper_sandbox.decode ~sanitize:Fun.id (`Assoc [])
  with
  | Ok _ -> Alcotest.fail "missing sandbox_live was accepted"
  | Error detail ->
    Alcotest.(check bool) "actionable error" true
      (contains detail "no sandbox_live observation")


(* Where a microvm keeper's build output lands.

   A checkout on the virtiofs share pins one host descriptor -- and so one
   host vnode -- per file it writes. That is what emptied the table and
   panicked the host three times, and it was visible from no operator
   surface. *)

let microvm_observed ~unlinked =
  Yojson.Safe.from_string
    (Printf.sprintf
       {|{
      "name": "polisher",
      "keeper_last_error": null,
      "sandbox_live": {
        "keeper": "polisher",
        "sandbox_profile": "microvm",
        "configured_network_mode": "inherit",
        "effective_mode": "keeper_vm",
        "managed_container_kind": "keeper-vm",
        "containers": [],
        "preflight": null,
        "build_volume": {
          "name": "masc-keeper-build-polisher",
          "guest_root": "/masc-build",
          "linked": 14,
          "unlinked": %s
        },
        "container_error": null,
        "why_no_container": null
      }
    }|}
       unlinked)
;;

let test_build_volume_reports_where_output_lands () =
  let rendered = render (microvm_observed ~unlinked:"[]") in
  List.iter
    (fun needle ->
      Alcotest.(check bool)
        (Printf.sprintf "%S is rendered" needle)
        true
        (contains rendered needle))
    [ "build output"; "masc-keeper-build-polisher"; "14 checkout(s)"; "/masc-build" ]
;;

let test_checkouts_still_on_the_share_are_named () =
  (* The count alone is not actionable: clearing a real _build is a person's
     job, because the server refuses to delete build output it did not
     create. So the path has to appear, not just the number. *)
  let rendered =
    render
      (microvm_observed
         ~unlinked:
           {|[{"path":"masc-t362","reason":"holds build output on the share"}]|})
  in
  List.iter
    (fun needle ->
      Alcotest.(check bool)
        (Printf.sprintf "%S is rendered" needle)
        true
        (contains rendered needle))
    [ "still on the share"; "masc-t362"; "holds build output on the share" ]
;;

let test_docker_keeper_shows_no_build_volume_section () =
  (* [`Null] for a profile that has no volume, and the section disappears
     rather than rendering an empty one. *)
  let rendered = render observed in
  Alcotest.(check bool)
    "no build output section for docker"
    false
    (contains rendered "build output")
;;

let test_malformed_build_volume_fails_closed () =
  (* A missing count is a broken observation, not zero: reporting zero linked
     checkouts would read as "nothing is protected" and send an operator
     hunting a problem that is not there. *)
  let json =
    Yojson.Safe.from_string
      {|{
        "name": "polisher",
        "keeper_last_error": null,
        "sandbox_live": {
          "sandbox_profile": "microvm",
          "containers": [],
          "build_volume": {
            "name": "masc-keeper-build-polisher",
            "guest_root": "/masc-build",
            "unlinked": []
          }
        }
      }|}
  in
  match
    Masc_tui_keeper_sandbox.decode
      ~sanitize:Masc.Tui_decode.sanitize_terminal_text
      json
  with
  | Ok _ -> Alcotest.fail "a build_volume without [linked] must not decode"
  | Error detail ->
    Alcotest.(check bool)
      "the error names the field"
      true
      (contains detail "linked")
;;

let () =
  Alcotest.run "tui keeper sandbox"
    [ ( "projection"
      , [ Alcotest.test_case "declared effective observed flow" `Quick
            test_declared_effective_observed_flow
        ; Alcotest.test_case "containers and errors" `Quick
            test_live_container_and_errors_are_visible
        ; Alcotest.test_case "terminal controls sanitized" `Quick
            test_hostile_text_is_sanitized_before_state
        ; Alcotest.test_case "missing observation fails closed" `Quick
            test_missing_live_observation_fails_closed
        ] )
    ; ( "build volume"
      , [ Alcotest.test_case "reports where output lands" `Quick
            test_build_volume_reports_where_output_lands
        ; Alcotest.test_case "names checkouts still on the share" `Quick
            test_checkouts_still_on_the_share_are_named
        ; Alcotest.test_case "docker keeper shows no section" `Quick
            test_docker_keeper_shows_no_build_volume_section
        ; Alcotest.test_case "malformed observation fails closed" `Quick
            test_malformed_build_volume_fails_closed
        ] )
    ]
