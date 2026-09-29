(** The operator's account of every keeper's execution lane, one row per
    keeper: what {!Keeper_tool_lane_status} tells a keeper about its own lane,
    read for all of them at once.

    A projection of what this process learned from its own probes and
    dispatches. Reads no disk beyond the keeper metas, dispatches nothing,
    starts no guest and stores nothing, so it is empty for a keeper whose lane
    has not been asked since the server started, and a server restart empties
    it. Each row's [probe.observed_at_unix] says how old its shim reading is. *)

type error =
  | Keeper_names_unread of string
  | Keeper_meta_unread of { keeper : string; detail : string }
      (** A keeper whose meta cannot be read has no lane to describe; the
          whole answer refuses rather than leave that keeper out of a list
          that looks complete. *)

val json : config:Workspace.config -> (Yojson.Safe.t, error) result
(** [server_release], and [keepers]: rows sorted by keeper name, each
    [keeper] plus {!Keeper_tool_lane_status.handle}'s document for it. *)

val error_detail : error -> string
