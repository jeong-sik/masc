(** Read-only portrait, accessory catalog and previews for the current Keeper. *)

val minimum_size : int
val maximum_size : int
val default_size : int
(** The [size] range and default the tool declares in
    config/tools/keeper_portrait_read.toml. A size outside
    [minimum_size, maximum_size] is refused with those two numbers, even where
    the renderer could draw it. *)

val equipment_to_json : Keeper_portrait_look.equipment -> Yojson.Safe.t
(** The displayed equipment, using {!Keeper_portrait_item}'s canonical ids
    for nonempty slots. Empty slots retain their explicit empty labels. *)

val handle
  :  base_path:string
  -> keeper_name:string
  -> tool_name:string
  -> start_time:Tool_timing.started
  -> args:Yojson.Safe.t
  -> Tool_result.result
(** Return a PNG handle retained in the Keeper's vision store, including after
    transient screen frames are evicted. [preview_item] selects one catalog
    item for the returned picture only. The response distinguishes [current]
    and [preview] modes, and reports starting, currently equipped and
    rendered equipment shown in the PNG. It does not report inventory or persist an
    equipment choice. *)
