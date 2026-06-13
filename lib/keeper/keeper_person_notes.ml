(* See .mli. Sibling of Keeper_chat_store: same path/sanitize/failure
   conventions, separate directory and metric. *)

let sanitize_name name =
  Workspace_utils_backend_setup.sanitize_namespace_segment name

let notes_dir base_dir =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path:base_dir)
    "keeper_person_notes"

let notes_path ~base_dir ~keeper_name =
  Filename.concat (notes_dir base_dir) (sanitize_name keeper_name ^ ".jsonl")

let persistence_surface = "keeper_person_notes"

let report_read_drop ~reason ~path ~detail =
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () ->
      Otel_metric_store.inc_counter
        Otel_metric_store.metric_persistence_read_drops
        ~labels:[ ("surface", persistence_surface); ("reason", reason) ]
        ())
    ~surface:persistence_surface
    ~reason
    ~path
    ~detail

let set_note ~base_dir ~keeper_name ~(speaker_id : string) ~(note : string) ()
    =
  try
    ignore (Keeper_fs.ensure_dir (notes_dir base_dir));
    let line =
      Yojson.Safe.to_string
        (`Assoc
          [
            ("speaker_id", `String speaker_id);
            ("note", `String note);
            ("ts", `Float (Time_compat.now ()));
          ])
    in
    Fs_compat.append_file (notes_path ~base_dir ~keeper_name) (line ^ "\n")
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string PersonNoteStoreFailures)
      ~labels:[ ("operation", "append") ]
      ();
    Log.Keeper.warn "keeper_person_notes: append failed for %s: %s"
      (sanitize_name keeper_name) (Printexc.to_string exn)

let parse_row ~file_path line : (string * string) option =
  try
    let json = Yojson.Safe.from_string line in
    let field key =
      match Json_util.assoc_member_opt key json with
      | Some (`String v) -> Some v
      | _ -> None
    in
    match field "speaker_id" with
    | Some id when String.trim id <> "" ->
        Some (String.trim id, Option.value (field "note") ~default:"")
    | Some _ | None ->
        report_read_drop
          ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
          ~path:file_path
          ~detail:"person-note row missing non-empty speaker_id";
        None
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Yojson.Json_error detail ->
    report_read_drop
      ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
      ~path:file_path
      ~detail;
    None

let notes ~base_dir ~keeper_name : (string * string) list =
  let path = notes_path ~base_dir ~keeper_name in
  if not (Sys.file_exists path) then []
  else
    try
      (* Latest row wins per speaker; insertion order of first
         appearance is irrelevant to callers (roster sorts on its own
         keys). Blank note = tombstone. *)
      let tbl : (string, string) Hashtbl.t = Hashtbl.create 8 in
      let (), _boundary =
        Fs_compat.fold_appended_lines ~path ~from:0 ~init:()
          ~f:(fun () line ->
            match parse_row ~file_path:path (String.trim line) with
            | Some (id, note) -> Hashtbl.replace tbl id note
            | None -> ())
      in
      Hashtbl.fold
        (fun id note acc ->
          if String.trim note = "" then acc else (id, note) :: acc)
        tbl []
    with
    | Sys_error detail ->
        report_read_drop
          ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
          ~path
          ~detail;
        []
    | exn ->
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string PersonNoteStoreFailures)
          ~labels:[ ("operation", "load") ]
          ();
        Log.Keeper.warn "keeper_person_notes: load failed for %s: %s"
          (sanitize_name keeper_name) (Printexc.to_string exn);
        []
