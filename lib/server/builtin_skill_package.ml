type package = { name : string; files : (string * string) list }
let name package = package.name

let valid_component value =
  value <> "" && value <> "." && value <> ".."
  && not (String.contains value '/') && not (String.contains value '\\')
  && not (String.contains value '\000')

let make ~name ~files =
  let valid_path path =
    String.split_on_char '/' path |> List.for_all valid_component
  in
  let paths = List.map fst files in
  if not (valid_component name) || not (List.for_all valid_path paths)
     || not (List.mem "SKILL.md" paths)
     || List.length paths <> List.length (List.sort_uniq String.compare paths)
     || List.exists (fun path ->
          List.exists (fun other -> String.starts_with ~prefix:(path ^ "/") other) paths) paths
  then Error "a builtin package needs unique relative files and a root SKILL.md"
  else Ok { name; files }

type ownership = Recorded | Untracked | Modified
type inspection =
  | Missing
  | Present of { revision : string; bundled_revision : string; ownership : ownership }
type request = Seed_missing | Automatic
  | Replace_if_revisions of { installed_revision : string; bundled_revision : string }
type outcome = Installed | Already_present | Current | Preserved of inspection
  | Preserved_uninspectable of { reason : string } | Updated of { backup : string }
type error =
  | Invalid_path of string
  | Revision_conflict of inspection
  | Bundled_revision_conflict of { actual_revision : string }
  | Io_error of string
  | Published_but_unrecorded of { backup : string option; reason : string }
  | Exported_but_unsynced of { destination : string; reason : string }

let error_message = function
  | Invalid_path path -> "Skill package path is not an owned regular tree: " ^ path
  | Revision_conflict Missing -> "Skill package disappeared; inspect it again"
  | Revision_conflict (Present { revision; _ }) ->
    "Skill package changed; inspect it again (revision=" ^ revision ^ ")"
  | Bundled_revision_conflict { actual_revision } ->
    "Bundled Skill package changed; export and review it again (revision=" ^ actual_revision ^ ")"
  | Io_error reason -> reason
  | Published_but_unrecorded { backup; reason } ->
    "Skill package was published but not recorded: " ^ reason
    ^ (match backup with None -> "" | Some path -> "; previous package: " ^ path)
  | Exported_but_unsynced { destination; reason } ->
    "Skill package was exported to " ^ destination
    ^ " but its parent directory was not synced: " ^ reason
    ^ "; inspect the existing export before choosing a new destination"

exception Rejected of error

let protect action =
  try Ok (action ()) with
  | Rejected error -> Error error
  | (Unix.Unix_error _ | Sys_error _) as exn -> Error (Io_error (Printexc.to_string exn))

let stat path =
  try Some (Unix.lstat path) with Unix.Unix_error (Unix.ENOENT, _, _) -> None

let sync_dir path =
  let fd = Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)

let ensure_dir_with_sync ~sync_parent path =
  (match stat path with
   | None ->
     (try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) ->
       match stat path with
       | Some info when info.Unix.st_kind = Unix.S_DIR -> ()
       | None | Some _ -> raise (Rejected (Invalid_path path)))
   | Some info when info.Unix.st_kind = Unix.S_DIR -> ()
   | Some _ -> raise (Rejected (Invalid_path path)));
  (* Existing entries may come from a previous failed sync or a racing mkdir.
     Their presence alone does not prove the parent entry is durable. *)
  sync_parent (Filename.dirname path)

let ensure_dir = ensure_dir_with_sync ~sync_parent:sync_dir

let require_chain ~root path =
  match Fs_compat.inspect_owned_directory_chain ~ownership_root:root path with
  | Ok observation -> observation
  | Error _ -> raise (Rejected (Invalid_path path))

let load_receipt ~root path =
  (* Receipt format is a hex SHA-256 plus newline, never a resource payload. *)
  let max_bytes = Digestif.SHA256.digest_size * 2 + 1 in
  match Fs_compat.load_owned_regular_file_prefix ~ownership_root:root ~max_bytes path with
  | Ok None -> None
  | Ok (Some receipt) when not receipt.truncated -> Some receipt.content
  | Ok (Some _) -> raise (Rejected (Invalid_path path))
  | Error _ -> raise (Rejected (Invalid_path path))

let hash content = Digestif.SHA256.(to_hex (digest_string content))

(* Include directory entries and permissions: empty operator directories and
   chmod edits must not disappear merely because all file bytes still match. *)
let revision entries =
  entries |> List.sort compare |> fun entries ->
  `List (List.map (fun (kind, path, mode, digest) ->
    `List [ `String kind; `String path; `Int mode; `String digest ]) entries)
  |> Yojson.Safe.to_string |> hash

let directory_entries files =
  let rec parents path acc =
    let parent = Filename.dirname path in
    if parent = "." then acc else parents parent (parent :: acc)
  in
  List.fold_left (fun acc (path, _) -> parents path acc) [ "" ] files
  |> List.sort_uniq String.compare
  |> List.map (fun path -> "directory", path, 0o700, "")

let bundled_revision package =
  revision (directory_entries package.files @ List.map (fun (path, content) ->
    "file", path, 0o644, hash content) package.files)

let tree_revision ~root directory =
  match require_chain ~root directory with
  | Fs_compat.Owned_directory_missing -> None
  | Fs_compat.Owned_directory _ ->
    let rec visit rel =
      let path = if rel = "" then directory else Filename.concat directory rel in
      let info = Unix.lstat path in
      match info.Unix.st_kind with
      | Unix.S_DIR ->
        (match require_chain ~root path with
         | Fs_compat.Owned_directory _ -> ()
         | Fs_compat.Owned_directory_missing -> raise (Rejected (Invalid_path path)));
        let children = Sys.readdir path |> Array.to_list |> List.sort String.compare in
        ("directory", rel, info.st_perm, "") :: List.concat_map (fun child ->
          visit (if rel = "" then child else rel ^ "/" ^ child)) children
      | Unix.S_REG ->
        (* A byte-identical hard link still carries operator-owned sharing
           semantics that a distribution replacement cannot preserve. *)
        if info.st_nlink <> 1 then raise (Rejected (Invalid_path path));
        (match Fs_compat.sha256_owned_regular_file ~ownership_root:root path with
         | Ok (Some digest) -> [ "file", rel, info.st_perm, digest ]
         | Ok None | Error _ -> raise (Rejected (Invalid_path path)))
      | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
        raise (Rejected (Invalid_path path))
    in
    Some (revision (visit ""))

type locations = { root : string; skills : string; state : string; target : string; receipt : string }

let locations ~base_path package =
  let base_path = Unix.realpath base_path in
  let deployment_root = Common.masc_dir_from_base_path ~base_path in
  (* The deployment root may intentionally point at a mounted volume.
     Resolve it once for this operation; every descendant and receipt uses
     the same physical root. Descendant symlinks remain disallowed. *)
  let root = match stat deployment_root with
    | None -> deployment_root
    | Some _ ->
      let physical =
        try Unix.realpath deployment_root with
        | Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR | Unix.ELOOP), _, _) ->
          raise (Rejected (Invalid_path deployment_root)) in
      (match stat physical with
       | Some info when info.Unix.st_kind = Unix.S_DIR -> physical
       | None | Some _ -> raise (Rejected (Invalid_path deployment_root))) in
  let skills = Filename.concat root "skills" in
  let state = Filename.concat root "skill-packages" in
  { root; skills; state; target = Filename.concat skills package.name
  ; receipt = Filename.concat state (package.name ^ ".sha256") }

let observe paths package =
  (* An absent package still needs a valid receipt slot. Reject occupied
     non-regular receipt paths before publishing any active package. *)
  let receipt = load_receipt ~root:paths.root paths.receipt in
  match tree_revision ~root:paths.root paths.target with
  | None -> Missing
  | Some revision ->
    let ownership = match receipt with
      | None -> Untracked
      | Some recorded when recorded = revision ^ "\n" -> Recorded
      | Some _ -> Modified
    in
    Present { revision; bundled_revision = bundled_revision package; ownership }

let inspect ~base_path package =
  protect (fun () -> observe (locations ~base_path package) package)

let write_file path content =
  let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ] 0o600 in
  let channel = Unix.out_channel_of_descr fd in
  Fun.protect ~finally:(fun () -> close_out_noerr channel) (fun () ->
    output_string channel content;
    flush channel;
    Unix.fchmod fd 0o644;
    Unix.fsync fd)

let stage ~parent package =
  let directory = Filename.temp_dir ~temp_dir:parent (package.name ^ "-") "" in
  try
    List.iter (fun (rel, content) ->
      let rec create_parents path =
        if path <> directory then (create_parents (Filename.dirname path); ensure_dir path)
      in
      let destination = Filename.concat directory rel in
      create_parents (Filename.dirname destination);
      write_file destination content) package.files;
    directory_entries package.files |> List.rev |> List.iter (fun (_, rel, _, _) ->
      sync_dir (if rel = "" then directory else Filename.concat directory rel));
    sync_dir parent;
    directory
  with exn -> Fs_compat.remove_tree directory; raise exn

let export_with_sync ~sync_parent ~destination package =
  protect (fun () ->
    let parent = Unix.realpath (Filename.dirname destination) in
    let leaf = Filename.basename destination in
    if not (valid_component leaf) then raise (Rejected (Invalid_path destination));
    let destination = Filename.concat parent leaf in
    let directory = stage ~parent package in
    Fun.protect ~finally:(fun () -> Fs_compat.remove_tree directory) (fun () ->
      Fs_compat.rename_noreplace directory destination;
      match protect (fun () -> sync_parent parent) with
      | Ok () -> ()
      | Error error -> raise (Rejected (Exported_but_unsynced {
          destination; reason = error_message error }))))

let export = export_with_sync ~sync_parent:sync_dir

module For_testing = struct
  let export = export_with_sync
  let ensure_directory ~sync_parent path =
    protect (fun () -> ensure_dir_with_sync ~sync_parent path)
end

(* lockf is process-owned. This mutex also excludes another synchronous
   installer on a different systhread in this process. No Eio effects inside. *)
let installer_mutex = Mutex.create ()

let with_lock paths action =
  Mutex.lock installer_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock installer_mutex) (fun () ->
  ensure_dir paths.root;
  ensure_dir paths.skills;
  ensure_dir paths.state;
  let path = Filename.concat paths.state "install.lock" in
  (match stat path with
   | None -> ()
   | Some info when info.Unix.st_kind = Unix.S_REG -> ()
   | Some _ -> raise (Rejected (Invalid_path path)));
  let fd = Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC ] 0o600 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
    let descriptor = Unix.fstat fd in
    let named = Unix.lstat path in
    if named.st_kind <> Unix.S_REG || named.st_dev <> descriptor.st_dev
       || named.st_ino <> descriptor.st_ino then raise (Rejected (Invalid_path path));
    Unix.lockf fd Unix.F_LOCK 0;
    action ()))

let publish paths package before =
  let directory = stage ~parent:paths.state package in
  let published = ref false in
  let backup = match before with Missing -> None | Present _ -> Some directory in
  Fun.protect
    ~finally:(fun () -> if not !published then Fs_compat.remove_tree directory)
    (fun () ->
      let current = observe paths package in
      if current <> before then raise (Rejected (Revision_conflict current));
      (match before with
       | Missing -> Fs_compat.rename_noreplace directory paths.target
       | Present _ -> Fs_compat.exchange_paths directory paths.target);
      published := true;
      let finish = protect (fun () ->
        sync_dir paths.skills;
        sync_dir paths.state;
        let expected = bundled_revision package in
        if tree_revision ~root:paths.root paths.target <> Some expected then
          raise (Rejected (Invalid_path paths.target));
        (match before with
         | Missing -> ()
         | Present { revision; _ } ->
           if tree_revision ~root:paths.root directory <> Some revision then
             raise (Rejected (Invalid_path directory)));
        (* Receipt follows publication. A crash before this write preserves
           the new tree as Modified on the next run, never authorizes a guess. *)
        match Fs_compat.save_file_atomic_strict paths.receipt (expected ^ "\n") with
        | Ok () -> ()
        | Error reason -> raise (Rejected (Io_error reason))) in
      match finish with
      | Error error -> raise (Rejected (Published_but_unrecorded { backup; reason = error_message error }))
      | Ok () -> match backup with None -> Installed | Some backup -> Updated { backup })

let install ~base_path ~request package =
  protect (fun () ->
    (match request with
     | Seed_missing | Automatic -> Fs_compat.mkdir_p base_path
     | Replace_if_revisions { bundled_revision = expected; _ } ->
       let actual_revision = bundled_revision package in
       if expected <> actual_revision then
         raise (Rejected (Bundled_revision_conflict { actual_revision })));
    let paths = locations ~base_path package in
    match request, stat paths.target with
    | Seed_missing, Some _ -> Already_present
    | (Seed_missing, None) | ((Automatic | Replace_if_revisions _), _) ->
    with_lock paths (fun () ->
      match request, stat paths.target with
      | Seed_missing, Some _ -> Already_present
      | (Seed_missing, None) | ((Automatic | Replace_if_revisions _), _) ->
      match request, protect (fun () -> observe paths package) with
      | Automatic, Error ((Invalid_path _ | Io_error _) as error) ->
        Preserved_uninspectable { reason = error_message error }
      | _, Error error -> raise (Rejected error)
      | _, Ok before ->
      match request, before with
      | Replace_if_revisions _, Missing -> raise (Rejected (Revision_conflict Missing))
      | Replace_if_revisions { installed_revision = expected; _ }, Present { revision; _ } when expected <> revision ->
        raise (Rejected (Revision_conflict before))
      | (Seed_missing | Automatic), Missing -> publish paths package before
      | Seed_missing, Present _ -> Already_present
      | Automatic, Present { ownership = (Untracked | Modified); _ } -> Preserved before
      | (Automatic | Replace_if_revisions _), Present { revision; bundled_revision; ownership = Recorded }
        when revision = bundled_revision -> Current
      | (Automatic | Replace_if_revisions _), Present _ -> publish paths package before))
