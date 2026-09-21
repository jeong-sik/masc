type frontier = { trace_id : string; end_atom : int; boundary_line : int }
type input = Summarized of frontier | Uncompressed | Not_applied
type t =
  { prepared_at : float
  ; runtime_id : string
  ; input : input
  ; request_bytes : int
  }
let observations : ((string * string), t) Hashtbl.t = Hashtbl.create 16
let mutex = Stdlib.Mutex.create ()
let key ~config ~keeper_name = Workspace.keepers_runtime_dir config, keeper_name
let record ~config ~keeper_name observation =
  Stdlib.Mutex.protect mutex (fun () ->
    Hashtbl.replace observations (key ~config ~keeper_name) observation)
let latest ~config ~keeper_name =
  Stdlib.Mutex.protect mutex (fun () ->
    Hashtbl.find_opt observations (key ~config ~keeper_name))
let forget ~config ~keeper_name =
  Stdlib.Mutex.protect mutex (fun () ->
    Hashtbl.remove observations (key ~config ~keeper_name))
