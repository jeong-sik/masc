(** Surface destinations for the terminal strip and keys. *)

open Masc_tui_types

(* One mapping for the strip highlight and Tab family. Every surface is named
   so a new surface must choose its destination explicitly. *)
let surface_ring_family (view : surface) =
  match view with
  | Keepers _ -> Keepers Keeper_list
  | Verification | Harness | Approvals | Board -> Planning
  | Changes | Schedules | Fusion | Memory -> Keepers Keeper_list
  | Runtime | Acting | System_logs -> Config
  | Code -> Repositories
  | Resources | Tools | Clients | Connectors | Lanes -> Lanes
  | Metrics -> Overview
  | Overview -> Overview
  | Planning -> Planning
  | Repositories -> Repositories
  | Config -> Config

let surface_ring_index (view : surface) =
  let ring = surface_ring in
  let family = surface_ring_family view in
  let rec find i = function
    | [] -> 0
    | (surface, _) :: rest -> if surface = family then i else find (i + 1) rest
  in
  find 0 ring
;;
