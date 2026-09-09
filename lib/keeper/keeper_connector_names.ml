(* Names for what a connector brings in -- people and places -- kept across
   restarts. Live connector answers always win; this store only recalls a name
   seen before when the current event has none. Person and channel id spaces
   remain separate through [scope]. *)

let sanitize_name name =
  Workspace_utils_backend_setup.sanitize_namespace_segment name
;;

type scope =
  | Person
  | Channel
  | Server

let scope_segment = function
  | Person -> "people"
  | Channel -> "channels"
  | Server -> "servers"
;;

let names_dir base_dir =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path:base_dir)
    "connector_names"
;;

let names_path ~base_dir ~connector ~scope =
  Filename.concat
    (names_dir base_dir)
    (sanitize_name connector ^ "-" ^ scope_segment scope ^ ".jsonl")
;;

let persistence_surface = "connector_names"

let report_read_drop ~reason ~path ~detail =
  Safe_ops.report_persistence_read_drop_counted
    ~surface:persistence_surface
    ~reason
    ~path
    ~detail
;;

let parse_row ~file_path line =
  try
    match Yojson.Safe.from_string line with
    | `Assoc fields ->
      (match List.assoc_opt "id" fields, List.assoc_opt "name" fields with
       | Some (`String id), Some (`String name) -> Some (id, name)
       | _ ->
         report_read_drop
           ~reason:Read_drop_reason.Invalid_payload
           ~path:file_path
           ~detail:"row has no id/name pair";
         None)
    | _ ->
      report_read_drop
        ~reason:Read_drop_reason.Invalid_payload
        ~path:file_path
        ~detail:"row is not a JSON object";
      None
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    report_read_drop
      ~reason:Read_drop_reason.Json_syntax_error
      ~path:file_path
      ~detail:(Printexc.to_string exn);
    None
;;

(* Each scoped connector directory is loaded once per process. Without this
   cache every missing live name rescans the append history, and repeated live
   answers append the same row forever. The mutex also serializes shared
   connector writers. *)
let directories : (string, (string, string) Hashtbl.t) Hashtbl.t =
  Hashtbl.create 8
;;

let sorted_directories : (string, (string * string) list) Hashtbl.t =
  Hashtbl.create 8
;;

let directories_mu = Stdlib.Mutex.create ()

let with_directories_lock f =
  Stdlib.Mutex.lock directories_mu;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock directories_mu) f
;;

let load_directory file_path =
  let directory = Hashtbl.create 32 in
  if Sys.file_exists file_path
  then (
    try
      Fs_compat.load_file file_path
      |> String.split_on_char '\n'
      |> List.iter (fun line ->
        if String.trim line <> ""
        then
          match parse_row ~file_path line with
          | Some (id, name) -> Hashtbl.replace directory id name
          | None -> ())
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Sys_error detail ->
      report_read_drop
        ~reason:Read_drop_reason.Entry_load_error
        ~path:file_path
        ~detail);
  directory
;;

let directory_for_path file_path =
  match Hashtbl.find_opt directories file_path with
  | Some directory -> directory
  | None ->
    let directory = load_directory file_path in
    Hashtbl.add directories file_path directory;
    directory
;;

let remember ~base_dir ~connector ~scope ~(id : string) ~(name : string) () =
  let id = String.trim id in
  let name = String.trim name in
  if String.equal id "" || String.equal name ""
  then ()
  else
    with_directories_lock (fun () ->
      let file_path = names_path ~base_dir ~connector ~scope in
      let directory = directory_for_path file_path in
      match Hashtbl.find_opt directory id with
      | Some known when String.equal known name -> ()
      | Some _ | None ->
        (try
           ignore (Keeper_fs.ensure_dir (names_dir base_dir));
           let line =
             Yojson.Safe.to_string
               (`Assoc
                 [ "id", `String id
                 ; "name", `String name
                 ; "ts", `Float (Time_compat.now ())
                 ])
           in
           Fs_compat.append_file file_path (line ^ "\n");
           Hashtbl.replace directory id name;
           Hashtbl.remove sorted_directories file_path
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
           Log.Keeper.warn "connector_names: append failed for %s/%s: %s"
             (sanitize_name connector)
             (scope_segment scope)
             (Printexc.to_string exn)))
;;

let recall ~base_dir ~connector ~scope ~(id : string) =
  let id = String.trim id in
  if String.equal id ""
  then None
  else
    with_directories_lock (fun () ->
      let file_path = names_path ~base_dir ~connector ~scope in
      directory_for_path file_path |> fun directory -> Hashtbl.find_opt directory id)
;;

let entries ~base_dir ~connector ~scope =
  with_directories_lock (fun () ->
    let file_path = names_path ~base_dir ~connector ~scope in
    match Hashtbl.find_opt sorted_directories file_path with
    | Some snapshot -> snapshot
    | None ->
      let snapshot =
        directory_for_path file_path
        |> Hashtbl.to_seq
        |> List.of_seq
        |> List.sort (fun (left, _) (right, _) -> String.compare left right)
      in
      Hashtbl.replace sorted_directories file_path snapshot;
      snapshot)
;;

let path ~base_dir ~connector ~scope =
  names_path ~base_dir ~connector ~scope
;;
