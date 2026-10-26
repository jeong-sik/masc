module Injected_unix = struct
include Unix
let interrupts=ref 0
let read fd buffer offset length =
  if !interrupts>0 then (decr interrupts;raise (Unix_error (EINTR,"read","injected")))
  else Unix.read fd buffer offset (min 97 length)
end

module Baseline = struct
let ( let* ) = Result.bind
type record_verification = Visible | Durable
(* [Republished]: the path names another file by the end of the read, so
   the bytes read belong to a file the path no longer names. *)
type confirmed_read = Confirmed of string | Republished
let same_file a b = a.Unix.st_dev=b.Unix.st_dev && a.Unix.st_ino=b.Unix.st_ino
let record_bytes fd size =
  let buffer=Bytes.create size in
  let rec read offset =
    if offset=size then Ok () else
    match Unix.read fd buffer offset (size-offset) with
    | 0 -> Error "retained file shrank during read"
    | count -> read (offset+count)
    | exception Unix.Unix_error (Unix.EINTR,_,_) -> read offset in
  let* ()=read 0 in
  let rec end_of_record () =
    match Unix.read fd (Bytes.create 1) 0 1 with
    | 0 ->
      (* This read owns [buffer]; it has never escaped and no write follows
         EOF. Transfer it to the immutable result without copying the whole
         record. The verification read still owns a distinct buffer. *)
      Ok (Bytes.unsafe_to_string buffer)
    | _ -> Error "retained file grew during read"
    | exception Unix.Unix_error (Unix.EINTR,_,_) -> end_of_record () in
  end_of_record ()
let with_record_fd path fn =
  let fd = Unix.openfile path [Unix.O_RDONLY;Unix.O_NONBLOCK;Unix.O_CLOEXEC] 0 in
  match fn fd with
  | result -> Unix.close fd;result
  | exception exn ->
    let backtrace=Printexc.get_raw_backtrace () in
    (try Unix.close fd with Unix.Unix_error _ -> ());
    Printexc.raise_with_backtrace exn backtrace
let verify_record_bytes path fd stat bytes =
  let _offset=Unix.lseek fd 0 Unix.SEEK_SET in
  let* verified=record_bytes fd stat.Unix.st_size in
  if verified<>bytes then Error "retained file changed during sync"
  else if same_file stat (Unix.stat path) then Ok (Confirmed bytes)
  else Ok Republished
let settle_verified_record ~sync_file ~sync_parent path fd stat bytes parent_fd =
  let parent=Filename.dirname path in
  let parent_stat=Unix.fstat parent_fd in
  if parent_stat.Unix.st_kind<>Unix.S_DIR then Error "retained file parent is not a directory"
  else (
    sync_file fd;sync_parent parent_fd;
    let* read=verify_record_bytes path fd stat bytes in
    if same_file parent_stat (Unix.stat parent) then Ok read
    else Error "retained file parent changed during sync")
let read_verified_record ~sync_file ~sync_parent ~verification path fd stat =
  let* bytes=record_bytes fd stat.Unix.st_size in
  match verification with
  | Visible -> verify_record_bytes path fd stat bytes
  | Durable ->
    let parent=Filename.dirname path in
    with_record_fd parent (settle_verified_record ~sync_file ~sync_parent path fd stat bytes)
let changed_during_verification = function
  | Confirmed bytes -> Ok bytes
  | Republished -> Error "retained file changed during verification"

let observe ~sync_file ~sync_parent path =
  with_record_fd path (fun fd ->
    let stat=Unix.fstat fd in
    Result.bind (read_verified_record ~sync_file ~sync_parent ~verification:Durable path fd stat)
      changed_during_verification)
end

module Baseline_faults = struct
module Unix = Injected_unix
let ( let* ) = Result.bind
type record_verification = Visible | Durable
(* [Republished]: the path names another file by the end of the read, so
   the bytes read belong to a file the path no longer names. *)
type confirmed_read = Confirmed of string | Republished
let same_file a b = a.Unix.st_dev=b.Unix.st_dev && a.Unix.st_ino=b.Unix.st_ino
let record_bytes fd size =
  let buffer=Bytes.create size in
  let rec read offset =
    if offset=size then Ok () else
    match Unix.read fd buffer offset (size-offset) with
    | 0 -> Error "retained file shrank during read"
    | count -> read (offset+count)
    | exception Unix.Unix_error (Unix.EINTR,_,_) -> read offset in
  let* ()=read 0 in
  let rec end_of_record () =
    match Unix.read fd (Bytes.create 1) 0 1 with
    | 0 ->
      (* This read owns [buffer]; it has never escaped and no write follows
         EOF. Transfer it to the immutable result without copying the whole
         record. The verification read still owns a distinct buffer. *)
      Ok (Bytes.unsafe_to_string buffer)
    | _ -> Error "retained file grew during read"
    | exception Unix.Unix_error (Unix.EINTR,_,_) -> end_of_record () in
  end_of_record ()
let with_record_fd path fn =
  let fd = Unix.openfile path [Unix.O_RDONLY;Unix.O_NONBLOCK;Unix.O_CLOEXEC] 0 in
  match fn fd with
  | result -> Unix.close fd;result
  | exception exn ->
    let backtrace=Printexc.get_raw_backtrace () in
    (try Unix.close fd with Unix.Unix_error _ -> ());
    Printexc.raise_with_backtrace exn backtrace
let verify_record_bytes path fd stat bytes =
  let _offset=Unix.lseek fd 0 Unix.SEEK_SET in
  let* verified=record_bytes fd stat.Unix.st_size in
  if verified<>bytes then Error "retained file changed during sync"
  else if same_file stat (Unix.stat path) then Ok (Confirmed bytes)
  else Ok Republished
let settle_verified_record ~sync_file ~sync_parent path fd stat bytes parent_fd =
  let parent=Filename.dirname path in
  let parent_stat=Unix.fstat parent_fd in
  if parent_stat.Unix.st_kind<>Unix.S_DIR then Error "retained file parent is not a directory"
  else (
    sync_file fd;sync_parent parent_fd;
    let* read=verify_record_bytes path fd stat bytes in
    if same_file parent_stat (Unix.stat parent) then Ok read
    else Error "retained file parent changed during sync")
let read_verified_record ~sync_file ~sync_parent ~verification path fd stat =
  let* bytes=record_bytes fd stat.Unix.st_size in
  match verification with
  | Visible -> verify_record_bytes path fd stat bytes
  | Durable ->
    let parent=Filename.dirname path in
    with_record_fd parent (settle_verified_record ~sync_file ~sync_parent path fd stat bytes)
let changed_during_verification = function
  | Confirmed bytes -> Ok bytes
  | Republished -> Error "retained file changed during verification"

let observe ~sync_file ~sync_parent path =
  with_record_fd path (fun fd ->
    let stat=Unix.fstat fd in
    Result.bind (read_verified_record ~sync_file ~sync_parent ~verification:Durable path fd stat)
      changed_during_verification)
end

module Candidate = struct
let ( let* ) = Result.bind
type record_verification = Visible | Durable
(* [Republished]: the path names another file by the end of the read, so
   the bytes read belong to a file the path no longer names. *)
type confirmed_read = Confirmed of string | Republished
let same_file a b = a.Unix.st_dev=b.Unix.st_dev && a.Unix.st_ino=b.Unix.st_ino
let record_bytes fd size =
  let buffer=Bytes.create size in
  let rec read offset =
    if offset=size then Ok () else
    match Unix.read fd buffer offset (size-offset) with
    | 0 -> Error "retained file shrank during read"
    | count -> read (offset+count)
    | exception Unix.Unix_error (Unix.EINTR,_,_) -> read offset in
  let* ()=read 0 in
  let rec end_of_record () =
    match Unix.read fd (Bytes.create 1) 0 1 with
    | 0 ->
      (* This read owns [buffer]; it has never escaped and no write follows
         EOF. Transfer it to the immutable result without copying the whole
         record. The verification read still owns a distinct buffer. *)
      Ok (Bytes.unsafe_to_string buffer)
    | _ -> Error "retained file grew during read"
    | exception Unix.Unix_error (Unix.EINTR,_,_) -> end_of_record () in
  end_of_record ()
let with_record_fd path fn =
  let fd = Unix.openfile path [Unix.O_RDONLY;Unix.O_NONBLOCK;Unix.O_CLOEXEC] 0 in
  match fn fd with
  | result -> Unix.close fd;result
  | exception exn ->
    let backtrace=Printexc.get_raw_backtrace () in
    (try Unix.close fd with Unix.Unix_error _ -> ());
    Printexc.raise_with_backtrace exn backtrace
let verify_record_bytes path fd stat bytes =
  let _offset=Unix.lseek fd 0 Unix.SEEK_SET in
  let size=stat.Unix.st_size in
  let* verified=
    if size <= 2 * Sys.io_buffer_size then record_bytes fd size
    else
      (* Two reusable I/O buffers replace the second file-sized allocation.
         Keep the direct read when it needs no more memory than this pair.
         Neither scratch buffer aliases the immutable first observation. *)
      let observed=Bytes.create Sys.io_buffer_size in
      let expected=Bytes.create Sys.io_buffer_size in
      let rec fill offset length =
        if offset=length then Ok () else
        match Unix.read fd observed offset (length-offset) with
        | 0 -> Error "retained file shrank during read"
        | count -> fill (offset+count) length
        | exception Unix.Unix_error (Unix.EINTR,_,_) -> fill offset length in
      let eof=Bytes.create 1 in
      let rec finish unchanged =
        match Unix.read fd eof 0 1 with
        | 0 -> if unchanged then Ok bytes else Error "retained file changed during sync"
        | _ -> Error "retained file grew during read"
        | exception Unix.Unix_error (Unix.EINTR,_,_) -> finish unchanged in
      let rec compare offset unchanged =
        if offset=size then finish unchanged else
        let count=min (Bytes.length observed) (size-offset) in
        let* ()=fill 0 count in
        Bytes.blit_string bytes offset expected 0 count;
        (* A short final chunk leaves equal tails from the preceding full
           comparison whenever [unchanged] is true. A prior mismatch stays
           false; still read through EOF to retain shrink/growth failures. *)
        let unchanged=unchanged && Bytes.equal observed expected in
        compare (offset+count) unchanged in
      compare 0 true in
  if verified<>bytes then Error "retained file changed during sync"
  else if same_file stat (Unix.stat path) then Ok (Confirmed bytes)
  else Ok Republished
let settle_verified_record ~sync_file ~sync_parent path fd stat bytes parent_fd =
  let parent=Filename.dirname path in
  let parent_stat=Unix.fstat parent_fd in
  if parent_stat.Unix.st_kind<>Unix.S_DIR then Error "retained file parent is not a directory"
  else (
    sync_file fd;sync_parent parent_fd;
    let* read=verify_record_bytes path fd stat bytes in
    if same_file parent_stat (Unix.stat parent) then Ok read
    else Error "retained file parent changed during sync")
let read_verified_record ~sync_file ~sync_parent ~verification path fd stat =
  let* bytes=record_bytes fd stat.Unix.st_size in
  match verification with
  | Visible -> verify_record_bytes path fd stat bytes
  | Durable ->
    let parent=Filename.dirname path in
    with_record_fd parent (settle_verified_record ~sync_file ~sync_parent path fd stat bytes)
let changed_during_verification = function
  | Confirmed bytes -> Ok bytes
  | Republished -> Error "retained file changed during verification"

let observe ~sync_file ~sync_parent path =
  with_record_fd path (fun fd ->
    let stat=Unix.fstat fd in
    Result.bind (read_verified_record ~sync_file ~sync_parent ~verification:Durable path fd stat)
      changed_during_verification)
end

module Candidate_faults = struct
module Unix = Injected_unix
let ( let* ) = Result.bind
type record_verification = Visible | Durable
(* [Republished]: the path names another file by the end of the read, so
   the bytes read belong to a file the path no longer names. *)
type confirmed_read = Confirmed of string | Republished
let same_file a b = a.Unix.st_dev=b.Unix.st_dev && a.Unix.st_ino=b.Unix.st_ino
let record_bytes fd size =
  let buffer=Bytes.create size in
  let rec read offset =
    if offset=size then Ok () else
    match Unix.read fd buffer offset (size-offset) with
    | 0 -> Error "retained file shrank during read"
    | count -> read (offset+count)
    | exception Unix.Unix_error (Unix.EINTR,_,_) -> read offset in
  let* ()=read 0 in
  let rec end_of_record () =
    match Unix.read fd (Bytes.create 1) 0 1 with
    | 0 ->
      (* This read owns [buffer]; it has never escaped and no write follows
         EOF. Transfer it to the immutable result without copying the whole
         record. The verification read still owns a distinct buffer. *)
      Ok (Bytes.unsafe_to_string buffer)
    | _ -> Error "retained file grew during read"
    | exception Unix.Unix_error (Unix.EINTR,_,_) -> end_of_record () in
  end_of_record ()
let with_record_fd path fn =
  let fd = Unix.openfile path [Unix.O_RDONLY;Unix.O_NONBLOCK;Unix.O_CLOEXEC] 0 in
  match fn fd with
  | result -> Unix.close fd;result
  | exception exn ->
    let backtrace=Printexc.get_raw_backtrace () in
    (try Unix.close fd with Unix.Unix_error _ -> ());
    Printexc.raise_with_backtrace exn backtrace
let verify_record_bytes path fd stat bytes =
  let _offset=Unix.lseek fd 0 Unix.SEEK_SET in
  let size=stat.Unix.st_size in
  let* verified=
    if size <= 2 * Sys.io_buffer_size then record_bytes fd size
    else
      (* Two reusable I/O buffers replace the second file-sized allocation.
         Keep the direct read when it needs no more memory than this pair.
         Neither scratch buffer aliases the immutable first observation. *)
      let observed=Bytes.create Sys.io_buffer_size in
      let expected=Bytes.create Sys.io_buffer_size in
      let rec fill offset length =
        if offset=length then Ok () else
        match Unix.read fd observed offset (length-offset) with
        | 0 -> Error "retained file shrank during read"
        | count -> fill (offset+count) length
        | exception Unix.Unix_error (Unix.EINTR,_,_) -> fill offset length in
      let eof=Bytes.create 1 in
      let rec finish unchanged =
        match Unix.read fd eof 0 1 with
        | 0 -> if unchanged then Ok bytes else Error "retained file changed during sync"
        | _ -> Error "retained file grew during read"
        | exception Unix.Unix_error (Unix.EINTR,_,_) -> finish unchanged in
      let rec compare offset unchanged =
        if offset=size then finish unchanged else
        let count=min (Bytes.length observed) (size-offset) in
        let* ()=fill 0 count in
        Bytes.blit_string bytes offset expected 0 count;
        (* A short final chunk leaves equal tails from the preceding full
           comparison whenever [unchanged] is true. A prior mismatch stays
           false; still read through EOF to retain shrink/growth failures. *)
        let unchanged=unchanged && Bytes.equal observed expected in
        compare (offset+count) unchanged in
      compare 0 true in
  if verified<>bytes then Error "retained file changed during sync"
  else if same_file stat (Unix.stat path) then Ok (Confirmed bytes)
  else Ok Republished
let settle_verified_record ~sync_file ~sync_parent path fd stat bytes parent_fd =
  let parent=Filename.dirname path in
  let parent_stat=Unix.fstat parent_fd in
  if parent_stat.Unix.st_kind<>Unix.S_DIR then Error "retained file parent is not a directory"
  else (
    sync_file fd;sync_parent parent_fd;
    let* read=verify_record_bytes path fd stat bytes in
    if same_file parent_stat (Unix.stat parent) then Ok read
    else Error "retained file parent changed during sync")
let read_verified_record ~sync_file ~sync_parent ~verification path fd stat =
  let* bytes=record_bytes fd stat.Unix.st_size in
  match verification with
  | Visible -> verify_record_bytes path fd stat bytes
  | Durable ->
    let parent=Filename.dirname path in
    with_record_fd parent (settle_verified_record ~sync_file ~sync_parent path fd stat bytes)
let changed_during_verification = function
  | Confirmed bytes -> Ok bytes
  | Republished -> Error "retained file changed during verification"

let observe ~sync_file ~sync_parent path =
  with_record_fd path (fun fd ->
    let stat=Unix.fstat fd in
    Result.bind (read_verified_record ~sync_file ~sync_parent ~verification:Durable path fd stat)
      changed_during_verification)
end

let path=Sys.argv.(1)
let save path bytes=Out_channel.with_open_bin path (fun output -> output_string output bytes)
let payload size=String.init size (fun offset -> Char.chr ((offset * 13 + offset / 65536) mod 256))
let readers=["baseline",Baseline.observe;"candidate",Candidate.observe]
let fault_readers=["baseline",Baseline_faults.observe;"candidate",Candidate_faults.observe]
let observe reader ?(mutate=fun () -> ()) path =
  reader ~sync_file:(fun fd -> Unix.fsync fd;mutate ()) ~sync_parent:Unix.fsync path
let check label expected actual =
  if expected<>actual then failwith (label ^ ": baseline/candidate or required outcome differs");
  Printf.printf "CHECK\t%s\n%!" label
let () =
  List.iter (fun size ->
    let bytes=payload size in
    save path bytes;
    List.iter (fun (name,reader) ->
      check (name ^ " stable " ^ string_of_int size) (Ok bytes) (observe reader path)) readers)
    [0;1;65535;65536;131071;131072;131073;1048576;1048593];
  List.iter (fun size ->
    let bytes=payload size in save path bytes;
    List.iter (fun (name,reader) ->
      Injected_unix.interrupts:=3;
      check (name ^ " real short reads after EINTR " ^ string_of_int size)
        (Ok bytes) (observe reader path)) fault_readers) [0;64;131073;1048593];
  let bytes=payload 1048593 in
  List.iter (fun offset ->
    let results=List.map (fun (_,reader) ->
      save path bytes;
      observe reader ~mutate:(fun () ->
        let fd=Unix.openfile path [Unix.O_WRONLY] 0 in
        Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
          ignore (Unix.lseek fd offset Unix.SEEK_SET);
          let replacement=String.make 1 (Char.chr ((Char.code bytes.[offset]+1) mod 256)) in
          if Unix.write_substring fd replacement 0 1<>1 then failwith "short mutation")) path) readers in
    List.iter (check ("mutation " ^ string_of_int offset) (Error "retained file changed during sync")) results)
    [0;65535;65536;131071;131072;1048575;1048576;1048592];
  List.iter (fun (name,reader) ->
    save path bytes;
    check (name ^ " shrink") (Error "retained file shrank during read")
      (observe reader ~mutate:(fun () -> Unix.truncate path (String.length bytes-1)) path);
    save path bytes;
    check (name ^ " grow") (Error "retained file grew during read")
      (observe reader ~mutate:(fun () ->
        Out_channel.with_open_gen [Open_wronly;Open_append;Open_binary] 0o600 path
          (fun output -> output_char output '\000')) path);
    save path bytes;
    let held=path ^ ".held" in
    let result=observe reader ~mutate:(fun () -> Unix.rename path held;save path bytes) path in
    Unix.unlink path;Unix.rename held path;
    check (name ^ " identical replacement") (Error "retained file changed during verification") result;
    let calls=ref 0 in
    let result=reader ~sync_file:(fun fd -> incr calls;Unix.fsync fd)
      ~sync_parent:(fun fd -> incr calls;Unix.fsync fd) path in
    check (name ^ " real fsync calls") 2 !calls;
    check (name ^ " real fsync bytes") (Ok bytes) result) readers;
  Printf.printf "role,size,reads,block,elapsed_ms,allocated_bytes\n%!";
  List.iter (fun (size,count) ->
    let bytes=payload size in save path bytes;
    List.iteri (fun block name ->
      let reader=List.assoc name readers in
      let allocation=Gc.allocated_bytes () in
      let started=Mtime_clock.elapsed_ns () in
      for _=1 to count do
        match observe reader path with
        | Ok actual when String.equal actual bytes -> ()
        | Ok _ -> failwith "benchmark changed bytes"
        | Error detail -> failwith detail
      done;
      let elapsed=Int64.to_float (Int64.sub (Mtime_clock.elapsed_ns ()) started)/.1e6 in
      let allocated=Gc.allocated_bytes ()-.allocation in
      Printf.printf "%s,%d,%d,%d,%.6f,%.0f\n%!" name size count block elapsed allocated)
      ["baseline";"candidate";"candidate";"baseline"])
    [64,300;65536,300;131072,300;1048576,30;1048576,300;4194321,30];
  Sys.remove path
