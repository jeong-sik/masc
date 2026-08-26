(* Names for the people a connector brings in, kept across restarts.

   Slack answers [users.info] most of the time and not always: a workspace
   without [users:read], a rate limit, a network blip. The gateway's directory
   caches the answer for an hour and the failure for five minutes, in memory,
   so a restart loses every name it had learned. That is why one person
   arrived as [Vincent] twelve times and as [U09L0RHPW7P] twelve times in the
   same channel.

   The live answer always wins. This is only what to say when there is no live
   answer and there was one before -- a name we have seen, not a name we are
   asserting. A person who renames themselves is called the old name until the
   next successful lookup, which is the trade: a stale name reads as a person,
   a raw id reads as nothing.

   Keyed by connector and id, not by keeper: the same Slack user is the same
   person on every keeper's pane. *)

let sanitize_name name =
  Workspace_utils_backend_setup.sanitize_namespace_segment name

let people_dir base_dir =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path:base_dir)
    "connector_people"

let people_path ~base_dir ~connector =
  Filename.concat (people_dir base_dir) (sanitize_name connector ^ ".jsonl")

let persistence_surface = "connector_person_names"

let report_read_drop ~reason ~path ~detail =
  Safe_ops.report_persistence_read_drop_counted
    ~surface:persistence_surface
    ~reason
    ~path
    ~detail

let parse_row ~file_path line =
  try
    match Yojson.Safe.from_string line with
    | `Assoc fields ->
      (match List.assoc_opt "id" fields, List.assoc_opt "name" fields with
       | Some (`String id), Some (`String name) -> Some (id, name)
       | _ ->
         report_read_drop ~reason:Read_drop_reason.Invalid_payload ~path:file_path
           ~detail:"row has no id/name pair";
         None)
    | _ ->
      report_read_drop ~reason:Read_drop_reason.Invalid_payload ~path:file_path
        ~detail:"row is not a JSON object";
      None
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    report_read_drop ~reason:Read_drop_reason.Json_syntax_error ~path:file_path
      ~detail:(Printexc.to_string exn);
    None

(* One process reads each connector directory once. Successful live lookups
   are much more frequent than renames; without this cache, every message
   appended the same pair and every fallback rescanned the growing history.
   The mutex also makes the shared connector append a single physical row. *)
let directories : (string, (string, string) Hashtbl.t) Hashtbl.t =
  Hashtbl.create 4
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

(* Append-only, last line wins, but only a changed name earns a row. A rename
   is a new row rather than a rewrite, so a crash mid-write costs the newest
   name and not the directory. *)
let remember ~base_dir ~connector ~(id : string) ~(name : string) () =
  let id = String.trim id in
  let name = String.trim name in
  if String.equal id "" || String.equal name ""
  then ()
  else
    with_directories_lock (fun () ->
      let file_path = people_path ~base_dir ~connector in
      let directory = directory_for_path file_path in
      match Hashtbl.find_opt directory id with
      | Some known when String.equal known name -> ()
      | Some _ | None ->
        (try
           ignore (Keeper_fs.ensure_dir (people_dir base_dir));
           let line =
             Yojson.Safe.to_string
               (`Assoc
                 [ "id", `String id
                 ; "name", `String name
                 ; "ts", `Float (Time_compat.now ())
                 ])
           in
           Fs_compat.append_file file_path (line ^ "\n");
           Hashtbl.replace directory id name
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
           Log.Keeper.warn "connector_person_names: append failed for %s: %s"
             (sanitize_name connector) (Printexc.to_string exn)))
;;

let recall ~base_dir ~connector ~(id : string) =
  let id = String.trim id in
  if String.equal id ""
  then None
  else
    with_directories_lock (fun () ->
      let file_path = people_path ~base_dir ~connector in
      directory_for_path file_path |> fun directory -> Hashtbl.find_opt directory id)
;;
