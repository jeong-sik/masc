(** Keeper_file_tracker — cross-keeper file collision detection.

    Process-scoped tracker that records which keeper modified which
    files. Detects when two different keepers touch the same file
    within a time window.

    Non-yielding Hashtbl operations only — single-domain Eio safe.

    @since 2.254.0 — execution evidence system (#5620) *)

type collision_warning = {
  file_path : string;
  other_keeper : string;
  other_ts : float;
}

type file_entry = {
  keeper_name : string;
  ts : float;
}

let collision_window_sec = 300.0

let mu = Eio.Mutex.create ()
let tracker : (string, file_entry) Hashtbl.t = Hashtbl.create 64

let with_lock f =
  Eio.Mutex.use_rw ~protect:true mu (fun () -> f ())

let gc_stale () =
  let now = Unix.gettimeofday () in
  Hashtbl.fold
    (fun path entry acc ->
      if now -. entry.ts > collision_window_sec *. 2.0 then path :: acc
      else acc)
    tracker []
  |> List.iter (Hashtbl.remove tracker)

(** Record files from a turn's git status output. Returns collision warnings.
    Each status line is e.g. " M lib/foo.ml" — extract file path. *)
let record_turn_files ~keeper_name ~files : collision_warning list =
  let now = Unix.gettimeofday () in
  let extract_path line =
    let trimmed = String.trim line in
    if String.length trimmed > 3 then
      String.sub trimmed 3 (String.length trimmed - 3)
      |> String.trim
    else trimmed
  in
  with_lock (fun () ->
    gc_stale ();
    let warnings = ref [] in
    List.iter (fun raw_line ->
      let path = extract_path raw_line in
      if path <> "" then begin
        (match Hashtbl.find_opt tracker path with
         | Some entry
           when entry.keeper_name <> keeper_name
                && now -. entry.ts < collision_window_sec ->
           warnings := { file_path = path;
                         other_keeper = entry.keeper_name;
                         other_ts = entry.ts } :: !warnings
         | _ -> ());
        Hashtbl.replace tracker path { keeper_name; ts = now }
      end
    ) files;
    List.rev !warnings)

(** Recent collisions involving a specific keeper. *)
let recent_collisions ~keeper_name : collision_warning list =
  let now = Unix.gettimeofday () in
  Eio.Mutex.use_ro mu (fun () ->
      Hashtbl.fold
        (fun path entry acc ->
          if entry.keeper_name <> keeper_name
             && now -. entry.ts < collision_window_sec then
            { file_path = path;
              other_keeper = entry.keeper_name;
              other_ts = entry.ts } :: acc
          else acc)
        tracker [])

let collision_to_json (w : collision_warning) : Yojson.Safe.t =
  `Assoc [
    ("file_path", `String w.file_path);
    ("other_keeper", `String w.other_keeper);
    ("other_ts", `Float w.other_ts);
  ]
