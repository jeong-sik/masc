type ownership =
  | Unspawned
  | Spawn_pending
  | Process_group of int

let path root = Filename.concat root "process-owner.json"

let publish ~root ownership =
  let fields = match ownership with
    | Unspawned -> ["state", `String "unspawned"]
    | Spawn_pending -> ["state", `String "spawn_pending"]
    | Process_group pid -> ["state", `String "process_group"; "pgid", `Int pid]
  in
  Fs_compat.save_file_atomic_strict_staged (path root)
    (Yojson.Safe.to_string (`Assoc fields))
  |> Result.map_error Fs_compat.atomic_replace_failure_to_string
;;

let initialize ~root = publish ~root Unspawned
let before_spawn ~root = publish ~root Spawn_pending

let valid_group pid = pid > 1 && Int32.to_int (Int32.of_int pid) = pid

let spawned ~root ~pid =
  if valid_group pid then publish ~root (Process_group pid)
  else Error "Antigravity panelist did not report a valid foreground process group"
;;

let decode text =
  match Yojson.Safe.from_string text with
  | `Assoc ["state", `String "unspawned"] -> Some Unspawned
  | `Assoc ["state", `String "spawn_pending"] -> Some Spawn_pending
  | `Assoc ["state", `String "process_group"; "pgid", `Int pid]
      when valid_group pid -> Some (Process_group pid)
  | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null
  | `String _ -> None
  | exception Yojson.Json_error _ -> None
;;

let group_is_absent pid =
  match Unix.kill (-pid) 0 with
  | () -> false
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> true
  | exception (Unix.Unix_error _ | Invalid_argument _) -> false
;;

let can_remove ~root =
  match Fs_compat.load_owned_regular_file_with_snapshot
    ~owner_uid:(Unix.geteuid ()) ~ownership_root:root (path root) with
  | Ok (Some contents) when contents.snapshot.permissions land 0o7777 = 0o600 ->
      (match decode contents.content with
       | Some Unspawned -> true
       | Some (Process_group pid) -> group_is_absent pid
       | Some Spawn_pending | None -> false)
  | Ok None | Ok (Some _) | Error _ -> false
;;
