(** Surface destinations and availability for the terminal strip and keys. *)

open Masc_tui_types

let is_surface_active (state : state) (s : surface) =
  match s with
  | Approvals ->
      (* An entry that disappears says "nothing is waiting", which is the one
         thing the strip cannot say when it could not look. With the server
         unreachable every other surface drew "(load failed)" and this one
         left the ring, so the screen that holds the operator's decisions was
         the only one that read as settled. The entry stands until a reading
         says the lists are empty. *)
      state.view = Approvals
      || Masc_tui_approvals_model.approvals_surface_pending state > 0
      || not (Masc_tui_approvals_model.approvals_reading_current state)
  | _ -> true
;;

let visible_surface_ring (state : state) : (surface * string) list =
  List.filter (fun (s, _) -> is_surface_active state s) surface_ring
;;

(* One mapping for the strip highlight and Tab family. Every surface is named
   so a new surface must choose its destination explicitly. *)
let surface_ring_family (state : state) (view : surface) =
  match view with
  | Keepers _ -> Keepers Keeper_list
  | Verification | Harness | Approvals -> Planning
  | Connectors when Option.is_some (browser_lane_on_screen state) -> Config
  | Changes | Connectors | Schedules | Fusion | Memory -> Keepers Keeper_list
  | Runtime | Clients | Lanes | Acting | System_logs -> Config
  | Code -> Repositories
  | Resources | Tools -> Config
  | Metrics -> Metrics
  | Overview -> Overview
  | Board -> Board
  | Planning -> Planning
  | Repositories -> Repositories
  | Config -> Config

let visible_surface_ring_index (state : state) (view : surface) =
  let ring = visible_surface_ring state in
  let family = surface_ring_family state view in
  let rec find i = function
    | [] -> 0
    | (surface, _) :: rest -> if surface = family then i else find (i + 1) rest
  in
  find 0 ring
;;
