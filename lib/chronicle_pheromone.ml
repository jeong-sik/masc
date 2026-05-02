type path_id = string

type t = {
  mutable paths : (path_id, float) Hashtbl.t;
  tau_min : float;
  tau_max : float;
  base_rho : float;
  stagnation_threshold : float;
}

let create ?(tau_min=0.1) ?(tau_max=10.0) ?(base_rho=0.05) ?(stagnation_threshold=0.8) () =
  {
    paths = Hashtbl.create 16;
    tau_min;
    tau_max;
    base_rho;
    stagnation_threshold;
  }

let get_level t path =
  match Hashtbl.find_opt t.paths path with
  | Some v -> v
  | None -> t.tau_min

let deposit t path ~amount =
  let current = get_level t path in
  let updated = min t.tau_max (current +. amount) in
  Hashtbl.replace t.paths path updated

let evaporate t =
  let max_val = ref t.tau_min in
  Hashtbl.iter (fun _ v -> if v > !max_val then max_val := v) t.paths;
  
  (* Adaptive evaporation: if a path is near tau_max, increase evaporation rate to avoid stagnation *)
  let adaptive_rho =
    if !max_val > (t.tau_max *. t.stagnation_threshold) then
      min 1.0 (t.base_rho *. 2.0)
    else
      t.base_rho
  in

  let to_remove = ref [] in
  Hashtbl.iter (fun path v ->
    let next_val = max t.tau_min ((1.0 -. adaptive_rho) *. v) in
    if next_val <= t.tau_min then
      to_remove := path :: !to_remove
    else
      Hashtbl.replace t.paths path next_val
  ) t.paths;
  
  List.iter (fun path -> Hashtbl.remove t.paths path) !to_remove
