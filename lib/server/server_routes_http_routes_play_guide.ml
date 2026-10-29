(** How an agent handed an invite link joins the shared DOS machine (RFC
    play-link-for-the-shared-machine §2.7).

    The wording lives in the prompt [play.agent_guide]; this module fills in
    the addresses and schemas the server itself routes and checks, so the
    guide names the same doors the requests go through. *)

open Server_auth
module Http = Http_server_eio

let markdown_content_type = "text/markdown; charset=utf-8"

(* The schema the move route checks the body against
   ([Server_routes_http_routes_dos.moves]), not a copy of it. *)
let move_section ~base (path, (schema : Masc_domain.tool_schema)) =
  Printf.sprintf "### `POST %s%s`\n\nThe arguments of `%s`: %s\n\n```json\n%s\n```\n" base path
    schema.name schema.description
    (Yojson.Safe.pretty_to_string schema.input_schema)

let guide ~base ~skills =
  Prompt_registry.render_prompt_template Prompt_names.play_agent_guide
    [ ("mcp_url", base ^ Server_mcp_transport_http.profile_label Server_mcp_transport_http.Seat)
    ; ("seat_url", base ^ Server_routes_http_routes_play_page.seat_path)
    ; ("participants_url", base ^ Server_routes_http_routes_play_page.participants_path)
    ; ("session_url", base ^ Server_routes_http_routes_play_page.session_path)
    ; ("screen_url", base ^ Server_routes_http_routes_play_screen.screen_path)
    ; ("room_url", base ^ Server_routes_http_routes_play_room.path)
    ; ("moves", String.concat "\n" (List.map (move_section ~base) Server_routes_http_routes_dos.moves))
    ; ("skills", Server_play_skills.guide_section ~base skills)
    ]

let log_unavailable catalog =
  match catalog with
  | Ok _ -> ()
  | Error unavailable ->
    Option.iter
      (Log.DosLog.warn "play skill guides unavailable: %s")
      (Server_play_skills.unavailable_detail unavailable)

(* The guide is public and reads no credential, so it reads the published
   state directly. Without one there is no published Skill snapshot either. *)
let current_skills () =
  let catalog =
    match Server_auth.current_server_state () with
    | None -> Error Server_play_skills.Skills_unpublished
    | Some state -> Server_play_skills.catalog ~config:(Mcp_server.workspace_config state)
  in
  log_unavailable catalog;
  catalog

let public_base () =
  match Env_config_core.masc_http_base_url_opt () with
  | None ->
    Error
      ( `Conflict
      , Server_refusal.json ~code:"not_ready"
          "MASC_HTTP_BASE_URL is not set, so there is no address to join at" )
  | Some base when not (Play_invite.is_http_public_base_url base) ->
    Error
      ( `Conflict
      , Server_refusal.json ~code:"not_ready"
          "MASC_HTTP_BASE_URL is not an http(s) base URL, so there is no address to join at" )
  | Some base -> Ok base

let guide_response () =
  match public_base () with
  | Error refusal -> Error refusal
  | Ok base ->
    (match guide ~base ~skills:(current_skills ()) with
     | Ok text -> Ok text
     | Error message ->
       Error (`Internal_server_error, Server_refusal.json ~code:"guide_unrendered" message))

(* A guide stays unavailable, not absent, while it cannot be read now: no
   snapshot yet, no machine attached, a Skill configuration not in effect, an
   unreadable source. Each is a 503 with its own code, the answer the seat
   gives with no attached DOS worker; the same URL answers once that changes.
   404 is only for a path that names nothing published. A refusal never
   carries a host path; the reason goes to the operator log. *)
let skill_response ~base ~catalog path =
  let refuse status code message = Error (status, Server_refusal.json ~code message) in
  match Server_play_skills.fetch ~base catalog path with
  | Server_play_skills.Served text -> Ok text
  | Served_without_references { body; detail } ->
    Log.DosLog.warn "play skill references unreadable: %s" detail;
    Ok body
  | Server_play_skills.Not_found ->
    refuse `Not_found "skill_not_found" "no game guide or reference file has this name"
  | Unavailable unavailable ->
    log_unavailable (Error unavailable);
    (match unavailable with
     | Skills_unpublished ->
       refuse `Service_unavailable "skills_unpublished"
         "this server has not published its Skill catalog yet"
     | Machine_not_attached ->
       refuse `Service_unavailable "machine_unavailable" "no DOS machine add-on is attached"
     | Skills_not_in_effect ->
       refuse `Service_unavailable "skills_not_configured"
         "this server's Skill configuration is not in effect"
     | Source_unavailable _ ->
       refuse `Service_unavailable "skills_source_unavailable"
         "the DOS machine add-on's Skills cannot be read right now"
     | Catalog_unreadable _ ->
       refuse `Internal_server_error "skills_unreadable" "this server could not read its Skill catalog")
  | References_unreadable detail ->
    Log.DosLog.warn "play skill references unreadable: %s" detail;
    refuse `Service_unavailable "references_unreadable"
      "this guide's reference files cannot be read right now"
  (* The add-on ships a file over the workspace's resource read bound; a
     Keeper's keeper_skill refuses the same file. *)
  | Reference_too_large { file; bytes; max_bytes } ->
    refuse `Internal_server_error "reference_too_large"
      (Printf.sprintf "%s is %d bytes, over this server's %d-byte Skill resource read bound"
         file bytes max_bytes)
  | Reference_unreadable detail ->
    Log.DosLog.warn "play skill reference unreadable: %s" detail;
    refuse `Service_unavailable "reference_unreadable" "this reference file cannot be read right now"

let markdown_headers = [ ("cache-control", "no-store"); ("x-content-type-options", "nosniff") ]

let respond_markdown text reqd =
  Http.Response.bytes ~headers:markdown_headers ~content_type:markdown_content_type text reqd

let add_routes router =
  router
  |> Server_route.get Server_route.Always_public Play_invite.agent_guide_path (fun request reqd ->
       match guide_response () with
       | Ok text -> respond_markdown text reqd
       | Error (status, json) ->
         respond_json_value_with_cors ~status:(status :> Httpun.Status.t) request reqd json)
  |> Server_route.prefix_get (Server_route.Token_permission Masc_domain.CanPlayMachine) Server_play_skills.prefix (fun state _name request reqd ->
           let answer =
             match public_base () with
             | Error (status, json) -> Error ((status :> Httpun.Status.t), json)
             | Ok base ->
               let catalog = Server_play_skills.catalog ~config:(Mcp_server.workspace_config state) in
               skill_response ~base ~catalog (Http.Request.path request)
               |> Result.map_error (fun (status, json) -> ((status :> Httpun.Status.t), json))
           in
           match answer with
           | Ok text -> respond_markdown text reqd
           | Error (status, json) -> respond_json_value_with_cors ~status request reqd json)
