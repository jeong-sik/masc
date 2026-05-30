(** Catalog-aware variant of route → cascade name resolution.

    After cascade nuke: always returns "tool_strict". The cascade indirection
    layer is gone — all routing goes through Runtime directly. *)

let cascade_name_for_use ?config_path:_ _use =
  Runtime.get_default_cascade_name ()
