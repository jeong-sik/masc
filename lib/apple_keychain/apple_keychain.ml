type observation = Found of string | Missing | Unsupported | Unavailable

type access = Readable | Absent | Not_macos | Inaccessible

external security_access : string -> int = "masc_antigravity_keychain_security_access"

let access_of_code = function
  | 0 -> Readable
  | 1 -> Absent
  | 2 -> Not_macos
  | _ -> Inaccessible

let security_tool = "/usr/bin/security"
let service = "gemini"
let account = "antigravity"

(* go-keyring's Get waits on security(1) without a limit; a lock that lands
   between the native check and this run would leave security(1) waiting on
   a password dialog. Ending it is the refusal the native check would have
   given a moment earlier. *)
let deadline_s = 10.0

(* agy's value is one login JSON, base64 encoded: a few kilobytes. *)
let output_limit = 1 lsl 20

(* errSecItemNotFound, which security(1) returns as its exit status. *)
let item_not_found_exit = 44

type run = Exited of int * string | Failed

(* The read and the wait poll against the deadline instead of select(2),
   which refuses descriptors past FD_SETSIZE; the managed-keychain check runs
   inside the server, which can hold more than that many. *)
let poll_interval_s = 0.01

let read_until_deadline fd ~deadline =
  let buffer = Buffer.create 4096 in
  let chunk = Bytes.create 4096 in
  let rec loop () =
    match Unix.read fd chunk 0 (Bytes.length chunk) with
    | 0 -> Ok (Buffer.contents buffer)
    | n when Buffer.length buffer + n > output_limit -> Error `Too_long
    | n -> Buffer.add_subbytes buffer chunk 0 n; loop ()
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
      if Unix.gettimeofday () >= deadline then Error `Deadline
      else (Unix.sleepf poll_interval_s; loop ())
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
    | exception Unix.Unix_error _ -> Error `Read_failed
  in
  loop ()

let rec wait_until_deadline pid ~deadline =
  match Unix.waitpid [ Unix.WNOHANG ] pid with
  | 0, _ when Unix.gettimeofday () >= deadline -> `Running
  | 0, _ -> Unix.sleepf poll_interval_s; wait_until_deadline pid ~deadline
  | _, status -> `Ended status
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_until_deadline pid ~deadline
  | exception Unix.Unix_error _ -> `Lost

(* After SIGKILL the child ends without further help; reap it so no zombie
   is left. *)
let rec reap pid =
  match Unix.waitpid [] pid with
  | _ -> ()
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> reap pid
  | exception Unix.Unix_error _ -> ()

let kill_and_reap pid =
  (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
  reap pid

(* HIGH-RISK-UNREVIEWED: the only place masc runs security(1) on a login
   item. Fixed argv, no shell, stdin and stderr closed to it; called only
   after [security_access] answered [Readable] for the same path. *)
let run_security args =
  match Unix.pipe ~cloexec:true () with
  | exception Unix.Unix_error _ -> Failed
  | stdout_read, stdout_write ->
    let close_quietly fd = try Unix.close fd with Unix.Unix_error _ -> () in
    Fun.protect ~finally:(fun () -> close_quietly stdout_read) @@ fun () ->
    match Unix.openfile "/dev/null" [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 with
    | exception Unix.Unix_error _ -> close_quietly stdout_write; Failed
    | null ->
      let spawned =
        try Ok (Unix.create_process security_tool
                  (Array.of_list (security_tool :: args)) null stdout_write null)
        with Unix.Unix_error _ -> Error () in
      close_quietly stdout_write;
      close_quietly null;
      match spawned with
      | Error () -> Failed
      | Ok pid ->
        let deadline = Unix.gettimeofday () +. deadline_s in
        let output = match Unix.set_nonblock stdout_read with
          | () -> read_until_deadline stdout_read ~deadline
          | exception Unix.Unix_error _ -> Error `Read_failed in
        match output with
        | Error (`Deadline | `Too_long | `Read_failed) -> kill_and_reap pid; Failed
        | Ok text ->
          match wait_until_deadline pid ~deadline with
          | `Ended (Unix.WEXITED code) -> Exited (code, text)
          (* Already reaped: its pid may belong to another process now. *)
          | `Ended (Unix.WSIGNALED _) -> Failed
          (* Without WUNTRACED a stop is not reported; if it were, the child
             is still ours and alive. *)
          | `Ended (Unix.WSTOPPED _) -> kill_and_reap pid; Failed
          | `Running -> kill_and_reap pid; Failed
          (* Reaped by another waiter: the exit status, and so the answer, is lost. *)
          | `Lost -> Failed

(* security -w ends the value with one newline. *)
let value_of_output text =
  let length = String.length text in
  if length > 0 && text.[length - 1] = '\n' then String.sub text 0 (length - 1) else text

(* The keychain path is the last operand: security(1) parses options with
   getopt, which stops at the first operand. *)
let item_args ?(options = []) command path =
  (command :: "-s" :: service :: "-a" :: account :: options) @ [ path ]

let read ~path =
  match access_of_code (security_access path) with
  | Absent -> Missing
  | Not_macos -> Unsupported
  | Inaccessible -> Unavailable
  | Readable ->
    match run_security (item_args ~options:[ "-w" ] "find-generic-password" path) with
    | Exited (0, text) when String.trim (value_of_output text) <> "" -> Found (value_of_output text)
    | Exited (code, _) when code = item_not_found_exit -> Missing
    | Exited _ | Failed -> Unavailable

let clear ~path =
  match access_of_code (security_access path) with
  | Absent | Not_macos -> Ok ()
  | Inaccessible -> Error ()
  | Readable ->
    match run_security (item_args "delete-generic-password" path) with
    | Exited (0, _) -> Ok ()
    | Exited (code, _) when code = item_not_found_exit -> Ok ()
    | Exited _ | Failed -> Error ()
