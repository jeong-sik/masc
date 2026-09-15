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
  | Adopt_with_release_permissions
  | Permissions_pending of { revision : string }
  | Replace_recorded of { backup : string }
  | Replace_pending of { revision : string }
  | Keep_modified of { revision : string }
  | Keep_untracked_different of { revision : string }
  | Keep_uninspectable of { reason : string }
type retired_verdict =
  | Retire_recorded of { backup : string option }
  | Retire_pending of { revision : string option }
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
  | Backup_move_pending of { note : string }
  | Backup_move_unresolved of { note : string }
type backup_move =
  | Move_never_started
  | Move_completed
  | Move_finished of { backup : string }
type report =
  | Interrupted of { name : string; result : (backup_move, error) result }
  | Bundled of { name : string; result : (bundled_verdict, error) result }
  | Retired of { name : string; result : (retired_verdict, error) result }
  | Unfinished of { path : string; result : (unit, error) result }
type startup_reconciliation =
  | Reconciled of report list
  | Busy of { lock : string }
type replacement = Replaced of { backup : string } | Already_current

let skills_dirname = "skills"
let state_dirname = "skill-packages"
(* Three directories beside the receipts. The staging directory holds one
   fresh holder per operation, with the tree at HOLDER/NAME: a release being
   built, a tree on its way to the backups directory, or an earlier backup
   about to be deleted. The backups directory has one entry per package and
   receives a tree only through a single rename or exchange of a complete,
   synced tree, so an entry there is never partial. The moves directory holds
   one note per tree that has to reach the backups directory; while a note
   exists, staging is not emptied. *)
let staging_dirname = "staging"
let backups_dirname = "previous"
let moves_dirname = "moving"
let lock_filename = "install.lock"
(* A receipt's file name is the package name plus this suffix, and nothing
   else in the receipt directory carries it: the staging and backups entries
   are directories and atomic-write temporaries use their own shape. *)
let receipt_suffix = ".sha256"
(* The modes every published package has. They are part of the revision, so a
   tree whose modes differ is a different tree. *)
let release_directory_mode = 0o700
let release_file_mode = 0o644
let owner_only_file_mode = 0o600
let installer_command = "masc init --skills-only --base-path BASE"

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
  | Backup_move_pending { note } ->
    "an interrupted installation has not finished moving this package's previous tree ("
    ^ note ^ "); " ^ installer_command
    ^ " finishes it when that tree can be found, and until then the package is not replaced or retired"
  | Backup_move_unresolved { note } ->
    "no tree with the revision recorded in " ^ note
    ^ " is in the Skill source, the backup entry or staging, so staging was not emptied;"
    ^ " look for the tree in staging, then delete the note"

let review_hint name =
  "review with masc skills-refresh " ^ name ^ " --base-path BASE"

let report_to_string = function
  | Bundled { name; result = Ok Install_missing } -> "installed builtin Skill " ^ name
  | Bundled { name; result = Ok Up_to_date } -> "builtin Skill " ^ name ^ " is up to date"
  | Bundled { name; result = Ok Adopt_identical } ->
    "recorded builtin Skill " ^ name ^ " (installed files already match this release)"
  | Bundled { name; result = Ok Adopt_with_release_permissions } ->
    "recorded builtin Skill " ^ name
    ^ " (installed files already matched this release; their permissions were set to the release's)"
  | Bundled { name; result = Ok (Permissions_pending { revision }) } ->
    "builtin Skill " ^ name
    ^ " has this release's files with other permissions and no installation receipt (revision="
    ^ revision ^ "); server start does not change installed Skills, " ^ installer_command
    ^ " sets the release permissions and records it"
  | Bundled { name; result = Ok (Replace_recorded { backup }) } ->
    "updated builtin Skill " ^ name ^ " (previous package: " ^ backup ^ ")"
  | Bundled { name; result = Ok (Replace_pending { revision }) } ->
    "builtin Skill " ^ name
    ^ " is unchanged since installation and differs from this release (revision=" ^ revision
    ^ "); server start does not replace installed Skills, " ^ installer_command ^ " does"
  | Bundled { name; result = Ok (Keep_modified { revision }) } ->
    "kept Skill " ^ name ^ " (edited since installation, revision=" ^ revision ^ "; "
    ^ review_hint name ^ ")"
  | Bundled { name; result = Ok (Keep_untracked_different { revision }) } ->
    "kept Skill " ^ name
    ^ " (no installation receipt and its files differ from this release, revision="
    ^ revision ^ "; " ^ review_hint name ^ ")"
  | Bundled { name; result = Ok (Keep_uninspectable { reason }) } ->
    "kept Skill " ^ name ^ " (cannot inspect package: " ^ reason ^ ")"
  | Retired { name; result = Ok (Retire_recorded { backup = Some backup }) } ->
    "removed builtin Skill " ^ name ^ " that this release no longer ships (previous package: "
    ^ backup ^ ")"
  | Retired { name; result = Ok (Retire_recorded { backup = None }) } ->
    "removed the installation receipt of builtin Skill " ^ name
    ^ " that this release no longer ships (its directory was already gone)"
  | Retired { name; result = Ok (Retire_pending { revision = Some revision }) } ->
    "builtin Skill " ^ name
    ^ " is no longer shipped by this release and unchanged since installation (revision="
    ^ revision ^ "); server start does not remove installed Skills, " ^ installer_command
    ^ " moves it aside"
  | Retired { name; result = Ok (Retire_pending { revision = None }) } ->
    "builtin Skill " ^ name
    ^ " is no longer shipped by this release and its directory is already gone; "
    ^ installer_command ^ " removes its installation receipt"
  | Retired { name; result = Ok (Keep_retired_modified { revision }) } ->
    "kept Skill " ^ name ^ " that this release no longer ships (edited since installation, revision="
    ^ revision ^ "; delete " ^ state_dirname ^ "/" ^ name ^ receipt_suffix
    ^ " to keep it as your own Skill, or delete the Skill directory too)"
  | Retired { name; result = Ok (Keep_retired_uninspectable { reason }) } ->
    "kept Skill " ^ name ^ " that this release no longer ships (cannot inspect package: "
    ^ reason ^ ")"
  | Interrupted { name; result = Ok Move_never_started } ->
    "an interrupted installation of Skill " ^ name
    ^ " had not moved its installed tree; nothing was left to finish"
  | Interrupted { name; result = Ok Move_completed } ->
    "an interrupted installation of Skill " ^ name
    ^ " had already kept its previous tree in the backup entry"
  | Interrupted { name; result = Ok (Move_finished { backup }) } ->
    "moved the previous tree of Skill " ^ name
    ^ ", left in staging by an interrupted installation, to " ^ backup
  | Interrupted { name; result = Error error } ->
    "an interrupted installation of Skill " ^ name ^ " was not finished: " ^ error_message error
  | Unfinished { path; result = Ok () } ->
    "removed " ^ path ^ ", left by an interrupted Skill installation"
  | Unfinished { path; result = Error error } ->
    "could not remove " ^ path ^ ", left by an interrupted Skill installation: "
    ^ error_message error ^ "; the next installation tries again"
  | Bundled { name; result = Error error } | Retired { name; result = Error error } ->
    "Skill " ^ name ^ " was not reconciled: " ^ error_message error

exception Rejected of error

let protect action =
  try Ok (action ()) with
  | Rejected error -> Error error
  | (Unix.Unix_error _ | Sys_error _) as exn -> Error (Io_error (Printexc.to_string exn))

(* A descriptor opened only to sync a directory or to hold the installer lock
   carries no data, and the kernel releases the lock when the process exits.
   Its close must not replace the outcome of the work it guarded: a raising
   [Fun.protect] finalizer turns into [Fun.Finally_raised] and discards that
   outcome, including changes already on disk. *)
let close_quietly fd = try Unix.close fd with Unix.Unix_error _ -> ()

(* Cleanup after a failure. The failure being raised is what the caller has
   to see. A directory that stays behind in the staging directory is removed
   and reported by the next installation; one staged beside an export
   destination stays until the operator removes it. *)
let remove_quietly directory =
  match protect (fun () -> Fs_compat.remove_tree directory) with
  | Ok () | Error _ -> ()

let stat path =
  try Some (Unix.lstat path) with Unix.Unix_error (Unix.ENOENT, _, _) -> None

let sync_dir path =
  let fd = Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect ~finally:(fun () -> close_quietly fd) (fun () -> Unix.fsync fd)

let ensure_dir_with_sync ~sync_parent path =
  (match stat path with
   | None ->
     (try Unix.mkdir path release_directory_mode with Unix.Unix_error (Unix.EEXIST, _, _) ->
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

type entry_kind = Directory | File
type entry = { kind : entry_kind; path : string; mode : int; digest : string }

let entry_kind_tag = function Directory -> "directory" | File -> "file"
let release_mode = function Directory -> release_directory_mode | File -> release_file_mode

(* Include directory entries and permissions: empty operator directories and
   chmod edits must not disappear merely because all file bytes still match. *)
let revision entries =
  entries
  |> List.map (fun { kind; path; mode; digest } -> entry_kind_tag kind, path, mode, digest)
  |> List.sort compare
  |> List.map (fun (kind, path, mode, digest) ->
    `List [ `String kind; `String path; `Int mode; `String digest ])
  |> (fun items -> `List items)
  |> Yojson.Safe.to_string |> hash

let directory_entries files =
  let rec parents path acc =
    let parent = Filename.dirname path in
    if parent = "." then acc else parents parent (parent :: acc)
  in
  List.fold_left (fun acc (path, _) -> parents path acc) [ "" ] files
  |> List.sort_uniq String.compare
  |> List.map (fun path ->
    { kind = Directory; path; mode = release_mode Directory; digest = "" })

let bundled_revision package =
  revision (directory_entries package.files @ List.map (fun (path, content) ->
    { kind = File; path; mode = release_mode File; digest = hash content }) package.files)

let tree_entries ~root directory =
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
        { kind = Directory; path = rel; mode = info.st_perm; digest = "" }
        :: List.concat_map (fun child ->
          visit (if rel = "" then child else rel ^ "/" ^ child)) children
      | Unix.S_REG ->
        (* A byte-identical hard link still carries operator-owned sharing
           semantics that a distribution replacement cannot preserve. *)
        if info.st_nlink <> 1 then raise (Rejected (Invalid_path path));
        (match Fs_compat.sha256_owned_regular_file ~ownership_root:root path with
         | Ok (Some digest) -> [ { kind = File; path = rel; mode = info.st_perm; digest } ]
         | Ok None | Error _ -> raise (Rejected (Invalid_path path)))
      | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
        raise (Rejected (Invalid_path path))
    in
    Some (visit "")

let tree_revision ~root directory = Option.map revision (tree_entries ~root directory)

type files_match = Same_tree | Same_files_other_permissions | Different_files

(* Compare with the release twice: as installed, and with every mode set to
   the release's. The second tells a tree whose files and bytes are this
   release's apart from one whose files differ. *)
let files_match package ~revision:installed entries =
  let bundled = bundled_revision package in
  let with_release_modes =
    List.map (fun entry -> { entry with mode = release_mode entry.kind }) entries in
  match String.equal installed bundled, String.equal (revision with_release_modes) bundled with
  | true, (true | false) -> Same_tree
  | false, true -> Same_files_other_permissions
  | false, false -> Different_files

type locations =
  { root : string; skills : string; state : string; staging : string; backups : string
  ; moves : string }

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
  let state = Filename.concat root state_dirname in
  { root
  ; skills = Filename.concat root skills_dirname
  ; state
  ; staging = Filename.concat state staging_dirname
  ; backups = Filename.concat state backups_dirname
  ; moves = Filename.concat state moves_dirname }

let package_target paths name = Filename.concat paths.skills name
let backup_target paths name = Filename.concat paths.backups name
let receipt_path paths name = Filename.concat paths.state (name ^ receipt_suffix)
let receipt_content revision = revision ^ "\n"
let lock_path paths = Filename.concat paths.state lock_filename
let move_note_path paths name = Filename.concat paths.moves (name ^ receipt_suffix)

(* The receipt is read first: an absent package still needs a valid receipt
   slot, so an occupied non-regular receipt path is rejected before anything
   is published. *)
let observe_installed paths name =
  let receipt = load_receipt ~root:paths.root (receipt_path paths name) in
  let tree = tree_entries ~root:paths.root (package_target paths name) in
  receipt, tree

let ownership_of receipt revision =
  match receipt with
  | None -> Untracked
  | Some recorded when String.equal recorded (receipt_content revision) -> Recorded
  | Some _ -> Modified

let observe paths package =
  match observe_installed paths package.name with
  | _, None -> Missing
  | receipt, Some entries ->
    let revision = revision entries in
    Present { revision; bundled_revision = bundled_revision package
            ; ownership = ownership_of receipt revision }

let inspect ~base_path package =
  protect (fun () -> observe (locations ~base_path) package)

let write_file path content =
  let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ]
      owner_only_file_mode in
  let channel = Unix.out_channel_of_descr fd in
  Fun.protect ~finally:(fun () -> close_out_noerr channel) (fun () ->
    output_string channel content;
    flush channel;
    Unix.fchmod fd (release_mode File);
    Unix.fsync fd)

(* Build [package] inside [directory], which exists and is empty, then sync
   every directory of the tree and the directory holding it. *)
let stage_into directory package =
  List.iter (fun (rel, content) ->
    let rec create_parents path =
      if path <> directory then (create_parents (Filename.dirname path); ensure_dir path)
    in
    let destination = Filename.concat directory rel in
    create_parents (Filename.dirname destination);
    write_file destination content) package.files;
  directory_entries package.files |> List.rev |> List.iter (fun { path; _ } ->
    sync_dir (if path = "" then directory else Filename.concat directory path));
  sync_dir (Filename.dirname directory)

let stage ~parent package =
  let directory = Filename.temp_dir ~temp_dir:parent (package.name ^ "-") "" in
  match protect (fun () -> stage_into directory package) with
  | Ok () -> directory
  | Error error -> remove_quietly directory; raise (Rejected error)

let export_with_sync ~sync_parent ~destination package =
  protect (fun () ->
    let parent = Unix.realpath (Filename.dirname destination) in
    let leaf = Filename.basename destination in
    if not (valid_component leaf) then raise (Rejected (Invalid_path destination));
    let destination = Filename.concat parent leaf in
    let directory = stage ~parent package in
    (match protect (fun () -> Fs_compat.rename_noreplace directory destination) with
     | Ok () -> ()
     | Error error -> remove_quietly directory; raise (Rejected error));
    match protect (fun () -> sync_parent parent) with
    | Ok () -> ()
    | Error error -> raise (Rejected (Exported_but_unsynced {
        destination; reason = error_message error })))

let export = export_with_sync ~sync_parent:sync_dir

(* lockf belongs to the process: another systhread of this process is granted
   the same lock, and closing any descriptor of the lock file releases it. One
   mutex per receipt directory excludes those threads, so installations into
   different base paths in one process do not wait for each other and a busy
   report names the lock that was actually held. The table grows only by the
   receipt directories this process installs into. No Eio effects inside. *)
let installer_mutexes : (int * int, Mutex.t) Hashtbl.t = Hashtbl.create 1
let installer_mutexes_guard = Mutex.create ()

let installer_mutex paths =
  ensure_dir paths.root;
  ensure_dir paths.state;
  let state = Unix.lstat paths.state in
  let key = state.Unix.st_dev, state.Unix.st_ino in
  Mutex.protect installer_mutexes_guard (fun () ->
    match Hashtbl.find_opt installer_mutexes key with
    | Some mutex -> mutex
    | None ->
      let mutex = Mutex.create () in
      Hashtbl.replace installer_mutexes key mutex;
      mutex)

let open_lock paths =
  let path = lock_path paths in
  (match stat path with
   | None -> ()
   | Some info when info.Unix.st_kind = Unix.S_REG -> ()
   | Some _ -> raise (Rejected (Invalid_path path)));
  let fd = Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC ] owner_only_file_mode in
  let same_file = protect (fun () ->
    let descriptor = Unix.fstat fd in
    let named = Unix.lstat path in
    if named.st_kind <> Unix.S_REG || named.st_dev <> descriptor.st_dev
       || named.st_ino <> descriptor.st_ino then raise (Rejected (Invalid_path path))) in
  match same_file with
  | Ok () -> fd
  | Error error -> close_quietly fd; raise (Rejected error)

let lock_is_free fd =
  match Unix.lockf fd Unix.F_TLOCK 0 with
  | () -> true
  | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES), _, _) -> false

(* A person runs the installer, and what usually holds the lock is a server
   start publishing a missing package, which ends on its own. So the installer
   waits, and says once which lock it waits for. *)
let with_installer_lock ~on_wait paths action =
  let mutex = installer_mutex paths in
  let waited = not (Mutex.try_lock mutex) in
  if waited then (on_wait (lock_path paths); Mutex.lock mutex);
  Fun.protect ~finally:(fun () -> Mutex.unlock mutex) (fun () ->
    let fd = open_lock paths in
    Fun.protect ~finally:(fun () -> close_quietly fd) (fun () ->
      if not (lock_is_free fd) then begin
        if not waited then on_wait (lock_path paths);
        Unix.lockf fd Unix.F_LOCK 0
      end;
      action ()))

(* Server start never waits: a stopped installer holding the lock must not
   stop the server with it. [None] when either lock is held. *)
let with_lock_if_free paths action =
  let mutex = installer_mutex paths in
  match Mutex.try_lock mutex with
  | false -> None
  | true ->
    Fun.protect ~finally:(fun () -> Mutex.unlock mutex) (fun () ->
      let fd = open_lock paths in
      Fun.protect ~finally:(fun () -> close_quietly fd) (fun () ->
        match lock_is_free fd with
        | false -> None
        | true -> Some (action ())))

let write_receipt paths name ~revision =
  match Fs_compat.save_file_atomic_strict (receipt_path paths name) (receipt_content revision) with
  | Ok () -> ()
  | Error reason -> raise (Rejected (Io_error reason))

(* Before a tree that has to reach the backup entry leaves the Skill source, a
   note with its revision is written and synced. Until the note is removed the
   tree is in the Skill source, in a staging holder, or in the backup entry,
   and the next installation finds it there by revision. A revision covers
   every path, byte and mode, so a tree with the same revision holds the same
   files. An existing note means an earlier move is unfinished; it is never
   overwritten. *)
let write_move_note paths name ~revision =
  ensure_dir paths.moves;
  let note = move_note_path paths name in
  (match stat note with
   | None -> ()
   | Some _ -> raise (Rejected (Backup_move_pending { note })));
  match Fs_compat.save_file_atomic_strict note (receipt_content revision) with
  | Ok () -> ()
  | Error reason -> raise (Rejected (Io_error reason))

let remove_move_note paths name =
  Unix.unlink (move_note_path paths name);
  sync_dir paths.moves

(* Used only when the tree never left the Skill source. A note that stays
   names a tree the Skill source still holds, and the next installation
   removes it as [Move_never_started]. *)
let remove_move_note_quietly paths name =
  match protect (fun () -> remove_move_note paths name) with
  | Ok () | Error _ -> ()

(* A fresh holder in staging with the tree path HOLDER/NAME, so a tree keeps
   its package name inside whichever holder it is in. *)
let new_holder paths name =
  ensure_dir paths.staging;
  let holder = Filename.temp_dir ~temp_dir:paths.staging (name ^ "-") "" in
  holder, Filename.concat holder name

let stage_in_holder paths package =
  let holder, tree = new_holder paths package.name in
  match protect (fun () ->
    Unix.mkdir tree release_directory_mode;
    stage_into tree package) with
  | Ok () -> holder, tree
  | Error error -> remove_quietly holder; raise (Rejected error)

(* [tree] holds a tree that left the Skill source. It takes the package's
   backup entry; an earlier backup trades places with it and stays at [tree],
   inside the holder the caller deletes. *)
let place_backup paths name tree =
  ensure_dir paths.backups;
  let backup = backup_target paths name in
  (match stat backup with
   | None -> Fs_compat.rename_noreplace tree backup
   | Some _ -> Fs_compat.exchange_paths tree backup);
  sync_dir paths.backups;
  backup

type previous_tree = { backup : string; revision : string }

(* Receipt follows publication and verification. A crash before this write
   leaves the new tree with an absent or stale receipt; the next reconcile
   compares that tree with the bundle byte for byte and never guesses. The
   move note goes once the backup entry is verified to hold the tree it names. *)
let record_publication paths package ~previous =
  let target = package_target paths package.name in
  let recorded = protect (fun () ->
    sync_dir paths.skills;
    let expected = bundled_revision package in
    if tree_revision ~root:paths.root target <> Some expected then
      raise (Rejected (Invalid_path target));
    (match previous with
     | None -> ()
     | Some { backup; revision } ->
       if tree_revision ~root:paths.root backup <> Some revision then
         raise (Rejected (Invalid_path backup));
       remove_move_note paths package.name);
    write_receipt paths package.name ~revision:expected) in
  match recorded with
  | Ok () -> ()
  | Error error ->
    let backup = match previous with None -> None | Some { backup; _ } -> Some backup in
    raise (Rejected (Published_but_unrecorded { backup; reason = error_message error }))

let require_unchanged paths package before =
  let current = observe paths package in
  if current <> before then raise (Rejected (Revision_conflict current))

let publish_missing paths package =
  ensure_dir paths.skills;
  let holder, tree = stage_in_holder paths package in
  let published = protect (fun () ->
    require_unchanged paths package Missing;
    Fs_compat.rename_noreplace tree (package_target paths package.name)) in
  remove_quietly holder;
  match published with
  | Ok () -> record_publication paths package ~previous:None
  | Error error -> raise (Rejected error)

(* Points between the steps of a replacement or retirement, where a test can
   stop the process as a crash would. *)
type interruption = After_move_note | After_leaving_skill_source | After_backup_placed

let no_interruption (_ : interruption) = ()

(* The staged release trades places with the installed tree in one exchange,
   then the installed tree moves from the staging holder into the backup
   entry. The move note written before the exchange keeps the next
   installation from deleting that tree if this one stops in between. The
   backup entry is not touched until the installed tree has left the Skill
   source, so it never holds a release that was not installed. Returns the
   backup entry. *)
let publish_over ~interrupt paths package ~revision ~ownership =
  let target = package_target paths package.name in
  let holder, tree = stage_in_holder paths package in
  (match protect (fun () ->
     require_unchanged paths package
       (Present { revision; bundled_revision = bundled_revision package; ownership });
     write_move_note paths package.name ~revision) with
   | Ok () -> ()
   | Error error -> remove_quietly holder; raise (Rejected error));
  interrupt After_move_note;
  (match protect (fun () -> Fs_compat.exchange_paths tree target) with
   | Ok () -> ()
   | Error error ->
     remove_move_note_quietly paths package.name;
     remove_quietly holder;
     raise (Rejected error));
  interrupt After_leaving_skill_source;
  let backup =
    match protect (fun () -> place_backup paths package.name tree) with
    | Ok backup -> backup
    | Error error ->
      raise (Rejected (Published_but_unrecorded { backup = Some tree; reason = error_message error }))
  in
  interrupt After_backup_placed;
  remove_quietly holder;
  record_publication paths package ~previous:(Some { backup; revision });
  backup

(* Change one entry's mode through a descriptor, never through the path. The
   entry is opened and changed only if the descriptor is the entry [lstat]
   saw, so a symlink swapped in after inspection is not followed. *)
let set_release_mode ~root absolute kind =
  (match Fs_compat.inspect_owned_directory_chain ~ownership_root:root (Filename.dirname absolute) with
   | Ok (Fs_compat.Owned_directory _) -> ()
   | Ok Fs_compat.Owned_directory_missing | Error _ -> raise (Rejected (Invalid_path absolute)));
  let named = Unix.lstat absolute in
  let fd = Unix.openfile absolute [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ] 0 in
  Fun.protect ~finally:(fun () -> close_quietly fd) (fun () ->
    let opened = Unix.fstat fd in
    let same_entry =
      named.Unix.st_dev = opened.Unix.st_dev && named.Unix.st_ino = opened.Unix.st_ino in
    match same_entry, kind, opened.Unix.st_kind with
    | true, Directory, Unix.S_DIR | true, File, Unix.S_REG -> Unix.fchmod fd (release_mode kind)
    | false, (Directory | File),
      (Unix.S_DIR | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK)
    | true, Directory, (Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK)
    | true, File, (Unix.S_DIR | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK) ->
      raise (Rejected (Invalid_path absolute)))

(* Files and bytes already equal this release; only modes differ. The whole
   tree is compared with the release before the receipt is written. *)
let set_release_permissions paths package ~revision ~entries =
  require_unchanged paths package
    (Present { revision; bundled_revision = bundled_revision package; ownership = Untracked });
  let target = package_target paths package.name in
  List.iter (fun { kind; path; mode = _; digest = _ } ->
    set_release_mode ~root:paths.root (if path = "" then target else Filename.concat target path) kind)
    entries;
  let expected = bundled_revision package in
  if tree_revision ~root:paths.root target <> Some expected then
    raise (Rejected (Revision_conflict (observe paths package)));
  write_receipt paths package.name ~revision:expected

(* Move a recorded tree out of the Skill source into a staging holder, then
   into the package's backup entry, under a move note like a replacement. The
   receipt goes last, so a crash leaves a receipt without a tree, which the
   next installation removes. *)
let retire ~interrupt paths name ~revision =
  let target = package_target paths name in
  let holder, tree = new_holder paths name in
  (match protect (fun () -> write_move_note paths name ~revision) with
   | Ok () -> ()
   | Error error -> remove_quietly holder; raise (Rejected error));
  interrupt After_move_note;
  (match protect (fun () -> Fs_compat.rename_noreplace target tree) with
   | Ok () -> ()
   | Error error ->
     remove_move_note_quietly paths name;
     remove_quietly holder;
     raise (Rejected error));
  interrupt After_leaving_skill_source;
  let backup =
    match protect (fun () -> sync_dir paths.skills; place_backup paths name tree) with
    | Ok backup -> backup
    | Error error ->
      raise (Rejected (Retired_but_unrecorded { backup = tree; reason = error_message error }))
  in
  interrupt After_backup_placed;
  remove_quietly holder;
  let recorded = protect (fun () ->
    if tree_revision ~root:paths.root backup <> Some revision then
      raise (Rejected (Invalid_path backup));
    remove_move_note paths name;
    Unix.unlink (receipt_path paths name);
    sync_dir paths.state) in
  match recorded with
  | Ok () -> Retire_recorded { backup = Some backup }
  | Error error ->
    raise (Rejected (Retired_but_unrecorded { backup; reason = error_message error }))

let remove_receipt paths name =
  Unix.unlink (receipt_path paths name);
  sync_dir paths.state;
  Retire_recorded { backup = None }

type authority = Startup | Installer

type bundled_step =
  | Settled of bundled_verdict
  | Publish
  | Record of { revision : string }
  | Record_with_release_permissions of { revision : string; entries : entry list }
  | Exchange of { revision : string }

type retired_step =
  | Settled_retired of retired_verdict
  | Remove_receipt
  | Move_aside of { revision : string }

(* The one judgement of an installed package. [authority] decides only whether
   a change to an installed tree runs now or is reported as pending. Server
   start publishes missing packages and writes receipts for trees that already
   equal its release, and nothing else: binaries with different packages start
   against the same base path, and each would undo the other on every start. *)
let bundled_step ~authority paths package =
  match protect (fun () -> observe_installed paths package.name) with
  | Error ((Invalid_path _ | Io_error _) as error) ->
    Settled (Keep_uninspectable { reason = error_message error })
  | Error ((Revision_conflict _ | Bundled_revision_conflict _ | Published_but_unrecorded _
           | Exported_but_unsynced _ | Retired_but_unrecorded _ | Backup_move_pending _
           | Backup_move_unresolved _) as error) ->
    raise (Rejected error)
  | Ok (_, None) -> Publish
  | Ok (receipt, Some entries) ->
    let revision = revision entries in
    match ownership_of receipt revision, files_match package ~revision entries, authority with
    | Recorded, Same_tree, (Startup | Installer) -> Settled Up_to_date
    | (Untracked | Modified), Same_tree, (Startup | Installer) -> Record { revision }
    | Untracked, Same_files_other_permissions, Installer ->
      Record_with_release_permissions { revision; entries }
    | Untracked, Same_files_other_permissions, Startup ->
      Settled (Permissions_pending { revision })
    | Recorded, (Same_files_other_permissions | Different_files), Installer -> Exchange { revision }
    | Recorded, (Same_files_other_permissions | Different_files), Startup ->
      Settled (Replace_pending { revision })
    | Modified, (Same_files_other_permissions | Different_files), (Startup | Installer) ->
      Settled (Keep_modified { revision })
    | Untracked, Different_files, (Startup | Installer) ->
      Settled (Keep_untracked_different { revision })

(* [None] when the receipt is gone by the time it is read: the name then has
   no installation record left to reconcile. *)
let retired_step ~authority paths name =
  match protect (fun () -> observe_installed paths name) with
  | Error ((Invalid_path _ | Io_error _) as error) ->
    Some (Ok (Settled_retired (Keep_retired_uninspectable { reason = error_message error })))
  | Error ((Revision_conflict _ | Bundled_revision_conflict _ | Published_but_unrecorded _
           | Exported_but_unsynced _ | Retired_but_unrecorded _ | Backup_move_pending _
           | Backup_move_unresolved _) as error) ->
    Some (Error error)
  | Ok (None, _) -> None
  | Ok (Some _, None) ->
    Some (Ok (match authority with
      | Installer -> Remove_receipt
      | Startup -> Settled_retired (Retire_pending { revision = None })))
  | Ok (Some recorded, Some entries) ->
    let revision = revision entries in
    Some (Ok (match String.equal recorded (receipt_content revision), authority with
      | true, Installer -> Move_aside { revision }
      | true, Startup -> Settled_retired (Retire_pending { revision = Some revision })
      | false, (Startup | Installer) -> Settled_retired (Keep_retired_modified { revision })))

(* Package names of the receipt-shaped files in [directory]: receipts in the
   receipt directory, move notes in the moves directory. *)
let noted_names directory =
  match stat directory with
  | None -> []
  | Some info when info.Unix.st_kind = Unix.S_DIR ->
    Sys.readdir directory
    |> Array.to_list
    |> List.sort String.compare
    |> List.filter_map (fun entry ->
      match Filename.chop_suffix_opt ~suffix:receipt_suffix entry with
      | Some name when valid_component name -> Some name
      | Some _ | None -> None)
  | Some _ -> raise (Rejected (Invalid_path directory))

(* Receipts are the only evidence that a Skill directory came from this
   installer, so they are the only names retirement considers. *)
let recorded_names paths = noted_names paths.state

type plan =
  { bundled : (package * (bundled_step, error) result) list
  ; retired : (string * (retired_step, error) result) list }

(* Every package is judged before anything is changed. *)
let plan ~authority paths ~recorded packages =
  let shipped = List.map name packages in
  { bundled = List.map (fun package ->
      package, protect (fun () -> bundled_step ~authority paths package)) packages
  ; retired = recorded
      |> List.filter (fun recorded -> not (List.mem recorded shipped))
      |> List.filter_map (fun name ->
        Option.map (fun step -> name, step) (retired_step ~authority paths name)) }

let changes_anything plan =
  List.exists (fun (_, step) -> match step with
    | Ok (Settled _) | Error _ -> false
    | Ok (Publish | Record _ | Record_with_release_permissions _ | Exchange _) -> true) plan.bundled
  || List.exists (fun (_, step) -> match step with
    | Ok (Settled_retired _) | Error _ -> false
    | Ok (Remove_receipt | Move_aside _) -> true) plan.retired

let apply_bundled ~interrupt paths package = function
  | Settled verdict -> verdict
  | Publish -> publish_missing paths package; Install_missing
  | Record { revision } -> write_receipt paths package.name ~revision; Adopt_identical
  | Record_with_release_permissions { revision; entries } ->
    set_release_permissions paths package ~revision ~entries; Adopt_with_release_permissions
  | Exchange { revision } ->
    Replace_recorded { backup = publish_over ~interrupt paths package ~revision ~ownership:Recorded }

let apply_retired ~interrupt paths name = function
  | Settled_retired verdict -> verdict
  | Remove_receipt -> remove_receipt paths name
  | Move_aside { revision } -> retire ~interrupt paths name ~revision

let execute ~interrupt paths plan =
  List.map (fun (package, step) ->
    Bundled { name = package.name
            ; result = Result.bind step (fun step ->
                protect (fun () -> apply_bundled ~interrupt paths package step)) }) plan.bundled
  @ List.map (fun (name, step) ->
    Retired { name
            ; result = Result.bind step (fun step ->
                protect (fun () -> apply_retired ~interrupt paths name step)) }) plan.retired

(* Holders in staging that could hold the tree a note names. *)
let staged_trees paths name =
  match stat paths.staging with
  | None -> []
  | Some info when info.Unix.st_kind = Unix.S_DIR ->
    Sys.readdir paths.staging
    |> Array.to_list
    |> List.sort String.compare
    |> List.map (fun holder -> Filename.concat (Filename.concat paths.staging holder) name)
  | Some _ -> raise (Rejected (Invalid_path paths.staging))

(* Finish one noted move, looking for the tree by the revision in its note. A
   place whose tree cannot be inspected does not hold it. [None] when the note
   is gone by the time it is read. *)
let resume_move paths name =
  let note = move_note_path paths name in
  match load_receipt ~root:paths.root note with
  | None -> None
  | Some noted ->
    let holds directory =
      match protect (fun () -> tree_revision ~root:paths.root directory) with
      | Ok (Some revision) -> String.equal (receipt_content revision) noted
      | Ok None | Error _ -> false
    in
    let outcome =
      match holds (backup_target paths name), holds (package_target paths name) with
      | true, (true | false) -> Move_completed
      | false, true -> Move_never_started
      | false, false ->
        match List.find_opt holds (staged_trees paths name) with
        | Some tree -> Move_finished { backup = place_backup paths name tree }
        | None -> raise (Rejected (Backup_move_unresolved { note }))
    in
    remove_move_note paths name;
    Some outcome

let resume_moves paths =
  noted_names paths.moves
  |> List.filter_map (fun name ->
    match protect (fun () -> resume_move paths name) with
    | Ok None -> None
    | Ok (Some outcome) -> Some (name, Ok outcome)
    | Error error -> Some (name, Error error))

(* Only an installation that holds the lock and has resolved every move note
   gets here, so every entry is left over from an interrupted one. *)
let clear_staging paths =
  match stat paths.staging with
  | None -> []
  | Some info when info.Unix.st_kind = Unix.S_DIR ->
    Sys.readdir paths.staging
    |> Array.to_list
    |> List.sort String.compare
    |> List.map (fun entry ->
      let path = Filename.concat paths.staging entry in
      Unfinished { path; result = protect (fun () -> Fs_compat.remove_tree path) })
  | Some _ -> raise (Rejected (Invalid_path paths.staging))

(* Judged without the lock first. A start whose packages are all settled
   takes no lock and writes nothing, however long another installation holds
   the lock. Otherwise the judgement is repeated under the lock, because the
   first one may have been read while an installation was moving trees. *)
let reconcile_at_startup ~base_path packages =
  protect (fun () ->
    Fs_compat.mkdir_p base_path;
    let paths = locations ~base_path in
    let unlocked = plan ~authority:Startup paths ~recorded:(recorded_names paths) packages in
    match changes_anything unlocked with
    | false -> Reconciled (execute ~interrupt:no_interruption paths unlocked)
    | true ->
      match with_lock_if_free paths (fun () ->
        execute ~interrupt:no_interruption paths
          (plan ~authority:Startup paths ~recorded:(recorded_names paths) packages)) with
      | Some reports -> Reconciled reports
      | None -> Busy { lock = lock_path paths })

let install_with ~interrupt ~on_wait ~base_path packages =
  protect (fun () ->
    Fs_compat.mkdir_p base_path;
    let paths = locations ~base_path in
    with_installer_lock ~on_wait paths (fun () ->
      let recorded = recorded_names paths in
      let moves = resume_moves paths in
      (* A holder may still hold a tree an unresolved note names. *)
      let unfinished =
        match List.for_all (fun (_, result) -> Result.is_ok result) moves with
        | true -> clear_staging paths
        | false -> []
      in
      List.map (fun (name, result) -> Interrupted { name; result }) moves
      @ unfinished
      @ execute ~interrupt paths (plan ~authority:Installer paths ~recorded packages)))

let install = install_with ~interrupt:no_interruption

let replace_reviewed ~on_wait ~base_path ~installed_revision ~bundled_revision:reviewed_bundle
    package =
  protect (fun () ->
    let actual_revision = bundled_revision package in
    if not (String.equal reviewed_bundle actual_revision) then
      raise (Rejected (Bundled_revision_conflict { actual_revision }));
    let paths = locations ~base_path in
    with_installer_lock ~on_wait paths (fun () ->
      match observe paths package with
      | Missing -> raise (Rejected (Revision_conflict Missing))
      | Present { revision; bundled_revision; ownership } as before ->
        match String.equal installed_revision revision, ownership,
              String.equal revision bundled_revision with
        | false, (Recorded | Untracked | Modified), (true | false) ->
          raise (Rejected (Revision_conflict before))
        | true, Recorded, true -> Already_current
        | true, (Untracked | Modified), true | true, (Recorded | Untracked | Modified), false ->
          Replaced { backup = publish_over ~interrupt:no_interruption paths package ~revision ~ownership }))

module For_testing = struct
  type nonrec interruption = interruption =
    | After_move_note
    | After_leaving_skill_source
    | After_backup_placed
  let export = export_with_sync
  let ensure_directory ~sync_parent path =
    protect (fun () -> ensure_dir_with_sync ~sync_parent path)
  let install = install_with
end
