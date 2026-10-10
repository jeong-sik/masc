(** The shared DOS machine's screen as a PNG, for a player that reads images
    rather than a canvas (RFC play-link-for-the-shared-machine §2.7).

    [GET /api/v1/play/screen.png] needs [CanPlayMachine] from a bearer, so an
    invite's token reads it: an external agent with only a shell does
    [curl -H "Authorization: Bearer $TOKEN" -o screen.png]. It is the frame
    [masc_dos_screen] shows a Keeper. A VGA game such as 삼국지3 draws its
    Korean menus as pixels, so the text fields of a press answer cannot spell
    them. *)

open Server_auth
module Http = Http_server_eio

let screen_path = "/api/v1/play/screen.png"

let png_content_type = "image/png"

(* Screen bytes come from the same attached worker as tool calls. *)
let screen_response ~config =
  let unavailable message = Error (`Service_unavailable,
    Server_refusal.json ~code:"machine_unavailable" message) in
  match Machine_addon_host.call_shared ~config ~principal:Lane_addon_call_context.Anonymous
      ~name:"masc_dos_screen" ~arguments:(`Assoc []) with
  | Error (Lane_addon_runtime.Unavailable message
          | Lane_addon_runtime.Outcome_unknown message
          | Lane_addon_runtime.Host_refusal (Lane_addon_call_context.Rejected message | Unavailable message | Activity_disabled message | Activity_unobserved message)) ->
      unavailable message
  | Ok result when result.Mcp_protocol.Mcp_types.is_error = Some true ->
      let message = Agent_core.Mcp.text_of_tool_result result in
      let code = match result._meta with
        | Some (`Assoc fields) -> List.assoc_opt "io.github.jeong-sik/masc.machine.screenError" fields
        | _ -> None in
      (match code with
       | Some (`String "no_machine") -> Error (`Conflict, Server_refusal.json ~code:"no_machine" message)
       | Some (`String "encode_failed") -> Error (`Internal_server_error, Server_refusal.json ~code:"encode_failed" message)
       | _ -> Error (`Internal_server_error, Server_refusal.json ~code:"capture_failed" message))
  | Ok result ->
      match List.find_map (function
        | Mcp_protocol.Mcp_types.ImageContent {mime_type="image/png"; data; _} -> Some data
        | _ -> None) result.content with
      | None -> Error (`Internal_server_error,
          Server_refusal.json ~code:"capture_failed" "DOS worker returned no PNG frame")
      | Some encoded ->
          (match Base64.decode encoded with
           | Ok png -> Ok png
           | Error (`Msg message) -> Error (`Internal_server_error,
               Server_refusal.json ~code:"encode_failed" message))

let add_routes router =
  router
  |> Http.Router.get screen_path (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanPlayMachine
         (fun state _name request reqd ->
           match screen_response ~config:(Mcp_server.workspace_config state) with
           | Ok png ->
             Http.Response.bytes
               ~headers:[ ("cache-control", "no-store"); ("x-content-type-options", "nosniff") ]
               ~content_type:png_content_type png reqd
           | Error (status, json) -> respond_json_value_with_cors ~status request reqd json)
         request reqd)
