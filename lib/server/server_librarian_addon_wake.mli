(** Thin hint bridge onto the existing serialized per-Keeper Memory lanes. *)
val install : sw:Eio.Switch.t -> config:Workspace.config -> unit
(** Subscribe once for the served workspace's Librarian Addon. Callbacks only
    schedule a child on this server switch; actual original-owner/epoch and
    queue discovery happens after yielding in that child. Result hints wake
    only their strictly restored original Keeper. Configuration/export hints
    rescan persisted Keeper metadata owners, actual pending queue names and
    every published original scope. A history-only Keeper blocked before it
    could capture an original is therefore woken when its dependency attaches;
    a retained history owner also survives missing metadata/profile. Invalid
    physical/epoch ownership remains a reported refusal and supplies no wake
    authority. Each failed inventory is reported without discarding names from
    independently readable inventories; suspect originals supply no names
    or dispatch authority. No provider, commit, timer, retry
    policy, second owner or registry is introduced; shutdown fences copied
    callbacks and unsubscribes this exact registration. *)
module For_testing : sig
  val discover : config:Workspace.config -> store:Lane_addon_store.t ->
    after_inventory:(unit -> unit) -> on_original:(Lane_addon_tool_request_owner.retained -> unit) ->
    event:Lane_addon_runtime.owner_event -> ((string list * string list * string list), string) result
  (** Run the bridge's discovery with observation hooks at the actual inventory
      boundary and each restored original. Does not schedule a wake. *)
end
