(** Legendary Bash dark-launch observer HTTP surface.

    Exposes the in-process [Legendary_counters] snapshot as a single
    public-read JSON endpoint for dashboards and flip-decision tooling.
    The counters themselves are incremented only while the matching
    observer env flag is enabled (see [LEGENDARY-BASH-RUNBOOK.md]);
    this endpoint is a zero-cost read.

      GET /api/v1/legendary_bash/shadow_counters

    Response (200): JSON shape mirrors [Legendary_counters.snapshot]
    field-for-field. See [legendary_counters.mli] for the stable
    contract. *)

open Server_utils
open Server_auth

module Http = Http_server_eio

let snapshot_response () : Yojson.Safe.t =
  let snap = Legendary_counters.snapshot () in
  Legendary_counters.snapshot_to_json snap

let add_routes router =
  router
  |> Http.Router.get "/api/v1/legendary_bash/shadow_counters"
       (fun request reqd ->
         with_public_read
           (fun _state _req reqd ->
             let json = snapshot_response () in
             respond_public_read_json ~status:`OK request reqd
               (Yojson.Safe.to_string json))
           request reqd)
