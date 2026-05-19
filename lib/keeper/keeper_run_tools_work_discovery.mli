val make
  :  config:Coord.config
  -> get_meta:(unit -> Keeper_types.keeper_meta)
  -> unit
  -> unit
  -> string option
(** Build the OAS before-turn work-discovery nudge callback.

    The callback reads the latest keeper meta through [get_meta] so registry
    refreshes performed during the run are reflected in subsequent turns. *)
