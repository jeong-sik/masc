open Masc_memory_types
open Eio.Std

type t = {
  env_fs : Eio.Fs.dir_ty Eio.Path.t;
  env_clock : float Eio.Time.clock_ty Eio.Resource.t;
  db_path : string;
  stream : memory_row Eio.Stream.t;
}

let create ~env_fs ~env_clock ~db_path =
  {
    env_fs;
    env_clock;
    db_path;
    stream = Eio.Stream.create 1000;
  }

let enqueue t row =
  try
    Eio.Stream.add t.stream row;
    Ok ()
  with exn ->
    Error (Printf.sprintf "Outbox enqueue failed: %s" (Printexc.to_string exn))

let process_queue t ~write_pgvector ~write_neo4j =
  while true do
    let row = Eio.Stream.take t.stream in
    let file_path = Eio.Path.(t.env_fs / Printf.sprintf "pending_%s.json" row.id) in
    let write_state pg_done neo_done =
      let content = Yojson.Safe.to_string (`Assoc [
        "id", `String row.id;
        "text", `String row.text;
        "ts_unix", `Float row.ts_unix;
        "pgvector_done", `Bool pg_done;
        "neo4j_done", `Bool neo_done;
      ]) in
      (try Eio.Path.save ~create:(`Or_truncate 0o600) file_path content with _ -> ())
    in
    (try
       write_state false false;
       let rec retry pg_done neo_done attempt =
         if attempt > 5 then
           ()
         else
           let pg_done = if pg_done then true else match write_pgvector row with Ok () -> true | Error _ -> false in
           let neo_done = if neo_done then true else match write_neo4j row with Ok () -> true | Error _ -> false in
           write_state pg_done neo_done;
           if pg_done && neo_done then
             Eio.Path.unlink file_path
           else (
             Eio.Time.sleep t.env_clock (float_of_int (attempt * 2));
             retry pg_done neo_done (attempt + 1)
           )
       in
       retry false false 1
     with _ -> ())
  done
