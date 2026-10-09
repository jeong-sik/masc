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
        ] )
    ; ( "actual logs"
      , [ Alcotest.test_case "typed and terminal safe" `Quick
            test_actual_container_logs_are_typed_and_terminal_safe
        ; Alcotest.test_case "no local stream refuses a backend" `Quick
            test_no_local_stream_rejects_a_backend
        ; Alcotest.test_case
            "the reader accepts every runtime the server can name" `Quick
            test_the_reader_accepts_every_runtime_the_server_can_name
        ; Alcotest.test_case "an unknown backend is still refused" `Quick
            test_an_unknown_backend_is_still_refused
        ;] )
    ]
