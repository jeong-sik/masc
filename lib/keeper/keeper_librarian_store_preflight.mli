(** Current-only Librarian original payload inspection. Every retained record,
    including historical gates, is checked in its captured namespace. The
    supplied port reads verified parent/body snapshots; no Current, live-owner,
    worker, provider, recovery, mutation or ACK operation is reachable here.
    This establishes readable schema/source/binding, not effect authority or
    completed consumption. *)
val validate :
  read:(scope:string -> request_id:string -> (Lane_addon_tool_request_owner.retained option, string) result) ->
  read_body:(scope:string -> request_digest:string -> (Yojson.Safe.t, string) result) ->
  Lane_addon_tool_request_owner.retained -> (unit, string) result
