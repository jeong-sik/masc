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

let guide ~base =
  Prompt_registry.render_prompt_template Prompt_names.play_agent_guide
    [ ("mcp_url", base ^ Server_mcp_transport_http.profile_label Server_mcp_transport_http.Seat)
    ; ("seat_url", base ^ Server_routes_http_routes_play_page.seat_path)
    ; ("screen_url", base ^ Server_routes_http_routes_play_screen.screen_path)
    ; ("moves", String.concat "\n" (List.map (move_section ~base) Server_routes_http_routes_dos.moves))
    ]

let guide_response () =
  match Env_config_core.masc_http_base_url_opt () with
  | None ->
    Error
      ( `Conflict
      , Server_refusal.json ~code:"not_ready"
          "MASC_HTTP_BASE_URL is not set, so there is no address to join at" )
  | Some base ->
    (match guide ~base with
     | Ok text -> Ok text
     | Error message ->
       Error (`Internal_server_error, Server_refusal.json ~code:"guide_unrendered" message))

let add_routes router =
  router
  |> Http.Router.get Play_invite.agent_guide_path (fun request reqd ->
       match guide_response () with
       | Ok text ->
         Http.Response.bytes
           ~headers:[ ("cache-control", "no-store"); ("x-content-type-options", "nosniff") ]
           ~content_type:markdown_content_type text reqd
       | Error (status, json) ->
         respond_json_value_with_cors ~status:(status :> Httpun.Status.t) request reqd json)
