type t = { state : string; parent : int; group : int; start : string }

(* The fields after pgrp start at field 6, so field 22 is the 17th. *)
let start_after_group = 16

let parse line =
  match String.rindex_opt line ')' with
  | None -> None
  | Some close ->
    let after = String.sub line (close + 1) (String.length line - close - 1) in
    (match List.filter (fun field -> field <> "") (String.split_on_char ' ' (String.trim after)) with
     | state :: ppid :: pgrp :: rest ->
       (match int_of_string_opt ppid, int_of_string_opt pgrp, List.nth_opt rest start_after_group with
        | Some parent, Some group, Some start -> Some { state; parent; group; start }
        | _ -> None)
     | [ _; _ ] | [ _ ] | [] -> None)

(* A stat line is a few hundred bytes. *)
let read_chunk_bytes = 512

(* Read through [Unix] rather than a channel: a channel turns the errno into
   [Sys_error] text, and [ESRCH] for a process reaped after the open has to
   reach the caller as itself. *)
let read pid =
  let fd = Unix.openfile (Printf.sprintf "/proc/%d/stat" pid) [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect
    ~finally:(fun () ->
      (* The line is read or the read has failed by now; a close that fails
         on a read-only /proc file changes neither. *)
      try Unix.close fd with Unix.Unix_error (_, _, _) -> ())
    (fun () ->
      let line = Buffer.create read_chunk_bytes and chunk = Bytes.create read_chunk_bytes in
      let rec fill () =
        match Unix.read fd chunk 0 read_chunk_bytes with
        | 0 -> Buffer.contents line
        | count ->
          Buffer.add_subbytes line chunk 0 count;
          fill ()
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> fill ()
      in
      fill ())
