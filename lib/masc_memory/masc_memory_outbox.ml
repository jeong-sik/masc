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
    let content = Yojson.Safe.to_string (`Assoc [
      "id", `String row.id;
      "text", `String row.text;
      "ts_unix", `Float row.ts_unix;
    ]) in
    (try
       Eio.Path.save ~create:(`Exclusive 0o600) file_path content;
       let rec retry attempt =
         if attempt > 5 then
           ()
         else
           match write_pgvector row, write_neo4j row with
           | Ok (), Ok () ->
               Eio.Path.unlink file_path
           | _ ->
               Eio.Time.sleep t.env_clock (float_of_int (attempt * 2));
               retry (attempt + 1)
       in
       retry 1
     with _ -> ())
  done
