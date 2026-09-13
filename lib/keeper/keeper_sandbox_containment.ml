(** Keeper_sandbox_containment — see .mli for contract. *)

let check_target ~config ~sandbox_roots ~target =
  match
    Keeper_alerting_path.resolve_keeper_target_path
      ~config
      ~sandbox_roots
      ~raw_path:target
  with
  | Ok _ -> Ok ()
  | Error rejection ->
    Error (Keeper_alerting_path.rejection_to_user_message rejection)

(* task-634 / #26289 (operator decision, ask938aaf519a5c543e: read_superset)
   — the READ authority widens to the same objective roots the exec
   lane already judges ([/tmp], the documented sandbox workspace root),
   so a path Execute is allowed to touch there answers to the same
   containment as a Read of it. The WRITE authority (plain
   [check_target] above, and every other caller of
   [Keeper_alerting_path.sandbox_roots]) is unchanged — this widening
   is read-only and lives only in this one call site. *)
let read_sandbox_roots ~meta =
  let write_roots = Keeper_alerting_path.sandbox_roots ~meta in
  let exec_objective_roots = [ "/tmp"; (Host_config.host ()).sandbox_workspace_root ] in
  write_roots
  @ List.filter
      (fun root -> not (List.mem root write_roots))
      exec_objective_roots
;;

let check_read_target ~config ~meta ~target =
  check_target ~config ~sandbox_roots:(read_sandbox_roots ~meta) ~target

