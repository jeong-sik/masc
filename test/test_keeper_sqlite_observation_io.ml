(* Step helpers shared by the receiver journals, against real SQLite. *)
module Io = Masc.Keeper_sqlite_observation_io

type failure = { operation : string; detail : string }

let error ~operation ~detail = { operation; detail }
let on_cleanup ~operation:_ ~detail:_ = ()

let starts_with ~prefix text =
  String.length text >= String.length prefix
  && String.equal (String.sub text 0 (String.length prefix)) prefix

let with_memory_db f =
  let db = Sqlite3.db_open ":memory:" in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close db : bool)) (fun () -> f db)

let run db sql =
  match Sqlite3.exec db sql with
  | Sqlite3.Rc.OK -> ()
  | rc -> Alcotest.failf "setup %s failed: %s" sql (Sqlite3.Rc.to_string rc)

let step_of_first_row db sql =
  let stmt = Sqlite3.prepare db sql in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt : Sqlite3.Rc.t))
    (fun () -> Io.step stmt)

let test_step_classifies () =
  with_memory_db (fun db ->
    run db "CREATE TABLE t(v INTEGER)";
    (match step_of_first_row db "SELECT 1" with
     | Io.Row -> ()
     | Io.Done | Io.Failed _ -> Alcotest.fail "SELECT 1 must be Row");
    (match step_of_first_row db "SELECT v FROM t" with
     | Io.Done -> ()
     | Io.Row | Io.Failed _ -> Alcotest.fail "empty SELECT must be Done");
    (match step_of_first_row db "INSERT INTO t VALUES(1)" with
     | Io.Done -> ()
     | Io.Row | Io.Failed _ -> Alcotest.fail "INSERT must be Done");
    run db "CREATE UNIQUE INDEX t_v ON t(v)";
    match step_of_first_row db "INSERT INTO t VALUES(1)" with
    | Io.Failed rc ->
        Alcotest.(check string) "constraint code" "CONSTRAINT" (Sqlite3.Rc.to_string rc)
    | Io.Row | Io.Done -> Alcotest.fail "duplicate insert must be Failed")

let done_ db sql =
  let stmt = Sqlite3.prepare db sql in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt : Sqlite3.Rc.t))
    (fun () -> Io.done_ ~error db stmt ~operation:"op")

let test_done_accepts_only_done () =
  with_memory_db (fun db ->
    run db "CREATE TABLE t(v INTEGER UNIQUE)";
    (match done_ db "INSERT INTO t VALUES(1)" with
     | Ok () -> ()
     | Error failure -> Alcotest.failf "DONE must be Ok: %s" failure.detail);
    (match done_ db "SELECT v FROM t" with
     | Ok () -> Alcotest.fail "ROW must be Error"
     | Error failure ->
         Alcotest.(check string) "operation" "op" failure.operation;
         Alcotest.(check bool) "detail names ROW" true
           (starts_with ~prefix:"ROW:" failure.detail));
    match done_ db "INSERT INTO t VALUES(1)" with
    | Ok () -> Alcotest.fail "CONSTRAINT must be Error"
    | Error failure ->
        Alcotest.(check bool) "detail names CONSTRAINT" true
          (starts_with ~prefix:"CONSTRAINT:" failure.detail))

let test_done_reports_busy () =
  let path = Filename.temp_file "keeper_sqlite_observation_io_" ".sqlite3" in
  let holder = Sqlite3.db_open path in
  let writer = Sqlite3.db_open path in
  Fun.protect ~finally:(fun () ->
    ignore (Sqlite3.db_close writer : bool);
    ignore (Sqlite3.db_close holder : bool);
    Sys.remove path) (fun () ->
    run holder "CREATE TABLE t(v INTEGER)";
    run holder "BEGIN IMMEDIATE";
    match done_ writer "INSERT INTO t VALUES(1)" with
    | Ok () -> Alcotest.fail "BUSY must be Error"
    | Error failure ->
        Alcotest.(check bool) "detail names BUSY" true
          (starts_with ~prefix:"BUSY:" failure.detail))

let scalar db sql = Io.scalar ~error ~on_cleanup db sql

let test_scalar_one_row () =
  with_memory_db (fun db ->
    match scalar db "SELECT 7" with
    | Ok (Sqlite3.Data.INT 7L) -> ()
    | Ok _ -> Alcotest.fail "wrong value"
    | Error failure -> Alcotest.failf "unexpected error: %s" failure.detail)

let test_scalar_rejects_zero_and_extra_rows () =
  with_memory_db (fun db ->
    run db "CREATE TABLE t(v INTEGER)";
    (match scalar db "SELECT v FROM t" with
     | Ok _ -> Alcotest.fail "zero rows must be Error"
     | Error failure ->
         Alcotest.(check string) "operation" "scalar" failure.operation;
         Alcotest.(check bool) "detail names DONE" true
           (starts_with ~prefix:"DONE:" failure.detail));
    run db "INSERT INTO t VALUES(1)";
    run db "INSERT INTO t VALUES(2)";
    match scalar db "SELECT v FROM t ORDER BY v" with
    | Ok _ -> Alcotest.fail "a second row must be Error"
    | Error failure ->
        Alcotest.(check string) "operation" "scalar end" failure.operation;
        Alcotest.(check bool) "detail names ROW" true
          (starts_with ~prefix:"ROW:" failure.detail))

let test_scalar_prepare_failure () =
  with_memory_db (fun db ->
    match scalar db "SELECT nope FROM missing" with
    | Ok _ -> Alcotest.fail "bad SQL must be Error"
    | Error failure -> Alcotest.(check string) "operation" "scalar" failure.operation)

let () =
  Alcotest.run "keeper_sqlite_observation_io"
    [ ( "step",
        [ Alcotest.test_case "classifies ROW, DONE and failure" `Quick test_step_classifies ] );
      ( "done_",
        [ Alcotest.test_case "only DONE is Ok" `Quick test_done_accepts_only_done;
          Alcotest.test_case "BUSY is Error" `Quick test_done_reports_busy ] );
      ( "scalar",
        [ Alcotest.test_case "one row" `Quick test_scalar_one_row;
          Alcotest.test_case "zero and extra rows" `Quick
            test_scalar_rejects_zero_and_extra_rows;
          Alcotest.test_case "prepare failure" `Quick test_scalar_prepare_failure ] ) ]
