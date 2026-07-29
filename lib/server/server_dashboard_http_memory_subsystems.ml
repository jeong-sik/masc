(** Memory subsystem dashboard HTTP JSON helpers. *)

open Server_utils

   existing fixtures in test_server_dashboard_http_memory_subsystems.ml). *)

let dashboard_memory_subsystems_http_json
      ~(config : Workspace_utils.config)
      request
  : Yojson.Safe.t
  =
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:500 in
  let delegation_requests =
    match
      Keeper_delegation_request_store.list_requests ~base_path:config.base_path
        ~limit
    with
    | Ok listing ->
      `Assoc
        [ "total", `Int listing.total
        ; "shown", `Int listing.shown
        ; "limit", `Int listing.limit
        ; "index_path", `String listing.index_path
        ; ( "items"
          , `List
              (List.map
                 Keeper_delegation_request_store.request_summary_to_json
                 listing.items) )
        ; "error", `Null
        ]
    | Error msg ->
      `Assoc
        [ "total", `Int 0
        ; "shown", `Int 0
        ; "limit", `Int limit
        ; ( "index_path"
          , `String
              (Keeper_delegation_request_store.index_path
                 ~base_path:config.base_path) )
        ; "items", `List []
        ; "error", `String msg
        ]
  in
  `Assoc
    [ "generated_at", `String (Masc_domain.now_iso ())
    ; "delegation_requests", delegation_requests
    ]
;;
