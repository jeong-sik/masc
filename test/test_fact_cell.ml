(** [Fact_cell]: one fact kept in memory beside the file that holds it.

    The file here is a counter of rows and the fact is that count. A writer
    sees the cell, adds a row, and settles the cell; a reader fills it; a
    remover empties the file and forgets the cell. The interleavings are
    written out one by one: a fill takes its read as a function, so whatever
    a test runs inside that function happens between the fill's look at the
    cell and its compare-and-set.

    The invariant every test ends on: a filled cell holds the file's count. *)

open Alcotest

type file = { mutable rows : int }

let slot_testable =
  testable
    (fun formatter -> function
      | Fact_cell.Unfilled -> Format.pp_print_string formatter "Unfilled"
      | Fact_cell.Filled rows -> Format.fprintf formatter "Filled %d" rows)
    ( = )
;;

let filled_testable =
  testable
    (fun formatter -> function
      | Fact_cell.Held rows -> Format.fprintf formatter "Held %d" rows
      | Fact_cell.Read_and_kept rows -> Format.fprintf formatter "Read_and_kept %d" rows
      | Fact_cell.Read_not_kept rows -> Format.fprintf formatter "Read_not_kept %d" rows
      | Fact_cell.Read_failed reason -> Format.fprintf formatter "Read_failed %s" reason)
    ( = )
;;

let slot_of cell = Fact_cell.slot (Fact_cell.see cell)
let generation_of cell = Fact_cell.generation (Fact_cell.see cell)
let read file () = Ok file.rows
let fill file cell = Fact_cell.fill cell ~read:(read file)

(* A whole write: the cell is seen, the row goes to the file, the cell is
   settled. *)
let write file cell =
  let seen = Fact_cell.see cell in
  file.rows <- file.rows + 1;
  Fact_cell.settle cell seen ~step:(fun rows -> Some (rows + 1))
;;

let holds_the_file file cell =
  match slot_of cell with
  | Fact_cell.Unfilled -> ()
  | Fact_cell.Filled rows -> check int "a filled cell holds the file's count" file.rows rows
;;

let test_a_new_cell_claims_nothing () =
  let cell : int Fact_cell.t = Fact_cell.make () in
  check slot_testable "unfilled" Fact_cell.Unfilled (slot_of cell);
  check (option int) "no value" None (Fact_cell.held cell)
;;

let test_a_fill_keeps_what_it_read () =
  let file = { rows = 3 } in
  let cell = Fact_cell.make () in
  check filled_testable "the first fill reads" (Fact_cell.Read_and_kept 3) (fill file cell);
  let reads = ref 0 in
  let counted () =
    incr reads;
    Ok file.rows
  in
  check
    filled_testable
    "the second fill is handed the kept value"
    (Fact_cell.Held 3)
    (Fact_cell.fill cell ~read:counted);
  check int "and reads nothing" 0 !reads;
  check (option int) "held" (Some 3) (Fact_cell.held cell)
;;

let test_a_failed_read_keeps_nothing () =
  let cell : int Fact_cell.t = Fact_cell.make () in
  let before = generation_of cell in
  check
    filled_testable
    "the failure is the answer"
    (Fact_cell.Read_failed "no file")
    (Fact_cell.fill cell ~read:(fun () -> Error "no file"));
  check slot_testable "the cell is still unfilled" Fact_cell.Unfilled (slot_of cell);
  check int "and is the cell it was" before (generation_of cell)
;;

let test_a_write_moves_a_filled_cell () =
  let file = { rows = 3 } in
  let cell = Fact_cell.make () in
  ignore (fill file cell : (int, string) Fact_cell.filled);
  write file cell;
  check slot_testable "the cell counts the new row" (Fact_cell.Filled 4) (slot_of cell);
  holds_the_file file cell
;;

(* A writer knows its own row and not the rows before it. *)
let test_a_write_does_not_fill () =
  let file = { rows = 3 } in
  let cell = Fact_cell.make () in
  write file cell;
  check slot_testable "still unfilled" Fact_cell.Unfilled (slot_of cell)
;;

let test_a_write_that_cannot_tell_the_value_forgets () =
  let file = { rows = 3 } in
  let cell = Fact_cell.make () in
  ignore (fill file cell : (int, string) Fact_cell.filled);
  let seen = Fact_cell.see cell in
  file.rows <- file.rows + 1;
  Fact_cell.settle cell seen ~step:(fun _ -> None);
  check slot_testable "unfilled" Fact_cell.Unfilled (slot_of cell);
  check filled_testable "the next fill reads the file" (Fact_cell.Read_and_kept 4) (fill file cell)
;;

(* The fill read the file before the row was there. The write settled an
   unfilled cell meanwhile, and that alone has to turn the fill away. *)
let test_a_write_during_a_fill_keeps_the_fill_out () =
  let file = { rows = 3 } in
  let cell = Fact_cell.make () in
  let answer =
    Fact_cell.fill cell ~read:(fun () ->
      let rows = file.rows in
      write file cell;
      Ok rows)
  in
  check filled_testable "the fill has its own answer" (Fact_cell.Read_not_kept 3) answer;
  check slot_testable "which the cell does not hold" Fact_cell.Unfilled (slot_of cell);
  holds_the_file file cell
;;

(* The other order of the same race: the fill lands between the write's look
   at the cell and its settling. The fill's value may or may not count the
   row, and the write cannot tell which. *)
let test_a_fill_during_a_write_is_forgotten () =
  List.iter
    (fun fill_reads_after_the_row ->
       let file = { rows = 3 } in
       let cell = Fact_cell.make () in
       let seen = Fact_cell.see cell in
       if not fill_reads_after_the_row then ignore (fill file cell : (int, string) Fact_cell.filled);
       file.rows <- file.rows + 1;
       if fill_reads_after_the_row then ignore (fill file cell : (int, string) Fact_cell.filled);
       Fact_cell.settle cell seen ~step:(fun rows -> Some (rows + 1));
       check slot_testable "unfilled" Fact_cell.Unfilled (slot_of cell);
       holds_the_file file cell)
    [ false; true ]
;;

(* The same race with a cell that was filled before the write began: the
   write saw the value, something replaced it, and adding the row to the
   value the write saw would count the row once or twice. *)
let test_a_refill_during_a_write_is_forgotten () =
  let file = { rows = 3 } in
  let cell = Fact_cell.make () in
  ignore (fill file cell : (int, string) Fact_cell.filled);
  let seen = Fact_cell.see cell in
  file.rows <- file.rows + 1;
  Fact_cell.forget cell;
  check filled_testable "a fill reads the row" (Fact_cell.Read_and_kept 4) (fill file cell);
  Fact_cell.settle cell seen ~step:(fun rows -> Some (rows + 1));
  check slot_testable "unfilled, not five" Fact_cell.Unfilled (slot_of cell)
;;

let test_a_removal_forgets () =
  let file = { rows = 3 } in
  let cell = Fact_cell.make () in
  ignore (fill file cell : (int, string) Fact_cell.filled);
  file.rows <- 0;
  Fact_cell.forget cell;
  check slot_testable "unfilled" Fact_cell.Unfilled (slot_of cell);
  check filled_testable "the next fill reads the file" (Fact_cell.Read_and_kept 0) (fill file cell)
;;

(* The fill read the file before the removal. Forgetting an unfilled cell
   still has to turn it away. *)
let test_a_removal_during_a_fill_keeps_the_fill_out () =
  let file = { rows = 3 } in
  let cell = Fact_cell.make () in
  let answer =
    Fact_cell.fill cell ~read:(fun () ->
      let rows = file.rows in
      file.rows <- 0;
      Fact_cell.forget cell;
      Ok rows)
  in
  check filled_testable "the fill has its own answer" (Fact_cell.Read_not_kept 3) answer;
  check slot_testable "which the cell does not hold" Fact_cell.Unfilled (slot_of cell)
;;

(* A write whose row leaves the value as it was still moves the cell: a fill
   that looked before the write must not be kept after it. *)
let test_a_write_that_changes_no_value_still_moves_the_cell () =
  let cell = Fact_cell.make () in
  ignore (Fact_cell.fill cell ~read:(fun () -> Ok 3) : (int, string) Fact_cell.filled);
  let before = Fact_cell.see cell in
  Fact_cell.settle cell before ~step:(fun rows -> Some rows);
  check slot_testable "the same value" (Fact_cell.Filled 3) (slot_of cell);
  check bool "in a new state" true (Fact_cell.generation (Fact_cell.see cell) > Fact_cell.generation before)
;;

(* Writers take turns (the store's mutex); readers and removers do not wait
   for anyone. After everyone is done the cell is unfilled or holds the
   file's count, whatever the order was. *)
let test_readers_writers_and_removers_together () =
  let rounds = 300 in
  for _ = 1 to rounds do
    let file = Atomic.make 0 in
    let cell = Fact_cell.make () in
    let writers_turn = Mutex.create () in
    let start = Atomic.make false in
    let wait_for_start () =
      while not (Atomic.get start) do
        Domain.cpu_relax ()
      done
    in
    let writer () =
      wait_for_start ();
      for _ = 1 to 20 do
        Mutex.protect writers_turn (fun () ->
          let seen = Fact_cell.see cell in
          Atomic.incr file;
          Fact_cell.settle cell seen ~step:(fun rows -> Some (rows + 1)))
      done
    in
    let reader () =
      wait_for_start ();
      for _ = 1 to 40 do
        ignore
          (Fact_cell.fill cell ~read:(fun () -> Ok (Atomic.get file))
           : (int, string) Fact_cell.filled)
      done
    in
    let remover () =
      wait_for_start ();
      for _ = 1 to 5 do
        Mutex.protect writers_turn (fun () -> Atomic.set file 0);
        Fact_cell.forget cell
      done
    in
    let domains = List.map Domain.spawn [ writer; writer; reader; reader; remover ] in
    Atomic.set start true;
    List.iter Domain.join domains;
    match Fact_cell.held cell with
    | None -> ()
    | Some rows -> check int "a filled cell holds the file's count" (Atomic.get file) rows
  done
;;

(* Nothing in this executable says it before this test. *)
let test_a_process_keeps_facts_once_it_says_so () =
  check bool "not before it is said" false (Fact_cell.kept_in_this_process ());
  Fact_cell.keep_in_this_process ();
  check bool "once it is said" true (Fact_cell.kept_in_this_process ())
;;

let () =
  run
    "fact_cell"
    [ ( "one party"
      , [ test_case "a new cell claims nothing" `Quick test_a_new_cell_claims_nothing
        ; test_case "a fill keeps what it read" `Quick test_a_fill_keeps_what_it_read
        ; test_case "a failed read keeps nothing" `Quick test_a_failed_read_keeps_nothing
        ; test_case "a write moves a filled cell" `Quick test_a_write_moves_a_filled_cell
        ; test_case "a write does not fill" `Quick test_a_write_does_not_fill
        ; test_case
            "a write that cannot tell the value forgets"
            `Quick
            test_a_write_that_cannot_tell_the_value_forgets
        ; test_case "a removal forgets" `Quick test_a_removal_forgets
        ; test_case
            "a write that changes no value still moves the cell"
            `Quick
            test_a_write_that_changes_no_value_still_moves_the_cell
        ] )
    ; ( "two parties"
      , [ test_case
            "a write during a fill keeps the fill out"
            `Quick
            test_a_write_during_a_fill_keeps_the_fill_out
        ; test_case
            "a fill during a write is forgotten"
            `Quick
            test_a_fill_during_a_write_is_forgotten
        ; test_case
            "a refill during a write is forgotten"
            `Quick
            test_a_refill_during_a_write_is_forgotten
        ; test_case
            "a removal during a fill keeps the fill out"
            `Quick
            test_a_removal_during_a_fill_keeps_the_fill_out
        ] )
    ; ( "every party"
      , [ test_case
            "readers, writers and removers together"
            `Quick
            test_readers_writers_and_removers_together
        ] )
    ; ( "the process that keeps facts"
      , [ test_case
            "a process keeps facts once it says so"
            `Quick
            test_a_process_keeps_facts_once_it_says_so
        ] )
    ]
;;
