open Agent_sdk

let () =
  let open Alcotest in
  run
    "Session"
    [ ( "create"
      , [ test_case "default id" `Quick (fun () ->
            let s = Session.create () in
            check
              bool
              "starts with session-"
              true
              (String.length s.id = 40
               && String.sub s.id 0 8 = "session-"
               && String.for_all
                    (fun ch -> (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'))
                    (String.sub s.id 8 32)))
        ; test_case "custom id" `Quick (fun () ->
            let s = Session.create ~id:"my-session" () in
            check string "id" "my-session" s.id)
        ; test_case "initial turn_count is 0" `Quick (fun () ->
            let s = Session.create () in
            check int "turn_count" 0 s.turn_count)
        ; test_case "resumed_from" `Quick (fun () ->
            let s = Session.create ~resumed_from:"prev-123" () in
            check (option string) "resumed" (Some "prev-123") s.resumed_from)
        ; test_case "cwd" `Quick (fun () ->
            let s = Session.create ~cwd:"/tmp" () in
            check (option string) "cwd" (Some "/tmp") s.cwd)
        ] )
    ; ( "lifecycle"
      , [ test_case "record_turn increments" `Quick (fun () ->
            let s = Session.create () in
            let s = Session.record_turn s in
            let s = Session.record_turn s in
            check int "turn_count" 2 s.turn_count)
        ; test_case "touch updates last_active_at" `Quick (fun () ->
            Eio_main.run
            @@ fun env ->
            let clock = Eio.Stdenv.clock env in
            let s = Session.create () in
            let before = s.last_active_at in
            Eio.Time.sleep clock 0.01;
            let s = Session.touch s in
            check bool "updated" true (s.last_active_at >= before))
        ; test_case "elapsed >= 0" `Quick (fun () ->
            let s = Session.create () in
            check bool "non-negative" true (Session.elapsed s >= 0.0))
        ] )
    ; ( "json_roundtrip"
      , [ test_case "basic roundtrip" `Quick (fun () ->
            let s = Session.create ~id:"rt-1" ~cwd:"/home" ~resumed_from:"old" () in
            let s = Session.record_turn s in
            let json = Session.to_json s in
            let s2 = Result.get_ok (Session.of_json json) in
            check string "id" s.id s2.id;
            check int "turn_count" s.turn_count s2.turn_count;
            check (option string) "cwd" s.cwd s2.cwd;
            check (option string) "resumed_from" s.resumed_from s2.resumed_from)
        ; test_case "metadata survives roundtrip" `Quick (fun () ->
            let s = Session.create ~id:"rt-2" () in
            Context.set s.metadata "key" (`String "value");
            let json = Session.to_json s in
            let s2 = Result.get_ok (Session.of_json json) in
            check
              (option string)
              "metadata key"
              (Some "value")
              (match Context.get s2.metadata "key" with
               | Some (`String v) -> Some v
               | _ -> None))
        ; test_case "malformed json returns Error" `Quick (fun () ->
            let bad = `Assoc [ "not_id", `Int 42 ] in
            check bool "is error" true (Result.is_error (Session.of_json bad)))
        ; test_case "non-object metadata returns Error" `Quick (fun () ->
            let bad =
              `Assoc
                [ "id", `String "bad-metadata"
                ; "started_at", `Float 1.0
                ; "last_active_at", `Float 1.0
                ; "turn_count", `Int 0
                ; "resumed_from", `Null
                ; "cwd", `Null
                ; "metadata", `String "invalid"
                ]
            in
            check bool "is error" true (Result.is_error (Session.of_json bad)))
        ] )
    ]
;;
