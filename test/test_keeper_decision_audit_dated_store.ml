(** The decision-audit flush must land in the day file that reads this store.

    [.masc/decision_audit/<keeper>/YYYY-MM/DD.jsonl] is pruned by
    [Server_runtime_startup_maintenance.prune_shared_jsonl_stores], which
    resolves its cutoff through {!Dated_jsonl}. While the flush picked the day
    from a different calendar than the store does, a directory name denoted one
    day to the writer and another to the pruner: 39% of the 104803 records in
    the live store sat under a name that was not their own UTC day.

    The assertion is direct rather than a spelling check — a probe appended
    through {!Dated_jsonl} at the same base directory must land in the file the
    flush already wrote. A writer on a different calendar fails this within the
    UTC offset of midnight; a writer that agrees passes at every instant. *)

open Alcotest
module Audit = Masc.Keeper_decision_audit

let rec rm_rf path =
  match Sys.is_directory path with
  | true ->
    Array.iter (fun entry -> rm_rf (Filename.concat path entry)) (Sys.readdir path);
    Unix.rmdir path
  | false -> Sys.remove path
  | exception Sys_error _ -> ()
;;

(* [Dated_jsonl] guards each base_dir with an [Eio.Mutex], so these run inside
   an Eio context — the same one the heartbeat flush call site provides. *)
let with_base prefix body =
  Eio_main.run
  @@ fun _env ->
  let base_path = Filename.temp_dir prefix "" in
  Fun.protect ~finally:(fun () -> rm_rf base_path) (fun () -> body base_path)
;;

let record ~keeper_name ~wall_clock =
  Audit.make
    ~cycle_id:"cycle-1"
    ~keeper_name
    ~turn_verdict:
      (Masc.Keeper_world_observation.Run { reasons = Never_started, [] })
    ~wall_clock
    ()
;;

let audit_base_dir ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat (Common.masc_dir_from_base_path ~base_path) "decision_audit")
    keeper_name
;;

(* Every [YYYY-MM/DD.jsonl] below the store root, as a month/day pair. *)
let day_files base_dir =
  match Sys.is_directory base_dir with
  | false | (exception Sys_error _) -> []
  | true ->
    Sys.readdir base_dir
    |> Array.to_list
    |> List.concat_map (fun month ->
      let month_dir = Filename.concat base_dir month in
      match Sys.is_directory month_dir with
      | false | (exception Sys_error _) -> []
      | true ->
        Sys.readdir month_dir
        |> Array.to_list
        |> List.map (fun day -> Filename.concat month day))
    |> List.sort String.compare
;;

let test_flush_lands_where_the_store_reads () =
  with_base "decision-audit-dated" @@ fun base_path ->
  let keeper_name = "decision-audit-day-file" in
  (* flush_batch_size is 10, so 12 appends trip the batch condition instead of
     waiting out the 60s interval. *)
  for i = 1 to 12 do
    Audit.append ~keeper_name (record ~keeper_name ~wall_clock:(float_of_int i))
  done;
  Audit.flush_if_needed ~base_path ~keeper_name;
  let base_dir = audit_base_dir ~base_path ~keeper_name in
  let after_flush = day_files base_dir in
  check int "the flush wrote exactly one day file" 1 (List.length after_flush);
  let store = Dated_jsonl.create ~base_dir () in
  Dated_jsonl.append store (`Assoc [ "probe", `Bool true ]);
  check
    (list string)
    "the store appends into the file the flush already wrote"
    after_flush
    (day_files base_dir)
;;

(* The flush is the only writer, so the records it emits must be readable back
   through the store rather than merely present as bytes. *)
let test_flushed_records_are_store_readable () =
  with_base "decision-audit-readback" @@ fun base_path ->
  let keeper_name = "decision-audit-readback" in
  for i = 1 to 12 do
    Audit.append ~keeper_name (record ~keeper_name ~wall_clock:(float_of_int i))
  done;
  Audit.flush_if_needed ~base_path ~keeper_name;
  let store = Dated_jsonl.create ~base_dir:(audit_base_dir ~base_path ~keeper_name) () in
  check int "every buffered record is readable back" 12 (Dated_jsonl.count_entries store)
;;

let () =
  run
    "Keeper decision audit dated store"
    [ ( "layout"
      , [ test_case
            "flush and store agree on the day file"
            `Quick
            test_flush_lands_where_the_store_reads
        ; test_case
            "flushed records read back through the store"
            `Quick
            test_flushed_records_are_store_readable
        ] )
    ]
;;
