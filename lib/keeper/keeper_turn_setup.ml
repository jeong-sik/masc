(** Keeper_turn_setup -- keeper setup helpers.

    Extracted from keeper_turn.ml. Provides [ensure_keeper_exists]. *)

open Keeper_types

let ensure_keeper_exists
    ~(ctx : _ context)
    ~name
  : (keeper_meta, string) result =
  match read_meta_resolved ctx.config name with
  | Error e -> Error e
  | Ok (Some (_resolved_name, m)) -> Ok m
  | Ok None -> Error (Printf.sprintf "keeper not found: %s" name)
