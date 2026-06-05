let fd_warn_threshold = max_int

let approximate_open_fd_count () =
  let candidates = [ "/dev/fd"; "/proc/self/fd" ] in
  let rec first_readable = function
    | [] -> None
    | path :: rest ->
      (try Some (Sys.readdir path) with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | Sys_error _ -> first_readable rest)
  in
  match first_readable candidates with
  | None -> 0
  | Some entries -> max 0 (Array.length entries - 1)
;;
