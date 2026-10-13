(** Uploading board-compose attachments to the artifact store.

    The wire half of the board write path (the read side's labels live in
    {!Masc_tui_board_attachments}). A staged file's bytes go to
    [POST /api/v1/artifacts] and the returned content address becomes the
    post payload's [attachments] entry.

    A library of its own so the transport and the sequencing can be driven
    without the executable around them. *)

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

let host_for_url host =
  if String.contains host ':' && not (String.starts_with ~prefix:"[" host) then
    "[" ^ host ^ "]"
  else host
;;

(** The raw POST: [bytes] as the body. Returns the status and body
    uninterpreted; what a refusal means is the caller's to say. *)
let post_artifact_raw ?clock ~timeout_sec ~headers ~host ~port ~bytes () =
  let url =
    Printf.sprintf "http://%s:%d/api/v1/artifacts" (host_for_url host) port
  in
  Masc_http_client.post_sync ?clock ~timeout_sec ~url
    ~headers:(("Content-Type", "application/octet-stream") :: headers)
    ~body:bytes ()
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
type inspected = { device : int; inode : int }

let inspect ~max_bytes path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Error "no such file"
  | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
  | { Unix.st_kind = Unix.S_DIR; _ } -> Error "that is a directory, not a file"
  (* A link shows its own name on the pane and uploads whatever it points
     at, which the name does not say. *)
  | { Unix.st_kind = Unix.S_LNK; _ } ->
      Error "that is a symbolic link; attach the file it points to"
  | { Unix.st_kind = Unix.S_REG; st_size = 0; _ } -> Error "the file is empty"
  | { Unix.st_kind = Unix.S_REG; st_size; _ } when st_size > max_bytes ->
      Error (too_large ~max_bytes st_size)
  | { Unix.st_kind = Unix.S_REG; st_dev; st_ino; _ } ->
      Ok { device = st_dev; inode = st_ino }
  | { Unix.st_kind = (Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK); _ } ->
    Error "not a regular file"
;;

(** Whether [path] can be attached: a regular file, not a link to one, that
    is not empty and no larger than [max_bytes]. The server refuses the rest,
    and a device or a pipe has no end to read to. Asked when the file is
    staged; {!read_file} asks again of the file it actually opened. *)
let attachable ~max_bytes path = Result.map ignore (inspect ~max_bytes path)

(** The staged file's bytes, read at send time. The path is inspected by
    name and then the opened file is inspected again: a name can be pointed
    elsewhere between the two, and a file can grow, so the read stops at
    [max_bytes] whatever its size said. *)
let read_file ~max_bytes path =
  match inspect ~max_bytes path with
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
              | { Unix.st_kind = Unix.S_REG; st_dev; st_ino; _ }
                when st_dev = named.device && st_ino = named.inode ->
                  let read = Buffer.create 65536 in
                  let chunk = Bytes.create 65536 in
                  let rec fill () =
                    if Buffer.length read > max_bytes then
                      Error (too_large ~max_bytes (Buffer.length read))
                    else
                      match Unix.read descriptor chunk 0 (Bytes.length chunk) with
                      | 0 -> Ok (Buffer.contents read)
                      | count ->
                          Buffer.add_subbytes read chunk 0 count;
                          fill ()
                      | exception Unix.Unix_error (Unix.EINTR, _, _) -> fill ()
                      | exception Unix.Unix_error (error, _, _) ->
                          Error (Unix.error_message error)
                  in
                  fill ()
              | { Unix.st_kind = Unix.S_REG; _ } ->
                Error "the file changed while it was being opened"
              | { Unix.st_kind =
                    (Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK); _ } ->
                Error "the file changed while it was being opened"))
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
