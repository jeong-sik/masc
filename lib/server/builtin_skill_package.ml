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
type bundled_verdict =
  | Install_missing
  | Up_to_date
  | Adopt_identical
  | Replace_recorded of { backup : string }
  | Keep_modified of { revision : string }
  | Keep_untracked_different of { revision : string }
  | Keep_uninspectable of { reason : string }
type retired_verdict =
  | Retire_recorded of { backup : string option }
  | Keep_retired_modified of { revision : string }
  | Keep_retired_uninspectable of { reason : string }
type error =
  | Invalid_path of string
  | Revision_conflict of inspection
  | Bundled_revision_conflict of { actual_revision : string }
  | Io_error of string
  | Published_but_unrecorded of { backup : string option; reason : string }
  | Exported_but_unsynced of { destination : string; reason : string }
  | Retired_but_unrecorded of { backup : string; reason : string }
type report =
  | Bundled of { name : string; result : (bundled_verdict, error) result }
  | Retired of { name : string; result : (retired_verdict, error) result }
type replacement = Replaced of { backup : string } | Already_current

let skills_dirname = "skills"
let state_dirname = "skill-packages"
let lock_filename = "install.lock"
(* A receipt's file name is the package name plus this suffix, and nothing
   else in the receipt directory carries it: backups are directories and
   atomic-write temporaries use their own shape. *)
let receipt_suffix = ".sha256"

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
  | Retired_but_unrecorded { backup; reason } ->
    "Retired Skill package was moved to " ^ backup
    ^ " but its installation receipt was not removed: " ^ reason
    ^ "; inspect that directory before restoring it"

let review_hint name =
  "review with masc skills-refresh " ^ name ^ " --base-path BASE"

let report_to_string = function
  | Bundled { name; result = Ok Install_missing } -> "installed builtin Skill " ^ name
  | Bundled { name; result = Ok Up_to_date } -> "builtin Skill " ^ name ^ " is up to date"
  | Bundled { name; result = Ok Adopt_identical } ->
    "recorded builtin Skill " ^ name ^ " (installed files already match this release)"
  | Bundled { name; result = Ok (Replace_recorded { backup }) } ->
    "updated builtin Skill " ^ name ^ " (previous package: " ^ backup ^ ")"
  | Bundled { name; result = Ok (Keep_modified { revision }) } ->
    "kept Skill " ^ name ^ " (edited since installation, revision=" ^ revision ^ "; "
    ^ review_hint name ^ ")"
  | Bundled { name; result = Ok (Keep_untracked_different { revision }) } ->
    "kept Skill " ^ name ^ " (no installation receipt and files differ from this release, revision="
    ^ revision ^ "; " ^ review_hint name ^ ")"
  | Bundled { name; result = Ok (Keep_uninspectable { reason }) } ->
    "kept Skill " ^ name ^ " (cannot inspect package: " ^ reason ^ ")"
  | Retired { name; result = Ok (Retire_recorded { backup = Some backup }) } ->
    "removed builtin Skill " ^ name ^ " that this release no longer ships (previous package: "
    ^ backup ^ ")"
  | Retired { name; result = Ok (Retire_recorded { backup = None }) } ->
    "removed the installation receipt of builtin Skill " ^ name
    ^ " that this release no longer ships (its directory was already gone)"
  | Retired { name; result = Ok (Keep_retired_modified { revision }) } ->
    "kept Skill " ^ name ^ " that this release no longer ships (edited since installation, revision="
    ^ revision ^ "; delete " ^ state_dirname ^ "/" ^ name ^ receipt_suffix
    ^ " to keep it as your own Skill, or delete the Skill directory too)"
  | Retired { name; result = Ok (Keep_retired_uninspectable { reason }) } ->
    "kept Skill " ^ name ^ " that this release no longer ships (cannot inspect package: "
    ^ reason ^ ")"
  | Bundled { name; result = Error error } | Retired { name; result = Error error } ->
    "Skill " ^ name ^ " was not reconciled: " ^ error_message error

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

type locations = { root : string; skills : string; state : string }

let locations ~base_path =
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
  { root
  ; skills = Filename.concat root skills_dirname
  ; state = Filename.concat root state_dirname }

let package_target paths name = Filename.concat paths.skills name
let receipt_path paths name = Filename.concat paths.state (name ^ receipt_suffix)
let receipt_content revision = revision ^ "\n"

(* The receipt is read first: an absent package still needs a valid receipt
   slot, so an occupied non-regular receipt path is rejected before anything
   is published. *)
let observe_installed paths name =
  let receipt = load_receipt ~root:paths.root (receipt_path paths name) in
  let tree = tree_revision ~root:paths.root (package_target paths name) in
  receipt, tree

let observe paths package =
  match observe_installed paths package.name with
  | _, None -> Missing
  | receipt, Some revision ->
    let ownership = match receipt with
      | None -> Untracked
      | Some recorded when String.equal recorded (receipt_content revision) -> Recorded
      | Some _ -> Modified
    in
    Present { revision; bundled_revision = bundled_revision package; ownership }

let inspect ~base_path package =
  protect (fun () -> observe (locations ~base_path) package)

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
  let path = Filename.concat paths.state lock_filename in
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

type previous_tree = { backup : string; revision : string }

(* Receipt follows publication and verification. A crash before this write
   leaves the new tree with an absent or stale receipt; the next reconcile
   compares that tree with the bundle byte for byte and never guesses. *)
let record_publication paths package ~previous =
  let target = package_target paths package.name in
  let recorded = protect (fun () ->
    sync_dir paths.skills;
    sync_dir paths.state;
    let expected = bundled_revision package in
    if tree_revision ~root:paths.root target <> Some expected then
      raise (Rejected (Invalid_path target));
    (match previous with
     | None -> ()
     | Some { backup; revision } ->
       if tree_revision ~root:paths.root backup <> Some revision then
         raise (Rejected (Invalid_path backup)));
    match Fs_compat.save_file_atomic_strict (receipt_path paths package.name)
            (receipt_content expected) with
    | Ok () -> ()
    | Error reason -> raise (Rejected (Io_error reason))) in
  match recorded with
  | Ok () -> ()
  | Error error ->
    let backup = match previous with None -> None | Some { backup; _ } -> Some backup in
    raise (Rejected (Published_but_unrecorded { backup; reason = error_message error }))

(* Stage the complete package beside the receipts, then hand it to [publish].
   The staged directory is removed unless [publish] reports it moved. *)
let with_staged paths package publish =
  let directory = stage ~parent:paths.state package in
  let moved = ref false in
  Fun.protect
    ~finally:(fun () -> if not !moved then Fs_compat.remove_tree directory)
    (fun () -> publish directory ~moved:(fun () -> moved := true))

let require_unchanged paths package before =
  let current = observe paths package in
  if current <> before then raise (Rejected (Revision_conflict current))

let publish_missing paths package =
  with_staged paths package (fun directory ~moved ->
    require_unchanged paths package Missing;
    Fs_compat.rename_noreplace directory (package_target paths package.name);
    moved ();
    record_publication paths package ~previous:None)

(* Exchange the staged package with the installed one; the exchanged-out tree
   stays at the staging path and is returned as the backup. *)
let publish_over paths package ~revision ~ownership =
  with_staged paths package (fun directory ~moved ->
    require_unchanged paths package
      (Present { revision; bundled_revision = bundled_revision package; ownership });
    Fs_compat.exchange_paths directory (package_target paths package.name);
    moved ();
    record_publication paths package ~previous:(Some { backup = directory; revision });
    directory)

(* The installed tree already equals the bundle, directories and permissions
   included, so writing the receipt changes no Skill file. A later release
   then treats it as an unmodified installation. *)
let adopt paths package ~revision =
  match Fs_compat.save_file_atomic_strict (receipt_path paths package.name)
          (receipt_content revision) with
  | Ok () -> ()
  | Error reason -> raise (Rejected (Io_error reason))

let reconcile_bundled paths package =
  match protect (fun () -> observe paths package) with
  | Error ((Invalid_path _ | Io_error _) as error) ->
    Keep_uninspectable { reason = error_message error }
  | Error ((Revision_conflict _ | Bundled_revision_conflict _ | Published_but_unrecorded _
           | Exported_but_unsynced _ | Retired_but_unrecorded _) as error) ->
    raise (Rejected error)
  | Ok Missing -> publish_missing paths package; Install_missing
  | Ok (Present { revision; bundled_revision; ownership }) ->
    match ownership, String.equal revision bundled_revision with
    | Recorded, true -> Up_to_date
    | (Untracked | Modified), true -> adopt paths package ~revision; Adopt_identical
    | Recorded, false -> Replace_recorded { backup = publish_over paths package ~revision ~ownership }
    | Modified, false -> Keep_modified { revision }
    | Untracked, false -> Keep_untracked_different { revision }

(* Move a recorded tree out of the Skill source into a fresh backup directory
   under the receipts. [Unix.rename] replaces only that empty directory, which
   this call just created; any other occupant makes the rename fail. The
   receipt goes last, so a crash leaves a receipt without a tree, which the
   next reconcile removes. *)
let retire paths name ~revision =
  let backup = Filename.temp_dir ~temp_dir:paths.state (name ^ "-") "" in
  let moved = ref false in
  Fun.protect
    ~finally:(fun () -> if not !moved then Fs_compat.remove_tree backup)
    (fun () ->
      Unix.rename (package_target paths name) backup;
      moved := true;
      let recorded = protect (fun () ->
        sync_dir paths.skills;
        sync_dir paths.state;
        if tree_revision ~root:paths.root backup <> Some revision then
          raise (Rejected (Invalid_path backup));
        Unix.unlink (receipt_path paths name);
        sync_dir paths.state) in
      match recorded with
      | Ok () -> Retire_recorded { backup = Some backup }
      | Error error ->
        raise (Rejected (Retired_but_unrecorded { backup; reason = error_message error })))

let remove_receipt paths name =
  Unix.unlink (receipt_path paths name);
  sync_dir paths.state;
  Retire_recorded { backup = None }

(* [None] when the receipt is gone by the time it is read: the name then has
   no installation record left to reconcile. *)
let reconcile_retired paths name =
  match protect (fun () -> observe_installed paths name) with
  | Error ((Invalid_path _ | Io_error _) as error) ->
    Some (Ok (Keep_retired_uninspectable { reason = error_message error }))
  | Error ((Revision_conflict _ | Bundled_revision_conflict _ | Published_but_unrecorded _
           | Exported_but_unsynced _ | Retired_but_unrecorded _) as error) ->
    Some (Error error)
  | Ok (None, _) -> None
  | Ok (Some _, None) -> Some (protect (fun () -> remove_receipt paths name))
  | Ok (Some recorded, Some revision) ->
    (match String.equal recorded (receipt_content revision) with
     | true -> Some (protect (fun () -> retire paths name ~revision))
     | false -> Some (Ok (Keep_retired_modified { revision })))

(* Receipts are the only evidence that a Skill directory came from this
   installer, so they are the only names retirement considers. *)
let recorded_names paths =
  Sys.readdir paths.state
  |> Array.to_list
  |> List.sort String.compare
  |> List.filter_map (fun entry ->
    match Filename.chop_suffix_opt ~suffix:receipt_suffix entry with
    | Some name when valid_component name -> Some name
    | Some _ | None -> None)

let reconcile ~base_path packages =
  protect (fun () ->
    Fs_compat.mkdir_p base_path;
    let paths = locations ~base_path in
    with_lock paths (fun () ->
      let shipped = List.map name packages in
      let bundled = List.map (fun package ->
        Bundled { name = package.name
                ; result = protect (fun () -> reconcile_bundled paths package) }) packages in
      let retired =
        recorded_names paths
        |> List.filter (fun recorded -> not (List.mem recorded shipped))
        |> List.filter_map (fun name ->
          match reconcile_retired paths name with
          | None -> None
          | Some result -> Some (Retired { name; result }))
      in
      bundled @ retired))

let replace_reviewed ~base_path ~installed_revision ~bundled_revision:reviewed_bundle package =
  protect (fun () ->
    let actual_revision = bundled_revision package in
    if not (String.equal reviewed_bundle actual_revision) then
      raise (Rejected (Bundled_revision_conflict { actual_revision }));
    let paths = locations ~base_path in
    with_lock paths (fun () ->
      match observe paths package with
      | Missing -> raise (Rejected (Revision_conflict Missing))
      | Present { revision; bundled_revision; ownership } as before ->
        match String.equal installed_revision revision, ownership,
              String.equal revision bundled_revision with
        | false, (Recorded | Untracked | Modified), (true | false) ->
          raise (Rejected (Revision_conflict before))
        | true, Recorded, true -> Already_current
        | true, (Untracked | Modified), true | true, (Recorded | Untracked | Modified), false ->
          Replaced { backup = publish_over paths package ~revision ~ownership }))
