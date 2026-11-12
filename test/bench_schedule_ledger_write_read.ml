(* Not a test: prints how long a schedule ledger mutation takes and how long
   the read that follows it takes, for a ledger of a given size.

     bench_schedule_ledger_write_read NOTES NOTE_BYTES CYCLES

   A ledger holding one schedule and NOTES notes of NOTE_BYTES each is put
   under a temporary workspace by writing the file directly. A domain pool of
   one domain is set, as a server has one. Each cycle appends a note through
   the store and then reads the ledger; the two are timed apart. One line:
   the ledger's size and the median and largest time of each, in ms. Run it
   several times and note the host's load. *)

open Schedule_domain

let now () = Unix.gettimeofday ()
let runner_tick_sec = 1.0
let schedule_id = "bench-schedule"
let operator = { id = "bench"; kind = Human_operator; display_name = None }

let store_ok = function
  | Ok value -> value
  | Error error -> failwith (Schedule_store.store_error_to_string error)
;;

let median sorted = sorted.(Array.length sorted / 2)

let append_note config ~body =
  store_ok
    (Schedule_store.append_note config ~schedule_id ~author_id:operator.id
       ~author_kind:operator.kind ~body ~now:(now ()))
;;

(* The ledger the store wrote for one schedule and one note, with that note
   repeated: the same row under another id and with a body of the size asked
   for. *)
let grown_ledger ~notes ~note_bytes text =
  let body = String.make note_bytes 'n' in
  let repeated index = function
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (name, value) ->
              match name with
              | "note_id" -> name, `String (Printf.sprintf "bench-%d" index)
              | "body" -> name, `String body
              | _ -> name, value)
           fields)
    | _ -> failwith "bench_schedule_ledger_write_read: a note is not an object"
  in
  match Yojson.Safe.from_string text with
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (name, value) ->
            match name, value with
            | "notes", `List [ note ] -> name, `List (List.init notes (fun index -> repeated index note))
            | _ -> name, value)
         fields)
    |> Yojson.Safe.to_string
  | _ -> failwith "bench_schedule_ledger_write_read: the ledger is not an object"
;;

let () =
  let notes = int_of_string Sys.argv.(1) in
  let note_bytes = int_of_string Sys.argv.(2) in
  let cycles = int_of_string Sys.argv.(3) in
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.temp_dir "bench_schedule_ledger" "" in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> Masc_test_deps.cleanup_test_workspace dir);
  let config = Workspace_core.default_config dir in
  ignore (Workspace_core.init config ~agent_name:(Some "bench"));
  let request =
    match
      create_request ~schedule_id ~requested_by:operator ~scheduled_by:operator
        ~requested_at:100.0 ~due_at:200.0
        ~payload:
          (`Assoc [ "kind", `String "consumer.note"; "body", `Assoc [ "text", `String "bench" ] ])
        ~source:Operator_request ()
    with
    | Ok request -> request
    | Error message -> failwith message
  in
  ignore (store_ok (Schedule_store.insert_request config ~runner_tick_sec request));
  ignore (append_note config ~body:"first");
  let path = Filename.concat (Workspace_utils.masc_dir config) "schedules.json" in
  let ledger =
    grown_ledger ~notes ~note_bytes (In_channel.with_open_bin path In_channel.input_all)
  in
  Out_channel.with_open_bin path (fun channel -> output_string channel ledger);
  Domain_pool_ref.set (Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env));
  Fun.protect ~finally:Domain_pool_ref.clear_for_tests
  @@ fun () ->
  ignore (Schedule_store.read_state config);
  let writes = Array.make cycles 0.0 in
  let reads = Array.make cycles 0.0 in
  for cycle = 0 to cycles - 1 do
    let started = now () in
    ignore (append_note config ~body:"cycle");
    let written = now () in
    ignore (Schedule_store.read_state config);
    let read = now () in
    writes.(cycle) <- (written -. started) *. 1000.0;
    reads.(cycle) <- (read -. written) *. 1000.0
  done;
  Array.sort Float.compare writes;
  Array.sort Float.compare reads;
  Printf.printf
    "ledger %.1f MB  cycles %d  write p50 %.1f max %.1f ms  read after it p50 %.1f max %.1f ms\n"
    (float_of_int (String.length ledger) /. 1_048_576.0)
    cycles (median writes) writes.(cycles - 1) (median reads) reads.(cycles - 1)
;;
