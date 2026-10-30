(** One explicit human toggle, pinned to the authoritative observation used to
    prepare it. No transport, optimistic confirmation or automatic retry. *)
type request
val prepare : (unit, Masc_tui_artifact_checks.inventory) Masc_tui_fetched.t ->
  Masc_tui_resource_catalog.report -> (request, string) result
val same_request : request -> request -> bool
val body : expected_workspace:Masc.Tui_decode.server_identity -> request -> Yojson.Safe.t
val decode_response : request -> Yojson.Safe.t -> (Masc.Published_artifact_check.t, string) result
(** Require the exact target, desired state and a fresh change ID. A successful
    receipt still requires a separate authoritative inventory reread. *)
