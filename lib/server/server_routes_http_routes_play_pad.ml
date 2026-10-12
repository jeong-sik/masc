(** The masc pad over HTTP (RFC play-link-for-the-shared-machine §2.9).

    [GET /api/v1/play/pad] answers the layout of the program loaded now:
    [{saves_name, source, buttons: [{button, label, keys}]}]. It needs
    [CanPlayMachine] from a bearer.

    [POST /api/v1/play/pad] [{button, saves_name}] presses the keys that
    button stands for in that layout, as [POST /api/v1/dos/press] would under
    the same credential: the ledger records machine keys. [saves_name] is the
    one the GET answered: the layout the person was looking at. Another
    program loaded since is refused, and so is an unbound button; nothing is
    pressed. *)

open Server_auth
module Http = Http_server_eio

let pad_path = "/api/v1/play/pad"

type loaded =
  | Layout of { saves_name : string; source : Machine_pad_layout.source; layout : Machine_pad_layout.layout }
  | Refused of Httpun.Status.t * Yojson.Safe.t

(* The layout and program identity come from one worker screen observation. *)
let current_layout ~config =
  let failure status code message = Refused (status, Server_refusal.json ~code message) in
  match Machine_addon_host.call_shared ~config ~principal:Lane_addon_call_context.Anonymous
      ~name:"masc_dos_screen" ~arguments:(`Assoc ["include_pad", `Bool true]) with
  | Error (Lane_addon_runtime.Unavailable message | Lane_addon_runtime.Outcome_unknown message
      | Lane_addon_runtime.Host_refusal (Lane_addon_call_context.Rejected message | Unavailable message | Activity_disabled message | Activity_unobserved message)) ->
      failure `Service_unavailable "machine_unavailable" message
  | Ok result when result.Mcp_protocol.Mcp_types.is_error = Some true ->
      let code = match result._meta with
        | Some (`Assoc fields) -> List.assoc_opt "io.github.jeong-sik/masc.machine.screenError" fields
        | _ -> None in
      let message = Agent_core.Mcp.text_of_tool_result result in
      (match code with
       | Some (`String "no_machine") -> failure `Conflict "no_machine" message
       | _ -> failure `Internal_server_error "screen_failed" message)
  | Ok result ->
      let pad = match result.structured_content with
        | Some (`Assoc fields) -> List.assoc_opt "pad" fields | _ -> None in
      match pad with
      | Some (`Assoc fields) ->
          (match List.assoc_opt "kind" fields with
           | Some (`String "ready") ->
               (match List.assoc_opt "layout" fields with
                | Some json ->
                    (match Machine_pad_layout.of_json json with
                     | Ok (saves_name, source, layout) -> Layout {saves_name;source;layout}
                     | Error message -> failure `Internal_server_error "layout_invalid" message)
                | None -> failure `Internal_server_error "layout_invalid" "worker omitted pad layout")
           | Some (`String "missing") ->
               (match List.assoc_opt "saves_name" fields with
                | Some (`String saves_name) -> Refused (`Not_found,
                    Server_refusal.json ~code:"no_layout" ~fields:["saves_name", `String saves_name]
                      ("no pad layout for " ^ saves_name ^ "; the keyboard and text box still work"))
                | _ -> failure `Internal_server_error "layout_invalid" "worker omitted program identity")
           | Some (`String "no_machine") -> failure `Conflict "no_machine" "no DOS program is loaded"
           | Some (`String "invalid") ->
               (match List.assoc_opt "message" fields with
                | Some (`String message) -> failure `Internal_server_error "layout_invalid" message
                | _ -> failure `Internal_server_error "layout_invalid" "invalid worker pad layout")
           | _ -> failure `Internal_server_error "layout_invalid" "unknown worker pad result")
      | _ -> failure `Internal_server_error "layout_invalid" "worker omitted pad information"

let layout_json = Machine_pad_layout.to_json

let get_response ~config =
  match current_layout ~config with
  | Refused (status, json) -> status, json
  | Layout { saves_name; source; layout } -> `OK, layout_json ~saves_name ~source layout

let string_field fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | None -> Error (name ^ " is required")
  | Some (`Int _ | `Intlit _ | `Float _ | `Bool _ | `Null | `List _ | `Assoc _) ->
    Error (name ^ " must be a string")

(* [{button, saves_name}]: the button, and the saves name of the layout it
   was pressed on. *)
let decode_press body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error message -> Error ("body is not JSON: " ^ message)
  | `Assoc fields ->
    (match List.remove_assoc "saves_name" (List.remove_assoc "button" fields) with
     | (field, _) :: _ -> Error (Printf.sprintf "unknown field %S (button, saves_name)" field)
     | [] ->
       Result.bind (string_field fields "button") (fun name ->
         Result.bind (Machine_pad_layout.button_of_string name) (fun button ->
           Result.map (fun saves_name -> button, saves_name) (string_field fields "saves_name"))))
  | `Int _ | `Intlit _ | `Float _ | `String _ | `Bool _ | `Null | `List _ ->
    Error "body must be a JSON object"

(* The saves name is compared twice. Here, so a pad read for another program
   gets its own answer rather than that program's layout's; and again by
   the worker under the machine's lock, because the screen read
   above has let the lock go and a load can land before the keys do. *)
let press_response ~config ~who ~body =
  match decode_press body with
  | Error message -> `Bad_request, Server_refusal.json ~code:"invalid_request" message
  | Ok (button, read_for) ->
    (match current_layout ~config with
     | Refused (status, json) -> status, json
     | Layout { saves_name; layout; _ } ->
       if not (String.equal saves_name read_for) then
         ( `Conflict
         , Server_refusal.json ~code:"program_changed" ~fields:[ ("saves_name", `String saves_name) ]
             (Printf.sprintf "the pad was read for %s and %s is loaded now; nothing was pressed"
                read_for saves_name) )
       else
         (match Machine_pad_layout.binding layout button with
          | None ->
            ( `Bad_request
            , Server_refusal.json ~code:"unbound"
                (Printf.sprintf "%s does nothing in the %s layout" (Machine_pad_layout.button_to_string button) saves_name) )
          | Some { Machine_pad_layout.keys; _ } ->
            let status, json = Server_routes_http_routes_dos.press_into ~config ~who ~saves_name ~keys in
            ((status :> Httpun.Status.t), json)))

let add_routes router =
  router
  |> Http.Router.get pad_path (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanPlayMachine
         (fun state _name request reqd ->
           let status, json = get_response ~config:(Mcp_server.workspace_config state) in
           respond_json_value_with_cors ~status request reqd json)
         request reqd)
  |> Http.Router.post pad_path (fun request reqd ->
       with_tool_actor_auth ~tool_name:"masc_dos_press"
         (fun state who request reqd ->
           let config = Mcp_server.workspace_config state in
           Http.Request.read_body_async reqd (fun body ->
             let status, json = press_response ~config ~who ~body in
             respond_json_value_with_cors ~status request reqd json))
         request reqd)
