(** Subsystem health registry.
    Tracks which forked subsystems are alive or have crashed.
    Populated by server_runtime_bootstrap, queried by /health. *)

let registry_ref : (string, bool * float option) Hashtbl.t option ref = ref None

let set_registry tbl = registry_ref := Some tbl

let to_yojson () : Yojson.Safe.t =
  match !registry_ref with
  | None -> `String "not_initialized"
  | Some tbl ->
    let entries = Hashtbl.fold (fun name (alive, crash_time) acc ->
      let status = if alive then "alive" else "dead" in
      let fields = [
        ("status", `String status);
      ] @ (match crash_time with
        | Some t -> [("crashed_at", `Float t)]
        | None -> [])
      in
      (name, `Assoc fields) :: acc
    ) tbl [] in
    `Assoc (List.sort (fun (a, _) (b, _) -> String.compare a b) entries)
