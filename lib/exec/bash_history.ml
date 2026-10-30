type process_status =
  | Exited of int
  | Signaled of int
  | Stopped of int

type history_entry =
  { ts : float
  ; command : string
  ; duration_ms : int
  ; status : process_status
  }

let process_status_of_unix = function
  | Unix.WEXITED code -> Exited code
  | Unix.WSIGNALED signal -> Signaled signal
  | Unix.WSTOPPED signal -> Stopped signal
;;

let process_status_to_json = function
  | Exited code -> `Assoc [ "kind", `String "exit"; "code", `Int code ]
  | Signaled signal -> `Assoc [ "kind", `String "signal"; "signal", `Int signal ]
  | Stopped signal -> `Assoc [ "kind", `String "stopped"; "signal", `Int signal ]
;;

let entry_to_json entry =
  `Assoc
    [ "ts", `Float entry.ts
    ; "command", `String entry.command
    ; "duration_ms", `Int entry.duration_ms
    ; "status", process_status_to_json entry.status
    ]
;;

let history_path ~base_path ~keeper_name =
  let dir =
    Filename.concat
      (Common.masc_dir_from_base_path ~base_path)
      (Filename.concat "keeper" keeper_name)
  in
  Filename.concat dir "bash_history.jsonl", dir
;;

let rec mkdir_p path =
  if String.equal path "" || String.equal path "." || String.equal path "/"
  then ()
  else if Sys.file_exists path
  then (
    if not (Sys.is_directory path)
    then raise (Unix.Unix_error (Unix.ENOTDIR, "mkdir", path)))
  else (
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) when Sys.is_directory path -> ())
;;

let append ~base_path ~keeper_name entry =
  let path, dir = history_path ~base_path ~keeper_name in
  try
    mkdir_p dir;
    let oc = open_out_gen [ Open_wronly; Open_creat; Open_append ] 0o644 path in
    (try
       output_string oc (Yojson.Safe.to_string (entry_to_json entry));
       output_char oc '\n';
       close_out oc;
       Ok ()
     with
     | Sys_error _ as exn ->
       close_out_noerr oc;
       Error exn)
  with
  | (Sys_error _ | Unix.Unix_error _) as exn -> Error exn
;;
