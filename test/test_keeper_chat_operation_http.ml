open Alcotest
open Masc

module Api = Server_dashboard_http_keeper_chat_operations

let test_dashboard_worker_permissions () =
  check bool
    "operation reads use read-state authority"
    true
    (Api.read_permission = Masc_domain.CanReadState);
  check bool
    "queued mutations use chat broadcast authority"
    true
    (Api.mutation_permission = Masc_domain.CanBroadcast)
;;

let test_exact_routes () =
  (match Api.get_route "/api/v1/keepers/alpha/chat/operations" with
   | Some (Api.Operation_list { keeper_name }) ->
     check string "list keeper" "alpha" keeper_name
   | Some _ | None -> fail "operation list route did not match");
  (match Api.get_route "/api/v1/keepers/alpha/chat/operations/kmsg-1" with
   | Some (Api.Operation_exact { keeper_name; raw_operation_id }) ->
     check string "exact keeper" "alpha" keeper_name;
     check string "exact operation" "kmsg-1" raw_operation_id
   | Some _ | None -> fail "exact operation route did not match");
  List.iter
    (fun (action, expected) ->
       match
         Api.mutation_route
           ("/api/v1/keepers/alpha/chat/operations/kmsg-1/" ^ action)
       with
       | Some { Api.mutation; _ } ->
         check bool "mutation kind" true (mutation = expected)
       | None -> fail ("mutation route did not match: " ^ action))
    [ "edit", Api.Edit; "move-to-end", Api.Move_to_end; "cancel", Api.Cancel ]
;;

let test_unknown_routes_do_not_match () =
  List.iter
    (fun path ->
       check bool
         ("unknown route rejected: " ^ path)
         true
         (Option.is_none (Api.get_route path)
          && Option.is_none (Api.mutation_route path)))
    [ "/api/v1/keepers/alpha/chat/operations/kmsg-1/retry"
    ; "/api/v1/keepers/alpha/chat/tasks/kmsg-1"
    ]
;;

let test_mutation_bodies_are_closed () =
  let input =
    `Assoc
      [ "schema", `String "masc.keeper_chat_operation.input.v1"
      ; "message", `String "edited"
      ; "user_blocks", `List []
      ; "turn_instructions", `Null
      ; "surface_context", `Null
      ; "attachments", `List []
      ]
  in
  let body = `Assoc [ "input", input ] |> Yojson.Safe.to_string in
  (match Api.For_testing.parse_mutation_body Api.Edit body with
   | Ok (Some observed) when Yojson.Safe.equal input observed -> ()
   | Ok _ -> fail "edit input projection changed"
   | Error code -> fail ("valid edit rejected: " ^ code));
  List.iter
    (fun body ->
       match Api.For_testing.parse_mutation_body Api.Edit body with
       | Error "invalid_input" -> ()
       | Error code -> fail ("wrong edit error: " ^ code)
       | Ok _ -> fail ("invalid edit body accepted: " ^ body))
    [ {|{"input":{"message":"edited"},"obsolete_authority":"old"}|}
    ; {|{"input":{"message":"edited"}}|}
    ; {|{"input":{},"input":{}}|}
    ; {|{"message":"flattened body"}|}
    ];
  List.iter
    (fun mutation ->
       (match Api.For_testing.parse_mutation_body mutation "{}" with
        | Ok None -> ()
        | Ok (Some _) -> fail "empty mutation unexpectedly returned input"
        | Error code -> fail ("empty mutation rejected: " ^ code));
       List.iter
         (fun body ->
            match Api.For_testing.parse_mutation_body mutation body with
            | Error "invalid_input" -> ()
            | Error code -> fail ("wrong closed mutation error: " ^ code)
            | Ok _ -> fail ("unknown mutation field accepted: " ^ body))
         [ {|{"obsolete_authority":"old"}|}; {|{"input":null}|} ])
    [ Api.Move_to_end; Api.Cancel ]
;;

let () =
  run
    "keeper chat operation http"
    [ ( "routes"
      , [ test_case
            "dashboard Worker permissions"
            `Quick
            test_dashboard_worker_permissions
        ; test_case "exact operation routes" `Quick test_exact_routes
        ; test_case "unknown routes do not match" `Quick test_unknown_routes_do_not_match
        ; test_case "mutation bodies are closed" `Quick test_mutation_bodies_are_closed
        ] )
    ]
;;
