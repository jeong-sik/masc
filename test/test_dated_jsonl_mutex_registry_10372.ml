(** Pin the file-scope mutex registry contract.

    The writers of one store directory take one mutex, whichever spelling
    reached the directory.  A handle asks for the mutex on each write, and
    the registry keeps it under the name the file system gives the
    directory.

    Tests pin:

    1. Different directories → distinct mutexes.
    2. A [Reader] leaves no registry entry and reads the store's rows.
    3. Two spellings share the mutex exactly when the file system says they
       are one directory: a trailing slash, a symbolic link at the root or
       below it, a relative path, a different letter case.
    4. A handle opened before its directory existed takes the directory's
       mutex once it is there; a directory that exists is asked about once.
    5. Behavioural: concurrent appends through two store
       instances at the same dir produce all-parseable lines,
       even with payloads larger than [PIPE_BUF].
    6. Each function that changes a store's files waits for the store's
       mutex: both appends, the prune of one store and the pass over the
       listed stores.
    7. Stores under one root take a mutex each. *)

open Alcotest

module D = Dated_jsonl

let counter = ref 0

let tmpdir prefix =
  incr counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s_%d_%d_%.0f" prefix !counter (Unix.getpid ())
         (Unix.gettimeofday ()))
  in
  Fs_compat.mkdir_p dir;
  dir


(* Every store here is a listed store under a fresh temporary root. The
   store's directory is [D.Store.dir location]; it exists, as the
   temporary directory did before. *)
let store_under root = D.Store.(at (root_of_masc_dir root) Root.Audit)

let temp_store prefix =
  let location = store_under (tmpdir prefix) in
  Fs_compat.mkdir_p (D.Store.dir location);
  location

(* --- 2. different base_dir → distinct mutexes ---------- *)

let test_different_base_dir_distinct_mutex () =
  let dir_a_location = temp_store "djmr_diff_a" in
  let dir_b_location = temp_store "djmr_diff_b" in
  let a = D.open_store dir_a_location in
  let b = D.open_store dir_b_location in
  check bool "distinct base_dir → distinct mutex" false
    (D.For_testing.cross_context_mutex a == D.For_testing.cross_context_mutex b)

(* --- 3. a reader takes no registry entry ------------------------- *)

let test_reader_takes_no_registry_entry () =
  let location = temp_store "djmr_reader" in
  let dir = D.Store.dir location in
  let month = Filename.concat dir "2026-02" in
  Fs_compat.mkdir_p month;
  Fs_compat.append_file (Filename.concat month "01.jsonl") "{\"i\":1}\n";
  let reader = D.Reader.open_store location in
  check string "the reader names the store's directory" dir (D.Reader.base_dir reader);
  (match D.Reader.read_recent_lines_result reader 10 with
   | Ok rows ->
     check
       (list (pair string string))
       "the reader reads the store's rows"
       [ Filename.concat month "01.jsonl", "{\"i\":1}" ]
       rows
   | Error error -> failf "the reader failed: %s" (D.read_error_to_string error));
  (match D.Reader.read_recent_result reader 10 with
   | Ok rows -> check int "the parsed read returns the row" 1 (List.length rows)
   | Error error -> failf "the reader failed: %s" (D.read_error_to_string error));
  check bool "opening and reading through a reader leaves no registry entry" false
    (D.For_testing.in_registry location);
  let store = D.open_store location in
  check bool "opening the store takes none either" false
    (D.For_testing.in_registry location);
  D.append store (`Assoc [ "i", `Int 2 ]);
  check bool "a write through the store takes the entry" true
    (D.For_testing.in_registry location)

(* --- 3. spellings of one directory share the mutex ---- *)

let mutex_of handle = D.For_testing.cross_context_mutex handle

let shares_mutex a b = mutex_of (D.open_store a) == mutex_of (D.open_store b)

(* What the registry has to agree with. The device and inode of a directory
   do not come from its name. *)
let one_directory a b =
  let identity location =
    let stat = Unix.stat (D.Store.dir location) in
    stat.Unix.st_dev, stat.Unix.st_ino
  in
  identity a = identity b

let made location =
  Fs_compat.mkdir_p (D.Store.dir location);
  location

let test_trailing_slash_normalizes () =
  let root = tmpdir "djmr_slash" in
  check bool "a directory that does not exist yet" true
    (shares_mutex (store_under root) (store_under (root ^ "/")));
  ignore (made (store_under root) : D.Store.location);
  check bool "and once it exists" true
    (shares_mutex (store_under root) (store_under (root ^ "/")))

(* A second spelling of [real]: a symbolic link beside it. *)
let alias_of real =
  let alias = real ^ "-alias" in
  Unix.symlink real alias;
  alias

let test_symlinked_root_shares_the_mutex () =
  let real = tmpdir "djmr_symlink" in
  let alias = alias_of real in
  let through_real = made (store_under real) in
  let through_alias = store_under alias in
  check bool "the two spellings are one directory" true
    (one_directory through_real through_alias);
  check bool "the root and a link to it reach one mutex" true
    (shares_mutex through_real through_alias);
  check string "the directory through the root is spelled with the root"
    (Filename.concat real "audit")
    (D.Store.dir through_real);
  check string "the directory through the link is spelled with the link"
    (Filename.concat alias "audit")
    (D.Store.dir through_alias);
  check bool "another store under the link has its own mutex" false
    (shares_mutex through_real D.Store.(at (root_of_masc_dir alias) Root.Events))

(* Neither store directory exists when the mutex is asked for. The nearest
   ancestor that exists decides. *)
let test_directory_that_does_not_exist_yet_shares_the_mutex () =
  let real = tmpdir "djmr_absent_root" in
  let alias = alias_of real in
  let below spelling = Filename.concat (Filename.concat spelling "not-made") "state" in
  check bool "a root below the directory and below the link reach one mutex" true
    (shares_mutex (store_under (below real)) (store_under (below alias)))

(* A link anywhere on the way is followed, not only one at the root. *)
let test_link_below_the_root_reaches_the_directory () =
  let root = tmpdir "djmr_link_below" in
  let masc_root = D.Store.root_of_masc_dir root in
  let keeper name = D.Store.keeper masc_root ~keeper:name D.Store.Keeper.Metrics in
  let through_name = made (keeper "first") in
  let keepers = Filename.dirname (Filename.dirname (D.Store.dir through_name)) in
  Unix.symlink (Filename.concat keepers "first") (Filename.concat keepers "second");
  let through_link = keeper "second" in
  check bool "the two spellings are one directory" true
    (one_directory through_name through_link);
  check bool "a Keeper directory that is a link reaches the mutex of its target" true
    (shares_mutex through_name through_link)

(* The Keeper piece of a location is whatever the caller spelled, and the
   prune pass spells it as the directory entry is. Whether [alpha] and
   [Alpha] are one directory is the file system's answer: yes where letter
   case is folded (APFS as installed), no where it is not (ext4). The
   registry gives the same answer on both. *)
let test_letter_case_follows_the_file_system () =
  let root = D.Store.root_of_masc_dir (tmpdir "djmr_case") in
  let keeper name = D.Store.keeper root ~keeper:name D.Store.Keeper.Metrics in
  let lower = made (keeper "alpha") in
  let upper = made (keeper "Alpha") in
  check bool "the two spellings share a mutex exactly when they are one directory"
    (one_directory lower upper)
    (shares_mutex lower upper)

(* One relative spelling names a different directory in each working
   directory, so it is not remembered apart from the directory it was read
   in. *)
let test_relative_root_shares_the_mutex () =
  let first = tmpdir "djmr_relative_first" in
  let second = tmpdir "djmr_relative_second" in
  let relative = "state" in
  let started_in = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Sys.chdir started_in)
    (fun () ->
      Sys.chdir first;
      ignore (made (store_under relative) : D.Store.location);
      check bool "a relative root and its absolute spelling reach one mutex" true
        (shares_mutex (store_under relative) (store_under (Filename.concat first relative)));
      Sys.chdir second;
      ignore (made (store_under relative) : D.Store.location);
      check bool "the same relative root in another directory is another store" false
        (shares_mutex (store_under relative) (store_under (Filename.concat first relative)));
      check bool "and it is the store of that directory" true
        (shares_mutex (store_under relative) (store_under (Filename.concat second relative))))

(* Stores under one root take a mutex each: one Keeper's stores of two
   kinds, two Keepers' stores of one kind, and a store of the root itself.
   With one mutex for them all, every write under the root would wait for
   every other one. Asked before the directories exist and again once they
   do, since the registry names the two cases differently. *)
let test_stores_under_one_root_take_a_mutex_each () =
  let root = D.Store.root_of_masc_dir (tmpdir "djmr_one_root") in
  let keeper name kind = D.Store.keeper root ~keeper:name kind in
  let stores =
    [ "one Keeper's metrics", keeper "alpha" D.Store.Keeper.Metrics
    ; "that Keeper's turn records", keeper "alpha" D.Store.Keeper.Turn_records
    ; "another Keeper's metrics", keeper "beta" D.Store.Keeper.Metrics
    ; "the root's audit", D.Store.at root D.Store.Root.Audit
    ; "the root's events", D.Store.at root D.Store.Root.Events
    ]
  in
  let rec each_pair = function
    | [] -> []
    | first :: rest -> List.map (fun other -> first, other) rest @ each_pair rest
  in
  let check_each_has_its_own when_ =
    List.iter
      (fun ((first_name, first), (second_name, second)) ->
        check
          bool
          (Printf.sprintf "%s and %s, %s" first_name second_name when_)
          false
          (shares_mutex first second))
      (each_pair stores)
  in
  check_each_has_its_own "before the directories exist";
  List.iter (fun (_, location) -> ignore (made location : D.Store.location)) stores;
  check_each_has_its_own "once they exist"

(* --- 4. when the file system is asked ------------------ *)

(* The handles of a Keeper's stores are kept for the life of the process. A
   handle opened before its directory existed must not stay with the mutex
   its spelling had then. *)
let test_handle_opened_early_follows_the_directory () =
  let real = tmpdir "djmr_late" in
  let alias = real ^ "-late-alias" in
  let through_real = D.open_store (made (store_under real)) in
  let through_alias = D.open_store (store_under alias) in
  check bool "before the link is made the spellings are two stores" false
    (mutex_of through_alias == mutex_of through_real);
  Unix.symlink real alias;
  check bool "the handle opened before takes the directory's mutex" true
    (mutex_of through_alias == mutex_of through_real)

(* A directory that exists is asked about once: a write is on the path of
   every row, and [realpath] is a system call for each piece of the path.
   The price is stated here. A spelling keeps the answer of its first use
   while the process runs, also when the link is pointed somewhere else. *)
let test_existing_directory_is_asked_about_once () =
  let first = tmpdir "djmr_once_first" in
  let second = tmpdir "djmr_once_second" in
  let alias = alias_of first in
  ignore (made (store_under first) : D.Store.location);
  ignore (made (store_under second) : D.Store.location);
  check bool "the link reaches the store it points at" true
    (shares_mutex (store_under alias) (store_under first));
  Unix.unlink alias;
  Unix.symlink second alias;
  check bool "the spelling keeps the answer of its first use" true
    (shares_mutex (store_under alias) (store_under first));
  check bool "and does not take the new target's" false
    (shares_mutex (store_under alias) (store_under second))

(* --- 5. concurrent appends produce all-parseable lines  *)

(* Payload large enough to exercise the buffered [output_string]
   path that previously split into multiple [write(2)] calls past
   [PIPE_BUF].  We don't depend on the writer's exact threshold;
   we only assert that NO line is truncated or interleaved
   regardless of how many fibers append concurrently. *)
let big_payload tag =
  let body = String.make 6000 '.' in
  `Assoc
    [
      ("tag", `String tag);
      ("body", `String body);
      ("ts", `Float (Unix.gettimeofday ()));
    ]

let read_today_lines dir =
  let open Unix in
  let tm = gmtime (gettimeofday ()) in
  let month =
    Printf.sprintf "%04d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1)
  in
  let day = Printf.sprintf "%02d.jsonl" tm.tm_mday in
  let path = Filename.concat (Filename.concat dir month) day in
  if not (Sys.file_exists path) then []
  else
    Fs_compat.load_file path
    |> String.split_on_char '\n'
    |> List.filter (fun l -> String.trim l <> "")

let test_concurrent_two_instances_no_corruption () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let location = temp_store "djmr_concurrent" in
  let dir = D.Store.dir location in
  (* Two instances at the same dir — pre-fix this would mint
     two distinct mutexes; post-fix the registry forces sharing. *)
  let store_a = D.open_store location in
  let store_b = D.open_store location in
  check bool "registry shares mutex across instances" true
    (D.For_testing.cross_context_mutex store_a == D.For_testing.cross_context_mutex store_b);
  let n = 40 in
  Eio.Fiber.both
    (fun () ->
      for i = 0 to n - 1 do
        D.append store_a (big_payload (Printf.sprintf "a-%d" i))
      done)
    (fun () ->
      for i = 0 to n - 1 do
        D.append store_b (big_payload (Printf.sprintf "b-%d" i))
      done);
  let lines = read_today_lines dir in
  check int "all 80 lines present" (2 * n) (List.length lines);
  let parsed_count =
    List.fold_left
      (fun acc line ->
        match Yojson.Safe.from_string line with
        | _ -> acc + 1
        | exception Yojson.Json_error _ -> acc)
      0 lines
  in
  check int "every line parses as JSON" (2 * n) parsed_count

let test_append_failure_does_not_poison_registry_mutex () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let location = store_under (tmpdir "djmr_retry") in
  let base_dir = D.Store.dir location in
  Out_channel.with_open_text base_dir (fun oc -> output_string oc "blocked");
  let store = D.open_store location in
  let failed =
    try
      D.append store (`Assoc [ ("phase", `String "initial") ]);
      false
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> true
  in
  check bool "initial append failed" true failed;
  Sys.remove base_dir;
  Unix.mkdir base_dir 0o755;
  let retry_store = D.open_store location in
  D.append retry_store (`Assoc [ ("phase", `String "retry") ]);
  let records = D.read_recent retry_store 1 in
  check int "retry append persisted" 1 (List.length records)

let test_append_from_os_threads_under_contention () =
  (* The audit log is appended from [Thread.create] workers. A raw OS thread
     has no Eio effect handler, and [Eio.Mutex.use_ro] with a waiter performs
     an effect ([Waiters.await]); the thread dies with [Effect.Unhandled]
     before its row lands (2026-11-04 run 41848559369, 3608~3620). An
     uncontended [use_ro] performs none, so this test makes the threads
     contend: several writers share the store's gate at once, as the audit
     log's writers do through one registry entry per base_dir. *)
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let location = temp_store "djmr_os_contention" in
  let dir = D.Store.dir location in
  let store = D.open_store location in
  let errors = ref [] in
  let per_thread = 20 in
  let threads =
    List.init 8 (fun i ->
      Thread.create
        (fun () ->
          for row = 0 to per_thread - 1 do
            try
              D.append store
                (`Assoc [ ("tag", `String (Printf.sprintf "t%d-%d" i row)) ])
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | e -> errors := (Printf.sprintf "t%d-%d: %s" i row (Printexc.to_string e)) :: !errors
          done)
        ())
  in
  List.iter Thread.join threads;
  check (list string) "no OS thread raised" [] !errors;
  let lines = read_today_lines dir in
  check int "every contended append landed" (8 * per_thread) (List.length lines);
  let parsed =
    List.fold_left
      (fun acc line ->
        match Yojson.Safe.from_string line with
        | _ -> acc + 1
        | exception Yojson.Json_error _ -> acc)
      0 lines
  in
  check int "every line parses as JSON" (8 * per_thread) parsed

(* --- 6. whoever changes a store's files waits for its mutex ---------- *)

let held_seconds = 0.3

(* A thread holds the store's mutex while [change] runs on a fiber, as the
   server's writers do. [change] has not returned after [held_seconds], and
   it returns once the thread lets go.

   The first half can err one way only. A change that takes the mutex never
   returns while it is held. One that takes none returns at once, and is
   missed only on a machine that does not run it for [held_seconds]. *)
let waits_for_the_store_mutex env store change =
  let mutex = mutex_of store in
  let holding = Atomic.make false in
  let release = Atomic.make false in
  let holder =
    Thread.create
      (fun () ->
        Cross_context_mutex.with_lock mutex (fun () ->
          Atomic.set holding true;
          while not (Atomic.get release) do
            Thread.delay 0.001
          done))
      ()
  in
  while not (Atomic.get holding) do
    Thread.delay 0.001
  done;
  let returned = Atomic.make false in
  let returned_while_held = ref false in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set release true;
      Thread.join holder)
    (fun () ->
      Eio.Fiber.both
        (fun () ->
          change ();
          Atomic.set returned true)
        (fun () ->
          Eio.Time.sleep (Eio.Stdenv.clock env) held_seconds;
          returned_while_held := Atomic.get returned;
          Atomic.set release true));
  (not !returned_while_held) && Atomic.get returned

let test_every_change_of_the_files_waits_for_the_store_mutex () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = tmpdir "djmr_waits" in
  let root = D.Store.root_of_base_path ~base_path in
  (* A store the pass prunes: the operator's window is its retention. *)
  let location = made (D.Store.at root D.Store.Root.Telemetry) in
  let store = D.open_store location in
  let row = `Assoc [ "i", `Int 1 ] in
  let waits name change =
    check bool name true (waits_for_the_store_mutex env store change)
  in
  waits "an append" (fun () -> D.append store row);
  waits "an append that may rotate the file" (fun () ->
    ignore (D.append_rotating store ~max_current_file_bytes:0 row : D.append_outcome));
  waits "the prune of the store" (fun () -> ignore (D.prune store ~days:30 : int));
  waits "the pass over the listed stores" (fun () ->
    ignore
      (D.Store.with_retention_root root (fun held ->
         D.prune_listed_stores_bound root held ~operator_window_days:30 ~on_pruned:ignore)
       : int option))

let () =
  run "dated_jsonl_mutex_registry_10372"
    [
      ( "registry-identity",
        [
          test_case "different base_dir distinct mutex" `Quick
            test_different_base_dir_distinct_mutex;
          test_case "a reader takes no registry entry" `Quick
            test_reader_takes_no_registry_entry;
          test_case "trailing slash normalises" `Quick
            test_trailing_slash_normalizes;
          test_case "a symlinked root shares the mutex" `Quick
            test_symlinked_root_shares_the_mutex;
          test_case "a directory that does not exist yet shares the mutex" `Quick
            test_directory_that_does_not_exist_yet_shares_the_mutex;
          test_case "a link below the root reaches the directory" `Quick
            test_link_below_the_root_reaches_the_directory;
          test_case "letter case follows the file system" `Quick
            test_letter_case_follows_the_file_system;
          test_case "a relative root shares the mutex" `Quick
            test_relative_root_shares_the_mutex;
          test_case "stores under one root take a mutex each" `Quick
            test_stores_under_one_root_take_a_mutex_each;
          test_case "a handle opened early follows the directory" `Quick
            test_handle_opened_early_follows_the_directory;
          test_case "an existing directory is asked about once" `Quick
            test_existing_directory_is_asked_about_once;
        ] );
      ( "concurrent-append",
        [
          test_case "two instances at same dir do not corrupt" `Quick
            test_concurrent_two_instances_no_corruption;
          test_case "append failure does not poison registry mutex" `Quick
            test_append_failure_does_not_poison_registry_mutex;
        ] );
      ( "store mutex",
        [
          test_case "every change of the files waits for the store's mutex" `Quick
            test_every_change_of_the_files_waits_for_the_store_mutex;
        ] );
      ( "off-fiber append",
        [
          test_case "appends from contending OS threads all land" `Quick
            test_append_from_os_threads_under_contention;
        ] );
    ]
