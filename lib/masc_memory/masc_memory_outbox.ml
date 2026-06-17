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

let process_queue ~sw t ~write_pgvector ~write_neo4j =
  while true do
    let row = Eio.Stream.take t.stream in
    Eio.Fiber.fork ~sw (fun () ->
      let file_path = Eio.Path.(t.env_fs / Printf.sprintf "pending_%s.json" row.id) in
      let tmp_path = Eio.Path.(t.env_fs / Printf.sprintf "pending_%s.json.tmp" row.id) in
      let write_state pg_done neo_done =
        let embed_json = match row.embedding with
          | None -> `Null
          | Some arr -> `List (List.map (fun x -> `Float x) (Array.to_list arr))
        in
        let content = Yojson.Safe.to_string (`Assoc [
          "id", `String row.id;
          "kind", `String (kind_to_string row.kind);
          "horizon", `String (horizon_to_string row.horizon);
          "source_trace_id", `String row.source_trace_id;
          "text", `String row.text;
          "embedding", embed_json;
          "ts_unix", `Float row.ts_unix;
          "pgvector_done", `Bool pg_done;
          "neo4j_done", `Bool neo_done;
        ]) in
        (try
           Eio.Path.save ~create:(`Or_truncate 0o600) tmp_path content;
           Eio.Path.rename tmp_path file_path
         with _ -> ())
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
    )
  done

let recover_on_boot ~sw t ~write_pgvector ~write_neo4j =
  try
    let files = Eio.Path.read_dir t.env_fs in
    let pending_files =
      List.filter (fun name ->
        String.starts_with ~prefix:"pending_" name && String.ends_with ~suffix:".json" name
      ) files
    in
    List.iter (fun name ->
      Eio.Fiber.fork ~sw (fun () ->
        let file_path = Eio.Path.(t.env_fs / name) in
        let tmp_path = Eio.Path.(t.env_fs / Printf.sprintf "%s.tmp" name) in
        try
          let content = Eio.Path.load file_path in
          let json = Yojson.Safe.from_string content in
          let open Yojson.Safe.Util in
          let id = json |> member "id" |> to_string in
          let kind = json |> member "kind" |> to_string |> kind_of_string in
          let horizon = json |> member "horizon" |> to_string |> horizon_of_string in
          let source_trace_id = json |> member "source_trace_id" |> to_string in
          let text = json |> member "text" |> to_string in
          let embedding =
            match json |> member "embedding" with
            | `Null -> None
            | `List l ->
                let fl = List.map (function `Float x -> x | `Int x -> float_of_int x | _ -> 0.0) l in
                Some (Array.of_list fl)
            | _ -> None
          in
          let ts_unix = json |> member "ts_unix" |> to_number in
          let pgvector_done = json |> member "pgvector_done" |> to_bool in
          let neo4j_done = json |> member "neo4j_done" |> to_bool in
          let row = {
            id;
            kind;
            horizon;
            source_trace_id;
            text;
            embedding;
            ts_unix;
          } in
          
          let write_state pg_done neo_done =
            let embed_json = match embedding with
              | None -> `Null
              | Some arr -> `List (List.map (fun x -> `Float x) (Array.to_list arr))
            in
            let content = Yojson.Safe.to_string (`Assoc [
              "id", `String id;
              "kind", `String (kind_to_string kind);
              "horizon", `String (horizon_to_string horizon);
              "source_trace_id", `String source_trace_id;
              "text", `String text;
              "embedding", embed_json;
              "ts_unix", `Float ts_unix;
              "pgvector_done", `Bool pg_done;
              "neo4j_done", `Bool neo_done;
            ]) in
            (try
               Eio.Path.save ~create:(`Or_truncate 0o600) tmp_path content;
               Eio.Path.rename tmp_path file_path
             with _ -> ())
          in
          
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
          retry pgvector_done neo4j_done 1
        with _ -> ()
      )
    ) pending_files
  with _ -> ()

