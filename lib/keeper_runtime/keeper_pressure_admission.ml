type block =
  | Fd of Keeper_fd_pressure.admission_block
  | Disk of Keeper_disk_pressure.admission_block

type decision =
  | Admitted
  | Blocked of block

(* fd-priority: when both resources block, surface fd (the more acute
   process-level exhaustion). Every pair of the fd x disk decision product is
   listed explicitly — no [_ ->] catch-all — so a new [admission_decision]
   variant in either module forces a compile error here instead of being
   silently absorbed. *)
let decide_with ~fd ~disk =
  match fd, disk with
  | Keeper_fd_pressure.Block b, Keeper_disk_pressure.Admit -> Blocked (Fd b)
  | Keeper_fd_pressure.Block b, Keeper_disk_pressure.Block _ -> Blocked (Fd b)
  | Keeper_fd_pressure.Admit, Keeper_disk_pressure.Block b -> Blocked (Disk b)
  | Keeper_fd_pressure.Admit, Keeper_disk_pressure.Admit -> Admitted
;;

let decide ~masc_root ~active_keepers () =
  let fd =
    Keeper_fd_pressure.admission_decision ~active_keepers ~starting_keepers:0 ()
  in
  let disk = Keeper_disk_pressure.admission_decision ~masc_root () in
  decide_with ~fd ~disk
;;

let block_kind = function
  | Fd b -> "fd:" ^ Keeper_fd_pressure.admission_block_kind b
  | Disk b -> "disk:" ^ Keeper_disk_pressure.admission_block_kind b
;;

let block_summary = function
  | Fd b -> Keeper_fd_pressure.admission_block_summary b
  | Disk b -> Keeper_disk_pressure.admission_block_summary b
;;

let turn_admission_skip_prefix = "turn_admission_blocked:"
let skip_reason block = turn_admission_skip_prefix ^ block_kind block
