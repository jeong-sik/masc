(* Named machine checkpoints. See machine_checkpoint.mli. *)

type machine = Dos | Msx

let machine_to_string = function Dos -> "dos" | Msx -> "msx"

let machine_of_string = function
  | "dos" -> Some Dos
  | "msx" -> Some Msx
  | _ -> None
;;

type slot = string

let max_slot_length = 64

let slot_of_string s =
  let valid_char = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
    | _ -> false
  in
  if String.length s < 1 || String.length s > max_slot_length || not (String.for_all valid_char s)
  then Error "slot must be 1..64 letters, digits, underscores or hyphens"
  else Ok s
;;

let slot_to_string s = s

let slot_of_arguments ~default = function
  | `Assoc fields when List.for_all (fun (name, _) -> String.equal name "slot") fields -> (
    match fields with
    | [] -> slot_of_string default
    | [ (_, `String value) ] -> slot_of_string value
    | _ :: _ -> Error "slot must be one string")
  | _ -> Error "checkpoint arguments must be an object"
;;

type header = { machine : machine; format : int; core : string }

type error =
  | No_slot of slot
  | Unreadable of string
  | Other_machine of { saved : machine; expected : machine }
  | Other_format of { saved : int; expected : int }
  | Corrupt of string

let error_to_string = function
  | No_slot slot -> Printf.sprintf "no checkpoint named %s" slot
  | Unreadable message -> message
  | Other_machine { saved; expected } ->
    Printf.sprintf "that checkpoint is a %s machine, not a %s one"
      (machine_to_string saved) (machine_to_string expected)
  | Other_format { saved; expected } ->
    Printf.sprintf
      "that checkpoint is format %d and this server reads only format %d; it cannot be restored"
      saved expected
  | Corrupt message -> "that checkpoint does not read: " ^ message
;;

let extension = ".ckpt"
let path ~dir slot = Filename.concat dir (slot ^ extension)
let magic = "MASC-MACHINE-CHECKPOINT\000"

(* ---------- encoding ---------- *)

let int64_bytes n =
  let b = Bytes.create 8 in
  Bytes.set_int64_be b 0 (Int64.of_int n);
  Bytes.to_string b
;;

let sized s = int64_bytes (String.length s) ^ s

type compression = Raw | Zstd

let compression_byte = function Raw -> '\000' | Zstd -> '\001'

let compression_of_byte = function
  | '\000' -> Some Raw
  | '\001' -> Some Zstd
  | _ -> None
;;

let encode (h : header) ~meta ~machine_bytes =
  let body = sized (Yojson.Safe.to_string meta) ^ machine_bytes in
  let compression, stored =
    match Compression_codec.compress body with
    | Compression_codec.Compressed { payload; encoding = Compression_codec.Standard } ->
      (Zstd, payload)
    | Compression_codec.Compressed { encoding = Compression_codec.Dictionary; _ }
    | Compression_codec.Unchanged _ -> (Raw, body)
  in
  String.concat ""
    [ magic
    ; sized (machine_to_string h.machine)
    ; sized h.core
    ; int64_bytes h.format
    ; int64_bytes (String.length body)
    ; Digest.string body
    ; String.make 1 (compression_byte compression)
    ; stored
    ]
;;

(* ---------- decoding ---------- *)

exception Bad of string

type cursor = { s : string; mutable at : int }

let take c n =
  if n < 0 || c.at + n > String.length c.s then raise (Bad "truncated");
  let v = String.sub c.s c.at n in
  c.at <- c.at + n;
  v
;;

let int64 c = Int64.to_int (String.get_int64_be (take c 8) 0)

let string c =
  let n = int64 c in
  if n < 0 then raise (Bad "negative length");
  take c n
;;

(* The header is the first bytes of the file, ahead of the body. [take] is how
   the bytes arrive, so a string in memory and a file read from its front
   decode through one function. [total] is how many bytes exist: a length the
   file cannot honour is a truncation, whichever way the bytes arrive. *)
let decode_header_via ~take ~total =
  if total < String.length magic || not (String.equal (take (String.length magic)) magic)
  then raise (Bad "not a machine checkpoint");
  let int64 () = Int64.to_int (String.get_int64_be (take 8) 0) in
  let string () =
    let n = int64 () in
    if n < 0 then raise (Bad "negative length");
    take n
  in
  let machine =
    match machine_of_string (string ()) with
    | Some m -> m
    | None -> raise (Bad "unknown machine")
  in
  let core = string () in
  let format = int64 () in
  { machine; format; core }
;;

let decode_header c = decode_header_via ~take:(take c) ~total:(String.length c.s)

type contents = { header : header; meta : Yojson.Safe.t; machine_bytes : string }

(* The header check, the checksum and the decompression: everything a reader
   needs regardless of whether it goes on to split the body into [meta] and
   the machine bytes, or stops at [meta] alone. *)
let decode_body ~machine ~format s =
  let c = { s; at = 0 } in
  match decode_header c with
  | exception Bad message -> Error (Corrupt message)
  | h when h.machine <> machine -> Error (Other_machine { saved = h.machine; expected = machine })
  | h when h.format <> format -> Error (Other_format { saved = h.format; expected = format })
  | h ->
    (match
       let size = int64 c in
       let sum = take c 16 in
       let compression = take c 1 in
       let stored = take c (String.length s - c.at) in
       let body =
         match compression_of_byte compression.[0] with
         | Some Raw -> stored
         | Some Zstd ->
           (match Compression_codec.decompress ~orig_size:size stored with
            | Ok body -> body
            | Error message -> raise (Bad message))
         | None -> raise (Bad "unknown compression")
       in
       if String.length body <> size || not (String.equal (Digest.string body) sum) then
         raise (Bad "checksum mismatch");
       body
     with
     | body -> Ok (h, body)
     | exception Bad message -> Error (Corrupt message))
;;

let decode ~machine ~format s =
  match decode_body ~machine ~format s with
  | Error e -> Error e
  | Ok (header, body) ->
    (match
       let b = { s = body; at = 0 } in
       let meta = Yojson.Safe.from_string (string b) in
       let machine_bytes = take b (String.length body - b.at) in
       { header; meta; machine_bytes }
     with
     | contents -> Ok contents
     | exception Bad message -> Error (Corrupt message)
     | exception Yojson.Json_error message -> Error (Corrupt message))
;;

type meta_contents = { header : header; meta : Yojson.Safe.t; modified : float }

(* Same body, but the machine bytes are never sliced out: [take] on the tail
   is a [String.sub] the size of the whole guest memory, and a caller asking
   only what a checkpoint is should not pay for a copy of it. *)
let decode_meta ~machine ~format s =
  match decode_body ~machine ~format s with
  | Error e -> Error e
  | Ok (header, body) ->
    (match Yojson.Safe.from_string (string { s = body; at = 0 }) with
     | meta -> Ok (header, meta)
     | exception Bad message -> Error (Corrupt message)
     | exception Yojson.Json_error message -> Error (Corrupt message))
;;

(* ---------- files ---------- *)

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then begin
    mkdir_p (Filename.dirname dir);
    try Sys.mkdir dir 0o755 with Sys_error _ when Sys.file_exists dir -> ()
  end
;;

(* Fs_compat.save_file_atomic writes a sibling temp file, fsyncs it, renames
   it over the slot and fsyncs the directory. A bare rename could leave an
   empty or partial checkpoint after a crash, and that file is the only copy
   of a campaign after a restart.

   It is not the strict variant, on purpose. Both fsync the bytes before the
   rename, which is what keeps a partial file out of the slot. They differ in
   the fsync of the directory after it: this one ignores its error, and a file
   system's refusal to fsync (EINVAL, EOPNOTSUPP, as on some tmpfs and FUSE
   mounts). What that costs is a crash right after the rename bringing back the
   previous checkpoint, which is a valid one. The strict variant would turn
   the same file systems into a permanent write failure, with no autosave at
   all. *)
let write ~dir slot header ~meta ~machine_bytes =
  let contents = encode header ~meta ~machine_bytes in
  match mkdir_p dir with
  | exception Sys_error message -> Error message
  | () -> Fs_compat.save_file_atomic (path ~dir slot) contents
;;

let read_file file = In_channel.with_open_bin file In_channel.input_all

(* The bytes of [from] under [to_], whole and unread: a checkpoint this server
   cannot decode copies like any other. The replace is [write]'s, so [to_] is
   the old file or the complete copy, and [from] is never touched. *)
let copy ~dir ~from ~to_ =
  match read_file (path ~dir from) with
  | exception Sys_error message -> Error message
  | contents -> Fs_compat.save_file_atomic (path ~dir to_) contents
;;

let load_file ~dir slot =
  let file = path ~dir slot in
  if not (Sys.file_exists file) then Error (No_slot slot)
  else
    match read_file file with
    | exception Sys_error message -> Error (Unreadable message)
    | s -> Ok (file, s)
;;

let read ~dir slot ~machine ~format =
  match load_file ~dir slot with
  | Error e -> Error e
  | Ok (_file, s) -> decode ~machine ~format s
;;

let read_meta ~dir slot ~machine ~format =
  match load_file ~dir slot with
  | Error e -> Error e
  | Ok (file, s) ->
    (match decode_meta ~machine ~format s with
     | Error e -> Error e
     | Ok (header, meta) ->
       (match Unix.stat file with
        | st -> Ok { header; meta; modified = st.Unix.st_mtime }
        | exception Unix.Unix_error (e, _, _) -> Error (Unreadable (Unix.error_message e))))
;;

type listed = {
  slot : slot;
  size : int;
  modified : float;
  header : (header, error) result;
}

(* A listing names what each file is; the machine bytes behind the header are
   megabytes and play no part in that. Reading the front of the file keeps a
   listing of a full checkpoint directory from reading all of it. A length in
   the header that runs past the end of the file is a truncation, not a
   reason to allocate it. *)
let read_header_of_file file ~size =
  match
    In_channel.with_open_bin file (fun ic ->
      let at = ref 0 in
      let take n =
        if n < 0 || !at + n > size then raise (Bad "truncated");
        match really_input_string ic n with
        | bytes ->
          at := !at + n;
          bytes
        | exception End_of_file -> raise (Bad "truncated")
      in
      decode_header_via ~take ~total:size)
  with
  | header -> Ok header
  | exception Bad message -> Error (Corrupt message)
  | exception Sys_error message -> Error (Unreadable message)
;;

let list ~dir =
  if not (Sys.file_exists dir) then Ok []
  else
    match Sys.readdir dir with
    | exception Sys_error message -> Error message
    | names ->
      Array.to_list names
      |> List.filter_map (fun name ->
        if not (Filename.check_suffix name extension) then None
        else
          match slot_of_string (Filename.chop_suffix name extension) with
          | Error _ -> None
          | Ok slot ->
            let file = Filename.concat dir name in
            (match Unix.stat file with
             | exception Unix.Unix_error (e, _, _) ->
               Some { slot; size = 0; modified = 0.;
                      header = Error (Unreadable (Unix.error_message e)) }
             | st ->
               let size = st.Unix.st_size in
               Some { slot; size; modified = st.Unix.st_mtime;
                      header = read_header_of_file file ~size }))
      |> List.sort (fun a b -> String.compare a.slot b.slot)
      |> fun l -> Ok l
;;
