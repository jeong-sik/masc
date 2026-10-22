(** Dashboard browser workflows on one retained Add-on host. Commands use its
    selected tool hooks; projection and observation do not consult core browser
    queues or select a replacement connection. *)
val read : Browser_addon_host.t -> Yojson.Safe.t -> Tool_result.result
val scene : Browser_addon_host.t -> Yojson.Safe.t -> Tool_result.result
val capture : Browser_addon_host.t -> Yojson.Safe.t -> Tool_result.result
val interact : Browser_addon_host.t -> Yojson.Safe.t -> Tool_result.result
val session : Browser_addon_host.t -> Yojson.Safe.t -> Tool_result.result
val goto : Browser_addon_host.t -> Yojson.Safe.t -> Tool_result.result
(** The Add-on's clients and automatic choices, with [bidi_host] beside them as
    [bidiHost]. The caller observes it: the manual BiDi host record is read
    from this server's disk, not from the Add-on worker. *)
val clients :
  bidi_host:Browser_bidi_host_status.observation -> Browser_addon_host.t -> Tool_result.result
