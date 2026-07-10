type dated_path =
  { base_dir : string
  ; month_dir : string
  ; day_file : string
  ; path : string
  }



let dated_path ~base_dir ~ts =
  let tm = Unix.gmtime ts in
  let month_dir =
    Printf.sprintf "%04d-%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)
  in
  let day_file = Printf.sprintf "%02d.jsonl" tm.Unix.tm_mday in
  let path = Filename.concat (Filename.concat base_dir month_dir) day_file in
  { base_dir; month_dir; day_file; path }

let dated_path_now ~base_dir =
  (* NDT-OK: this helper is the runtime write boundary for date-split JSONL;
     deterministic callers use [dated_path ~ts] with an explicit timestamp. *)
  dated_path ~base_dir ~ts:(Unix.gettimeofday ())

let append_jsonl ~path json =
  Fs_compat.append_jsonl path json

let ensure_parent_durable path =
  let dir = Filename.dirname path in
  let rec missing current acc =
    if Fs_compat.file_exists current
       || String.equal current (Filename.dirname current)
    then acc
    else missing (Filename.dirname current) (current :: acc)
  in
  let created = missing dir [] in
  Fs_compat.mkdir_p dir;
  List.iter
    (fun created_dir ->
       match Fs_compat.fsync_directory (Filename.dirname created_dir) with
       | Ok () -> ()
       | Error detail -> raise (Sys_error detail))
    created
;;

let append_jsonl_durable ~path json =
  ensure_parent_durable path;
  Fs_compat.append_file_durable path (Yojson.Safe.to_string json ^ "\n")

let append_dated_jsonl ~base_dir ~ts json =
  let dated = dated_path ~base_dir ~ts in
  append_jsonl ~path:dated.path json;
  dated
