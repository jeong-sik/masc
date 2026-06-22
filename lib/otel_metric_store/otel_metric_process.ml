(* fd-pressure admission threshold.

   [None] disables the in-process gate: [Admission_queue.check_host_resources]
   skips the per-call [/dev/fd] directory scan entirely instead of computing a
   count that can never reach the threshold.  [Some n] rejects admission once
   the approximate open-fd count reaches 90% of [n].

   Disabled by default (previously encoded as the sentinel [max_int]).
   Encoding "disabled" as [None] rather than a sentinel makes the skip total
   and type-checked, and removes the [n * 9 / 10] overflow that the [max_int]
   sentinel computed on every admission. *)
let fd_warn_threshold : int option = None

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
