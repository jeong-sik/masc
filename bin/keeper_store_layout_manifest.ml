(** Emits the keeper runtime store layout as JSON on stdout.

    [Common.keeper_runtime_store] owns the dirname and placement of every
    keeper runtime store. Python and shell consumers cannot read an OCaml
    variant, so they assembled the same paths from their own string literals
    and a rename in [Common] left them reading a directory that no longer
    exists — a readiness gate that finds nothing reports the same "clean" as
    one that finds nothing wrong (#27583).

    Nothing is committed: consumers run this and read what the compiler owns,
    so there is no second copy to drift. *)

let placement_name = function
  | Common.Keeper_scoped_dated -> "keeper_scoped_dated"
  | Common.Keeper_scoped_versioned -> "keeper_scoped_versioned"
  | Common.Keeper_scoped_rotated -> "keeper_scoped_rotated"
  | Common.Workspace_scoped -> "workspace_scoped"
;;

let store_json store =
  `Assoc
    [ "dirname", `String (Common.keeper_runtime_store_dirname store)
    ; "placement", `String (placement_name (Common.keeper_runtime_store_placement store))
    ]
;;

let () =
  `Assoc
    [ "schema", `String "masc.keeper_runtime_store_layout.v1"
    ; "stores", `List (List.map store_json Common.keeper_runtime_stores)
    ]
  |> Yojson.Safe.pretty_to_channel stdout;
  output_char stdout '\n'
;;
