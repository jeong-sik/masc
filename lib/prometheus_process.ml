let fd_warn_threshold =
  Env_config_core.get_int ~default:3000 "MASC_FD_WARN_THRESHOLD" |> max 1
;;

let fd_warned_once = Atomic.make false

let approximate_open_fd_count () =
  let candidates = [ "/dev/fd"; "/proc/self/fd" ] in
  let rec first_readable = function
    | [] -> None
    | path :: rest ->
      (try Some (path, Sys.readdir path) with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | Sys_error _ -> first_readable rest)
  in
  match first_readable candidates with
  | None -> 0
  | Some (_path, entries) -> max 0 (Array.length entries - 1)
;;

let update_fd_gauges ~set_gauge ~metric_open_fds =
  let count = approximate_open_fd_count () in
  set_gauge metric_open_fds (float_of_int count);
  if count >= fd_warn_threshold && not (Atomic.get fd_warned_once)
  then (
    Atomic.set fd_warned_once true;
    Printf.eprintf
      "[WARN] [Server] process open fd count %d has reached warn threshold %d — likely \
       socket/file leak, investigate before accept() starts failing with EMFILE.\n\
       %!"
      count
      fd_warn_threshold)
  else if count < fd_warn_threshold / 2
  then Atomic.set fd_warned_once false
;;
