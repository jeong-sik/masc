(* [Tool_metrics_store] keeps one open SQLite handle behind a process-wide lock.
   The first call for a masc root opens the store while it holds that lock, and
   the open starts with [Fs_compat.mkdir_p], which suspends the calling fiber
   (Eio runs the mkdir on a worker thread). Every fiber of a domain shares one
   thread, and a [Stdlib.Mutex] raises
   [Sys_error "Mutex.lock: Resource deadlock avoided"] when the thread that
   holds it locks it again. The next fiber that touched the store raised
   instead of waiting. These cases put fibers on a store that is not open yet. *)
open Alcotest

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let row ~record_id : Tool_metrics_store.row =
  { record_id
  ; ts = 1000.0
  ; tool_name = "concurrent-tool"
  ; disposition = "completed"
  ; duration_ms = 1.0
  }

let get_ok label = function
  | Ok value -> value
  | Error error -> failf "%s: %s" label error

let record_ids ~masc_root =
  Tool_metrics_store.read_recent ~masc_root ~n:10 ()
  |> get_ok "read rows back"
  |> List.map (fun (row : Tool_metrics_store.row) -> row.record_id)
  |> List.sort String.compare

(* No store is open and no masc root exists when [f] starts, so the first call
   has to create the directory through Eio before it can open the database. *)
let with_cold_store f =
  let base = Filename.temp_dir "tool-metrics-store-concurrent-" "" in
  Fun.protect
    ~finally:(fun () ->
      Tool_metrics_store.reset_for_testing ();
      rm_rf base)
    (fun () ->
      Tool_metrics_store.reset_for_testing ();
      Eio_main.run (fun env ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        Fun.protect ~finally:Fs_compat.clear_fs (fun () -> f ~base)))

let test_inserts_on_a_cold_store_both_succeed () =
  with_cold_store (fun ~base ->
    let masc_root = Filename.concat base ".masc" in
    let asked = ref 0 in
    let asked_when_served = ref [] in
    let insert record_id =
      incr asked;
      let result = Tool_metrics_store.insert ~masc_root (row ~record_id) in
      asked_when_served := !asked :: !asked_when_served;
      result
    in
    let ids = [ "row-a"; "row-b" ] in
    let results = Eio.Fiber.List.map insert ids in
    (* The first insert suspends while it opens the store, so the second one
       has asked before either is served. An open that never suspended would
       serve the first caller after one ask and the case would prove nothing. *)
    check (list int) "every caller asked before any was served"
      (List.map (fun _ -> List.length ids) ids)
      !asked_when_served;
    List.iter2
      (fun record_id result -> get_ok ("insert " ^ record_id) result)
      ids results;
    check (list string) "both rows are readable" ids (record_ids ~masc_root))

let test_another_masc_root_waits_instead_of_raising () =
  with_cold_store (fun ~base ->
    let root_a = Filename.concat base "root-a" in
    let root_b = Filename.concat base "root-b" in
    let results =
      Eio.Fiber.List.map
        (fun (masc_root, record_id) ->
          Tool_metrics_store.insert ~masc_root (row ~record_id))
        [ root_a, "row-in-a"; root_b, "row-in-b" ]
    in
    List.iter (get_ok "insert into its own root") results;
    (* The second caller switched the open handle to its own root. Each root
       keeps the row that was written for it. *)
    check (list string) "root a holds its row" [ "row-in-a" ]
      (record_ids ~masc_root:root_a);
    check (list string) "root b holds its row" [ "row-in-b" ]
      (record_ids ~masc_root:root_b))

let test_reset_waits_for_an_open_in_flight () =
  with_cold_store (fun ~base ->
    let masc_root = Filename.concat base ".masc" in
    let finished = ref [] in
    Eio.Fiber.both
      (fun () ->
        Tool_metrics_store.insert ~masc_root (row ~record_id:"row-before-reset")
        |> get_ok "insert while the store opens";
        finished := "insert" :: !finished)
      (fun () ->
        Tool_metrics_store.reset_for_testing ();
        finished := "reset" :: !finished);
    check (list string) "the reset ran after the open it waited for"
      [ "insert"; "reset" ] (List.rev !finished);
    check (list string) "the row survived the reset" [ "row-before-reset" ]
      (record_ids ~masc_root))

(* No scheduler runs here, so the lock takes its plain-mutex path. The case
   passes with either lock; it pins that callers outside Eio keep working. *)
let test_store_works_outside_eio () =
  let base = Filename.temp_dir "tool-metrics-store-concurrent-" "" in
  Fun.protect
    ~finally:(fun () ->
      Tool_metrics_store.reset_for_testing ();
      rm_rf base)
    (fun () ->
      Tool_metrics_store.reset_for_testing ();
      let masc_root = Filename.concat base ".masc" in
      Tool_metrics_store.insert ~masc_root (row ~record_id:"row-outside-eio")
      |> get_ok "insert outside Eio";
      check (list string) "the row is readable" [ "row-outside-eio" ]
        (record_ids ~masc_root))

let () =
  run "tool metrics store concurrent"
    [ ( "cold store"
      , [ test_case "inserts on a cold store both succeed" `Quick
            test_inserts_on_a_cold_store_both_succeed
        ; test_case "another masc root waits instead of raising" `Quick
            test_another_masc_root_waits_instead_of_raising
        ; test_case "reset waits for an open in flight" `Quick
            test_reset_waits_for_an_open_in_flight
        ] )
    ; ( "outside eio"
      , [ test_case "the store works without a scheduler" `Quick
            test_store_works_outside_eio
        ] )
    ]
