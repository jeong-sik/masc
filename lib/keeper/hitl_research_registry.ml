module String_map = Map.Make (String)

let runners : Hitl_summary_worker.research_runner String_map.t Atomic.t =
  Atomic.make String_map.empty
;;

let rec install ~base_path runner =
  let current = Atomic.get runners in
  let updated = String_map.add base_path runner current in
  if not (Atomic.compare_and_set runners current updated)
  then install ~base_path runner
;;

let resolve ~base_path =
  match String_map.find_opt base_path (Atomic.get runners) with
  | Some runner -> Ok runner
  | None ->
    Error
      (Printf.sprintf
         "HITL full-tool research authority is not installed for workspace %s"
         base_path)
;;

module For_testing = struct
  let reset () = Atomic.set runners String_map.empty
end
;;
