let contains haystack needle =
  let pattern = Str.regexp_string needle in
  try
    ignore (Str.search_forward pattern haystack 0);
    true
  with Not_found -> false

let render json =
  match
    Masc_tui_keeper_sandbox.decode
      ~sanitize:Masc.Tui_terminal_text.sanitize_terminal_text
      json
  with
  | Error detail -> Alcotest.fail detail
  | Ok reading ->
    Masc_tui_keeper_sandbox.view_lines ~width:64 reading
    |> String.concat "\n"

let test_unknown_profile_fails_closed () =
  let json =
    Yojson.Safe.from_string
      {|{"sandbox_live":{"sandbox_profile":"mystery","containers":[]}}|}
  in
  match
    Masc_tui_keeper_sandbox.decode
      ~sanitize:Masc.Tui_terminal_text.sanitize_terminal_text
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

let discard_payload fields =
  `Assoc ["sandbox_live", `Assoc ["resource_config", `Assoc fields]]

let test_discard_observation_admission () =
  let observation state error = `Assoc ["state", `String state; "error", error] in
  let decode value = Masc_tui_keeper_sandbox.decode ~sanitize:Fun.id
      (discard_payload ["work_volume_discard_default", value]) in
  List.iter (fun value -> match decode value with
    | Ok _ -> () | Error detail -> Alcotest.fail detail)
    [`Null; observation "set" `Null; observation "absent" `Null;
     observation "unreadable" (`String "volume inspect unavailable")];
  List.iter (fun value -> match decode value with
    | Error _ -> () | Ok _ -> Alcotest.fail "malformed discard observation admitted")
    [`String "set"; `Assoc []; `Assoc ["state", `String "set"];
     `Assoc ["error", `Null];
     `Assoc ["state", `String "set"; "error", `Null; "extra", `Null];
     `Assoc ["state", `String "set"; "state", `String "absent"; "error", `Null];
     `Assoc ["state", `String "set"; "error", `Null; "error", `Null];
     observation "unknown" `Null; observation "set" (`String "error");
     observation "absent" (`String "error"); observation "unreadable" `Null;
     observation "unreadable" (`String " \t"); observation "unreadable" (`Int 1);
     `Assoc ["state", `Bool true; "error", `Null]];
  List.iter (fun json -> match Masc_tui_keeper_sandbox.decode ~sanitize:Fun.id json with
    | Error _ -> () | Ok _ -> Alcotest.fail "missing or duplicate discard boundary admitted")
    [discard_payload [];
     discard_payload ["work_volume_discard_default", `Null; "work_volume_discard_default", `Null];
     `Assoc ["sandbox_live", `Assoc
       ["resource_config", `Assoc ["work_volume_discard_default", `Null];
        "resource_config", `Assoc ["work_volume_discard_default", `Null]]]]
;;

let test_kata_name_observation_decisions () =
  let module K = Masc_tui_keeper_sandbox in
  let decode fields =
    K.decode ~sanitize:Fun.id (`Assoc ["sandbox_live", `Assoc
        ( ["sandbox_profile", `String "microvm"; "containers", `List []] @ fields )]) in
  let observation state scoped =
    "kata_name_observation", `Assoc ["state", `String state; "scoped_name_seen", scoped] in
  let expect expected fields = match decode fields with
    | Error detail -> Alcotest.fail detail
    | Ok reading -> Alcotest.(check bool) "decision" true (K.kata_status_decision reading = expected) in
  expect K.Kata_not_observed [];
  expect K.Kata_inapplicable [observation "not_applicable" `Null];
  expect K.Kata_absent [observation "absent" (`Bool false)];
  expect K.Kata_scoped_name_seen [observation "expected_runtime" (`Bool true)];
  expect K.Kata_unscoped_expected_runtime [observation "expected_runtime" (`Bool false)];
  expect K.Kata_unscoped_expected_runtime [observation "expected_runtime" `Null];
  expect K.Kata_other_runtime [observation "other_runtime" (`Bool false)];
  expect K.Kata_unreported_runtime [observation "runtime_unreported" (`Bool false)];
  expect K.Kata_unavailable [observation "unavailable" `Null];
  List.iter (fun fields -> match decode fields with
    | Error _ -> () | Ok _ -> Alcotest.fail "invalid name observation accepted")
    [ [observation "not_applicable" (`Bool true)]
    ; [observation "unknown" `Null]
    ; ["kata_name_observation", `Assoc ["state", `String "absent"]]
    ; [observation "absent" `Null; observation "absent" `Null]
    ]
;;

let test_independent_partial_observations () =
  let module K = Masc_tui_keeper_sandbox in
  let inventory = `Assoc ["sandbox_live", `Assoc [
    "sandbox_profile", `String "microvm";
    "containers", `List [`Assoc ["name", `String "vm-other-network";
      "id", `String "abc"; "image", `String "image"; "status", `String "raw";
      "running", `Bool true]]]] in
  let inventory = match K.decode ~sanitize:Fun.id inventory with
    | Ok value -> value | Error detail -> Alcotest.fail detail in
  let name = match K.decode_name ~sanitize:Fun.id ~keeper_name:"alpha"
      (`Assoc ["keeper", `String "alpha"; "expected_name", `String "vm-target";
               "host_environment_alignment", `String "selectors_match";
               "network_mode", `String "none"; "state", `String "expected_runtime"]) with
    | Ok value -> value | Error detail -> Alcotest.fail detail in
  let inventory_first = K.add_partial K.empty_partial (K.Inventory_result (Ok inventory)) in
  Alcotest.(check bool) "inventory arrives before name" true
    (K.partial_results inventory_first = (Some (Ok inventory), None));
  let duplicate = K.add_partial inventory_first (K.Inventory_result (Error "duplicate")) in
  Alcotest.(check bool) "duplicate completion cannot replace first result" true
    (K.partial_results duplicate = (Some (Ok inventory), None));
  Alcotest.(check bool) "pending does not complete" false (K.partial_complete inventory_first);
  let inventory_then_failure = K.add_partial inventory_first (K.Name_result (Error "name timeout")) in
  Alcotest.(check bool) "name timeout preserves inventory" true
    (K.partial_results inventory_then_failure = (Some (Ok inventory), Some (Error "name timeout")));
  Alcotest.(check bool) "both results settle" true (K.partial_complete inventory_then_failure);
  let name_first = K.add_partial K.empty_partial (K.Name_result (Ok name)) in
  Alcotest.(check bool) "name arrives before inventory" true
    (K.partial_results name_first = (None, Some (Ok name)));
  let name_then_failure = K.add_partial name_first (K.Inventory_result (Error "inventory timeout")) in
  Alcotest.(check bool) "inventory timeout preserves name" true
    (K.partial_results name_then_failure = (Some (Error "inventory timeout"), Some (Ok name)));
  let both = K.add_partial name_first (K.Inventory_result (Ok inventory)) in
  Alcotest.(check bool) "both independent observations retained" true
    (K.partial_results both = (Some (Ok inventory), Some (Ok name)))
;;

let test_name_read_admission () =
  let module K = Masc_tui_keeper_sandbox in
  let decode = K.decode_name ~sanitize:Fun.id ~keeper_name:"alpha" in
  let report ?(alignment=`String "selectors_match") keeper name state = `Assoc ["keeper", `String keeper;
    "expected_name", name; "host_environment_alignment", alignment;
    "network_mode", `String "none"; "state", `String state] in
  List.iter (fun json -> match decode json with
    | Ok _ -> () | Error detail -> Alcotest.fail detail)
    [report ~alignment:`Null "alpha" `Null "not_applicable";
     report "alpha" (`String "vm-alpha") "expected_runtime";
     report ~alignment:(`String "selectors_differ") "alpha" (`String "vm-alpha") "unavailable"];
  List.iter (fun json -> match decode json with
    | Error _ -> () | Ok _ -> Alcotest.fail "invalid name observation accepted")
    [report "beta" (`String "vm-alpha") "expected_runtime";
     report "alpha" `Null "absent";
     report "alpha" (`String "vm-alpha") "not_applicable";
     report "alpha" (`String "vm-alpha") "unknown";
     report ~alignment:(`String "selectors_differ") "alpha" (`String "vm-alpha") "absent";
     report ~alignment:(`String "selectors_unavailable") "alpha" (`String "vm-alpha") "expected_runtime";
     `Assoc ["keeper", `String "alpha"; "keeper", `String "alpha";
             "expected_name", `Null; "host_environment_alignment", `Null;
             "network_mode", `String "none"; "state", `String "not_applicable"];
     `Assoc ["keeper", `String "alpha"; "expected_name", `Null;
             "network_mode", `String "none"; "state", `String "not_applicable"]]
;;

let test_inventory_read_requires_matching_keeper () =
  let decode = Masc_tui_keeper_sandbox.decode_for_keeper ~sanitize:Fun.id ~keeper_name:"alpha" in
  let status outer inner = `Assoc ["name", `String outer;
    "sandbox_live", `Assoc ["keeper", `String inner; "containers", `List []]] in
  (match decode (status "alpha" "alpha") with
   | Ok _ -> () | Error detail -> Alcotest.fail detail);
  List.iter (fun json -> match decode json with
    | Error _ -> () | Ok _ -> Alcotest.fail "foreign or unbound inventory accepted")
    [status "alpha" "beta"; status "beta" "alpha";
     `Assoc ["name", `String "alpha"; "name", `String "beta";
       "sandbox_live", `Assoc ["keeper", `String "alpha"]];
     `Assoc ["name", `String "alpha"; "sandbox_live", `Assoc ["containers", `List []]]]
;;

let test_remote_inventory_is_unobserved_not_zero () =
  let module K = Masc_tui_keeper_sandbox in
  let decode profile containers = match K.decode ~sanitize:Fun.id
      (`Assoc ["sandbox_live", `Assoc ["sandbox_profile", `String profile;
        "containers", containers]]) with
    | Ok value -> value | Error detail -> Alcotest.fail detail in
  Alcotest.(check bool) "empty remote inventory does not observe remote execution" true
    (K.inventory_decision (decode "remote_ssh" (`List [])) = K.Remote_execution_unobserved);
  Alcotest.(check bool) "empty local inventory remains an observation" true
    (K.inventory_decision (decode "docker" (`List [])) =
       K.Inventory_observed {total = 0; running = 0; unknown = 0});
  let row = `Assoc ["name", `String "unexpected"; "id", `String "id";
    "image", `String "image"; "status", `String "raw"; "running", `Bool true] in
  Alcotest.(check bool) "remote profile with local rows is inconsistent" true
    (K.inventory_decision (decode "remote_ssh" (`List [row])) = K.Remote_inventory_inconsistent)
;;

let test_image_issue_is_typed_without_parsing_diagnostic () =
  let module K = Masc_tui_keeper_sandbox in
  let decode fields = K.decode ~sanitize:Fun.id (`Assoc ["sandbox_live", `Assoc fields]) in
  let issue fields = match decode fields with
    | Ok reading -> K.image_issue reading | Error detail -> Alcotest.fail detail in
  let fields code = ["configured_image_unresolved", `String "raw diagnostic";
                     "configured_image_unresolved_code", `String code] in
  List.iter (fun (code, expected) ->
    Alcotest.(check bool) code true (issue (fields code) = Some expected))
    ["not_declared", K.Image_not_declared; "catalog_unreadable", K.Image_catalog_unreadable;
     "unknown_image", K.Image_unknown_name; "not_promoted", K.Image_not_promoted;
     "no_image_store", K.Image_no_store; "future_code", K.Image_issue_unclassified];
  Alcotest.(check bool) "old server remains unclassified" true
    (issue ["configured_image_unresolved", `String "raw diagnostic"] = Some K.Image_issue_unclassified);
  List.iter (fun fields -> match decode fields with
    | Error _ -> () | Ok _ -> Alcotest.fail "invalid image issue accepted")
    [["configured_image_unresolved_code", `String "not_declared"];
     fields "not_declared" @ ["configured_image_unresolved_code", `String "not_declared"];
     ["configured_image_unresolved", `String "raw"; "configured_image_unresolved_code", `Bool true]]
;;

let test_inventory_context_error_is_typed () =
  let module K = Masc_tui_keeper_sandbox in
  let decode fields = K.decode ~sanitize:Fun.id (`Assoc ["sandbox_live", `Assoc fields]) in
  let fields code = ["container_error", `String "raw diagnostic";
                     "container_error_code", `String code] in
  (match decode (fields "kata_execution_context_unavailable") with
   | Ok reading -> Alcotest.(check bool) "typed context failure" true
       (K.inventory_decision reading = K.Inventory_context_unavailable "raw diagnostic")
   | Error detail -> Alcotest.fail detail);
  (match decode (fields "future_code") with
   | Ok reading -> Alcotest.(check bool) "unknown code preserves the diagnostic" true
       (K.inventory_decision reading = K.Inventory_failed "raw diagnostic")
   | Error detail -> Alcotest.fail detail);
  (match decode (fields "microvm_backend_unresolved") with
   | Ok reading -> Alcotest.(check bool) "unresolved backend stays distinct" true
       (K.inventory_decision reading = K.Inventory_backend_unresolved "raw diagnostic")
   | Error detail -> Alcotest.fail detail);
  List.iter (fun fields -> match decode fields with
    | Error _ -> () | Ok _ -> Alcotest.fail "invalid inventory error code accepted")
    [["container_error_code", `String "kata_execution_context_unavailable"];
     fields "kata_execution_context_unavailable" @
       ["container_error_code", `String "kata_execution_context_unavailable"];
     ["container_error", `String "raw"; "container_error_code", `Bool true]]
;;

let test_guest_size_error_is_typed_without_parsing_diagnostic () =
  let module K = Masc_tui_keeper_sandbox in
  let decode fields = K.decode ~sanitize:Fun.id
      (`Assoc ["sandbox_live", `Assoc ["resource_config", `Assoc
        (["work_volume_discard_default", `Null] @ fields)]]) in
  let issue fields = match decode fields with
    | Ok reading -> K.guest_size_issue reading | Error detail -> Alcotest.fail detail in
  let fields code = ["guest_size_error", `String "raw diagnostic";
                     "guest_size_error_code", `String code] in
  Alcotest.(check bool) "typed failure" true
    (issue (fields "guest_size_unresolved") = Some K.Guest_size_unresolved);
  Alcotest.(check bool) "future code is unclassified" true
    (issue (fields "future_code") = Some K.Guest_size_unclassified);
  Alcotest.(check bool) "old server is unclassified" true
    (issue ["guest_size_error", `String "raw diagnostic"] = Some K.Guest_size_unclassified);
  List.iter (fun fields -> match decode fields with
    | Error _ -> () | Ok _ -> Alcotest.fail "invalid guest size issue accepted")
    [["guest_size_error_code", `String "guest_size_unresolved"];
     fields "guest_size_unresolved" @ ["guest_size_error_code", `String "guest_size_unresolved"];
     ["guest_size_error", `String "raw"; "guest_size_error_code", `Bool true]]
;;

let test_remote_log_location_requires_typed_reason () =
  let module K = Masc_tui_keeper_sandbox in
  let payload reason_code = `Assoc (["keeper", `String "alpha";
    "backend", `Null; "state", `String "no_local_stream";
    "reason", `String "original diagnostic"; "tail", `Int 10;
    "instances", `List []] @ reason_code) in
  let location code = match K.decode_logs ~sanitize:Fun.id (payload code) with
    | Ok logs -> K.log_location logs | Error detail -> Alcotest.fail detail in
  Alcotest.(check bool) "remote reason code identifies SSH location" true
    (location ["reason_code", `String "remote_ssh"] = K.Remote_ssh_logs);
  Alcotest.(check bool) "old server location remains unknown" true
    (location [] = K.Unknown_log_location);
  Alcotest.(check bool) "future reason remains unknown" true
    (location ["reason_code", `String "future"] = K.Unknown_log_location);
  (match K.decode_logs ~sanitize:Fun.id (payload ["reason_code", `String "remote_ssh";
      "reason_code", `String "remote_ssh"]) with
   | Error _ -> () | Ok _ -> Alcotest.fail "duplicate reason code accepted")
;;

let test_log_context_is_typed_and_backend_scoped () =
  let module K = Masc_tui_keeper_sandbox in
  let payload backend extra = `Assoc (["keeper", `String "alpha";
    "backend", `String backend; "state", `String "no_instance";
    "reason", `Null; "tail", `Int 10; "instances", `List []] @ extra) in
  let decode backend extra = K.decode_logs ~sanitize:Fun.id (payload backend extra) in
  let alignment extra = match decode "nerdctl_kata" extra with
    | Ok logs -> K.logs_kata_host_alignment logs | Error detail -> Alcotest.fail detail in
  Alcotest.(check bool) "known equal selectors" true
    (alignment ["kata_host_environment_alignment", `String "selectors_match"] = Some K.Host_selectors_match);
  Alcotest.(check bool) "known differing selectors" true
    (alignment ["kata_host_environment_alignment", `String "selectors_differ"] = Some K.Host_selectors_differ);
  Alcotest.(check bool) "unavailable comparison remains unknown" true
    (alignment ["kata_host_environment_alignment", `String "selectors_unavailable"] = Some K.Host_selectors_unavailable);
  Alcotest.(check bool) "older server does not attest context" true (alignment [] = None);
  List.iter (fun json -> match K.decode_logs ~sanitize:Fun.id json with
    | Error _ -> () | Ok _ -> Alcotest.fail "invalid log context accepted")
    [payload "docker" ["kata_host_environment_alignment", `String "selectors_match"];
     payload "nerdctl_kata" ["kata_host_environment_alignment", `String "selectors_match";
                             "kata_host_environment_alignment", `String "selectors_match"];
     payload "nerdctl_kata" ["kata_host_environment_alignment", `String "unknown"]]
;;

let test_discard_diagnostic_is_sanitized_at_admission () =
  let raw = "unavailable\027]8;;https://bad.invalid\007" in
  let observed = ref [] in
  let sanitize text =
    let safe = Masc.Tui_terminal_text.sanitize_terminal_text text in
    observed := (text, safe) :: !observed;
    safe in
  match Masc_tui_keeper_sandbox.decode ~sanitize (discard_payload
      ["work_volume_discard_default", `Assoc
        ["state", `String "unreadable"; "error", `String raw]]) with
  | Error detail -> Alcotest.fail detail
  | Ok reading ->
    Alcotest.(check bool) "actual wire diagnostic reaches sanitizer" true
      (List.exists (fun (original, _) -> original = raw) !observed);
    let rendered = Masc_tui_keeper_sandbox.view_lines ~width:64 reading |> String.concat "\n" in
    Alcotest.(check bool) "raw terminal control never leaves decoded state" false (contains rendered "\027]");
    Alcotest.(check bool) "escaped control remains inspectable" true (contains rendered "\\x1B")
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
        ~sanitize:Masc.Tui_terminal_text.sanitize_terminal_text json
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

let test_the_reader_accepts_every_runtime_the_server_can_name () =
  List.iter
    (fun wire ->
      let json =
        Yojson.Safe.from_string
          (Printf.sprintf
             {|{"keeper":"alpha","backend":%S,"state":"no_instance","tail":50,"instances":[]}|}
             wire)
      in
      match Masc_tui_keeper_sandbox.decode_logs ~sanitize:Fun.id json with
      | Ok _ -> ()
      | Error detail ->
        Alcotest.failf
          "the server can name %s and this reader refuses it (%s); add its arm \
           to the decoder and its label to the renderer"
          wire
          detail)
    Masc.Keeper_microvm_backend.valid_strings
;;

let test_an_unknown_backend_is_still_refused () =
  let json =
    Yojson.Safe.from_string
      {|{"keeper":"alpha","backend":"firecracker","state":"no_instance","tail":50,"instances":[]}|}
  in
  match Masc_tui_keeper_sandbox.decode_logs ~sanitize:Fun.id json with
  | Ok _ -> Alcotest.fail "an unimplemented runtime was accepted by the reader"
  | Error detail ->
    Alcotest.(check bool) "the refusal names the value" true
      (contains detail "firecracker")
;;

let test_no_local_stream_rejects_a_backend () =
  let json =
    Yojson.Safe.from_string
      {|{"keeper":"alder","backend":"docker","state":"no_local_stream",
         "reason":"anything","tail":200,"instances":[]}|}
  in
  match Masc_tui_keeper_sandbox.decode_logs ~sanitize:Fun.id json with
  | Ok _ -> Alcotest.fail "a no_local_stream payload named a backend"
  | Error detail ->
    (* The whole message, not a substring: five decoder errors mention a
       backend, so a looser check would pass on the wrong refusal. *)
    Alcotest.(check string) "the refusal names the contradiction"
      "sandbox logs.no_local_stream cannot name a backend" detail
;;

let () =
  Alcotest.run "tui keeper sandbox"
    [ ( "projection"
      , [ Alcotest.test_case "unknown profile fails closed" `Quick
            test_unknown_profile_fails_closed
        ; Alcotest.test_case "terminal controls sanitized" `Quick
            test_hostile_text_is_sanitized_before_state
        ; Alcotest.test_case "missing observation fails closed" `Quick
            test_missing_live_observation_fails_closed
        ; Alcotest.test_case "discard observation fails closed" `Quick
            test_discard_observation_admission
        ; Alcotest.test_case "Kata observation decisions" `Quick
            test_kata_name_observation_decisions
        ; Alcotest.test_case "partial results are independent" `Quick
            test_independent_partial_observations
        ; Alcotest.test_case "name observation admission" `Quick
            test_name_read_admission
        ; Alcotest.test_case "inventory names match requested Keeper" `Quick
            test_inventory_read_requires_matching_keeper
        ; Alcotest.test_case "remote execution remains unobserved" `Quick
            test_remote_inventory_is_unobserved_not_zero
        ; Alcotest.test_case "image issue is a typed decision" `Quick
            test_image_issue_is_typed_without_parsing_diagnostic
        ; Alcotest.test_case "inventory context error is typed" `Quick
            test_inventory_context_error_is_typed
        ; Alcotest.test_case "guest size issue is typed" `Quick
            test_guest_size_error_is_typed_without_parsing_diagnostic
        ; Alcotest.test_case "discard diagnostic sanitized at admission" `Quick
            test_discard_diagnostic_is_sanitized_at_admission
        ] )
    ; ( "actual logs"
      , [ Alcotest.test_case "typed and terminal safe" `Quick
            test_actual_container_logs_are_typed_and_terminal_safe
        ; Alcotest.test_case "remote location requires typed reason" `Quick
            test_remote_log_location_requires_typed_reason
        ; Alcotest.test_case "log context is typed and backend-scoped" `Quick
            test_log_context_is_typed_and_backend_scoped
        ; Alcotest.test_case "no local stream refuses a backend" `Quick
            test_no_local_stream_rejects_a_backend
        ; Alcotest.test_case
            "the reader accepts every runtime the server can name" `Quick
            test_the_reader_accepts_every_runtime_the_server_can_name
        ; Alcotest.test_case "an unknown backend is still refused" `Quick
            test_an_unknown_backend_is_still_refused
        ;] )
    ]
