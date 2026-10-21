(** Durable, immutable native-client binding to its original browser worker.
    Filesystem operations block; the server offloads each call. [root] is a
    host-selected directory below this workspace's browser-lane directory. *)
type error = Identity_changed | Unconfirmed of string
val find : root:string -> client:Browser_lane.client_info -> (string option, error) result
(** Missing reservation is fresh. An existing but incomplete/unreadable
    reservation is never fresh. Successful reads confirm durability again. *)
val claim : root:string -> client:Browser_lane.client_info -> instance_id:string ->
  (string, error) result
(** Atomic directory creation selects a single writer. Concurrent claims return
    the original worker, never replace it. A changed client identity is refused.
    A failed first write leaves the ID reserved and cannot authorize dispatch. *)
