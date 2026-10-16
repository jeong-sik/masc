(** Uploading board-compose attachments to the artifact store.

    The wire half of the board write path (the read side's labels live in
    {!Masc_tui_board_attachments}). A staged file's bytes go to
    [POST /api/v1/artifacts] and the returned content address becomes the
    post payload's [attachments] entry.

    A library of its own so the sequencing can be driven without the
    executable around it. The POST itself is [Masc_tui_http.upload_artifact]'s,
    which sends it the way the TUI sends every request. *)

(** The largest file that can be attached: what the artifact store serves,
    which is also what the upload route accepts. *)
let max_attachment_bytes = Tool_blob_store.max_served_bytes

(** Strict decode of the upload route's 201 body, down to the content
    address the post will name. A response that cannot name one is a failed
    upload, whatever the status said. *)
let uploaded_sha256 json =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "sha256" fields with
      | Some (`String sha256) -> (
          match Tool_output.validate_sha256 sha256 with
          | Ok () -> Ok sha256
          | Error invalid ->
              Error
                ("artifact upload response carried an invalid sha256: "
                ^ Tool_output.invalid_sha256_to_string invalid))
      | Some _ | None -> Error "artifact upload response did not name a sha256")
  | _ -> Error "artifact upload response was not a JSON object"
;;

let size_text bytes =
  if bytes >= 1024 * 1024 then
    Printf.sprintf "%.1f MiB" (float_of_int bytes /. 1048576.)
  else Printf.sprintf "%d bytes" bytes
;;

let too_large ~max_bytes size =
  Printf.sprintf "the file is %s; an attachment holds at most %s"
    (size_text size) (size_text max_bytes)
;;

(* What the name points at, without following a link at its end. *)
type inspected = { device : int; inode : int; size : int }

let inspect path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Error "no such file"
  | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
  | { Unix.st_kind = Unix.S_DIR; _ } -> Error "that is a directory, not a file"
  (* A link shows its own name on the pane and uploads whatever it points
     at, which the name does not say. *)
  | { Unix.st_kind = Unix.S_LNK; _ } ->
      Error "that is a symbolic link; attach the file it points to"
  (* A device or a pipe has no end to read to. *)
  | { Unix.st_kind = Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK; _ } ->
      Error "not a regular file"
  | { Unix.st_kind = Unix.S_REG; st_size = 0; _ } -> Error "the file is empty"
  | { Unix.st_kind = Unix.S_REG; st_dev; st_ino; st_size; _ } ->
      Ok { device = st_dev; inode = st_ino; size = st_size }
;;

(** Whether [path] can be attached: a regular file, not a link to one, that
    is not empty and no larger than [max_bytes]. Asked when the file is
    staged, so a file that cannot go is refused while its path is still on
    the pane. {!read_file} holds the limit again at send time. *)
let attachable ~max_bytes path =
  match inspect path with
  | Error _ as refused -> refused
  | Ok { size; _ } when size > max_bytes -> Error (too_large ~max_bytes size)
  | Ok _ -> Ok ()
;;

(* The size to name when a read ran past the limit: what the file is now, and
   never less than what was already read of it. *)
let size_now descriptor ~at_least =
  match Unix.fstat descriptor with
  | { Unix.st_size; _ } -> max st_size at_least
  | exception Unix.Unix_error _ -> at_least
;;

(* The limit is a bound on what is read, not a size looked up first: a file
   can grow after it was staged. One byte past the limit is enough to know
   the file is over it, so no more than that is ever held. *)
let read_bounded ~max_bytes descriptor =
  let read = Buffer.create 65536 in
  let chunk = Bytes.create 65536 in
  let rec fill () =
    let room = max_bytes + 1 - Buffer.length read in
    if room = 0 then
      Error (too_large ~max_bytes (size_now descriptor ~at_least:(max_bytes + 1)))
    else
      match Unix.read descriptor chunk 0 (min room (Bytes.length chunk)) with
      | 0 -> Ok (Buffer.contents read)
      | count ->
          Buffer.add_subbytes read chunk 0 count;
          fill ()
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> fill ()
      | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
  in
  fill ()
;;

(** The staged file's bytes, read at send time. The path is inspected by
    name and then the opened file is checked to be that same file: a name can
    be pointed elsewhere between the two. The read stops one byte past
    [max_bytes] and refuses the file there. *)
let read_file ~max_bytes path =
  match inspect path with
  | Error _ as refused -> refused
  | Ok named -> (
      match Unix.openfile path [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ] 0 with
      | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
      | descriptor ->
          Fun.protect
            ~finally:(fun () ->
              try Unix.close descriptor with Unix.Unix_error _ -> ())
            (fun () ->
              match Unix.fstat descriptor with
              | exception Unix.Unix_error (error, _, _) ->
                  Error (Unix.error_message error)
              | opened ->
                  if
                    opened.Unix.st_kind = Unix.S_REG
                    && opened.st_dev = named.device
                    && opened.st_ino = named.inode
                  then read_bounded ~max_bytes descriptor
                  else Error "the file changed while it was being opened"))
;;

(** Read and upload each staged file in staging order, stopping at the first
    refusal: a post that names only some of its attachments is worse than no
    post, and the caller treats any [Error] as "not sent". [read] and
    [upload] are passed in: the TUI reads off its UI fiber and uploads over
    HTTP, and a test does neither. *)
let upload_staged ~read ~upload staged =
  let rec each sent = function
    | [] -> Ok (List.rev sent)
    | (file : Masc_tui_types.board_staged_attachment) :: rest -> (
        (* Either refusal names the file by the name the pane shows for it. *)
        let named detail = Error (Printf.sprintf "%s: %s" file.sa_name detail) in
        match read file.sa_path with
        | Error detail -> named detail
        | Ok bytes -> (
            match upload ~bytes with
            | Error detail -> named detail
            | Ok sha256 ->
                each
                  ({ Masc_tui_types.oa_kind = file.sa_kind
                   ; oa_sha256 = sha256
                   ; oa_name = file.sa_name
                   }
                   :: sent)
                  rest))
  in
  each [] staged
;;
