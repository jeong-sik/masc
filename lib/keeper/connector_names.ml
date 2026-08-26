(* Names for what a connector brings in -- the people and the places -- kept
   across restarts.

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

   Keyed by connector, scope and id, not by keeper: the same Slack user is the
   same person on every keeper's pane, and the same channel is the same room.

   People and channels share this rather than each getting a copy. They ask
   the same question -- what is this id called -- and two stores would be the
   same ninety lines twice, drifting on the next fix to either. [scope] keeps
   their id spaces apart. *)

let sanitize_name name =
  Workspace_utils_backend_setup.sanitize_namespace_segment name

type scope =
  | Person
  | Channel

let scope_segment = function Person -> "people" | Channel -> "channels"

let names_dir base_dir =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path:base_dir)
    "connector_names"

let names_path ~base_dir ~connector ~scope =
  Filename.concat
    (names_dir base_dir)
    (sanitize_name connector ^ "-" ^ scope_segment scope ^ ".jsonl")

let persistence_surface = "connector_names"

let report_read_drop ~reason ~path ~detail =
  Safe_ops.report_persistence_read_drop_counted
    ~surface:persistence_surface
    ~reason
    ~path
    ~detail

(* Append-only, last line wins. A rename is a new line rather than a rewrite,
   so a crash mid-write costs the newest name and not the file. *)
let remember ~base_dir ~connector ~scope ~(id : string) ~(name : string) () =
  if String.trim id = "" || String.trim name = "" then ()
  else
    try
      ignore (Keeper_fs.ensure_dir (names_dir base_dir));
      let line =
        Yojson.Safe.to_string
          (`Assoc
            [ ("id", `String id)
            ; ("name", `String name)
            ; ("ts", `Float (Time_compat.now ()))
            ])
      in
      Fs_compat.append_file (names_path ~base_dir ~connector ~scope) (line ^ "\n")
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Keeper.warn "connector_names: append failed for %s: %s"
        (sanitize_name connector) (Printexc.to_string exn)

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
  with exn ->
    report_read_drop ~reason:Read_drop_reason.Json_syntax_error ~path:file_path
      ~detail:(Printexc.to_string exn);
    None

let recall ~base_dir ~connector ~scope ~(id : string) =
  let file_path = names_path ~base_dir ~connector ~scope in
  match Fs_compat.load_file file_path with
  | exception Sys_error _ -> None
  | contents ->
    (* Last line wins, so the scan keeps the newest match rather than
       stopping at the first. *)
    String.split_on_char '\n' contents
    |> List.fold_left
         (fun found line ->
           if String.trim line = "" then found
           else
             match parse_row ~file_path line with
             | Some (row_id, name) when String.equal row_id id -> Some name
             | Some _ | None -> found)
         None
