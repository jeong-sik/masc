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
  | Layout of { saves_name : string; source : Play_pad.source; layout : Play_pad.layout }
  | Refused of Httpun.Status.t * Yojson.Safe.t

(* The loaded program's layout. Read off the Eio domain under the machine's
   lock, like every screen read. *)
let current_layout ~config =
  match Tool_misc_dos_lane.off_domain Dos_lane.screen with
  | Error Dos_lane.No_machine -> Refused (`Conflict, Server_refusal.json ~code:"no_machine" "no DOS program is loaded")
  | Error
      (( Dos_lane.Activity_disabled | Dos_lane.Activity_unobserved | Dos_lane.Invalid_request _ | Dos_lane.Unreadable _ | Dos_lane.Held_by _
       | Dos_lane.Guest_fault _ | Dos_lane.Unsaveable _ | Dos_lane.Checkpoint_refused _
       | Dos_lane.Other_program _ ) as err) ->
    Refused (`Internal_server_error, Server_refusal.json ~code:"screen_failed" (Dos_lane.error_to_string err))
  | Ok { Dos_lane.saves_name = None; _ } ->
    Refused (`Conflict, Server_refusal.json ~code:"no_machine" "no DOS program is loaded")
  | Ok { Dos_lane.saves_name = Some saves_name; _ } ->
    (match Play_pad.load ~base_path:config.Workspace.base_path ~saves_name with
     | Ok (Some (source, layout)) -> Layout { saves_name; source; layout }
     | Ok None ->
       Refused
         ( `Not_found
         , Server_refusal.json ~code:"no_layout" ~fields:[ ("saves_name", `String saves_name) ]
             ("no pad layout for " ^ saves_name ^ "; the keyboard and text box still work") )
     | Error message -> Refused (`Internal_server_error, Server_refusal.json ~code:"layout_invalid" message))

let layout_json ~saves_name ~source layout =
  `Assoc
    [ ("saves_name", `String saves_name)
    ; ("source", `String (Play_pad.source_to_string source))
    ; ( "buttons"
      , `List
          (List.map
             (fun (button, { Play_pad.keys; label }) ->
               `Assoc
                 [ ("button", `String (Play_pad.button_to_string button))
                 ; ("label", `String label)
                 ; ("keys", `List (List.map (fun key -> `String key) keys))
                 ])
             (Play_pad.bindings layout)) )
    ]

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
         Result.bind (Play_pad.button_of_string name) (fun button ->
           Result.map (fun saves_name -> button, saves_name) (string_field fields "saves_name"))))
  | `Int _ | `Intlit _ | `Float _ | `String _ | `Bool _ | `Null | `List _ ->
    Error "body must be a JSON object"

(* The saves name is compared twice. Here, so a pad read for another program
   gets its own answer rather than that program's layout's; and again by
   [Dos_lane.press_into] under the machine's lock, because the screen read
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
         (match Play_pad.binding layout button with
          | None ->
            ( `Bad_request
            , Server_refusal.json ~code:"unbound"
                (Printf.sprintf "%s does nothing in the %s layout" (Play_pad.button_to_string button) saves_name) )
          | Some { Play_pad.keys; _ } ->
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
