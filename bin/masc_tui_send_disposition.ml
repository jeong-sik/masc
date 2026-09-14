type 'request t =
  | Sends
  | Updates of 'request

let of_state ~inflight ~waiting =
  match inflight, waiting with
  | Some request, _ | None, Some request -> Updates request
  | None, None -> Sends
