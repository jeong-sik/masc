(** Subsystem health registry.
    Tracks which forked subsystems are alive or have crashed.
    Module-level Hashtbl: available from process start, no init timing dependency.
    Called by fork_subsystem in server_runtime_bootstrap, queried by /health. *)

let registry : (string, bool * float option) Hashtbl.t = Hashtbl.create 8

let register name =
  Hashtbl.replace registry name (true, None)

let mark_dead name =
  Hashtbl.replace registry name (false, Some (Time_compat.now ()))

let to_yojson () : Yojson.Safe.t =
  let entries = Hashtbl.fold (fun name (alive, crash_time) acc ->
    let status = if alive then "alive" else "dead" in
    let fields = [
      ("status", `String status);
    ] @ (match crash_time with
      | Some t -> [("crashed_at", `Float t)]
      | None -> [])
    in
    (name, `Assoc fields) :: acc
  ) registry [] in
  `Assoc (List.sort (fun (a, _) (b, _) -> String.compare a b) entries)
