type document = {
  file_name : string; source_path : string; source_text : string;
  source_revision : string; desired_revision : string option; messages : string list;
}
type error_code = Invalid_request | Not_found | Revision_conflict | Invalid_declaration | Io_error
type error = { code : error_code; message : string; current : document option }
type expectation = Create | Save of string
type write_request = { file_name : string; source_text : string; expected : expectation }
type write_state = Created | Saved | Unchanged
type durability = Durable | Unconfirmed of string
type receipt = { document : document; state : write_state; durability : durability }
let ( let* ) = Result.bind
let reject ?current code message = Error {code;message;current}
let digest text = Digestif.SHA256.(to_hex (digest_string text))
let code = function Invalid_request -> "invalid_request" | Not_found -> "not_found"
  | Revision_conflict -> "revision_conflict" | Invalid_declaration -> "invalid_declaration" | Io_error -> "io_error"
let nullable = function None -> `Null | Some text -> `String text
let document_to_json (d : document) = `Assoc ["file_name",`String d.file_name;
  "source_path",`String d.source_path; "source_text",`String d.source_text;
  "source_revision",`String d.source_revision; "desired_revision",nullable d.desired_revision;
  "validation",`Assoc ["valid",`Bool (d.messages=[]);
    "messages",`List (List.map (fun text -> `String text) d.messages)]]
let error_to_json error = `Assoc ["error",`String error.message;"code",`String (code error.code);
  "current",(match error.current with None -> `Null | Some d -> document_to_json d)]
let receipt_to_json receipt =
  let state = match receipt.state with Created -> "created" | Saved -> "saved" | Unchanged -> "unchanged" in
  let durability, detail = match receipt.durability with
    | Durable -> "durable",None | Unconfirmed detail -> "unconfirmed",Some detail in
  `Assoc ["document",document_to_json receipt.document;
    "write",`Assoc ["state",`String state;"durability",`String durability;"detail",nullable detail];
    "application",`String "pending_reconciliation"]
let fields allowed = function
  | `Assoc fields ->
      let names = List.map fst fields in
      if List.length names <> List.length (List.sort_uniq String.compare names)
        || List.exists (fun name -> not (List.mem name allowed)) names
      then reject Invalid_request "duplicate or unknown declaration request field" else Ok fields
  | _ -> reject Invalid_request "declaration request must be an object"
let text fields key = match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | _ -> reject Invalid_request (key ^ " requires a non-blank string")
let file_name name =
  if name <> Filename.basename name || String.contains name '\\' || String.contains name '\000'
    || String.length name <= String.length ".toml" || not (Filename.check_suffix name ".toml")
  then reject Invalid_request "file_name must be one direct-child .toml filename" else Ok name
let read_request json = let* fields = fields ["source_path"] json in text fields "source_path"
let write_request json =
  let* fields = fields ["mode";"file_name";"source_text";"expected_source_revision"] json in
  let* name = text fields "file_name" in let* file_name = file_name name in
  let* source_text = match List.assoc_opt "source_text" fields with
    | Some (`String value) -> Ok value | _ -> reject Invalid_request "source_text requires a string" in
  let* expected = match List.assoc_opt "mode" fields, List.assoc_opt "expected_source_revision" fields with
    | Some (`String "create"), None -> Ok Create
    | Some (`String "save"), Some (`String revision)
        when String.length revision=64 && String.for_all (function '0'..'9'|'a'..'f' -> true|_ -> false) revision -> Ok (Save revision)
    | _ -> reject Invalid_request "mode=create forbids a revision; mode=save requires expected_source_revision as a lowercase SHA-256" in
  Ok {file_name;source_text;expected}
let protect f = try f () with
  | Unix.Unix_error (error,call,path) -> reject Io_error (call ^ " " ^ path ^ ": " ^ Unix.error_message error)
  | Sys_error message -> reject Io_error message
let same_identity a b = a.Unix.st_dev=b.Unix.st_dev && a.Unix.st_ino=b.Unix.st_ino
  && a.Unix.st_size=b.Unix.st_size && a.Unix.st_mtime=b.Unix.st_mtime && a.Unix.st_ctime=b.Unix.st_ctime
let read_bytes path = protect (fun () ->
  let before = try Some (Unix.lstat path) with Unix.Unix_error (Unix.ENOENT,_,_) -> None in
  match before with
  | None -> Ok None
  | Some before when before.Unix.st_kind <> Unix.S_REG ->
      reject Invalid_request "declaration must be a regular file, not a symlink or directory"
  | Some before ->
      let fd = Unix.openfile path [Unix.O_RDONLY;Unix.O_NONBLOCK;Unix.O_CLOEXEC] 0 in
      let channel = Unix.in_channel_of_descr fd in
      Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
        if not (same_identity before (Unix.fstat fd)) then reject Io_error "declaration changed while opening"
        else
          try
            let bytes = really_input_string channel before.Unix.st_size in
            if same_identity before (Unix.fstat fd) && same_identity before (Unix.lstat path)
            then Ok (Some bytes) else reject Io_error "declaration changed while reading"
          with End_of_file -> reject Io_error "declaration changed while reading"))

let describe ~snapshot ~path source_text =
  let parsed = Lane_addon_config.load_source ~source_path:path ~source_text in
  let desired_revision, messages = match parsed with
    | Error message -> None,[message]
    | Ok declaration ->
        let messages = snapshot.Lane_addon_config.issues |> List.filter_map (fun (issue : Lane_addon_config.issue) ->
          (* Ignore the old target's parse error when validating its replacement.
             A matching identity at another path is still a collision. *)
          if issue.source_path <> path && issue.id=Some declaration.id then Some issue.message else None) in
        let collision = List.exists (fun (other : Lane_addon_config.declaration) ->
          other.source_path <> path && other.id=declaration.id) snapshot.declarations in
        Some declaration.revision,
        (if collision then "another declaration has the same installation id" :: messages else messages) in
  let messages = if snapshot.complete then messages
    else "configuration inventory is incomplete" :: messages in
  {file_name=Filename.basename path;source_path=path;source_text;source_revision=digest source_text;
   desired_revision;messages}

let read ~directory ~source_path =
  let* name = file_name (Filename.basename source_path) in
  if source_path <> Filename.concat directory name
  then reject Invalid_request "source_path must identify a direct declaration in the resolved Lane directory"
  else
    let* bytes = read_bytes source_path in
    match bytes with
    | None -> reject Not_found "declaration file is absent"
    | Some bytes -> protect (fun () ->
        let snapshot = Lane_addon_config.load ~directory in
        Ok (describe ~snapshot ~path:source_path bytes))

let replacement_result ~document ~state = function
  | Ok () -> Ok {document;state;durability=Durable}
  | Error (failure : Fs_compat.atomic_replace_failure) ->
      (match failure.stage with
       | Fs_compat.After_rename -> Ok {document;state;
           durability=Unconfirmed (Fs_compat.atomic_replace_failure_to_string failure)}
       | Fs_compat.Before_rename ->
           (match failure.exception_ with
            | Eio.Cancel.Cancelled _ -> Printexc.raise_with_backtrace failure.exception_ failure.backtrace
            | _ -> reject Io_error (Fs_compat.atomic_replace_failure_to_string failure)))

(* A fully written, synced sibling is linked into an absent target. link(2)
   cannot replace a concurrently created declaration. The staging filename is
   outside the *.toml inventory; the final path retains relative-path meaning. *)
let create ~replace_file ~directory ~document =
  let staged = Filename.concat directory (".lane-create-" ^ Random_id.uuid_v7 ()) in
  let remove_stage () = try Unix.unlink staged with Unix.Unix_error (Unix.ENOENT,_,_) -> () in
  match replace_file staged document.source_text with
  | Error failure ->
      remove_stage ();
      (match failure.Fs_compat.exception_ with
       | Eio.Cancel.Cancelled _ -> Printexc.raise_with_backtrace failure.exception_ failure.backtrace
       | _ -> reject Io_error (Fs_compat.atomic_replace_failure_to_string failure))
  | Ok () ->
      let linked = try Unix.link staged document.source_path; Ok () with
        | Unix.Unix_error (Unix.EEXIST,_,_) -> reject Revision_conflict "declaration appeared before create could publish"
        | Unix.Unix_error (error,call,path) -> reject Io_error (call ^ " " ^ path ^ ": " ^ Unix.error_message error) in
      (match linked with
       | Error error -> remove_stage (); Error error
       | Ok () ->
           try
             remove_stage ();
             Keeper_fs_durable_directory.fsync_directory directory;
             Ok {document;state=Created;durability=Durable}
           with Unix.Unix_error (error,call,path) ->
             Ok {document;state=Created;durability=Unconfirmed (call ^ " " ^ path ^ ": " ^ Unix.error_message error)})

let write_with ~replace_file ~directory request = protect (fun () ->
  Fs_compat.mkdir_p directory;
  let path = Filename.concat directory request.file_name in
  let* bytes = read_bytes path in
  let snapshot = Lane_addon_config.load ~directory in
  let current = Option.map (describe ~snapshot ~path) bytes in
  let* () = match request.expected,current with
    | Create,None -> Ok ()
    | Save revision,Some observed when revision=observed.source_revision -> Ok ()
    | _ -> reject ?current Revision_conflict "declaration source changed; read the current document before saving" in
  if not snapshot.complete then reject ?current Io_error "configuration inventory is unreadable; no declaration was written"
  else
    let document = describe ~snapshot ~path request.source_text in
    if document.messages <> [] then reject ?current Invalid_declaration (String.concat "; " document.messages)
    else
      (* Recheck after manifest/inventory I/O. This detects an external editor's
         intervening save; uncoordinated filesystem writers are not an atomic
         compare-and-swap participant with this process's serializer. *)
      let* latest = read_bytes path in
      if latest <> bytes then
        let current = Option.map (describe ~snapshot ~path) latest in
        reject ?current Revision_conflict "declaration changed while its candidate was validated"
      else match current,request.expected with
      | Some observed,Save _ when observed.source_text=request.source_text ->
          let sync = try
            let fd = Unix.openfile path [Unix.O_RDONLY;Unix.O_CLOEXEC] 0 in
            Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd);
            Keeper_fs_durable_directory.fsync_directory directory;
            Durable
          with Unix.Unix_error (error,call,path) -> Unconfirmed (call ^ " " ^ path ^ ": " ^ Unix.error_message error) in
          Ok {document;state=Unchanged;durability=sync}
      | _,Create -> create ~replace_file ~directory ~document
      | _,Save _ -> replacement_result ~document ~state:Saved (replace_file path request.source_text))

let write ~directory request =
  write_with ~replace_file:Fs_compat.save_file_atomic_strict_staged ~directory request
module For_testing = struct let write = write_with end
