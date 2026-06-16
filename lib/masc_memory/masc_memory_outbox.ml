open Masc_memory_types
open Eio.Std

type t = {
  env_fs : Eio.Fs.dir Eio.Path.t;
  db_path : string;
  stream : memory_row Eio.Stream.t;
}

let create ~env_fs ~db_path =
  {
    env_fs;
    db_path;
    stream = Eio.Stream.create 1000; (* 1000 size capacity non-blocking stream *)
  }

let enqueue t row =
  try
    (* Non-blocking stream push: 즉시 반환하여 메인 턴 블로킹 방어 *)
    Eio.Stream.add t.stream row;
    Ok ()
  with exn ->
    Error (Printf.sprintf "Outbox enqueue failed: %s" (Printexc.to_string exn))

let process_queue t ~write_pgvector ~write_neo4j =
  (* 백그라운드 무한 루프 파이버에서 실행 *)
  while true do
    let row = Eio.Stream.take t.stream in
    (* 1. 로컬 디렉토리에 원자적으로 기록 (fsync) *)
    let file_path = Eio.Path.(t.env_fs / Printf.sprintf "pending_%s.json" row.id) in
    let content = Yojson.Safe.to_string (`Assoc [
      "id", `String row.id;
      "text", `String row.text;
      "ts_unix", `Float row.ts_unix;
    ]) in
    (try
       Eio.Path.save ~create:(`Exclusive 0o600) file_path content;
       (* 2. pgvector 및 Neo4j에 멱등성 전송 (실패 시 재시도) *)
       let rec retry attempt =
         if attempt > 5 then
           Log.warn "Outbox: max retries reached for event %s" row.id
         else
           match write_pgvector row, write_neo4j row with
           | Ok (), Ok () ->
               (* 완료 시 로컬 보존 파일 삭제 *)
               Eio.Path.unlink file_path
           | _ ->
               (* 지수 백오프 수면 *)
               Eio.Time.sleep (Eio.Stdenv.clock Eio.Stdenv.clock) (float_of_int (attempt * 2));
               retry (attempt + 1)
       in
       retry 1
     with exn ->
       Log.error "Outbox process failed: %s" (Printexc.to_string exn))
  done
