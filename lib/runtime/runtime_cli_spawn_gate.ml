(* See .mli for the incident derivation of both bounds. *)

let max_concurrent_cli_spawns = 8
let child_fd_ceiling = 16000

let slots = Eio.Semaphore.make max_concurrent_cli_spawns
let active = Atomic.make 0

let with_cli_spawn_slot f =
  (* Acquire first: a cancelled waiter never reaches the counter. Release
     cannot suspend, so the finally arm is total. *)
  Eio.Semaphore.acquire slots;
  Atomic.incr active;
  Fun.protect
    ~finally:(fun () ->
      Atomic.decr active;
      Eio.Semaphore.release slots)
    (fun () -> Fd_accountant.observe ~kind:Fd_accountant.Provider_cli f)
;;

let active_cli_spawns () = Atomic.get active

let count_proc_fds ~pid =
  if pid <= 0
  then None
  else (
    match Sys.readdir (Printf.sprintf "/proc/%d/fd" pid) with
    | entries -> Some (Array.length entries)
    | exception Sys_error _ | exception Unix.Unix_error _ -> None)
;;

let count_lsof_lines output =
  match String.split_on_char '\n' output with
  | [] -> 0
  | _header :: rest ->
    List.fold_left
      (fun count line -> if String.trim line = "" then count else count + 1)
      0
      rest
;;

let lsof_child_fds ~mgr ~cwd ~pid =
  if pid <= 0
  then None
  else (
    try
      let stderr_buf = Buffer.create 256 in
      let output =
        Eio.Process.parse_out
          mgr
          Eio.Buf_read.take_all
          ~cwd
          ~stderr:(Eio.Flow.buffer_sink stderr_buf)
          [ "lsof"; "-p"; string_of_int pid ]
      in
      Some (count_lsof_lines output)
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | _ -> None)
;;

let child_fd_count ~mgr ~cwd ~pid =
  match count_proc_fds ~pid with
  | Some _ as count -> count
  | None -> lsof_child_fds ~mgr ~cwd ~pid
;;

module For_testing = struct
  let count_proc_fds = count_proc_fds
  let count_lsof_lines = count_lsof_lines
end
