(** Dashboard browser workflows on one retained Add-on host. Commands use its
    selected tool hooks; projection and observation do not consult core browser
    queues or select a replacement connection. *)
val read : Browser_addon_host.t -> Yojson.Safe.t -> Tool_result.result
val scene : Browser_addon_host.t -> Yojson.Safe.t -> Tool_result.result
val capture : Browser_addon_host.t -> Yojson.Safe.t -> Tool_result.result
val interact : Browser_addon_host.t -> Yojson.Safe.t -> Tool_result.result
val session : Browser_addon_host.t -> Yojson.Safe.t -> Tool_result.result
val goto : Browser_addon_host.t -> Yojson.Safe.t -> Tool_result.result
val clients : Browser_addon_host.t -> Tool_result.result
