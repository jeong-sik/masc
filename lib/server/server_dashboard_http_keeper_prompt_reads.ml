(* See server_dashboard_http_keeper_prompt_reads.mli. *)

module Http = Http_server_eio
module Api_post = Server_dashboard_http_keeper_api_post
module Types = Server_dashboard_http_keeper_api_types

(* The two provider-input doors: the parts of one turn's request, and one of
   those parts. Both name one Keeper and one exact turn, and both run their
   read on the pool: finding the row decodes snapshot rows newest first, and
   a live store holds 79-231 MB of them. *)
let handle_provider_input_get state req reqd ~name ~surface ~read =
  let bad_request detail =
    Http.Response.json_value
      ~status:`Bad_request
      (`Assoc [ "error", `String detail ])
      reqd
  in
  if String.length name = 0
  then Api_post.respond_error reqd "keeper name is required"
  else if not (Keeper_config.validate_name name)
  then bad_request (Printf.sprintf "invalid keeper name: %s" name)
  else
    match Server_utils.query_param req "turn_ref" with
    | None -> bad_request "turn_ref query parameter is required"
    | Some raw_turn_ref ->
      (match Ids.Turn_ref.of_string raw_turn_ref with
       | None -> bad_request (Printf.sprintf "invalid turn_ref: %s" raw_turn_ref)
       | Some turn_ref ->
         (match
            read ~config:(Mcp_server.workspace_config state) ~keeper:name ~turn_ref
          with
          | Error detail -> bad_request detail
          | Ok job ->
            let with_surface = function
              | `Assoc fields ->
                `Assoc (("dashboard_surface", `String surface) :: fields)
              | json -> json
            in
            (match
               Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
                 Result.map with_surface (job ()))
             with
             | Ok json ->
               Http.Response.json_value_on_cpu ~compress:true ~request:req json reqd
             | Error error ->
               let status =
                 match error with
                 | Keeper_provider_input_snapshot.Snapshot_not_found _
                 | Keeper_provider_input_snapshot.Part_not_found _ -> `Not_found
                 | Keeper_provider_input_snapshot.Unknown_keeper _
                 | Keeper_provider_input_snapshot.Store_read_failed _
                 | Keeper_provider_input_snapshot.Malformed_snapshot _
                 | Keeper_provider_input_snapshot.Invalid_artifact_reference _
                 | Keeper_provider_input_snapshot.Artifact_read_failed _
                 | Keeper_provider_input_snapshot.Artifact_missing _
                 | Keeper_provider_input_snapshot.Artifact_length_mismatch _ ->
                   `Service_unavailable
               in
               Http.Response.json_value
                 ~status
                 (`Assoc
                    [ ( "error"
                      , `String
                          (Keeper_provider_input_snapshot.read_error_to_string error) )
                    ])
                 reqd)))
;;

let handle_last_prompt_get state req reqd name =
  (* What this keeper was actually told, as text. The turn record keeps each
     block's bytes and digest — how much, never what. The blocks are stable
     turn to turn, so the last assembly is also the preview of the next. *)
  (match
     Keeper_prompt_capture.read ~config:(Mcp_server.workspace_config state) ~keeper:name
   with
   | Ok capture ->
     Http.Response.json_value ~compress:true ~request:req
       (match Keeper_prompt_capture.to_json capture with
        | `Assoc fields ->
          `Assoc
            (("keeper", `String name)
             :: ("dashboard_surface", `String "/api/v1/keepers/:name/last-prompt")
             :: fields)
        | json -> json)
       reqd
   | Error (Keeper_prompt_capture.Not_captured as error) ->
     Http.Response.json_value ~status:`Not_found
       (`Assoc
          [ "error", `String (Keeper_prompt_capture.read_error_to_string error) ])
       reqd
   | Error
       ((Keeper_prompt_capture.Unknown_keeper _
        | Keeper_prompt_capture.Malformed _) as error) ->
     Http.Response.json_value ~status:`Bad_request
       (`Assoc
          [ "error", `String (Keeper_prompt_capture.read_error_to_string error) ])
       reqd)
;;

let handle_provider_input_continuity_get state req reqd name =
  handle_provider_input_get state req reqd
    ~name
    ~surface:("/api/v1/keepers/:name" ^ Types.keeper_suffix_provider_input_continuity)
    ~read:(fun ~config ~keeper ~turn_ref ->
      Ok (fun () -> Keeper_continuity_evidence.read ~config ~keeper ~turn_ref))
;;

let handle_provider_input_part_get state req reqd name =
  handle_provider_input_get
    state
    req
    reqd
    ~name
    ~surface:"/api/v1/keepers/:name/provider-input/part"
    ~read:(fun ~config ~keeper ~turn_ref ->
      match Server_utils.query_param req "index" with
      | None -> Error "index query parameter is required"
      | Some raw_index ->
        (match int_of_string_opt raw_index with
         | Some index when index >= 0 ->
           Ok
             (fun () ->
               Keeper_provider_input_snapshot.read_part
                 ~config
                 ~keeper
                 ~turn_ref
                 ~index
               |> Result.map Keeper_provider_input_snapshot.part_content_to_json)
         | Some _ | None ->
           Error (Printf.sprintf "invalid index: %s" raw_index)))
;;

let handle_provider_input_manifest_get state req reqd name =
  handle_provider_input_get
    state
    req
    reqd
    ~name
    ~surface:"/api/v1/keepers/:name/provider-input"
    ~read:(fun ~config ~keeper ~turn_ref ->
      Ok
        (fun () ->
          Keeper_provider_input_snapshot.read_manifest
            ~config
            ~keeper
            ~turn_ref
          |> Result.map Keeper_provider_input_snapshot.manifest_to_json))
;;
