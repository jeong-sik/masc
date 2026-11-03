(** Current-only Librarian original payload inspection. Every retained record,
    including historical gates, is checked in its captured namespace. The
    supplied port reads verified parent/body snapshots; no Current, live-owner,
    worker, provider, recovery, mutation or ACK operation is reachable here.
    This establishes readable schema/source/binding, not effect authority or
    completed consumption.

    A validator belongs to one scan. It keeps the Librarian forests it has
    already read and passed, so the records of one owner share a single read of
    that owner's scopes. A forest that failed is read again by the next record
    that names it. *)
val validator : unit ->
  read:(scope:string -> request_id:string -> (Lane_addon_tool_request_owner.retained option, string) result) ->
  read_scope:(scope:string -> (Lane_addon_tool_request_owner.retained list, string) result) ->
  read_body:(scope:string -> request_digest:string -> (Yojson.Safe.t, string) result) ->
  Lane_addon_tool_request_owner.retained -> (unit, string) result
