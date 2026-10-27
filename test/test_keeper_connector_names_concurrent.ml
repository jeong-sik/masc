(* [Keeper_connector_names] keeps each connector file as one table in memory
   and guards the tables, and the appends to the files, with one lock.
   [remember] holds it across the directory creation and the append, and the
   first [recall], [remember] or [entries] on a file holds it across the read
   of the whole file. [Fs_compat] runs those on a worker thread, so the calling
   fiber suspends with the lock held. The fibers of a domain share one thread,
   so a lock that raises when the thread that holds it locks it again fails the
   next caller of the store instead of making it wait. A gateway handler that
   asked for a name while another handler was still writing one raised
   Sys_error "Mutex.lock: Resource deadlock avoided". *)
open Alcotest
module Names = Masc.Keeper_connector_names

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

(* The store never forgets a file it has read, so every case gets a base
   directory of its own and starts cold. *)
let with_base f =
  let base_dir = Filename.temp_dir "connector-names-concurrent-" "" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_dir)
    (fun () ->
      Eio_main.run (fun env ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        Fun.protect ~finally:Fs_compat.clear_fs (fun () -> f ~base_dir)))

let connector = "slack"
let scope = Names.Person

let row_json (id, name) =
  Yojson.Safe.to_string
    (`Assoc [ "id", `String id; "name", `String name; "ts", `Float 0. ])

(* The rows of the durable file, in the order they were appended. *)
let persisted_rows ~base_dir =
  let path = Names.path ~base_dir ~connector ~scope in
  if not (Sys.file_exists path) then []
  else
    Fs_compat.load_file path
    |> String.split_on_char '\n'
    |> List.filter (fun line -> String.trim line <> "")
    |> List.map (fun line ->
         match Yojson.Safe.from_string line with
         | `Assoc fields ->
           (match List.assoc_opt "id" fields, List.assoc_opt "name" fields with
            | Some (`String id), Some (`String name) -> id, name
            | _ -> failf "row has no id/name pair: %s" line)
         | _ -> failf "row is not an object: %s" line)

(* A store file written before the process has read it. *)
let write_store ~base_dir rows =
  let path = Names.path ~base_dir ~connector ~scope in
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc ->
    List.iter (fun row -> output_string oc (row_json row ^ "\n")) rows)

let sorted = List.sort compare

let test_recall_waits_for_a_remember_in_flight () =
  with_base (fun ~base_dir ->
    let writer_started = ref false in
    let writer_finished = ref false in
    let reader_saw = ref None in
    Eio.Fiber.both
      (fun () ->
        writer_started := true;
        Names.remember ~base_dir ~connector ~scope ~id:"U1" ~name:"Vincent" ();
        writer_finished := true)
      (fun () ->
        (* The second fiber only runs once the first one suspends. If
           [remember] never suspended it would already be finished here, and
           the recall below would prove nothing. *)
        let writer_was_suspended = !writer_started && not !writer_finished in
        let recalled = Names.recall ~base_dir ~connector ~scope ~id:"U1" in
        reader_saw := Some (writer_was_suspended, recalled, !writer_finished));
    match !reader_saw with
    | None -> fail "the reader did not run"
    | Some (writer_was_suspended, recalled, finished) ->
      check bool "the writer was suspended inside remember when recall was called"
        true writer_was_suspended;
      check (option string) "recall returns the name the writer was recording"
        (Some "Vincent") recalled;
      check bool "recall waited for the writer to finish" true finished)

let test_remembers_for_different_ids_both_land () =
  with_base (fun ~base_dir ->
    let people = [ "U1", "Vincent"; "U2", "Yuna" ] in
    let callers = List.length people in
    let asked = ref 0 in
    let asked_when_served = ref [] in
    let write (id, name) =
      incr asked;
      Names.remember ~base_dir ~connector ~scope ~id ~name ();
      asked_when_served := !asked :: !asked_when_served
    in
    Eio.Fiber.List.iter write people;
    (* The first append suspends inside the lock, so the second caller has
       asked before the first is served. An append that never suspended would
       serve the first caller after one ask and the test would prove nothing. *)
    check (list int) "every caller asked before any was served"
      (List.init callers (fun _ -> callers)) !asked_when_served;
    check (list (pair string string)) "entries lists both people" (sorted people)
      (Names.entries ~base_dir ~connector ~scope);
    check (list (pair string string)) "the file holds each person once"
      (sorted people) (sorted (persisted_rows ~base_dir)))

let test_remembers_of_one_name_append_one_row () =
  with_base (fun ~base_dir ->
    let callers = 2 in
    let asked = ref 0 in
    let asked_when_served = ref [] in
    let write () =
      incr asked;
      Names.remember ~base_dir ~connector ~scope ~id:"U1" ~name:"Vincent" ();
      asked_when_served := !asked :: !asked_when_served
    in
    Eio.Fiber.List.iter write (List.init callers (fun _ -> ()));
    check (list int) "every caller asked before any was served"
      (List.init callers (fun _ -> callers)) !asked_when_served;
    (* The second caller checks the known name after the first has appended
       and recorded it. Checking before the append would write the row twice. *)
    check (list (pair string string)) "one row for one observed name"
      [ "U1", "Vincent" ] (persisted_rows ~base_dir);
    Names.remember ~base_dir ~connector ~scope ~id:"U1" ~name:"Vincent" ();
    check (list (pair string string)) "a later repeat still appends nothing"
      [ "U1", "Vincent" ] (persisted_rows ~base_dir);
    check (list (pair string string)) "entries lists the name once"
      [ "U1", "Vincent" ]
      (Names.entries ~base_dir ~connector ~scope))

let test_readers_wait_for_a_cold_load_in_flight () =
  with_base (fun ~base_dir ->
    write_store ~base_dir [ "U1", "Vince"; "U2", "Yuna"; "U1", "Vincent" ];
    let first_started = ref false in
    let first_finished = ref false in
    let first_saw = ref None in
    let second_saw = ref None in
    Eio.Fiber.both
      (fun () ->
        first_started := true;
        first_saw := Some (Names.recall ~base_dir ~connector ~scope ~id:"U1");
        first_finished := true)
      (fun () ->
        let first_was_suspended = !first_started && not !first_finished in
        let listed = Names.entries ~base_dir ~connector ~scope in
        second_saw := Some (first_was_suspended, listed, !first_finished));
    check (option (option string)) "the first reader read the newest name"
      (Some (Some "Vincent")) !first_saw;
    match !second_saw with
    | None -> fail "the second reader did not run"
    | Some (first_was_suspended, listed, finished) ->
      check bool "the first reader was suspended in the file read when entries was called"
        true first_was_suspended;
      check (list (pair string string)) "entries lists the latest names by id"
        [ "U1", "Vincent"; "U2", "Yuna" ] listed;
      check bool "entries waited for the first reader to finish" true finished)

let () =
  run "keeper connector names concurrent"
    [ ( "directory lock"
      , [ test_case "recall waits for a remember in flight" `Quick
            test_recall_waits_for_a_remember_in_flight
        ; test_case "remembers for different ids both land" `Quick
            test_remembers_for_different_ids_both_land
        ; test_case "remembers of one name append one row" `Quick
            test_remembers_of_one_name_append_one_row
        ; test_case "readers wait for a cold load in flight" `Quick
            test_readers_wait_for_a_cold_load_in_flight
        ] )
    ]
