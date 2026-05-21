(** Keeper shell counter HTTP surface.

    Exposes the in-process [Legendary_counters] snapshot as a public-read JSON
    endpoint for dashboards and gate diagnostics.

      GET /api/v1/legendary_bash/counters

    Response (200): JSON shape mirrors [Legendary_counters.snapshot]. *)

open Server_utils
open Server_auth

module Http = Http_server_eio

let snapshot_response () : Yojson.Safe.t =
  Legendary_counters.snapshot () |> Legendary_counters.snapshot_to_json
;;

let add_routes ~sw:_ ~clock:_ router =
  router
  |> Http.Router.get "/api/v1/legendary_bash/counters" (fun request reqd ->
    with_public_read
      (fun _state _req reqd ->
         let json = snapshot_response () in
         respond_public_read_json
           ~status:`OK
           request
           reqd
           (Yojson.Safe.to_string json))
      request
      reqd)
;;
