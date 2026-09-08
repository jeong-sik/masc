external spawnp :
  string -> string array -> string array -> (string option * bool) ->
  (int * Unix.file_descr) list -> int = "masc_posix_spawnp"

external exited_without_reaping : int -> bool = "masc_process_exited_without_reaping"

type state = Unstarted | Owned | Reaped of Unix.process_status | Lost

type t = { mutable state : state; mutable pid : int; lock : Stdlib.Mutex.t }

let create () = { state = Unstarted; pid = 0; lock = Stdlib.Mutex.create () }

let locked t f =
  Stdlib.Mutex.lock t.lock;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock t.lock) f


let spawn t executable argv env stdin_fd stdout_fd stderr_fd = locked t (fun () ->
  (match t.state with
   | Unstarted -> ()
   | Owned | Reaped _ | Lost -> invalid_arg "foreground owner already started");
  t.pid <- spawnp executable (Array.of_list argv) env (None, true)
      [ 0, stdin_fd; 1, stdout_fd; 2, stderr_fd ];
  t.state <- Owned)


let lost_child () = raise (Unix.Unix_error (Unix.ECHILD, "foreground owner", ""))

let observe t pid =
  try exited_without_reaping pid with
  | Unix.Unix_error (Unix.ECHILD, _, _) as exn ->
    t.state <- Lost;
    raise exn

let rec wait pid =
  try snd (Unix.waitpid [] pid) with
  | Unix.Unix_error (Unix.EINTR, _, _) -> wait pid

let finish t pid =
  (* [observe] both retains the leader anchor and detects loss of wait
     authority. No other code may reap a child owned by this module. *)
  (* See [observe]: running and exited children both retain our wait authority. *)
  ignore (observe t pid : bool);
  (try Unix.kill (-pid) Sys.sigkill with
   | Unix.Unix_error (Unix.ESRCH, _, _) -> ());
  match wait pid with
  | status -> t.state <- Reaped status; status
  | exception (Unix.Unix_error (Unix.ECHILD, _, _) as exn) ->
    t.state <- Lost;
    raise exn

let poll t = locked t (fun () ->
  match t.state with
  | Reaped status -> Some status
  | Lost -> lost_child ()
  | Unstarted -> None
  | Owned -> if observe t t.pid then Some (finish t t.pid) else None)

let terminate t = locked t (fun () ->
  match t.state with
  | Reaped status -> status
  | Lost -> lost_child ()
  | Unstarted -> invalid_arg "foreground owner not started"
  | Owned -> finish t t.pid)

let close t = locked t (fun () ->
  match t.state with
  | Unstarted | Reaped _ | Lost -> ()
  | Owned ->
    (* See [finish]: the exit status is recorded in [t] before it is returned. *)
    ignore (finish t t.pid : Unix.process_status))
