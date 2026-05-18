type dated_path =
  { base_dir : string
  ; month_dir : string
  ; day_file : string
  ; path : string
  }

let ensure_dir = Fs_compat.mkdir_p

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

let append_dated_jsonl ~base_dir ~ts json =
  let dated = dated_path ~base_dir ~ts in
  append_jsonl ~path:dated.path json;
  dated
