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

let test_idle_status_answers_what_happens_next () =
  let rendered = render observed in
  List.iter
    (fun needle ->
      Alcotest.(check bool) needle true (contains rendered needle))
    [ "status"
    ; "IDLE"
    ; "Next"
    ; "container starts when a sandbox command runs"
    ; "configured"
    ; "Backend"
    ; "Docker"
    ; "Network"
    ; "inherit"
    ; "related"
    ]
  ; List.iter
      (fun stale_label ->
        Alcotest.(check bool)
          (stale_label ^ " is not rendered")
          false
          (contains rendered stale_label))
      [ "sandbox flow"; "Effective"; "oneshot_or_managed_inherit"; "Why no container" ]

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
    [ "DEGRADED"
    ; "1 reported with an inspection error"
    ; "live instance"
    ; "State"
    ; "masc-alpha"
    ; "abc123"
    ; "Owner PID"
    ; "4242"
    ; "Created"
    ; "2026-09-02T04:51:29Z"
    ; "Compute"
    ; "4 CPU"
    ; "2.0 GiB RAM"
    ; "Network"
    ; "192.168.64.64/24"
    ; "192.168.64.1"
    ; "configured"
    ; "work 256g"
    ; "filesystem"
    ; "/base/.masc/playground/alpha"
    ; "/masc-work/alpha"
    ; "/tmp/masc-runtime/.masc/config"
    ; "unavailable"
    ; "o  actual logs"
    ; "t  tool calls"
    ; "docker list partial"
    ; "previous launch failed"
    ]

let test_stopped_instance_is_not_reported_as_not_started () =
  let json =
    Yojson.Safe.from_string
      {|{
        "sandbox_live": {
          "sandbox_profile": "microvm",
          "containers": [{
            "id": "vm-stopped",
            "name": "masc-alpha",
            "image": "masc/sandbox:latest",
            "status": "stopped",
            "running": false
          }],
          "container_error": null
        }
      }|}
  in
  let rendered = render json in
  Alcotest.(check bool) "stopped status" true (contains rendered "STOPPED");
  Alcotest.(check bool) "not a never-started VM" false
    (contains rendered "NOT STARTED")

let test_unknown_profile_fails_closed () =
  let json =
    Yojson.Safe.from_string
      {|{"sandbox_live":{"sandbox_profile":"mystery","containers":[]}}|}
  in
  match
    Masc_tui_keeper_sandbox.decode
      ~sanitize:Masc.Tui_decode.sanitize_terminal_text
      json
  with
  | Ok _ -> Alcotest.fail "an unknown sandbox profile was accepted"
  | Error detail ->
    Alcotest.(check bool) "profile error names the value" true
      (contains detail "unsupported value mystery")

let test_hostile_text_is_sanitized_before_state () =
  let json =
    Yojson.Safe.from_string
      {|{
        "sandbox_live": {
          "configured_network_mode": "before\u001b]8;;https://bad.invalid\u0007after",
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
    [ "build cache"; "masc-keeper-build-polisher"; "14 checkout(s)"; "/masc-build" ]
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
    [ "still use the shared filesystem"
    ; "Shared fs"
    ; "masc-t362"
    ; "holds build output on the share"
    ]
;;

let test_docker_keeper_shows_no_build_volume_section () =
  (* [`Null] for a profile that has no volume, and the section disappears
     rather than rendering an empty one. *)
  let rendered = render observed in
  Alcotest.(check bool)
    "no build cache section for docker"
    false
    (contains rendered "build cache")
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

let test_actual_container_logs_are_typed_and_terminal_safe () =
  let json =
    Yojson.Safe.from_string
      {|{
        "keeper":"alpha",
        "backend":"apple_container",
        "state":"available",
        "tail":200,
        "instances":[{
          "instance_id":"vm-1",
          "instance_name":"masc-alpha",
          "running":true,
          "stdout":"ready\nserving",
          "stderr":"warning\u001b]8;;https://bad.invalid\u0007",
          "error":null
        }]
      }|}
  in
  let logs =
    match
      Masc_tui_keeper_sandbox.decode_logs
        ~sanitize:Masc.Tui_decode.sanitize_terminal_text json
    with
    | Ok logs -> logs
    | Error detail -> Alcotest.fail detail
  in
  let rendered =
    Masc_tui_keeper_sandbox.logs_view_lines ~width:64 logs
    |> String.concat "\n"
  in
  List.iter
    (fun needle ->
      Alcotest.(check bool) needle true (contains rendered needle))
    [ "container logs"
    ; "Apple Container"
    ; "masc-alpha"
    ; "vm-1"
    ; "out  ready"
    ; "out  serving"
    ; "err  warning\\x1B"
    ];
  Alcotest.(check bool) "raw escape is absent" false (contains rendered "\027]")
;;

let test_actual_container_logs_report_no_instance () =
  let json =
    Yojson.Safe.from_string
      {|{
        "keeper":"alpha",
        "backend":"docker",
        "state":"no_instance",
        "tail":200,
        "instances":[]
      }|}
  in
  match Masc_tui_keeper_sandbox.decode_logs ~sanitize:Fun.id json with
  | Error detail -> Alcotest.fail detail
  | Ok logs ->
    let rendered =
      Masc_tui_keeper_sandbox.logs_view_lines ~width:64 logs
      |> String.concat "\n"
    in
    Alcotest.(check bool) "no instance is explicit" true
      (contains rendered "run a sandbox command first")
;;

let () =
  Alcotest.run "tui keeper sandbox"
    [ ( "projection"
      , [ Alcotest.test_case "idle status answers next action" `Quick
            test_idle_status_answers_what_happens_next
        ; Alcotest.test_case "containers and errors" `Quick
            test_live_container_and_errors_are_visible
        ; Alcotest.test_case "stopped instance stays distinct" `Quick
            test_stopped_instance_is_not_reported_as_not_started
        ; Alcotest.test_case "unknown profile fails closed" `Quick
            test_unknown_profile_fails_closed
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
    ; ( "actual logs"
      , [ Alcotest.test_case "typed and terminal safe" `Quick
            test_actual_container_logs_are_typed_and_terminal_safe
        ; Alcotest.test_case "no instance is explicit" `Quick
            test_actual_container_logs_report_no_instance
        ] )
    ]
