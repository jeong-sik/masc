(* Callers share the carried-tally lock and must receive the same canonical
   rows, regardless of whether the storage read suspends their fiber. *)
open Alcotest
open Masc
module Change = Keeper_tool_call_file_change

let window_hours = 1.0

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let log_rows ~keeper_name tool_names =
  List.iter
    (fun tool_name ->
      Keeper_tool_call_log.log_call
        ~keeper_name ~tool_name
        ~input:(`Assoc []) ~output_text:"out"
        ~wire_outcome:Tool_result.Ok ~duration_ms:1.0 ())
    tool_names

(* The store is opened under [base] before [f] runs, and [f] writes its rows
   before it asks for a tally, so each (keeper, window) key starts without a
   carried tally. *)
let with_store f =
  let base = Filename.temp_dir "keeper-tool-call-file-change-" "" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_tool_call_log.reset_for_testing ();
      rm_rf base)
    (fun () ->
      Keeper_tool_call_log.reset_for_testing ();
      Eio_main.run (fun env ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        Fun.protect ~finally:Fs_compat.clear_fs (fun () ->
          Keeper_tool_call_log.init ~base_path:base ();
          f ~base)))

let tally ?keeper_name () =
  Keeper_tool_call_log.file_change_tally ?keeper_name ~window_hours ()

(* The same store with every carried tally dropped, so the next call for any
   key folds the rows from the start. *)
let drop_carried_tallies ~base =
  Keeper_tool_call_log.reset_for_testing ();
  Keeper_tool_call_log.init ~base_path:base ()

let check_same_tally label expected actual =
  check bool label true (expected = actual)

let test_callers_of_one_key_get_the_sequential_tally () =
  with_store (fun ~base ->
    log_rows ~keeper_name:"alice" [ "first"; "second"; "third" ];
    log_rows ~keeper_name:"bob" [ "other" ];
    let sequential = tally ~keeper_name:"alice" () in
    check int "the sequential call saw alice's three rows" 3
      (Change.rows_counted sequential);
    check int "a whole read agrees" 3
      (Change.rows_counted
         (Change.classify_all
            (Keeper_tool_call_log.read_window
               ~keeper_name:"alice" ~window_hours ())));
    drop_carried_tallies ~base;
    let callers = 4 in
    let results = Eio.Fiber.List.map
        (fun _ -> tally ~keeper_name:"alice" ()) (List.init callers Fun.id) in
    List.iter (check_same_tally "each caller gets the sequential tally" sequential)
      results)

let test_another_keeper_waits_instead_of_raising () =
  with_store (fun ~base ->
    log_rows ~keeper_name:"alice" [ "first"; "second" ];
    log_rows ~keeper_name:"bob" [ "other" ];
    let alice_sequential = tally ~keeper_name:"alice" () in
    let bob_sequential = tally ~keeper_name:"bob" () in
    check int "alice's rows" 2 (Change.rows_counted alice_sequential);
    check int "bob's rows" 1 (Change.rows_counted bob_sequential);
    drop_carried_tallies ~base;
    match
      Eio.Fiber.List.map
        (fun keeper_name -> tally ~keeper_name ())
        [ "alice"; "bob" ]
    with
    | [ alice; bob ] ->
      check_same_tally "alice's tally" alice_sequential alice;
      check_same_tally "bob's tally" bob_sequential bob
    | other -> failf "expected two tallies, got %d" (List.length other))

let test_reset_waits_for_a_fold_in_flight () =
  with_store (fun ~base ->
    log_rows ~keeper_name:"alice" [ "first"; "second" ];
    let sequential = tally ~keeper_name:"alice" () in
    drop_carried_tallies ~base;
    let finished = ref [] in
    let folded = ref None in
    Eio.Fiber.both
      (fun () ->
        folded := Some (tally ~keeper_name:"alice" ());
        finished := "tally" :: !finished)
      (fun () ->
        Keeper_tool_call_log.reset_for_testing ();
        finished := "reset" :: !finished);
    check (list string) "the reset ran after the fold it waited for"
      [ "tally"; "reset" ] (List.rev !finished);
    match !folded with
    | Some folded -> check_same_tally "the fold in flight was not disturbed" sequential folded
    | None -> fail "the fold did not finish")

let () =
  run "keeper tool call log file change concurrent"
    [ ( "carried tally"
      , [ test_case "callers of one key get the sequential tally" `Quick
            test_callers_of_one_key_get_the_sequential_tally
        ; test_case "another keeper waits instead of raising" `Quick
            test_another_keeper_waits_instead_of_raising
        ; test_case "reset waits for a fold in flight" `Quick
            test_reset_waits_for_a_fold_in_flight
        ] )
    ]
