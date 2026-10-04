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

(* The capture every DOS image surface shares (Tool_misc_dos_lane.capture_png). *)
let screen_response () =
  match Tool_misc_dos_lane.capture_png () with
  | Error (Tool_misc_dos_lane.Lane Dos_lane.No_machine) ->
    Error (`Conflict, Server_refusal.json ~code:"no_machine" "no DOS program is loaded")
  | Error
      (Tool_misc_dos_lane.Lane
        (( Dos_lane.Activity_disabled | Dos_lane.Activity_unobserved | Dos_lane.Invalid_request _ | Dos_lane.Unreadable _ | Dos_lane.Held_by _
         | Dos_lane.Guest_fault _ | Dos_lane.Unsaveable _ | Dos_lane.Checkpoint_refused _
         | Dos_lane.Other_program _ ) as err)) ->
    Error (`Internal_server_error, Server_refusal.json ~code:"capture_failed" (Dos_lane.error_to_string err))
  | Error (Tool_misc_dos_lane.Encode message) ->
    Error (`Internal_server_error, Server_refusal.json ~code:"encode_failed" message)
  | Ok { Tool_misc_dos_lane.png; _ } -> Ok png

let add_routes router =
  router
  |> Http.Router.get screen_path (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanPlayMachine
         (fun _state _name request reqd ->
           match screen_response () with
           | Ok png ->
             Http.Response.bytes
               ~headers:[ ("cache-control", "no-store"); ("x-content-type-options", "nosniff") ]
               ~content_type:png_content_type png reqd
           | Error (status, json) -> respond_json_value_with_cors ~status request reqd json)
         request reqd)
