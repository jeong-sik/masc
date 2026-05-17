type kind = Docker_spawn | Provider_http | Sandbox_exec | Log_writer

let all_kinds = [ Docker_spawn; Provider_http; Sandbox_exec; Log_writer ]

let kind_to_string = function
  | Docker_spawn -> "docker_spawn"
  | Provider_http -> "provider_http"
  | Sandbox_exec -> "sandbox_exec"
  | Log_writer -> "log_writer"

let kind_of_string = function
  | "docker_spawn" -> Some Docker_spawn
  | "provider_http" -> Some Provider_http
  | "sandbox_exec" -> Some Sandbox_exec
  | "log_writer" -> Some Log_writer
  | _ -> None

let env_var = function
  | Docker_spawn -> "MASC_DOCKER_SPAWN_CONCURRENCY"
  | Provider_http -> "MASC_PROVIDER_HTTP_CONCURRENCY"
  | Sandbox_exec -> "MASC_SANDBOX_EXEC_CONCURRENCY"
  | Log_writer -> "MASC_LOG_WRITER_CONCURRENCY"

let default_cap = function
  | Docker_spawn -> 8
  | Provider_http -> 16
  | Sandbox_exec -> 32
  | Log_writer -> 64

let read_cap kind =
  match Sys.getenv_opt (env_var kind) with
  | Some s -> (
      match int_of_string_opt (String.trim s) with
      | Some n when n >= 1 && n <= 1024 -> n
      | _ -> default_cap kind)
  | None -> default_cap kind

(* Per-kind state: configured cap + semaphore (lazily realised; first
   acquire is during startup which is sequential, so a Lazy.force race
   is harmless). *)
type slot_state = { cap : int ; sem : Eio.Semaphore.t }

let _state_for_kind : (kind * slot_state) list =
  List.map
    (fun kind ->
      let cap = read_cap kind in
      (kind, { cap ; sem = Eio.Semaphore.make cap }))
    all_kinds

let state_of kind = List.assoc kind _state_for_kind

(* Shared FD-pressure mutex — when Keeper_fd_pressure.active () is
   true, all kinds serialize through one global gate. Reuses the
   pattern from Docker_spawn_throttle (PR #15727). *)
let _shared_pressure_mutex = Eio.Mutex.create ()

let with_slot ~kind f =
  let { sem ; _ } = state_of kind in
  Eio.Semaphore.acquire sem ;
  Eio.Switch.run @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> Eio.Semaphore.release sem) ;
  if Keeper_fd_pressure.active () then
    Eio.Mutex.use_rw ~protect:true _shared_pressure_mutex f
  else f ()

let configured_concurrency ~kind = (state_of kind).cap

let effective_concurrency ~kind =
  if Keeper_fd_pressure.active () then 1
  else (state_of kind).cap

(* In-flight count = configured cap minus current semaphore credits.
   Eio.Semaphore exposes [get_value] which returns the available credit
   count; in-flight = cap − available. *)
let in_flight kind =
  let { cap ; sem } = state_of kind in
  let available = Eio.Semaphore.get_value sem in
  max 0 (cap - available)

(* Best-effort FD-open count using /dev/fd (macOS) or /proc/self/fd
   (Linux). Returns -1 on other platforms. *)
let read_fd_open () =
  let candidates =
    [ "/dev/fd" ; "/proc/self/fd" ; "/proc/self/task/self/fd" ]
  in
  let rec try_dirs = function
    | [] -> -1
    | dir :: rest ->
        (try
           let entries = Sys.readdir dir in
           Array.length entries
         with _ -> try_dirs rest)
  in
  try_dirs candidates

let read_fd_limit () =
  try
    let chan = Unix.open_process_in "ulimit -n" in
    let line = input_line chan in
    let _ = Unix.close_process_in chan in
    match int_of_string_opt (String.trim line) with
    | Some n -> n
    | None -> -1
  with _ -> -1

type snapshot = {
  per_kind : (kind * int) list ;
  fd_open : int ;
  fd_limit : int ;
  pressure_active : bool ;
}

let fd_snapshot () =
  {
    per_kind = List.map (fun k -> (k, in_flight k)) all_kinds ;
    fd_open = read_fd_open () ;
    fd_limit = read_fd_limit () ;
    pressure_active = Keeper_fd_pressure.active () ;
  }
