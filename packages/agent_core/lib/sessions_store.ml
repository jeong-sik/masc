(** Sessions store operations — file I/O, artifact retrieval, raw trace access.

    Read-from-store operations that bridge the runtime file layout
    with the typed Sessions domain. *)

open Sessions_types
open Result_syntax

let make_store ?session_root () = Runtime_store.create ?root:session_root ()

(** [result_all xs] collects a list of results into a result of a list,
    short-circuiting on the first [Error] and preserving element order. *)
let result_all xs =
  List.fold_left
    (fun acc item ->
       let* acc = acc in
       let* item = item in
       Ok (item :: acc))
    (Ok [])
    xs
  |> Result.map List.rev
;;

let get_raw_trace_dir ?session_root ~session_id () =
  let* store = make_store ?session_root () in
  Ok (Runtime_store.raw_traces_dir store session_id)
;;

let get_raw_trace_files ?session_root ~session_id () =
  let* dir = get_raw_trace_dir ?session_root ~session_id () in
  if not (Sys.file_exists dir)
  then Ok []
  else
    dir
    |> Sys.readdir
    |> Array.to_list
    |> List.filter (fun name -> Filename.check_suffix name ".jsonl")
    |> List.sort String.compare
    |> List.map (fun name -> Filename.concat dir name)
    |> fun paths -> Ok paths
;;

let get_raw_trace_runs ?session_root ~session_id () =
  let* paths = get_raw_trace_files ?session_root ~session_id () in
  let+ runs =
    paths
    |> List.map (fun path -> Raw_trace_query.read_runs ~path ())
    |> result_all
    |> Result.map List.flatten
  in
  List.sort
    (fun (a : raw_trace_run) (b : raw_trace_run) -> Int.compare a.start_seq b.start_seq)
    runs
;;
