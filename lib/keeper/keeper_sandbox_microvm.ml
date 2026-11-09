(** microVM argv for the [Micro_vm] sandbox profile.

    Every builder here takes the runtime the keeper declared
    ({!Keeper_microvm_backend.t}). Before #32837 the lifecycle surfaces took
    it and the boot, exec, image and listing surfaces did not, so a keeper
    naming [microsandbox] booted under Apple's [container] and was then
    stopped and inspected with [msb] -- two runtimes for one guest, and
    nothing able to reap the one that actually booted.

    One lightweight VM per container through Virtualization.framework, so an
    Apple guest runs its own Linux kernel instead of sharing the host's.
    Measured
    2026-08-28 on macOS 26.6.1 / M3 Max with container CLI 1.3.0: about
    460 MB of host memory per running guest, and the guest reporting
    [Linux <uuid> 6.18.35].

    Cost is per keeper, not per call. Booting a guest takes 1.3-2.4s, but
    #31340 made the guest keeper-lifetime, so a turn pays [container exec]
    at 0.06-0.10s -- under Docker's 0.6-0.9s per-call container start. An
    earlier version of this comment quoted 4.0-4.4s per call: that was
    measured before guests were adopted across turns, and stayed here after
    the number stopped being true.

    This module builds the command and nothing else; [Keeper_turn_sandbox_runtime]
    runs the boot and lifecycle argv, and the remote lane
    ([Keeper_sandbox_remote]) drives the guest's shim over [container exec].
    The guest's working tree is on a Keeper-named volume (RFC-0400), which
    can be shared by same-named Keepers in different workspaces. The host
    playground is never mounted into it. *)

include Keeper_sandbox_microvm_base
include Keeper_sandbox_microvm_network
include Keeper_sandbox_microvm_image_probe
include Keeper_sandbox_microvm_guest_argv

module Backend = Keeper_microvm_backend
module Kata_vmm = Keeper_microvm_kata_vmm

(* ── The work volume and the shim (RFC-0400) ────────────────────────── *)

(** Volume names reach [container] as an argument and become a directory name
    under its state directory, so a name outside this set is refused rather
    than escaped. *)
let valid_volume_segment segment =
  (not (String.equal segment ""))
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' -> true
         | _ -> false)
       segment

(** Apple's spelling of a sized volume. It is named after the runtime rather
    than left as the lane's default because the other two do not share it:
    [msb] rejects [-s] and wants [--kind disk --size] (measured 0.6.16), and
    [nerdctl volume create] documents [--label] only and no size flag at all.
    {!ensure_work_volume_for} is the entry that answers for all three. *)
let apple_volume_create_argv ~volume_name ~size =
  command_argv_for Backend.Apple_container
  @ [ "volume"; "create"; "-s"; size; volume_name ]
;;

(** msb's work volume is a directory-backed named volume ([volume create
    --kind dir], no size). Two facts force the kind, both measured 0.6.16:
    [--size] is rejected on a dir volume ("only supported with --kind disk
    until directory quotas are enforced"), and a disk volume cannot be
    mounted as a named work root -- [-v] and [--mount-named] both request a
    dir and refuse a disk one ("already exists as disk, but this sandbox
    requested dir"). So RFC-0400's size ceiling has no msb spelling, the way
    it has no nerdctl one; the dir volume mounts over virtiofs and the mount
    args are the shared [--volume NAME:DEST] form. *)
let msb_volume_create_argv ~volume_name =
  command_argv_for Backend.Microsandbox @ [ "volume"; "create"; "--kind"; "dir"; volume_name ]
;;

let work_volume_name ~keeper_name =
  if valid_volume_segment keeper_name
  then Ok ("masc-keeper-work-" ^ keeper_name)
  else Error ("unsupported keeper name for a work volume: " ^ keeper_name)
;;

let work_volume_mount_args ~volume_name =
  [ "--volume"; volume_name ^ ":" ^ work_volume_guest_root ]
;;

(* ── Checkouts and their build output ─────────────────────────────────
   The boot-time work volume helper removes real build output while no guest
   holds the volume, and the in-guest scan links each checkout's [_build] to
   the build volume once the guest is up. Both walk the same checkouts. *)

(** How far below a keeper's work root a checkout is looked for.

    Observed layouts put them at depth 1 ([polisher/masc-t362]) and depth 2
    ([lane-smith/repos/wt-370]). Three leaves room for one more level without
    turning this into a whole-tree walk. *)
let build_root_scan_depth = 3

(** A checkout is a directory holding [dune-project].

    That is the marker for the build output this addresses: [_build] is
    dune's name and dune's alone. Other ecosystems pin host descriptors the
    same way through their own output directories -- [node_modules],
    [target], [dist] -- and are {i not} handled here (measured: npm deletes
    and replaces a [node_modules] symlink on every install, defeating this
    mechanism outright). Naming that gap is
    deliberate, so a reader does not read this as covering every keeper. *)
let build_root_marker = "dune-project"

let build_output_dir_name = "_build"

(** A checkout holding this file keeps its real [_build] through a guest
    boot. The guest's idle build cleanup payload
    ([config/scripts/keeper-build-cleanup.py]) skips the same name. *)
let build_keep_marker = ".masc-keep-build"

let trim_guest_root = "/masc-trim"
let trim_capabilities = [ "CAP_SYS_ADMIN" ]
let work_volume_trim_name ~keeper_name =
  Keeper_sandbox_container_name.make
    (Keeper_sandbox_container_name.Micro_vm_work_volume_trim { keeper_name })
  |> Keeper_sandbox_container_name.to_string
;;

(* This payload runs under the Keeper uid/gid at its first owned turn
   handoff. All renames precede deletion, so a subsequent build cannot write
   into an old tree while it is being removed. The pending name is reserved. *)
let first_handoff_build_cleanup_script ~keeper_work_root =
  let root = Filename.quote keeper_work_root in
  Printf.sprintf
    {sh|[ ! -L %s ] || exit 1
if [ ! -e %s ]; then exit 0; fi
[ -d %s ] || exit 1
cd %s || exit 1
pending=./.masc-build-removing
[ ! -L "$pending" ] || exit 1
if [ -e "$pending" ] && [ ! -d "$pending" ]; then exit 1; fi
failed=0
find . -maxdepth %d \( -name .git -o -path ./.masc-build-removing \) -prune -o \( -name %s -type d -prune -exec sh -c '
pending=$1
shift
failed=0
for b do
  c=${b%%/%s}
  [ "$c" != . ] || continue
  [ -e "$c/%s" ] || continue
  [ ! -e "$c/%s" ] || continue
  [ -d "$b" ] && [ ! -L "$b" ] || continue
  [ ! -L "$pending" ] || exit 1
  if ! (umask 077; mkdir -p -- "$pending"); then failed=1; continue; fi
  staging=$(mktemp -d "$pending/removing.XXXXXXXX") || { failed=1; continue; }
  if mv -- "$b" "$staging/%s"; then
    printf "build output staged: %%s\n" "${b#./}"
  else
    rmdir -- "$staging" || :
    failed=1
  fi
done
exit "$failed"' sh "$pending" {} + \) || failed=1
[ ! -L "$pending" ] || exit 1
if [ -d "$pending" ]; then
  find "$pending" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || failed=1
  rmdir -- "$pending" || failed=1
fi
exit "$failed"|sh}
    root root root root (build_root_scan_depth + 1)
    build_output_dir_name build_output_dir_name build_root_marker build_keep_marker
    build_output_dir_name
;;

(* The only one-shot work-volume operation left: configure the ext4 default.
   No build deletion, remount or whole-filesystem trim occurs in this helper. *)
let discard_configuration_script_with ~findmnt ~tune2fs ~guest_root =
  Printf.sprintf "work_device=$(%s --noheadings --output SOURCE --target %s)\n%s -o discard \"$work_device\""
    (Filename.quote findmnt) (Filename.quote guest_root) (Filename.quote tune2fs)
;;

let work_volume_reclaim_script =
  discard_configuration_script_with ~findmnt:"/usr/bin/findmnt"
    ~tune2fs:"/usr/sbin/tune2fs" ~guest_root:trim_guest_root
;;

let apple_work_volume_trim_argv ~keeper_name ~volume_name ~image =
  command_argv_for Backend.Apple_container
  @ [ "run"; "--rm"; "--name"; work_volume_trim_name ~keeper_name
    ; "--user"; "0"; "--cap-drop"; "ALL" ]
  @ List.concat_map (fun capability -> [ "--cap-add"; capability ]) trim_capabilities
  @ [ "--network"; "none"; "--read-only"
    ; "--entrypoint"; "/bin/sh"
    ; "--volume"; volume_name ^ ":" ^ trim_guest_root
    ; image; "-eu"; "-c"; work_volume_reclaim_script ]
;;

(* The trim cleanup, the abandoned-guest sweep, Keeper status and the guest
   probe read this one argv: they ask the same runtime the same question. *)
let apple_container_list_argv () =
  command_argv_for Backend.Apple_container @ [ "list"; "--all"; "--format"; "json" ]
;;

(* The name of one row of Apple's [container list] JSON: the top-level [id],
   else [configuration.id]. [None] for a row that names no container. *)
let apple_listing_row_id fields =
  match List.assoc_opt "id" fields with
  | Some (`String id) when String.trim id <> "" -> Some id
  | Some _ -> None
  | None ->
    (match List.assoc_opt "configuration" fields with
     | Some (`Assoc config) ->
       (match List.assoc_opt "id" config with
        | Some (`String id) when String.trim id <> "" -> Some id
        | Some _ | None -> None)
     | Some _ | None -> None)
;;

(* Remove a one-shot volume helper by its stable name and prove it is gone.
   [helper] names it in the messages ("trim", "repair"). *)
let remove_apple_volume_helper ~run ~timeout_sec ~remove_timeout_sec ~name ~helper =
  (* Only the actual complete inventory authorizes absence. The legacy runner
     remains the deletion effect edge; its bounded output cannot prove it. *)
  let removal_status, _stdout, _stderr =
    run ~timeout_sec:remove_timeout_sec
      (delete_force_argv_for Backend.Apple_container ~container_name:name)
  in
  let unconfirmed detail = Error (helper ^ " helper absence unconfirmed: " ^ detail) in
  match Keeper_microvm_cli_output.read ~timeout_sec ~argv:(apple_container_list_argv ()) with
  | Error error -> unconfirmed (Keeper_microvm_cli_output.error_message error)
  | Ok (Unix.WEXITED 0, stdout) ->
    let module Inventory = Keeper_microvm_inventory_json in
    (match Inventory.of_apple_json stdout with
     | Error error -> unconfirmed (Inventory.invalid_inventory_message error)
     | Ok inventory ->
       match Inventory.presence ~guest_name:name inventory with
       | Error Inventory.Invalid_guest_name -> unconfirmed "invalid helper name"
       | Ok Inventory.Absent -> Ok ()
       | Ok Inventory.Present ->
         Error (Printf.sprintf "%s container %s remains after removal (%s)"
           helper name (Keeper_sandbox_exec_failure.status_label removal_status)))
  | Ok (((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), _stdout) ->
    unconfirmed (Keeper_sandbox_exec_failure.status_label status)
;;

let remove_apple_work_volume_trim ~run ~timeout_sec ~remove_timeout_sec ~keeper_name =
  remove_apple_volume_helper ~run ~timeout_sec ~remove_timeout_sec
    ~name:(work_volume_trim_name ~keeper_name) ~helper:"trim"
;;

type discard_read_failure =
  | Discard_backend_unsupported of Backend.t
  | Discard_volume_name_invalid of string
  | Discard_inspect_unavailable of Keeper_microvm_cli_output.error
  | Discard_inspect_failed of Unix.process_status
  | Discard_inspect_invalid_json
  | Discard_inspect_invalid of Keeper_volume_filesystem.inspect_failure
  | Discard_volume_mismatch of { expected : string; actual : string }
  | Discard_image_unreadable of Keeper_volume_filesystem.read_failure

type work_volume_discard_default =
  | Discard_default_set
  | Discard_default_absent
  | Superblock_unreadable of discard_read_failure

let apple_volume_inspect_argv ~volume_name =
  command_argv_for Backend.Apple_container @ [ "volume"; "inspect"; volume_name ]
;;

let read_work_volume_discard_default ~backend ~keeper_name ~timeout_sec =
  let unreadable failure = Superblock_unreadable failure in
  match (backend : Backend.t) with
  | Backend.Microsandbox | Backend.Nerdctl_kata -> unreadable (Discard_backend_unsupported backend)
  | Backend.Apple_container ->
    match work_volume_name ~keeper_name with
    | Error detail -> unreadable (Discard_volume_name_invalid detail)
    | Ok expected ->
      match Keeper_microvm_cli_output.read ~timeout_sec ~argv:(apple_volume_inspect_argv ~volume_name:expected) with
      | Error error -> unreadable (Discard_inspect_unavailable error)
      | Ok ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status, _) when status <> Unix.WEXITED 0 ->
        unreadable (Discard_inspect_failed status)
      | Ok ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), stdout) ->
        match Yojson.Safe.from_string stdout with
        | exception Yojson.Json_error _ -> unreadable Discard_inspect_invalid_json
        | json ->
          match Keeper_volume_filesystem.image_of_inspect json with
          | Error failure -> unreadable (Discard_inspect_invalid failure)
          | Ok image when image.volume <> expected ->
            unreadable (Discard_volume_mismatch {expected; actual=image.volume})
          | Ok image ->
            Eio_guard.run_in_systhread ~label:"microvm-discard-default" (fun () ->
              match Keeper_volume_filesystem.read_discard_default_image ~path:image.source with
              | Ok Keeper_volume_filesystem.Discard_default_set -> Discard_default_set
              | Ok Keeper_volume_filesystem.Discard_default_absent -> Discard_default_absent
              | Error failure -> unreadable (Discard_image_unreadable failure))
;;

let discard_read_failure_message = function
  | Discard_backend_unsupported backend -> "discard observation unsupported for " ^ Backend.to_string backend
  | Discard_volume_name_invalid detail -> detail
  | Discard_inspect_unavailable error -> Keeper_microvm_cli_output.error_message error
  | Discard_inspect_failed status -> "volume inspect " ^ Keeper_sandbox_exec_failure.status_label status
  | Discard_inspect_invalid_json -> "volume inspect returned invalid JSON"
  | Discard_inspect_invalid failure -> Keeper_volume_filesystem.inspect_failure_to_string failure
  | Discard_volume_mismatch {expected; actual} -> Printf.sprintf "volume inspect named %S, expected %S" actual expected
  | Discard_image_unreadable failure -> Keeper_volume_filesystem.read_failure_to_string failure
;;

type discard_configuration =
  | Discard_already_set
  | Discard_unreadable of discard_read_failure
  | Discard_helper_finished of
      { status : Unix.process_status; output : string; after : work_volume_discard_default }

let reclaim_apple_work_volume ~run ~on_cleanup_error ~timeout_sec ~remove_timeout_sec
    ~keeper_name ~volume_name ~image =
  let initial = match work_volume_name ~keeper_name with
    | Error detail -> Superblock_unreadable (Discard_volume_name_invalid detail)
    | Ok expected when expected <> volume_name ->
      Superblock_unreadable (Discard_volume_mismatch {expected; actual=volume_name})
    | Ok _ -> read_work_volume_discard_default ~backend:Backend.Apple_container ~keeper_name ~timeout_sec in
  match initial with
  | Discard_default_set -> Ok Discard_already_set
  | Superblock_unreadable failure -> Ok (Discard_unreadable failure)
  | Discard_default_absent ->
    let cleanup () = remove_apple_work_volume_trim ~run ~timeout_sec ~remove_timeout_sec ~keeper_name in
    let released = ref (Ok ()) in
    let result = Eio.Switch.run (fun sw ->
      Eio.Switch.on_release sw (fun () ->
        released := cleanup ();
        match !released with Ok () -> () | Error detail -> on_cleanup_error detail);
      let open Result.Syntax in
      let* () = cleanup () in
      let status, stdout, stderr = run ~timeout_sec
          (apple_work_volume_trim_argv ~keeper_name ~volume_name ~image) in
      Ok (status, output_for_log ~stdout ~stderr)) in
    match !released, result with
    | Error detail, _ | Ok (), Error detail -> Error detail
    | Ok (), Ok (status, output) ->
      let after = read_work_volume_discard_default ~backend:Backend.Apple_container ~keeper_name ~timeout_sec in
      Ok (Discard_helper_finished {status; output; after})
;;

(* RFC keeper-volume-filesystem-repair §3.3. *)
let volume_repair_guest_root = "/masc-repair"
let volume_repair_capabilities = [ "CAP_SYS_ADMIN" ]

(* util-linux and e2fsprogs paths in the catalog images, measured in
   [masc-sandbox:general] on 2026-10-22 (e2fsck 1.47.0). The trim helper's
   [tune2fs] comes from the same e2fsprogs package. *)
let findmnt_guest_path = "/usr/bin/findmnt"
let umount_guest_path = "/usr/bin/umount"
let e2fsck_guest_path = "/usr/sbin/e2fsck"

let volume_repair_name ~keeper_name =
  Keeper_sandbox_container_name.make
    (Keeper_sandbox_container_name.Micro_vm_volume_repair { keeper_name })
  |> Keeper_sandbox_container_name.to_string
;;

(* The runtime mounts the volume at [volume_repair_guest_root], and e2fsck
   needs it unmounted. [--mountpoint] matches only that mount; [--target]
   would find the root filesystem once the volume is gone (measured
   2026-10-22). The two e2fsck exit codes are printed as evidence only: the
   host reads the superblock again to decide what the repair did. *)
let volume_repair_script_with ~findmnt ~umount ~e2fsck ~guest_root =
  Printf.sprintf
    "device=$(%s --noheadings --output SOURCE --mountpoint %s)\n\
     %s %s\n\
     if %s --mountpoint %s >/dev/null; then echo 'volume is still mounted; e2fsck not run' >&2; exit 1; fi\n\
     set +e\n\
     %s -f -y \"$device\"\n\
     echo \"e2fsck repair exit $?\"\n\
     %s -f -n \"$device\"\n\
     echo \"e2fsck verify exit $?\""
    findmnt
    guest_root
    umount
    guest_root
    findmnt
    guest_root
    e2fsck
    e2fsck
;;

let volume_repair_script =
  volume_repair_script_with
    ~findmnt:findmnt_guest_path
    ~umount:umount_guest_path
    ~e2fsck:e2fsck_guest_path
    ~guest_root:volume_repair_guest_root
;;

let apple_volume_repair_argv ~keeper_name ~volume_name ~image =
  command_argv_for Backend.Apple_container
  @ [ "run"; "--rm"; "--name"; volume_repair_name ~keeper_name
    ; "--user"; "0"; "--cap-drop"; "ALL" ]
  @ List.concat_map (fun capability -> [ "--cap-add"; capability ]) volume_repair_capabilities
  @ [ "--network"; "none"; "--read-only"; "--tmpfs"; "/tmp"
    ; "--entrypoint"; "/bin/sh"
    ; "--volume"; volume_name ^ ":" ^ volume_repair_guest_root
    ; image; "-eu"; "-c"; volume_repair_script ]
;;

let remove_apple_volume_repair ~run ~timeout_sec ~remove_timeout_sec ~keeper_name =
  remove_apple_volume_helper ~run ~timeout_sec ~remove_timeout_sec
    ~name:(volume_repair_name ~keeper_name) ~helper:"repair"
;;

type volume_repair_run =
  { status : Unix.process_status
  ; stdout : string
  ; stderr : string
  ; cleanup : (unit, string) result
  }

(* The lifecycle of [reclaim_apple_work_volume]: a leftover helper is removed
   first, and the release handler removes this one whatever happens. Once
   the helper has run, a failed removal is reported beside its result, never
   in place of it: e2fsck may have written the image. [run_helper] has no
   timeout: cutting e2fsck short is worse than waiting for it. *)
let repair_apple_volume ~run ~run_helper ~on_start ~on_cleanup_error ~timeout_sec
    ~remove_timeout_sec ~keeper_name ~volume_name ~image =
  let cleanup () = remove_apple_volume_repair ~run ~timeout_sec ~remove_timeout_sec ~keeper_name in
  let released = ref (Ok ()) in
  let result = Eio.Switch.run (fun sw ->
    Eio.Switch.on_release sw (fun () ->
      released := cleanup ();
      match !released with Ok () -> () | Error detail -> on_cleanup_error detail);
    match cleanup () with
    | Error _ as error -> error
    | Ok () ->
      on_start ();
      let status, stdout, stderr =
        run_helper (apple_volume_repair_argv ~keeper_name ~volume_name ~image)
      in
      Ok (status, stdout, stderr))
  in
  Result.map (fun (status, stdout, stderr) -> { status; stdout; stderr; cleanup = !released }) result
;;

(** The keeper's root on the work volume: [<work root>/<keeper>], the
    directory the shim jails every request under. *)
let keeper_work_root ~keeper_name =
  Filename.concat work_volume_guest_root (Playground_paths.sanitize_keeper_name keeper_name)
;;

(** Where the guest finds [masc-exec-shim] and its config: one host directory
    mounted read-only. The guest root is read-only and [/etc] is the image's,
    so the config travels beside the binary and the transport names it
    through [MASC_EXEC_SHIM_CONFIG]. *)
let shim_guest_dir = "/opt/masc-exec-shim"
let shim_binary_name = "masc-exec-shim"
let shim_config_name = "masc-exec-shim.conf"
let shim_sidecar_name = "masc-exec-shim.sha256"

(* RFC-0427 B-2. The installer places the release's shim and, beside it, the
   sha256 the release's SHA256SUMS gave for that asset. The boot reads the
   pair: a binary that does not match its own sidecar is refused by name,
   because a shim the release did not ship is the 2026-09-05 outage waiting
   to recur. No sidecar means a hand-built shim; it runs, and the boot log
   says it was not verified. *)
type shim_provenance =
  | Shim_verified of { sha256 : string }
  | Shim_unverified

(* Integrity follows current bytes, not metadata that an in-place writer
   can preserve. The boot edge offloads this read and hash to its executor. *)
let sha256_of_file path =
  match In_channel.with_open_bin path In_channel.input_all with
  | contents -> Ok Agent_core_sha256.(digest_string contents |> to_hex)
  | exception Sys_error detail -> Error detail
;;

let verify_shim_sidecar ~dir =
  let binary = Filename.concat dir shim_binary_name in
  let sidecar = Filename.concat dir shim_sidecar_name in
  if not (Sys.file_exists sidecar)
  then Ok Shim_unverified
  else
    match In_channel.with_open_bin sidecar In_channel.input_all with
    | exception Sys_error detail ->
      Error (Printf.sprintf "microvm_shim_sidecar_unreadable: %s: %s" sidecar detail)
    | content ->
      let want =
        match String.split_on_char ' ' (String.trim content) with
        | first :: _ -> String.trim first
        | [] -> ""
      in
      if not (String_util.is_lowercase_sha256_hex want)
      then
        Error
          (Printf.sprintf
             "microvm_shim_sidecar_invalid: %s does not begin with a lowercase sha256 hex digest"
             sidecar)
      else
        match sha256_of_file binary with
        | Error detail ->
          Error (Printf.sprintf "microvm_shim_unreadable: %s: %s" binary detail)
        | Ok got when String.equal got want -> Ok (Shim_verified { sha256 = got })
        | Ok got ->
          Error
            (Printf.sprintf
               "microvm_shim_hash_mismatch: %s is %s but %s says %s; reinstall both with scripts/install.sh, or remove the sidecar to run a hand-built shim unverified"
               binary got sidecar want)
;;
let shim_guest_path = Filename.concat shim_guest_dir shim_binary_name
let shim_config_guest_path = Filename.concat shim_guest_dir shim_config_name

let shim_mount_args ~host_dir =
  [ "--volume"; host_dir ^ ":" ^ shim_guest_dir ^ ":ro" ]
;;

(** The config the host writes for the guest's shim: the jail root is the
    work volume, the payload PATH is the image's, and the env allowlist
    names the config env the endpoint injects with every request
    ({!Keeper_sandbox_runtime.config_env_names}) -- the shim drops any
    request env it was not told to accept, and the guest is given the
    config mount, so it must be told the names that point at it. No
    [scratch_root] line: the boot mounts the guest's in-memory filesystem at
    the shim's own default ({!Backend.scratch_guest_root} is that constant),
    and a shim one release behind refuses a key it does not know, which
    would fail every request on the guest. The host writes only the keys
    every spoken shim reads. *)
let shim_env_allowlist =
  Keeper_sandbox_runtime.config_env_names
  @ [ Keeper_github_identity.git_config_global_env_name ]
;;

let shim_config_content ~payload_path =
  Printf.sprintf
    "remote_root=%s\npath=%s\nenv_allowlist=%s\n"
    work_volume_guest_root
    payload_path
    (String.concat "," shim_env_allowlist)
;;

(** What the guest endpoint declares to the remote runner. No caller env
    crosses into a guest today (typed guest dispatch refuses env), so the
    allowlist is empty; the session ceiling mirrors the OpenSSH default, and
    the connect budget covers a [container exec] that has to wait on a
    guest still settling after boot. *)
let remote_env_allowlist : string list = []
let remote_connect_timeout_sec = 10
let remote_max_concurrent_sessions = 8

(* ── Provisioning the work volume ──────────────────────────────────── *)

(** Volume ids in a [container volume list --format json] payload. Every
    row must be identifiable before the list can prove that a volume is
    absent. Apple encodes both [id] and [configuration.name] as the volume
    name; accept either alone but refuse conflicting or malformed fields. *)
let volume_names_of_json = function
  | `List entries ->
    let unique_member key fields =
      match List.filter (fun (name, _) -> String.equal name key) fields with
      | [] -> Ok None
      | [ (_, value) ] -> Ok (Some value)
      | _ -> Error ("duplicate " ^ key)
    in
    let name_member key fields =
      match unique_member key fields with
      | Error _ as error -> error
      | Ok None -> Ok None
      | Ok (Some (`String name)) when not (String.equal (String.trim name) "") ->
        Ok (Some name)
      | Ok (Some _) -> Error (key ^ " is not a nonblank string")
    in
    let name_of_entry = function
      | `Assoc fields ->
        (match name_member "id" fields, unique_member "configuration" fields with
         | Error detail, _ | _, Error detail -> Error detail
         | Ok id, Ok configuration ->
           let configured_name =
             match configuration with
             | None -> Ok None
             | Some (`Assoc config) ->
               (match name_member "name" config with
                | Ok None -> Error "configuration.name is missing"
                | Ok (Some _) as result -> result
                | Error _ as error -> error)
             | Some _ -> Error "configuration is not an object"
           in
           (match id, configured_name with
            | _, Error detail -> Error detail
            | Some id, Ok (Some name) when not (String.equal id name) ->
              Error "id and configuration.name disagree"
            | Some id, Ok _ -> Ok id
            | None, Ok (Some name) -> Ok name
            | None, Ok None -> Error "id and configuration.name are missing"))
      | _ -> Error "row is not an object"
    in
    let rec collect index names = function
      | [] -> Ok (List.rev names)
      | entry :: rest ->
        (match name_of_entry entry with
         | Error detail ->
           Error (Printf.sprintf "container volume list row %d: %s" index detail)
         | Ok name -> collect (index + 1) (name :: names) rest)
    in
    collect 0 [] entries
  | _ -> Error "container volume list did not return a JSON array"
;;

let apple_volume_list_argv () =
  command_argv_for Backend.Apple_container @ [ "volume"; "list"; "--format"; "json" ]
;;

type volume_probe_outcome =
  | Volume_present
  | Volume_absent
  | Volume_probe_failed of string

(** [container volume inspect] answers 0 for present, but its 1 covers "no
    such volume" together with a stopped container system and other faults,
    so a 1 is confirmed against the listing rather than trusted. This mirrors
    [classify_image_probe], and for the same reason: treating an ambiguous
    exit code as "absent" would make provisioning try to create a volume that
    already holds a keeper's working tree. *)
let classify_volume_probe ~volume_name ~inspect ~listing =
  let described label (status, stdout, stderr) =
    Printf.sprintf
      "container volume %s: %s (%s)"
      label
      (match status with
       | Unix.WEXITED code -> Printf.sprintf "exit %d" code
       | Unix.WSIGNALED n -> Printf.sprintf "signalled %d" n
       | Unix.WSTOPPED n -> Printf.sprintf "stopped %d" n)
      (output_for_log ~stdout ~stderr)
  in
  match inspect with
  | Unix.WEXITED 0, _, _ -> Volume_present
  | Unix.WEXITED 1, _, _ ->
    (match listing with
     | None ->
       Volume_probe_failed
         "container volume inspect exited 1 and no listing was taken to confirm whether the volume is absent"
     | Some (Unix.WEXITED 0, stdout, _) ->
       (match Yojson.Safe.from_string stdout with
        | exception Yojson.Json_error message ->
          Volume_probe_failed ("container volume list emitted invalid JSON: " ^ message)
        | json ->
          (match volume_names_of_json json with
           | Error message -> Volume_probe_failed message
           | Ok names ->
             if List.exists (String.equal volume_name) names
             then Volume_present
             else Volume_absent))
     | Some
         (((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _, _) as outcome) ->
       Volume_probe_failed (described "list" outcome))
  | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _, _) as outcome ->
    Volume_probe_failed (described "inspect" outcome)
;;

(** Create the work volume when absent, for whichever runtime the keeper
    declared. [container volume create] is not idempotent, so existence is
    settled by the probe rather than by reading its "already exists" message.

    Only Apple's grammar is established. [msb] and [nerdctl] return an
    [Error] naming what is missing rather than a guess: for [msb] the create
    is known and the inspect and list that settle existence are not, and
    creating over a volume that already holds a keeper's tree is exactly what
    that check exists to prevent; for [nerdctl] there is no size flag to
    establish. Error codes are [microvm_work_volume_*], or
    [microvm_build_volume_*] for Apple's build volume. *)
let apple_volume_probe ~volume_name ~timeout_sec =
  let inspect =
    Process_eio.run_argv_with_status_split ~timeout_sec (apple_volume_inspect_argv ~volume_name)
  in
  let listing =
    match inspect with
    | Unix.WEXITED 1, _, _ ->
      Some (Process_eio.run_argv_with_status_split ~timeout_sec (apple_volume_list_argv ()))
    | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _, _ -> None
  in
  classify_volume_probe ~volume_name ~inspect ~listing
;;

(** Which of a keeper's two Apple volumes a call is about. The probe and the
    create are the same [container volume] commands for both; only the error
    code a failure is reported under differs. *)
type apple_volume_role =
  | Work_volume
  | Build_volume

let apple_volume_error_code = function
  | Work_volume -> "microvm_work_volume"
  | Build_volume -> "microvm_build_volume"
;;

(** Create the volume when it is absent, and say so when it cannot be
    established either way.

    [container volume create] is not idempotent -- a second call errors with
    "already exists" -- so existence is settled by the probe above rather than
    by reading that message. The size is a ceiling: the image is sparse, and
    4 GiB nominal measured 84 MB on disk. *)
let ensure_apple_volume role ~volume_name ~size ~timeout_sec =
  let error_code = apple_volume_error_code role in
  match apple_volume_probe ~volume_name ~timeout_sec with
  | Volume_present -> Ok `Already_present
  | Volume_probe_failed message ->
    Error (Printf.sprintf "%s_probe_failed: %s" error_code message)
  | Volume_absent ->
    let argv = apple_volume_create_argv ~volume_name ~size in
    (match Process_eio.run_argv_with_status_split ~timeout_sec argv with
     | Unix.WEXITED 0, _, _ -> Ok `Created
     | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), stdout, stderr ->
       let failure =
         Error
           (Printf.sprintf
              "%s_create_failed: %s (%s; %s)"
              error_code
              volume_name
              (match status with
               | Unix.WEXITED code -> Printf.sprintf "exit %d" code
               | Unix.WSIGNALED n -> Printf.sprintf "signalled %d" n
               | Unix.WSTOPPED n -> Printf.sprintf "stopped %d" n)
              (output_for_log ~stdout ~stderr))
       in
       match Process_eio.exit_reason_of_status status with
       | Process_eio.Timed_out ->
         (* Killing the CLI does not prove that the backend stopped creating
            its volume. Observe the exact goal once; never replay create.
            Process_eio also classifies a native exit 124 as Timed_out, so
            that ambiguous outcome gets the same conservative observation. *)
         (match apple_volume_probe ~volume_name ~timeout_sec with
          | Volume_present -> Ok `Already_present
          | Volume_absent | Volume_probe_failed _ -> failure)
       | Process_eio.Completed _ | Process_eio.Signaled _ | Process_eio.Stopped _ -> failure)
;;

(** Volume names in an [msb volume list --format json] payload: each row
    carries [name] at top level (measured 0.6.16 against a real volume:
    [{ "name": ..., "kind": "dir", "capacity_bytes": ..., ... }]). Apple's
    [id]/[configuration.name] shape belongs to another runtime and is not
    read here, the way the two inspect parsers are kept apart. *)
let msb_volume_names_of_json = function
  | `List entries ->
    let malformed index =
      Error
        (Printf.sprintf
           "msb volume list row %d must be an object with one nonblank name"
           index)
    in
    let rec parse index names = function
      | [] -> Ok (List.rev names)
      | `Assoc fields :: rest ->
        (match List.filter (fun (key, _) -> String.equal key "name") fields with
         | [ (_, `String name) ] when not (String.equal (String.trim name) "") ->
           parse (index + 1) (name :: names) rest
         | _ -> malformed index)
      | _ :: _ -> malformed index
    in
    parse 0 [] entries
  | _ -> Error "msb volume list did not return a JSON array"
;;

(** msb settles existence from the listing alone. [msb volume list --format
    json] is the machine form (measured: an array, [[]] on an empty host);
    [msb volume inspect] carries no [--format] so there is no second machine
    source, and none is needed. A non-zero list is a probe failure, never
    "absent": reading a stopped runtime as absent would create over a volume
    that already holds a keeper's tree, which is the failure the check exists
    to prevent. *)
let msb_volume_probe ~volume_name ~timeout_sec =
  let list_argv =
    command_argv_for Backend.Microsandbox @ [ "volume"; "list"; "--format"; "json" ]
  in
  match Process_eio.run_argv_with_status_split ~timeout_sec list_argv with
  | Unix.WEXITED 0, stdout, _ ->
    (match Yojson.Safe.from_string stdout with
     | exception Yojson.Json_error message ->
       Volume_probe_failed ("msb volume list emitted invalid JSON: " ^ message)
     | json ->
       (match msb_volume_names_of_json json with
        | Error message -> Volume_probe_failed message
        | Ok names ->
          if List.exists (String.equal volume_name) names
          then Volume_present
          else Volume_absent))
  | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), stdout, stderr ->
    Volume_probe_failed
      (Printf.sprintf
         "msb volume list: %s (%s)"
         (match status with
          | Unix.WEXITED code -> Printf.sprintf "exit %d" code
          | Unix.WSIGNALED n -> Printf.sprintf "signalled %d" n
          | Unix.WSTOPPED n -> Printf.sprintf "stopped %d" n)
         (output_for_log ~stdout ~stderr))
;;

(** Create the msb work volume when the listing shows it absent. [msb volume
    create] errors "volume already exists" rather than clobbering (measured),
    so the listing is the guard and the create is the normal-path action. *)
let ensure_msb_work_volume ~volume_name ~timeout_sec =
  match msb_volume_probe ~volume_name ~timeout_sec with
  | Volume_present -> Ok `Already_present
  | Volume_probe_failed message ->
    Error (Printf.sprintf "microvm_work_volume_probe_failed: %s" message)
  | Volume_absent ->
    let argv = msb_volume_create_argv ~volume_name in
    (match Process_eio.run_argv_with_status_split ~timeout_sec argv with
     | Unix.WEXITED 0, _, _ -> Ok `Created
     | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), stdout, stderr ->
       Error
         (Printf.sprintf
            "microvm_work_volume_create_failed: %s (%s; %s)"
            volume_name
            (match status with
             | Unix.WEXITED code -> Printf.sprintf "exit %d" code
             | Unix.WSIGNALED n -> Printf.sprintf "signalled %d" n
             | Unix.WSTOPPED n -> Printf.sprintf "stopped %d" n)
            (output_for_log ~stdout ~stderr)))
;;

(* Nerdctl's volume store locks create and returns an existing named volume
   unchanged. Listing is unsuitable as proof of absence: upstream skips
   unreadable volume metadata while returning a successful list. Create then
   inspect avoids that ambiguity and never removes or replaces existing data.
   See containerd/nerdctl pkg/mountutil/volumestore/volumestore.go. *)
let ensure_nerdctl_work_volume ~volume_name ~size ~timeout_sec =
  let cli = command_argv_for Backend.Nerdctl_kata in
  let run suffix = Process_eio.run_argv_with_status_split ~timeout_sec (cli @ suffix) in
  let failure stage (status, stdout, stderr) =
    Error
      (Printf.sprintf "microvm_work_volume_%s_failed: %s (%s; %s)"
         stage volume_name
         (match status with
          | Unix.WEXITED code -> Printf.sprintf "exit %d" code
          | Unix.WSIGNALED n -> Printf.sprintf "signalled %d" n
          | Unix.WSTOPPED n -> Printf.sprintf "stopped %d" n)
         (output_for_log ~stdout ~stderr))
  in
  match run [ "volume"; "create"; volume_name ] with
  | Unix.WEXITED 0, _, _ ->
    (match run [ "volume"; "inspect"; volume_name ] with
     | Unix.WEXITED 0, stdout, _ ->
       let confirmed =
         match Yojson.Safe.from_string stdout with
         | exception Yojson.Json_error _ -> false
         | `List [ `Assoc fields ] ->
           let values key =
             List.filter_map
               (fun (name, value) -> if String.equal name key then Some value else None)
               fields
           in
           (match values "Name", values "Mountpoint" with
            | [ `String name ], [ `String mountpoint ] ->
              String.equal name volume_name
              && not (String.equal mountpoint "")
              && not (Filename.is_relative mountpoint)
            | _ -> false)
         | _ -> false
       in
       if confirmed then (
         Log.Keeper.warn
           "microvm work volume=%s backend=nerdctl_kata storage=managed_directory requested_size=%s capacity_enforced=false; host filesystem capacity applies"
           volume_name size;
         Ok `Ensured)
       else
         Error
           (Printf.sprintf
              "microvm_work_volume_probe_failed: nerdctl inspect did not confirm exactly one named volume with an absolute mountpoint: %s"
              volume_name)
     | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _, _) as outcome ->
       failure "probe" outcome)
  | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _, _) as outcome ->
    failure "create" outcome
;;

(** Apple takes a sized guest disk; msb and nerdctl use persistent managed
    directories. The latter do not claim Apple's capacity or flat host-FD
    behavior. All backends keep the working tree off the host playground. *)
let ensure_work_volume_for backend ~volume_name ~size ~timeout_sec =
  match (backend : Backend.t) with
  | Backend.Apple_container ->
    ensure_apple_volume Work_volume ~volume_name ~size ~timeout_sec
  | Backend.Microsandbox -> ensure_msb_work_volume ~volume_name ~timeout_sec
  | Backend.Nerdctl_kata -> ensure_nerdctl_work_volume ~volume_name ~size ~timeout_sec
;;

(* ── The build volume (RFC-keeper-build-output-returns-to-a-disposable-volume)
   Apple_container only: msb's named volume is a host directory ([--kind
   dir]), and nerdctl's managed volume is also a host directory with
   `capacity_enforced=false` (see ensure_msb_work_volume,
   ensure_nerdctl_work_volume above) -- deleting a file inside either
   already returns host disk immediately, no VM disk image between the
   guest and the host filesystem. Only Apple's volume is a sparse
   virtio-blk image (`volume.img`), and only Apple's image was measured
   (2026-09-24) to keep its allocated size after the guest deletes
   everything inside it -- `fstrim` inside the guest, run as root, answers
   "Operation not permitted", because the guest's capability set is empty
   (the disk itself accepts discard, measured 2026-09-26). Boot currently
   leaves the work volume's ext4 discard default unchanged while ownership
   is unverified; the build volume gets no such default, and what linked
   checkouts built on it is returned by deleting the volume and making a new
   one at every boot. *)

let build_volume_name ~keeper_name =
  if valid_volume_segment keeper_name
  then Ok ("masc-keeper-build-" ^ keeper_name)
  else Error ("unsupported keeper name for a build volume: " ^ keeper_name)
;;

let build_volume_mount_args ~volume_name =
  [ "--volume"; volume_name ^ ":" ^ build_volume_guest_root ]
;;

let apple_volume_delete_argv ~volume_name =
  command_argv_for Backend.Apple_container @ [ "volume"; "delete"; volume_name ]
;;

(* Both volume names are exact, but same-named Keepers in other workspaces
   may own the same volumes. The claims marker cannot prove that all owners
   are recorded, and this operation checks no workspace itself. Each delete
   is attempted whatever the other returned. A
   delete's exit code cannot prove absence: an already-absent volume and one
   a guest still holds can both exit non-zero. One listing after both deletes
   settles it, the same way the trim helper's removal is settled. *)
let remove_apple_keeper_volumes ~run ~timeout_sec ~keeper_name =
  match work_volume_name ~keeper_name, build_volume_name ~keeper_name with
  | Error detail, _ | _, Error detail -> Error detail
  | Ok work, Ok build ->
    let delete volume_name =
      volume_name, run ~timeout_sec (apple_volume_delete_argv ~volume_name)
    in
    let work_deletion = delete work in
    let build_deletion = delete build in
    let deletions = [ work_deletion; build_deletion ] in
    (match run ~timeout_sec (apple_volume_list_argv ()) with
     | Unix.WEXITED 0, listing, _ ->
       (match Yojson.Safe.from_string listing with
        | exception Yojson.Json_error detail ->
          Error ("keeper volume inventory is invalid JSON: " ^ detail)
        | json ->
          (match volume_names_of_json json with
           | Error _ as error -> error
           | Ok names ->
             (match
                List.filter
                  (fun (volume_name, _) -> List.exists (String.equal volume_name) names)
                  deletions
              with
              | [] -> Ok ()
              | remaining ->
                Error
                  (String.concat
                     "; "
                     (List.map
                        (fun (volume_name, (status, stdout, stderr)) ->
                           Printf.sprintf
                             "volume %s remains after removal (%s): %s"
                             volume_name
                             (Keeper_sandbox_exec_failure.status_label status)
                             (output_for_log ~stdout ~stderr))
                        remaining)))))
     | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), stdout, stderr ->
       Error
         (Printf.sprintf
            "cannot verify keeper %s's volumes %s and %s were removed (%s): %s"
            keeper_name
            work
            build
            (Keeper_sandbox_exec_failure.status_label status)
            (output_for_log ~stdout ~stderr)))
;;

(* ── The work volume claims marker ────────────────────────────────────
   Volume names carry the keeper name but not its workspace, so two
   workspaces running same-named keepers share one work volume and neither
   can tell whether the other still wants it. A claim is the base path of a
   workspace whose keeper boots onto the volume, recorded in a marker file
   at the volume root. The marker sits above the keeper's jailed work root
   and is written by root helpers only, so the guest's user can neither
   create nor delete it. *)

let volume_claims_marker_name = ".masc-volume-claims.json"
let claims_guest_root = "/masc-claims"
let volume_claimant_env_var = "MASC_VOLUME_CLAIMANT"

let volume_claim_helper_name ~keeper_name =
  Keeper_sandbox_container_name.make
    (Keeper_sandbox_container_name.Micro_vm_volume_claim { keeper_name })
  |> Keeper_sandbox_container_name.to_string
;;

(* A claimant travels in one [--env] argument and is written inside JSON
   string quotes by the helper scripts, which do no escaping of their own:
   a base path carrying a quote, a backslash or a control character is
   refused here rather than silently mangled. Everything else a real base
   path contains -- spaces, unicode, '$', '%' -- travels as data. *)
let valid_volume_claimant claimant =
  claimant <> ""
  && String.for_all
       (function
         | '"' | '\\' | '\x7f' -> false
         | c -> c >= ' ')
       claimant
;;

(* The marker is one JSON array, one claimant per line, so the scripts can
   match a whole element by quoting it and never drop a claim they read.
   The [add] script only inserts: it re-emits every element it recognized
   and ours. The [release] script filters ours out and regenerates; when
   ours was the last claim the marker file is removed instead. Both refuse
   a marker outside the complete line-oriented array they know how to write,
   and both land the new file with one [mv], which is atomic on the same
   filesystem. Reading is [cat] alone, so the host's strict decoder parses
   that response. The byte comparison requires [cmp]; if the image lacks it,
   an existing marker is refused without modification. *)
let volume_claim_validate_script =
  {sh|validate_claim_line() {
  case "$1" in
    '"'*'"') value=${1#\"}; value=${value%\"} ;;
    *) return 1 ;;
  esac
  case "$value" in
    ''|*'"'*|*\\*|*[[:cntrl:]]*) return 1 ;;
  esac
  return 0
}
validate_marker() {
  state=open
  while :; do
    line=
    if IFS= read -r line; then newline=1
    elif [ -n "$line" ]; then newline=0
    else break; fi
    case "$state" in
      open)
        [ "$line" = '[' ] || return 1
        state=first ;;
      first)
        if [ "$line" = ']' ]; then state=closed
        else validate_claim_line "$line" || return 1; state=next; fi ;;
      next)
        if [ "$line" = ']' ]; then state=closed
        else
          case "$line" in
            ,*) validate_claim_line "${line#,}" || return 1 ;;
            *) return 1 ;;
          esac
        fi ;;
      closed) return 1 ;;
    esac
    if [ "$newline" -eq 1 ]; then printf '%s\n' "$line"
    else printf '%s' "$line"; fi
  done < "$marker"
  [ "$state" = closed ]
}|sh}
;;

let volume_claim_add_script_with ~marker =
  Printf.sprintf
    {sh|set -eu
LC_ALL=C
export LC_ALL
marker=%s
%s
tmp=$marker.tmp
if ! command -v cmp >/dev/null 2>&1; then
  printf 'claims marker byte comparison is unavailable\n' >&2
  exit 1
fi
if [ -f "$marker" ]; then
  if ! validate_marker > "$tmp" || ! cmp -s "$marker" "$tmp"; then
    rm -f "$tmp"
    printf 'claims marker is not a complete supported array\n' >&2
    exit 1
  fi
  rm -f "$tmp"
fi
printf '[\n' > "$tmp"
first=1
present=0
if [ -f "$marker" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '['|']') ;;
      *)
        elem=${line#,}
        case "$elem" in
          '"'*'"')
            elem=${elem#\"}; elem=${elem%%\"}
            if [ "$elem" = "$MASC_VOLUME_CLAIMANT" ]; then present=1
            elif [ "$first" -eq 1 ]; then printf '"%%s"\n' "$elem" >> "$tmp"; first=0
            else printf ',"%%s"\n' "$elem" >> "$tmp"; fi ;;
          *) printf 'claims marker line is not a claimant\n' >&2; rm -f "$tmp"; exit 1 ;;
        esac ;;
    esac
  done < "$marker"
fi
if [ "$present" -eq 1 ]; then
  rm -f "$tmp"
  printf 'present\n'
  exit 0
fi
if [ "$first" -eq 1 ]; then printf '"%%s"\n' "$MASC_VOLUME_CLAIMANT" >> "$tmp"
else printf ',"%%s"\n' "$MASC_VOLUME_CLAIMANT" >> "$tmp"; fi
printf ']\n' >> "$tmp"
mv -f "$tmp" "$marker"
printf 'added\n'|sh}
    (Filename.quote marker) volume_claim_validate_script
;;

let volume_claim_release_script_with ~marker =
  Printf.sprintf
    {sh|set -eu
LC_ALL=C
export LC_ALL
marker=%s
%s
if [ ! -f "$marker" ]; then printf 'absent\n'; exit 0; fi
tmp=$marker.tmp
if ! validate_marker > "$tmp" || ! cmp -s "$marker" "$tmp"; then
  rm -f "$tmp"
  printf 'claims marker is not a complete supported array\n' >&2
  exit 1
fi
rm -f "$tmp"
printf '[\n' > "$tmp"
first=1
found=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    '['|']') ;;
    *)
      elem=${line#,}
      case "$elem" in
        '"'*'"')
          elem=${elem#\"}; elem=${elem%%\"}
          if [ "$elem" = "$MASC_VOLUME_CLAIMANT" ]; then found=1
          elif [ "$first" -eq 1 ]; then printf '"%%s"\n' "$elem" >> "$tmp"; first=0
          else printf ',"%%s"\n' "$elem" >> "$tmp"; fi ;;
        *) printf 'claims marker line is not a claimant\n' >&2; rm -f "$tmp"; exit 1 ;;
      esac ;;
  esac
done < "$marker"
if [ "$found" -eq 0 ]; then
  rm -f "$tmp"
  printf 'not-claimed\n'
  exit 0
fi
if [ "$first" -eq 1 ]; then
  rm -f "$marker" "$tmp"
  printf 'released-last\n'
  exit 0
fi
printf ']\n' >> "$tmp"
mv -f "$tmp" "$marker"
printf 'kept\n'
cat "$marker"|sh}
    (Filename.quote marker) volume_claim_validate_script
;;

let volume_claims_read_script_with ~marker =
  Printf.sprintf
    {sh|set -eu
marker=%s
if [ -f "$marker" ]; then cat "$marker"; fi|sh}
    (Filename.quote marker)
;;

let volume_claim_marker_guest_path =
  Filename.concat claims_guest_root volume_claims_marker_name
;;

let volume_claim_add_script = volume_claim_add_script_with ~marker:volume_claim_marker_guest_path
let volume_claim_release_script = volume_claim_release_script_with ~marker:volume_claim_marker_guest_path
let volume_claims_read_script = volume_claims_read_script_with ~marker:volume_claim_marker_guest_path

(* The claims helper shares the trim helper's shape -- one [container run
   --rm] of the keeper's own image, root, every capability dropped, no
   network, a read-only root -- but needs no capability at all: it only
   reads and writes files on the mounted volume. The helper name is
   keeper-scoped and shared across workspaces, so two workspaces claiming
   at once collide on the name and the second run fails; that failure, and
   a name observed present before this one starts, both leave the marker
   untouched and are reported rather than retried. *)
let apple_volume_claim_run_argv ?(env = []) ~keeper_name ~volume_name ~image script =
  command_argv_for Backend.Apple_container
  @ [ "run"; "--rm"; "--name"; volume_claim_helper_name ~keeper_name
    ; "--user"; "0"; "--cap-drop"; "ALL"
    ; "--network"; "none"; "--read-only"
    ; "--entrypoint"; "/bin/sh"
    ; "--volume"; volume_name ^ ":" ^ claims_guest_root
    ]
  @ List.concat_map (fun (key, value) -> [ "--env"; key ^ "=" ^ value ]) env
  @ [ image; "-eu"; "-c"; script ]
;;

let apple_volume_claims_read_argv ~keeper_name ~volume_name ~image =
  apple_volume_claim_run_argv ~keeper_name ~volume_name ~image volume_claims_read_script
;;

let apple_volume_claim_add_argv ~keeper_name ~volume_name ~image ~claimant =
  apple_volume_claim_run_argv
    ~env:[ volume_claimant_env_var, claimant ]
    ~keeper_name ~volume_name ~image volume_claim_add_script
;;

let apple_volume_claim_release_argv ~keeper_name ~volume_name ~image ~claimant =
  apple_volume_claim_run_argv
    ~env:[ volume_claimant_env_var, claimant ]
    ~keeper_name ~volume_name ~image volume_claim_release_script
;;

(* Strict decode of marker content. Empty output means no marker (the read
   helper prints nothing for an absent file); anything else must be a JSON
   array of valid claimants, or it is invalid -- never a default. *)
type volume_claims_read =
  | Marker_absent
  | Claims_read of string list
  | Claims_invalid of string

let volume_claims_of_output output =
  let trimmed = String.trim output in
  if String.equal trimmed ""
  then Marker_absent
  else
    match Yojson.Safe.from_string trimmed with
    | exception Yojson.Json_error detail -> Claims_invalid ("invalid JSON: " ^ detail)
    | `List elements ->
      let rec claimants_of elements acc =
        match elements with
        | [] -> Ok (List.rev acc)
        | `String claimant :: rest when valid_volume_claimant claimant ->
          claimants_of rest (claimant :: acc)
        | `String claimant :: _ ->
          Error (Printf.sprintf "claimant %S is not a valid base-path claim" claimant)
        | _ :: _ -> Error "a claims element is not a string"
      in
      (match claimants_of elements [] with
       | Ok claimants -> Claims_read claimants
       | Error detail -> Claims_invalid detail)
    | _ -> Claims_invalid "the claims marker is not a JSON array"
;;

(* The release helper's stdout protocol: one outcome word, and for [kept]
   the marker content that remains. Pure, so the mapping is testable
   without a container runtime. *)
type apple_volume_claim_helper_report =
  | Claims_marker_absent
  | Claimant_not_present
  | Released_last_claim
  | Kept_with_claimants of string list
  | Report_unrecognized of string

let volume_claim_helper_report_of_output output =
  match output with
  | "absent\n" -> Claims_marker_absent
  | "not-claimed\n" -> Claimant_not_present
  | "released-last\n" -> Released_last_claim
  | _ ->
    (match String.index_opt output '\n' with
     | None -> Report_unrecognized (String.trim output)
     | Some index ->
       let first = String.sub output 0 index in
       let rest = String.sub output (index + 1) (String.length output - index - 1) in
       match first with
       | "kept" ->
         (match volume_claims_of_output rest with
          | Claims_read claimants -> Kept_with_claimants claimants
          | Marker_absent | Claims_invalid _ ->
            Report_unrecognized "kept without a readable claims array")
       | other -> Report_unrecognized other)
;;

(* One container listing answers every presence question here. The strict
   inventory decoder rejects malformed rows wholesale, and unlabelled rows
   never prove a keeper's absence. *)
let apple_claims_inventory ~run ~timeout_sec =
  match run ~timeout_sec (apple_container_list_argv ()) with
  | Unix.WEXITED 0, stdout, _ ->
    (match Keeper_microvm_inventory_json.of_apple_json stdout with
     | Ok inventory -> Ok inventory
     | Error error ->
       Error
         ("microvm_volume_claims_inventory_invalid: "
          ^ Keeper_microvm_inventory_json.invalid_inventory_message error))
  | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), _, _ ->
    Error
      ("microvm_volume_claims_inventory_failed: container list "
       ^ Keeper_sandbox_exec_failure.status_label status)
;;

let apple_claims_helper_absent ~run ~timeout_sec ~keeper_name =
  let helper_name = volume_claim_helper_name ~keeper_name in
  match apple_claims_inventory ~run ~timeout_sec with
  | Error _ as error -> error
  | Ok inventory ->
    (match Keeper_microvm_inventory_json.presence ~guest_name:helper_name inventory with
     | Ok Keeper_microvm_inventory_json.Absent -> Ok ()
     | Ok Keeper_microvm_inventory_json.Present ->
       Error
         (Printf.sprintf
            "microvm_volume_claim_helper_present: claims helper %s is present; its \
             workspace owner is unknown, so this claim is not written"
            helper_name)
     | Error Keeper_microvm_inventory_json.Invalid_guest_name ->
       Error ("microvm_volume_claim_helper_unnamed: " ^ helper_name))
;;

(* Every observed container that references this keeper: guests carry the
   keeper's scoping label, and the three volume helpers carry its name. Any
   one of them present means a workspace may hold the volume right now --
   a live guest mounting it, or a helper mid-operation -- so a release
   refuses rather than race it. Unlabelled foreign rows prove nothing and
   are not treated as owners. *)
let apple_keeper_owner_containers ~run ~timeout_sec ~keeper_name =
  match apple_claims_inventory ~run ~timeout_sec with
  | Error _ as error -> error
  | Ok inventory ->
    let module Inventory = Keeper_microvm_inventory_json in
    let guests =
      List.filter_map
        (fun (row : Inventory.row) ->
           match row.scoping_labels with
           | Some labels when String.equal labels.keeper keeper_name -> Some row.name
           | Some _ | None -> None)
        (Inventory.rows inventory)
    in
    let helpers =
      List.filter_map
        (fun name ->
           match Inventory.presence ~guest_name:name inventory with
           | Ok Inventory.Present -> Some name
           | Ok Inventory.Absent | Error Inventory.Invalid_guest_name -> None)
        [ work_volume_trim_name ~keeper_name
        ; volume_repair_name ~keeper_name
        ; volume_claim_helper_name ~keeper_name
        ]
    in
    Ok (guests @ helpers)
;;

(* Record one workspace's claim, idempotently. Fresh Apple provisioning stops
   on an error. This does not establish that legacy or adopted users of an
   existing shared volume were recorded. *)
let add_apple_work_volume_claim ~run ~timeout_sec ~keeper_name ~volume_name ~image ~claimant
  : (unit, string) result
  =
  if not (valid_volume_claimant claimant)
  then
    Error
      (Printf.sprintf
         "microvm_volume_claimant_invalid: base path %S cannot be recorded as a claim"
         claimant)
  else
    match apple_claims_helper_absent ~run ~timeout_sec ~keeper_name with
    | Error _ as error -> error
    | Ok () ->
      let status, stdout, stderr =
        run ~timeout_sec (apple_volume_claim_add_argv ~keeper_name ~volume_name ~image ~claimant)
      in
      match status, stdout with
      | Unix.WEXITED 0, ("added\n" | "present\n") -> Ok ()
      | Unix.WEXITED 0, _ ->
        Error
          (Printf.sprintf
             "microvm_volume_claim_helper_unrecognized: %s returned %S"
             (volume_claim_helper_name ~keeper_name)
             (output_for_log ~stdout ~stderr))
      | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), _ ->
        Error
          (Printf.sprintf
             "microvm_volume_claim_helper_failed: %s (%s; %s)"
             (volume_claim_helper_name ~keeper_name)
             (Keeper_sandbox_exec_failure.status_label status)
             (output_for_log ~stdout ~stderr))
;;

type apple_volume_claim_release =
  | Kept_for_claimants of string list
  | Kept_for_containers of string list
  | Skipped_unverified of string

(* Release one workspace's claim and always keep the volumes. The last
   recorded claim plus an empty owner listing cannot prove exclusive
   ownership: a legacy, adopted, or paused-unrecorded owner in another
   workspace is absent from both the marker and the container listing, and
   no host-side enumeration can complete the owner set, so deletion on
   those signals could destroy another keeper's resume data. A concurrent
   boot between the listing and a deletion is likewise unfenced. This call
   therefore never deletes; it only releases the caller's claim. The
   release helper runs even when owner containers are present or the owner
   listing fails. A dissolved workspace should release its claim:
   dissolution is one-shot, and a workspace that never comes back would
   keep the marker naming it forever. A helper failure does not prove that
   the release took effect. One helper reads the marker, filters our claim
   out and rewrites it: the read and the write are one container, so no
   other helper can land a claim between them. When ours was the last
   recorded claim the helper removes the marker; the volumes stay, and the
   outcome reports the observation. *)
let release_apple_work_volume_claim ~run ~timeout_sec ~keeper_name ~volume_name ~image ~claimant
  : apple_volume_claim_release
  =
  let skipped detail = Skipped_unverified detail in
  if not (valid_volume_claimant claimant)
  then
    skipped
      (Printf.sprintf
         "microvm_volume_claimant_invalid: base path %S cannot be matched against claims"
         claimant)
  else
    let status, stdout, stderr =
      run ~timeout_sec
        (apple_volume_claim_release_argv ~keeper_name ~volume_name ~image ~claimant)
    in
    let report = volume_claim_helper_report_of_output stdout in
    match apple_keeper_owner_containers ~run ~timeout_sec ~keeper_name with
    | Error listing_detail ->
      let unverified detail =
        skipped
          (Printf.sprintf
             "microvm_volume_release_owner_unverified: the owner listing failed (%s); %s"
             listing_detail detail)
      in
      (match (status, report) with
       | Unix.WEXITED 0, Claims_marker_absent ->
         unverified "no claims marker, so no claim of this workspace remained anyway"
       | Unix.WEXITED 0, Claimant_not_present ->
         unverified
           (Printf.sprintf
              "%s held no recorded claim on the volume"
              claimant)
       | Unix.WEXITED 0, Kept_with_claimants claimants ->
         unverified
           (Printf.sprintf
              "this workspace's claim was released; %d other claimant(s) remain: %s"
              (List.length claimants)
              (String.concat ", " claimants))
       | Unix.WEXITED 0, Released_last_claim ->
         unverified
           "this workspace's claim was the last one and the marker was removed; the \
            volumes are kept because no owner evidence could be read"
       | Unix.WEXITED 0, Report_unrecognized word ->
         unverified
           (Printf.sprintf
              "the claims helper reported %S, so the claim's release is unconfirmed (%s)"
              word
              (output_for_log ~stdout ~stderr))
       | ( ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as failure_status)
         , ( Claims_marker_absent
           | Claimant_not_present
           | Released_last_claim
           | Kept_with_claimants _
           | Report_unrecognized _ ) ) ->
         unverified
           (Printf.sprintf
              "the claims helper failed (%s; %s), so the claim's release is unconfirmed"
              (Keeper_sandbox_exec_failure.status_label failure_status)
              (output_for_log ~stdout ~stderr)))
    | Ok owners ->
      (match (status, report) with
       | Unix.WEXITED 0, Claims_marker_absent ->
         skipped
           "microvm_volume_claims_absent: legacy volume without a claims marker; ownership \
            is not provable"
       | Unix.WEXITED 0, Claimant_not_present ->
         skipped
           (Printf.sprintf
              "microvm_volume_claims_not_claimed: %s holds no recorded claim on %s"
              claimant volume_name)
       | Unix.WEXITED 0, Kept_with_claimants claimants -> Kept_for_claimants claimants
       | Unix.WEXITED 0, Released_last_claim ->
         (match owners with
          | [] ->
            skipped
              "microvm_volume_ownership_unprovable: the last recorded claim was \
               released and no owner container was observed, but a legacy, \
               adopted, or paused-unrecorded owner in another workspace cannot \
               be excluded and a concurrent boot is not fenced; the work and \
               build volumes are kept"
          | _ :: _ -> Kept_for_containers owners)
       | Unix.WEXITED 0, Report_unrecognized word ->
         skipped
           (Printf.sprintf
              "microvm_volume_claims_unrecognized: claims helper %s reported %S (%s)"
              (volume_claim_helper_name ~keeper_name)
              word
              (output_for_log ~stdout ~stderr))
       | ( ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status)
         , ( Claims_marker_absent
           | Claimant_not_present
           | Released_last_claim
           | Kept_with_claimants _
           | Report_unrecognized _ ) ) ->
         skipped
           (Printf.sprintf
              "microvm_volume_claim_helper_failed: %s (%s; %s)"
              (volume_claim_helper_name ~keeper_name)
              (Keeper_sandbox_exec_failure.status_label status)
              (output_for_log ~stdout ~stderr)))
;;

(** Recreate the build volume fresh on every boot rather than reusing one
    across a guest's restarts: [_build] is entirely derived, so starting
    empty costs one cold build and reclaims whatever host disk the previous
    life's volume had grown to, since a keeper guest cannot discard its own
    blocks (its capability set is empty), and `container volume` has no attach/detach to
    swap it mid-session (checked: `create, delete/rm, list/ls, inspect,
    prune` only). A probe failure refuses the boot rather than guess --
    deleting on an ambiguous answer risks a volume this call did not create
    the record for. *)
let recreate_apple_build_volume ~volume_name ~size ~timeout_sec =
  let error_code = apple_volume_error_code Build_volume in
  match apple_volume_probe ~volume_name ~timeout_sec with
  | Volume_probe_failed message ->
    Error (Printf.sprintf "%s_probe_failed: %s" error_code message)
  | Volume_absent -> ensure_apple_volume Build_volume ~volume_name ~size ~timeout_sec
  | Volume_present ->
    let argv = apple_volume_delete_argv ~volume_name in
    (match Process_eio.run_argv_with_status_split ~timeout_sec argv with
     | Unix.WEXITED 0, _, _ ->
       ensure_apple_volume Build_volume ~volume_name ~size ~timeout_sec
     | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), stdout, stderr ->
       Error
         (Printf.sprintf
            "%s_delete_failed: %s (%s; %s)"
            error_code
            volume_name
            (match status with
             | Unix.WEXITED code -> Printf.sprintf "exit %d" code
             | Unix.WSIGNALED n -> Printf.sprintf "signalled %d" n
             | Unix.WSTOPPED n -> Printf.sprintf "stopped %d" n)
            (output_for_log ~stdout ~stderr)))
;;

(* ── Finding checkouts and their _build state inside the guest ────────
   A Micro_vm keeper's tree is on its own ext4 work volume:
   Keeper_types_profile_sandbox.tree_location_of_profile answers
   [Endpoint_owned] for it, and that type's doc comment says why a host op
   does not reach it -- "the host keeps only a bookkeeping bundle... a
   host-side file operation on the bundle would silently miss the tree."
   So the walk, the [_build] state read, and the symlink itself all run
   inside the guest over [container exec]; only the *decision*
   ({!plan_build_link}) stays host-side and pure. The checkouts it walks are
   the ones {!first_handoff_build_cleanup_script} walks at boot. *)

(** One [find], run in the keeper's work root. Paths travel as [find -exec]
    arguments, never newline-delimited input. Each checkout emits three
    NUL-terminated fields: path, state and link target (empty for other
    states). [find] without [-L] does not descend through symlinks; [_build]
    and [.git] are pruned rather than descended. *)
let build_scan_script =
  Printf.sprintf
    {sh|find . -maxdepth %d \( -name %s -o -name .git \) -prune -o -type d -exec sh -c '
for d do
  [ -e "$d/%s" ] || continue
  rel=${d#./}
  [ "$rel" = "." ] && continue
  b="$d/%s"
  if [ -L "$b" ]; then
    printf "%%s\000symlink\000" "$rel"
    readlink -n -- "$b" || exit 1
    printf "\000"
  elif [ -e "$b" ]; then
    printf "%%s\000real\000\000" "$rel"
  else
    printf "%%s\000absent\000\000" "$rel"
  fi
done
' sh {} +
|sh}
    build_root_scan_depth
    build_output_dir_name
    build_root_marker
    build_output_dir_name
;;

let build_scan_argv_for backend ~container_name ~keeper_work_root ~uid ~gid =
  exec_argv_for
    backend
    ~container_name
    ~uid
    ~gid
    ~container_cwd:keeper_work_root
    ~stdin:false
    ~command_argv:[ "sh"; "-c"; build_scan_script ]
;;

(** Scan reports an existing non-symlink entry as [real] without determining
    its file type. The first-handoff helper removes only real directories. *)
let build_link_warning plan =
  let real_entry_risk =
    Printf.sprintf
      "If the entry is a real directory, a later first owned handoff, including after a server restart, can stage and delete it. A %s marker that resolves as present in the checkout prevents that staging; see Keeper User Manual: Inspecting _build entries."
      build_keep_marker
  in
  match plan with
  | Link_refused_real_directory ->
    Some ("A checkout has a non-symlink _build entry; its build link was not changed. " ^ real_entry_risk)
  | Link_refused_invalid_path { state = Build_real_directory; _ } ->
    Some ("A checkout path cannot be represented as a build link; its non-symlink _build entry was not changed. " ^ real_entry_risk)
  | Link_refused_invalid_path { state = (Build_absent | Build_symlink _); _ } ->
    Some "A checkout path cannot be represented as a build link; it was not changed."
  | Link_preserve_symlink _ ->
    Some "A checkout's _build link points elsewhere and was left unchanged; if its target is missing, builds can fail. Inspect guest links and verify ownership before repair; see the Keeper User Manual's Apple MicroVM section."
  | Link_already_correct | Link_create _ -> None
;;

(** Input paths are guest argv values after the helper name and their count.
    They are not sent on stdin: each [container exec -i] leaves one pipe end
    open in the VM runtime (RFC microvm-guest-agent-over-socket sections 3.7
    and 4.1), and the paths are not secret. The guest checks the count and
    that no field is empty before any effect. Python isolated mode excludes
    the guest cwd and user Python paths; site initialization is also
    disabled. An image without a working supported interpreter cannot prepare
    build links. This does not fence checkout parent paths. *)
let checked_build_argv_script consumer =
  {py|import os, sys
count = int(sys.argv[2])
fields = [os.fsencode(field) for field in sys.argv[3:]]
if len(fields) != count or any(not field for field in fields):
    sys.exit(1)
|py} ^ consumer ^ "\n"
;;

let build_link_apply_script =
  checked_build_argv_script
    {py|if len(fields) % 2:
    sys.exit(1)
failed = False
for checkout, target in zip(fields[::2], fields[1::2]):
    try:
        os.symlink(target, checkout + b'/_build')
    except OSError:
        failed = True
sys.exit(1 if failed else 0)|py}
;;

let build_input_interpreter =
  {sh|if [ -x /usr/bin/python3 ]; then
  exec /usr/bin/python3 -I -S -c "$@"
fi
if [ -x /usr/local/bin/python3 ]; then
  exec /usr/local/bin/python3 -I -S -c "$@"
fi
exit 127|sh}
;;

let build_argv_command script name fields =
  [ "/bin/sh"; "-c"; build_input_interpreter; "masc-build-helper";
    script; name; string_of_int (List.length fields) ] @ fields
;;

(* 128 KiB. Nothing bounds how many checkouts a scan finds, so the paths are
   split across requests. macOS counts argv and the environment together
   against ARG_MAX (1 MiB, [getconf ARG_MAX]); a Linux guest counts them
   against a quarter of its stack limit (2 MiB at the default 8 MiB) and each
   string against MAX_ARG_STRLEN (128 KiB). The exec flags, the helper script
   and the server's environment fit in what this leaves. *)
let build_argv_values_budget_bytes = 128 * 1024

(* What execve counts for [values]: each string and its terminating NUL. *)
let argv_bytes values = List.fold_left (fun total value -> total + String.length value + 1) 0 values

(* [items] in order, in groups whose [values] fit the budget. A group holds at
   least one item, so an item over the budget is a request of its own, which
   the exec then refuses as a failed effect. *)
let build_argv_batches ~values items =
  let close current batches =
    match current with
    | [] -> batches
    | _ :: _ -> List.rev current :: batches
  in
  let rec group batches current size = function
    | [] -> List.rev (close current batches)
    | item :: rest ->
      let bytes = argv_bytes (values item) in
      (match current with
       | _ :: _ when size + bytes > build_argv_values_budget_bytes ->
         group (close current batches) [ item ] bytes rest
       | [] | _ :: _ -> group batches (item :: current) (size + bytes) rest)
  in
  group [] [] 0 items
;;

let pair_values (checkout, target) = [ checkout; target ]

let build_link_apply_requests_for backend ~container_name ~keeper_work_root ~uid ~gid ~actions =
  List.map
    (fun batch ->
      exec_argv_for backend ~container_name ~uid ~gid ~container_cwd:keeper_work_root
        ~stdin:false
        ~command_argv:
          (build_argv_command build_link_apply_script "masc-build-link" (List.concat_map pair_values batch)))
    (build_argv_batches ~values:pair_values actions)
;;

(** Create the link targets inside the guest.

    Measured, and the reason this step exists: dune does not create the
    directory a [_build] symlink points at. It lstats [_build], sees something
    there, and opens [_build/.lock] straight away --

    {v Error: open(_build/.lock): No such file or directory v}

    The host cannot create it either, because it lives inside the volume's
    ext4 image. The volume root is initially owned by root, so creation runs
    as root with an explicit writable mode. The mode applies only to newly created
    directories: existing keeper-owned targets remain untouched, which matters
    because Apple Container's user namespace refuses even guest root changing
    their mode. Each request is idempotent. *)
let build_target_dir_mode = "0777"

let build_target_mkdir_requests ~container_name ~targets =
  let script = checked_build_argv_script
      (Printf.sprintf {py|os.umask(0)
failed = False
for target in fields:
    try:
        os.makedirs(target, mode=0o%s, exist_ok=True)
    except OSError:
        failed = True
sys.exit(1 if failed else 0)|py} build_target_dir_mode) in
  List.map
    (fun batch ->
      exec_argv_for
        Backend.Apple_container
        ~container_name
        ~uid:0
        ~gid:0
        ~container_cwd:build_volume_guest_root
        ~stdin:false
        ~command_argv:(build_argv_command script "masc-build-mkdir" batch))
    (build_argv_batches ~values:(fun target -> [ target ]) targets)
;;

(** The keeper's root on the work volume, created inside the guest.

    The host does not access it directly; all backends provision through guest exec. The
    volume root is initially owned by root, and Apple Container's user
    namespace refuses even guest root changing a mode afterwards, so the
    directory is made as root with the mode it will keep. [-m] applies only
    to a newly created directory; an existing keeper-owned root is untouched.
    Idempotent. *)
let work_root_dir_mode = "0777"

(* nerdctl creates the volume data directory with mode 0700 (v2.3.5:
   pkg/mountutil/volumestore/volumestore.go and pkg/store/filestore.go).
   The keeper's writable child is unreachable without search permission on
   that root. Change only search bits, inside the mounted guest; do not grant
   write/list access or alter existing child permissions. *)
let work_volume_search_argv_for backend ~container_name =
  match (backend : Backend.t) with
  | Backend.Apple_container | Backend.Microsandbox -> None
  | Backend.Nerdctl_kata ->
    Some
      (exec_argv_for backend ~container_name ~uid:0 ~gid:0
         ~container_cwd:work_volume_guest_root ~stdin:false
         ~command_argv:[ "chmod"; "a+x"; work_volume_guest_root ])
;;

let keeper_work_root_mkdir_argv_for backend ~container_name ~keeper_name =
  exec_argv_for
    backend
    ~container_name
    ~uid:0
    ~gid:0
    ~container_cwd:work_volume_guest_root
    ~stdin:false
    ~command_argv:
      [ "mkdir"; "-p"; "-m"; work_root_dir_mode; keeper_work_root ~keeper_name ]
;;

(** Boot invariant (RFC-0052): {!work_volume_guest_root} must be a real
    mountpoint inside the guest, not a directory on the guest rootfs.

    The check exists because the two probes below cannot tell the difference:
    [mkdir -p] and a write both succeed against a writable rootfs directory,
    so a guest whose volume mount is absent at boot would pass them and then
    serve an ephemeral tree -- every keeper write evaporating on the next
    boot, with the delivery log still saying "delivered" (2026-09-04: an
    analyst guest served a turn off a stale rootfs tree). [/proc/mounts] is
    the kernel's own answer and the pattern names the mountpoint field with
    its surrounding spaces, so a prefix like [/masc-work-stale] cannot match.
    [-F] makes the match a fixed string structurally rather than by the
    pattern happening to carry no regex metacharacters. [grep] over
    [/proc/mounts] rather than [mountpoint(1)]: the image
    (sandbox-images/ocaml/Dockerfile, ubuntu-24.04) ships grep as essential and
    util-linux's mountpoint is not in the apt list. Runs as root from [/] so
    the answer does not depend on the keeper's uid or a workdir that is the
    very thing under test. The guest writes an explicit result for both grep
    outcomes: a failed container exec alone cannot prove that grep ran. *)
let work_volume_mounted_probe_script =
  "grep -qF -- \"$1\" \"$2\"; result=$?; \
   case \"$result\" in \
   0) printf 'mounted\\n' ;; \
   1) printf 'not_mounted\\n' ;; \
   *) exit \"$result\" ;; esac"
;;

let work_volume_mounted_probe_argv_for backend ~container_name =
  exec_argv_for
    backend
    ~container_name
    ~uid:0
    ~gid:0
    ~container_cwd:"/"
    ~stdin:false
    ~command_argv:
      [ "sh"; "-c"; work_volume_mounted_probe_script; "masc-mount-probe"
      ; Printf.sprintf " %s " work_volume_guest_root; "/proc/mounts" ]
;;

type work_volume_mount_probe =
  | Work_volume_mounted
  | Work_volume_not_mounted
  | Work_volume_probe_unverified of
      { status : Unix.process_status
      ; stdout : string
      ; stderr : string
      }

let work_volume_mount_probe_of_result ~status ~stdout ~stderr =
  let unverified () = Work_volume_probe_unverified { status; stdout; stderr } in
  match status with
  | Unix.WEXITED 0 ->
    (match stdout with
     | "mounted\n" -> Work_volume_mounted
     | "not_mounted\n" -> Work_volume_not_mounted
     | _ -> unverified ())
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> unverified ()
;;

(** The write that follows the mkdir, as the uid the keeper's commands run
    under. The mkdir proves the root exists; only a write as that uid proves
    the keeper can use it. The tree below the root can carry any ownership
    -- one imported from elsewhere under another uid reads identically to
    [ls] and refuses every write (2026-09-02: trees copied as 501 into a
    guest the server enters as 502) -- so the refusal names the owner and
    mode of the root, which is what has to change. *)
let keeper_work_root_write_probe_script =
  "d=\"$1\"; t=$(mktemp \"$d/.masc-probe.XXXXXX\") && unlink \"$t\" || { stat -c \
   \"owner=%u:%g mode=%a %n\" \"$d\" >&2; exit 1; }"
;;

let keeper_work_root_write_probe_argv_for backend ~container_name ~uid ~gid ~keeper_name =
  exec_argv_for
    backend
    ~container_name
    ~uid
    ~gid
    ~container_cwd:work_volume_guest_root
    ~stdin:false
    ~command_argv:
      [ "sh"; "-c"; keeper_work_root_write_probe_script; "masc-probe"
      ; keeper_work_root ~keeper_name ]
;;

(** Label value distinguishing a keeper-lifetime guest from turn
    containers. The guest outlives turns, so it carries no turn id. *)
let keeper_vm_container_kind = "keeper-vm"

(** [container inspect] answers JSON; state lives at [.[0].status.state]
    ("running" observed live). A non-zero exit is not parsed here: a missing
    container and a runtime that could not look both exit 1, and
    {!classify_guest_probe_for} settles which from the listing. *)
(* Two runtimes, two shapes, measured 2026-09-03:

     container inspect      [ { "status": { "state": "running" } } ]
     msb inspect --format json
                            { "name": ..., "status": "Running" }

   A list against an object, a nested state against a flat one, lowercase
   against capitalised. Neither parser is written to tolerate the other's
   shape: a shape this code does not know is [Error], never [Ok false]. Read
   as "not running", an unrecognised answer would take a live guest down and
   boot a second one beside it. *)
let running_of_microsandbox_inspect_json raw =
  match Yojson.Safe.from_string raw with
  | `Assoc fields ->
    (match List.assoc_opt "status" fields with
     | Some (`String status) ->
       Ok (String.equal (String.lowercase_ascii status) "running")
     | Some _ | None -> Error "msb inspect: status missing")
  | _ -> Error "msb inspect: unparseable JSON"
  | exception Yojson.Json_error _ -> Error "msb inspect: unparseable JSON"
;;

(* [nerdctl inspect --format "{{json .State.Running}}"] answers the bare
   literal, the same template masc already sends Docker. Anything else is an
   [Error]: a template that stopped resolving prints an empty line, and read
   as "not running" that takes a live guest down. *)
let running_of_nerdctl_state_json raw =
  match String.trim raw with
  | "true" -> Ok true
  | "false" -> Ok false
  | other ->
    Error
      (Printf.sprintf
         "nerdctl inspect: expected the State.Running literal, got %S"
         other)
;;

let running_of_apple_inspect_json raw =
  let open Result.Syntax in
  let fields name = function
    | `Assoc fields ->
      let keys = List.map fst fields in
      if List.length keys = List.length (List.sort_uniq String.compare keys)
      then Ok fields
      else Error ("container inspect: duplicate " ^ name ^ " key")
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error ("container inspect: invalid " ^ name)
  in
  match Yojson.Safe.from_string raw with
  | `List [row] ->
    let* row = fields "row" row in
    (match List.assoc_opt "status" row with
     | Some status ->
       let* status = fields "status" status in
       (match List.assoc_opt "state" status with
        | Some (`String "running") -> Ok true
        | Some (`String "stopped") -> Ok false
        | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _)
        | None -> Error "container inspect: unknown or missing status.state")
     | None -> Error "container inspect: status missing")
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _
  | `List [] | `List (_ :: _ :: _) -> Error "container inspect: expected exactly one row"
  | exception Yojson.Json_error _ -> Error "container inspect: unparseable JSON"
;;

(* Apple inspect configuration. Unknown metadata is left alone; every
   identity/isolation field below is mandatory and duplicate-free.
   [publishedSockets] and [useInit] were read from 1.6.1, which reports both
   for every guest (docs/evidence/2026-11-03-microvm-request-transport). *)
let apple_guest_facts ~container_name raw =
  let module Plan = Keeper_microvm_boot_plan in
  let open Result.Syntax in
  let ( >>= ) = Result.bind in
  let invalid field = Error ("container inspect: invalid or missing " ^ field) in
  let object_fields field = function
    | `Assoc fields ->
      let keys = List.map fst fields in
      if List.length keys = List.length (List.sort_uniq String.compare keys)
      then Ok fields else invalid (field ^ " (duplicate keys)")
    | _ -> invalid field in
  let member field fields = match List.assoc_opt field fields with
    | Some value -> Ok value | None -> invalid field in
  let string field = function `String value -> Ok value | _ -> invalid field in
  let boolean field = function `Bool value -> Ok value | _ -> invalid field in
  let list field parse = function
    | `List values ->
      let* reversed = List.fold_left (fun result value ->
        let* values = result in let* value = parse value in Ok (value :: values))
        (Ok []) values in
      Ok (List.rev reversed)
    | _ -> invalid field in
  let positive_integer field value =
    let parsed = match value with
      | `Int value -> Some (Int64.of_int value)
      | `Intlit value -> Int64.of_string_opt value
      | _ -> None in
    match parsed with Some value when value > 0L -> Ok value | Some _ | None -> invalid field in
  let string_member field fields = member field fields >>= string field in
  let strings_member field fields = member field fields >>= list field (string field) in
  let object_member field fields = member field fields >>= object_fields field in
  let string_pairs field fields =
    let* fields = object_fields field fields in
    List.fold_left (fun result (key, value) ->
      let* pairs = result in let* value = string field value in Ok ((key, value) :: pairs))
      (Ok []) fields in
  let environment value =
    let* entries = list "environment" (string "environment") value in
    let* pairs = List.fold_left (fun result entry ->
      let* pairs = result in
      match String.index_opt entry '=' with
      | None -> invalid "environment entry"
      | Some index ->
        let key = String.sub entry 0 index in
        if key = "" || List.mem_assoc key pairs then invalid "environment name"
        else Ok ((key, String.sub entry (index + 1) (String.length entry - index - 1)) :: pairs))
      (Ok []) entries in
    Ok (List.rev pairs) in
  let mount value =
    let* fields = object_fields "mount" value in
    let* destination = string_member "destination" fields in
    let* source = string_member "source" fields in
    let* options = strings_member "options" fields in
    let* kind = object_member "type" fields in
    match kind with
    | ["tmpfs", `Assoc []] ->
      if options = [] then Ok (Plan.Tmpfs {destination}) else invalid "tmpfs options"
    | ["virtiofs", `Assoc []] ->
      if options = [] || options = ["ro"] then
        Ok (Plan.Host_dir {source; destination; read_only = options = ["ro"]})
      else invalid "virtiofs options"
    | ["volume", detail] ->
      let* detail = object_fields "volume" detail in
      let* name = string_member "name" detail in
      if options = [] then Ok (Plan.Named_volume {name; destination})
      else invalid "volume options"
    | _ -> invalid "mount type" in
  let decode json =
    let* row = match json with `List [row] -> object_fields "row" row | _ -> invalid "row count" in
    let* id = string_member "id" row in
    let* config = object_member "configuration" row in
    let* configured_id = string_member "id" config in
    let* () = if id = container_name && configured_id = container_name then Ok () else invalid "guest identity" in
    let* image_fields = object_member "image" config in
    let* image = string_member "reference" image_fields in
    let* descriptor_digest = object_member "descriptor" image_fields >>= string_member "digest" in
    let* platform = object_member "platform" config in
    let* architecture = string_member "architecture" platform in
    let* os = string_member "os" platform in
    let* variant = match List.assoc_opt "variant" platform with
      | None | Some `Null -> Ok None
      | Some value -> Result.map Option.some (string "platform variant" value) in
    let* () = if descriptor_digest = "" || architecture = "" || os = "" || variant = Some ""
      then invalid "image identity" else Ok () in
    let image_identity : Keeper_microvm_image_command.identity =
      {descriptor_digest; platform={architecture; os; variant}} in
    let* resources = object_member "resources" config in
    let* cpus = member "cpus" resources >>= positive_integer "cpus" in
    let* cpus = if cpus <= Int64.of_int max_int then Ok (Int64.to_int cpus) else invalid "cpus" in
    let* memory_bytes = member "memoryInBytes" resources >>= positive_integer "memoryInBytes" in
    let* init = object_member "initProcess" config in
    let* user = object_member "user" init >>= object_member "raw" >>= string_member "userString" in
    let* working_directory = string_member "workingDirectory" init in
    let* executable = string_member "executable" init in
    let* arguments = strings_member "arguments" init in
    let* mounts = member "mounts" config >>= list "mounts" mount in
    let destinations = List.map (function
      | Plan.Tmpfs {destination} | Plan.Host_dir {destination; _}
      | Plan.Named_volume {destination; _} -> destination) mounts in
    let* () = if List.length destinations = List.length (List.sort_uniq String.compare destinations)
      then Ok () else invalid "duplicate mount destination" in
    let* read_only = member "readOnly" config >>= boolean "readOnly" in
    let* cap_drop = strings_member "capDrop" config in
    let* cap_add = strings_member "capAdd" config in
    let* published_sockets = member "publishedSockets" config >>= list "publishedSockets" (fun value ->
      let* fields = object_fields "published socket" value in
      let* host_path = string_member "hostPath" fields in
      let* guest_path = string_member "containerPath" fields in
      Ok {Plan.host_path; guest_path}) in
    let* use_init = member "useInit" config >>= boolean "useInit" in
    let* networks = member "networks" config >>= list "networks" (fun value ->
      object_fields "network" value >>= string_member "network") in
    let* environment = member "environment" init >>= environment in
    let* labels = member "labels" config >>= string_pairs "labels" in
    Ok {Plan.plan_label = List.assoc_opt Plan.label_key labels; image; image_identity; cpus; memory_bytes;
        user; working_directory; command = executable :: arguments; mounts;
        read_only; cap_drop; cap_add; published_sockets; use_init; networks; environment; labels}
  in
  match Yojson.Safe.from_string raw with
  | json -> (match decode json with Ok facts -> Plan.Facts facts | Error detail -> Plan.Unreadable detail)
  | exception Yojson.Json_error _ -> Plan.Unreadable "container inspect: unparseable JSON"
;;

let running_of_inspect_json_for backend raw =
  match (backend : Backend.t) with
  | Backend.Apple_container -> running_of_apple_inspect_json raw
  | Backend.Microsandbox -> running_of_microsandbox_inspect_json raw
  | Backend.Nerdctl_kata -> running_of_nerdctl_state_json raw
;;

(* [container inspect] answers JSON by default; [msb inspect] answers a
   human table unless asked, so the machine form is requested explicitly. *)
let inspect_argv_for backend ~container_name =
  match (backend : Backend.t) with
  | Backend.Apple_container -> command_argv_for backend @ [ "inspect"; container_name ]
  | Backend.Microsandbox ->
    command_argv_for backend @ [ "inspect"; container_name; "--format"; "json" ]
  (* [nerdctl inspect] documents [--mode=(dockercompat|native)] and states no
     default, so the mode is named. [{{json .State.Running}}] resolves only
     in dockercompat; inherited from an unstated default it would be a
     template that stops resolving the day the default moves, which prints an
     empty line and reads as "not running". Asking for the one field rather
     than the whole document keeps the parse to a literal. *)
  | Backend.Nerdctl_kata ->
    command_argv_for backend
    @ [ "inspect"
      ; "--mode"
      ; "dockercompat"
      ; "--format"
      ; "{{json .State.Running}}"
      ; container_name
      ]
;;

(* [container logs] takes [-n]; [msb logs] rejects [-n] and takes [--tail]
   (measured 0.6.16, 2026-09-04: "unexpected argument '-n' found"), and
   nerdctl documents [-n, --tail]. *)
let logs_tail_argv_for backend ~tail ~container_id =
  match (backend : Backend.t) with
  | Backend.Apple_container ->
    command_argv_for backend @ [ "logs"; "-n"; string_of_int tail; container_id ]
  | Backend.Microsandbox | Backend.Nerdctl_kata ->
    command_argv_for backend @ [ "logs"; "--tail"; string_of_int tail; container_id ]
;;

(** Guests whose owning server is gone.

    A guest is keeper-lifetime, so age says nothing: one running for days
    belongs to a keeper that has been busy for days. What marks a guest as
    abandoned is its [masc.mcp.owner_pid] label naming a process that no
    longer exists -- the server that booted it died without reaching
    shutdown finalization, which is the one path that removes a guest
    (#31413). Each is about 460 MB, so they are worth collecting.

    Owner liveness is a fact rather than a heuristic, which is why this does
    not fall back to a time cutoff when the label is missing or unreadable:
    a guest it cannot account for is left alone and reported, not removed.
    Removing somebody's running guest to tidy up is worse than leaking. *)
type sweep_candidate =
  { container_id : string
  ; keeper_name : string option
  ; owner_pid : int option
  }

let label_of entry key =
  let open Yojson.Safe.Util in
  match entry |> member "configuration" |> member "labels" |> member key with
  | `String value -> Some value
  | _ -> None
;;

let json_string_opt = function
  | `String value -> Some value
  | _ -> None
;;

let container_id_of_entry entry =
  let open Yojson.Safe.Util in
  match entry |> member "id" |> json_string_opt with
  | Some id -> Some id
  | None -> entry |> member "configuration" |> member "id" |> json_string_opt
;;

let live_containers_of_json ~base_path ~keeper_name = function
  | `List entries ->
    let open Yojson.Safe.Util in
    let expected_base_path_hash = Keeper_sandbox_runtime.base_path_hash base_path in
    let expected_keeper_name = Keeper_sandbox_runtime.sanitize_label_value keeper_name in
    let belongs_to_keeper entry =
      String.equal
        (Option.value ~default:""
           (label_of entry Keeper_sandbox_runtime.sandbox_component_label_key))
        Keeper_sandbox_runtime.sandbox_component_label_value
      && String.equal
           (Option.value ~default:""
              (label_of entry Keeper_sandbox_runtime.sandbox_base_path_hash_label_key))
           expected_base_path_hash
      && String.equal
           (Option.value ~default:""
              (label_of entry Keeper_sandbox_runtime.sandbox_keeper_label_key))
           expected_keeper_name
      && String.equal
           (Option.value ~default:""
              (label_of entry Keeper_sandbox_runtime.sandbox_kind_label_key))
           keeper_vm_container_kind
    in
    let decode entry =
      if not (belongs_to_keeper entry) then Ok None
      else
        match container_id_of_entry entry with
        | None ->
          Error
            (Printf.sprintf "microvm live container for %s is malformed: missing id"
               keeper_name)
        | Some id ->
          try
          let configuration = entry |> member "configuration" in
          let image = configuration |> member "image" |> member "reference" |> to_string in
          let state = entry |> member "status" |> member "state" |> to_string in
          let labels = configuration |> member "labels" in
          let label name = labels |> member name |> json_string_opt in
          let float_label name = Option.bind (label name) float_of_string_opt in
          let int_member name json =
            match json |> member name with
            | `Int value -> Some value
            | _ -> None
          in
          let network =
            match entry |> member "status" |> member "networks" with
            | `List (network :: _) -> Some network
            | `List [] | `Null | _ -> None
          in
          let network_string name =
            Option.bind network (fun row -> row |> member name |> json_string_opt)
          in
          let resources = configuration |> member "resources" in
          let owner_pid =
            Option.bind
              (label Keeper_sandbox_runtime.sandbox_owner_pid_label_key)
              int_of_string_opt
          in
          Ok
            (Some
               ({ id
                ; name = id
                ; image
                ; status = state
                ; running = Some (String.equal state "running")
                ; created_at = configuration |> member "creationDate" |> json_string_opt
                ; keeper_name = label Keeper_sandbox_runtime.sandbox_keeper_label_key
                ; container_kind = label Keeper_sandbox_runtime.sandbox_kind_label_key
                ; network_label = label Keeper_sandbox_runtime.sandbox_network_label_key
                ; owner_pid
                ; started_at = float_label Keeper_sandbox_runtime.sandbox_started_at_label_key
                ; ttl_sec = float_label Keeper_sandbox_runtime.sandbox_ttl_sec_label_key
                ; cpus = int_member "cpus" resources
                ; memory_bytes = int_member "memoryInBytes" resources
                ; hostname = network_string "hostname"
                ; ipv4_address = network_string "ipv4Address"
                ; ipv6_address = network_string "ipv6Address"
                ; gateway = network_string "ipv4Gateway"
                } : Keeper_sandbox_runtime.live_container))
          with Yojson.Safe.Util.Type_error (detail, _) ->
            Error
              (Printf.sprintf "microvm live container for %s is malformed: %s"
                 keeper_name detail)
    in
    List.fold_right
      (fun entry result ->
         match decode entry, result with
         | Error detail, _ | _, Error detail -> Error detail
         | Ok None, Ok containers -> Ok containers
         | Ok (Some container), Ok containers -> Ok (container :: containers))
      entries
      (Ok [])
  | _ -> Error "microvm container list must be a JSON array"
;;

(** How a runtime answers "which guests are here", and whether that answer
    carries the labels the scoping above reads.

    What the sweep needs from a row is not just "which guests" but "whose":
    the base path hash, the keeper name, and the owner pid it decides
    abandonment on. Filtering is not enough -- the pid has to be read back.

    Apple's [container list --all --format json] answers a JSON array whose
    entries nest [configuration.labels], which is where all three live.

    [msb list] documents [--label <LABEL>] (repeatable, AND-matched), so a
    guest can be scoped server-side; what its [--format json] rows carry is
    only created_at, image, name and status, with no label values at all
    (measured 0.6.16, 2026-09-04). The owner pid the sweep needs is therefore
    not in the answer, and msb keeps labels in [inspect] under
    [active_config.labels] -- one call per guest rather than one listing.

    Nerdctl's ListItem exposes LabelsMap to Go templates even though its
    ordinary JSON representation excludes that field. Request an explicit
    flat record, including the runtime identity; do not pretend its status
    prose is Apple's structured running state.
    Source: nerdctl v2.3.5 pkg/cmd/container/list.go:107-125,182-193. *)
type container_listing =
  | Labelled_json_array of string list
  | Nerdctl_labelled_json_lines of string list
  | Listing_not_established of string

let nerdctl_inventory_argv () =
  command_argv_for Backend.Nerdctl_kata
  @ [ "ps"; "-a"; "--no-trunc"; "--format";
      {|{"id":{{json .ID}},"name":{{json .Names}},"image":{{json .Image}},"status":{{json .Status}},"created_at":{{json .CreatedAt}},"runtime":{{json .Runtime}},"labels":{{json .LabelsMap}}}|} ]
;;

type kata_name_observation =
  | Kata_name_absent
  | Kata_name_expected_runtime
  | Kata_name_other_runtime
  | Kata_name_runtime_unreported
  | Kata_name_unavailable

(* This listing deliberately asks for no labels, images, IDs, logs or guest
   files. A reported runtime is a CLI observation, never proof of ownership. *)
let kata_name_listing_argv () =
  command_argv_for Backend.Nerdctl_kata
  @ [ "ps"; "-a"; "--no-trunc"; "--format";
      {|{"name":{{json .Names}},"runtime":{{json .Runtime}}}|} ]
;;

let kata_name_observation_of_json_lines ~guest_name raw =
  let open Result.Syntax in
  let row line =
    let* json =
      try Ok (Yojson.Safe.from_string line) with Yojson.Json_error _ -> Error ()
    in
    match json with
    | `Assoc fields ->
      let keys = List.map fst fields in
      if List.length keys <> List.length (List.sort_uniq String.compare keys)
      then Error ()
      else
        let* name = match List.assoc_opt "name" fields with
          | Some (`String name) when String.trim name <> "" -> Ok name
          | Some _ | None -> Error () in
        let* runtime = match List.assoc_opt "runtime" fields with
          | None | Some `Null | Some (`String "") -> Ok Kata_name_runtime_unreported
          | Some (`String runtime) ->
            if String.trim runtime = "" then Ok Kata_name_runtime_unreported
            else
              (match Kata_vmm.classify_runtime_id runtime with
               | Ours _ | Default_shim -> Ok Kata_name_expected_runtime
               | Unknown_runtime _ -> Ok Kata_name_other_runtime)
          | Some _ -> Error () in
        Ok (name, runtime)
    | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) ->
      Error ()
  in
  let decode () =
    let* rows =
      String.split_on_char '\n' raw
      |> List.map String.trim
      |> List.filter (fun line -> line <> "")
      |> fun lines -> List.fold_right (fun line acc ->
           let* rows = acc in
           let* current = row line in
           Ok (current :: rows)) lines (Ok [])
    in
    let names = List.map fst rows in
    if List.length names <> List.length (List.sort_uniq String.compare names)
       || String.trim guest_name = ""
    then Error ()
    else Ok (match List.assoc_opt guest_name rows with
      | Some observation -> observation
      | None -> Kata_name_absent)
  in
  match decode () with
  | Ok observation -> observation
  | Error () -> Kata_name_unavailable
;;

let observe_kata_name_with ~run ~env ~cwd ~base_path ~keeper_name ~network_mode ~timeout_sec =
  let guest_name =
    Keeper_sandbox_container_name.make
      (Keeper_sandbox_container_name.Micro_vm_persistent
         { base_path; keeper_name; network_mode })
    |> Keeper_sandbox_container_name.to_string in
  if not (Float.is_finite timeout_sec) || timeout_sec <= 0. then Kata_name_unavailable
  else match run ~timeout_sec ~env ~cwd ~argv:(kata_name_listing_argv ()) with
  | Ok (Unix.WEXITED 0, stdout) ->
    kata_name_observation_of_json_lines ~guest_name stdout
  | Ok ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _) | Error () ->
    Kata_name_unavailable
  | exception (Sys_error _ | Unix.Unix_error _ | Eio.Io _) -> Kata_name_unavailable
;;

let observe_kata_name ~env ~cwd ~base_path ~keeper_name ~network_mode ~timeout_sec =
  let run ~timeout_sec ~env ~cwd ~argv =
    Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
      Keeper_microvm_cli_output.read_with_environment ~timeout_sec
        ~stdout_limit:Common.max_process_capture_head_bytes
        ~stderr_limit:Common.max_process_capture_tail_bytes ~env ~cwd ~argv ()
      |> Result.map (fun (status, stdout, _) -> status, stdout)
      |> Result.map_error (fun _ -> ())) in
  observe_kata_name_with ~run ~env ~cwd ~base_path ~keeper_name ~network_mode ~timeout_sec
;;

let container_listing_for backend =
  match (backend : Backend.t) with
  | Backend.Apple_container -> Labelled_json_array (apple_container_list_argv ())
  | Backend.Microsandbox ->
    Listing_not_established
      "msb list can be scoped server-side with --label, but its --format \
       json rows report only {created_at, image, name, status} and echo no \
       label values, so the owner pid this sweep decides abandonment on \
       cannot be read back from the listing; msb keeps labels in `inspect` \
       under active_config.labels, one call per guest"
  | Backend.Nerdctl_kata -> Nerdctl_labelled_json_lines (nerdctl_inventory_argv ())
;;

type nerdctl_inventory_entry =
  { nerdctl_id : string
  ; nerdctl_name : string
  ; nerdctl_image : string
  ; nerdctl_status : string
  ; nerdctl_created_at : string
  ; nerdctl_runtime : string
  ; nerdctl_labels : (string * string) list
  }

let nerdctl_inventory_of_json_lines raw =
  let open Result.Syntax in
  let object_fields = function
    | `Assoc fields ->
      let names = List.map fst fields in
      if List.length names = List.length (List.sort_uniq String.compare names)
      then Ok fields else Error "nerdctl inventory contains duplicate fields"
    | _ -> Error "nerdctl inventory row must be an object"
  in
  let required_string fields name =
    match List.assoc_opt name fields with
    | Some (`String value) -> Ok value
    | _ -> Error ("nerdctl inventory requires string field " ^ name)
  in
  let decode line =
    let* json =
      try Ok (Yojson.Safe.from_string line)
      with Yojson.Json_error detail -> Error ("invalid nerdctl inventory JSON: " ^ detail)
    in
    let* fields = object_fields json in
    let* nerdctl_id = required_string fields "id" in
    (* --no-trunc returns the complete containerd id: accepting an empty or
       option-shaped id could make a removal target somebody else's guest. *)
    let* () =
      if String.length nerdctl_id = 64
         && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) nerdctl_id
      then Ok () else Error "nerdctl inventory requires a full hexadecimal container id"
    in
    let* nerdctl_name = required_string fields "name" in
    let* nerdctl_image = required_string fields "image" in
    let* nerdctl_status = required_string fields "status" in
    let* nerdctl_created_at = required_string fields "created_at" in
    let* nerdctl_runtime = required_string fields "runtime" in
    let* labels =
      match List.assoc_opt "labels" fields with
      | Some `Null -> Ok [] (* Go marshals a nil map as null; it owns no labels. *)
      | Some value -> object_fields value
      | None -> Error "nerdctl inventory requires labels"
    in
    let* nerdctl_labels =
      List.fold_right (fun (key, value) acc ->
        let* rest = acc in
        match value with
        | `String value -> Ok ((key, value) :: rest)
        | _ -> Error "nerdctl inventory label values must be strings") labels (Ok [])
    in
    Ok { nerdctl_id; nerdctl_name; nerdctl_image; nerdctl_status;
         nerdctl_created_at; nerdctl_runtime; nerdctl_labels }
  in
  let* rows =
    String.split_on_char '\n' raw
    |> List.map String.trim
    |> List.filter (fun line -> line <> "")
    |> fun lines -> List.fold_right (fun line acc ->
         let* row = decode line in
         let* rest = acc in
         Ok (row :: rest)) lines (Ok [])
  in
  let ids = List.map (fun row -> row.nerdctl_id) rows in
  if List.length ids = List.length (List.sort_uniq String.compare ids)
  then Ok rows else Error "nerdctl inventory contains duplicate container ids"
;;

let nerdctl_label row name = List.assoc_opt name row.nerdctl_labels

let nerdctl_belongs_to_base ~base_path row =
  let exact name expected = nerdctl_label row name = Some expected in
  (* Ownership runtime predicate widened by [task-2856]: rows started with any
     host-validated Kata-family id (default shim or per-VMM split) are ours;
     before, only the fixed shim id matched.  The component and
     base_path_hash labels below remain the real gates. *)
  (match Kata_vmm.classify_runtime_id row.nerdctl_runtime with
   | Ours _ | Default_shim -> true
   | Unknown_runtime _ -> false)
  && exact Keeper_sandbox_runtime.sandbox_component_label_key
       Keeper_sandbox_runtime.sandbox_component_label_value
  && exact Keeper_sandbox_runtime.sandbox_base_path_hash_label_key
       (Keeper_sandbox_runtime.base_path_hash base_path)
  && exact Keeper_sandbox_runtime.sandbox_kind_label_key keeper_vm_container_kind
;;

let nerdctl_owner_pid row =
  match Option.bind
          (nerdctl_label row Keeper_sandbox_runtime.sandbox_owner_pid_label_key)
          int_of_string_opt with
  | Some pid when pid > 0 -> Some pid
  | Some _ | None -> None
;;

let nerdctl_live_containers_of_json_lines ~base_path ~keeper_name raw =
  let expected_keeper = Keeper_sandbox_runtime.sanitize_label_value keeper_name in
  Result.map (fun rows ->
    List.filter_map (fun row ->
      if not (nerdctl_belongs_to_base ~base_path row)
         || nerdctl_label row Keeper_sandbox_runtime.sandbox_keeper_label_key <> Some expected_keeper
      then None
      else
        let label = nerdctl_label row in
        let float_label key = Option.bind (label key) float_of_string_opt in
        Some ({ id = row.nerdctl_id; name = row.nerdctl_name; image = row.nerdctl_image;
                status = row.nerdctl_status; running = None;
                created_at = Some row.nerdctl_created_at;
                keeper_name = label Keeper_sandbox_runtime.sandbox_keeper_label_key;
                container_kind = label Keeper_sandbox_runtime.sandbox_kind_label_key;
                network_label = label Keeper_sandbox_runtime.sandbox_network_label_key;
                owner_pid = nerdctl_owner_pid row;
                started_at = float_label Keeper_sandbox_runtime.sandbox_started_at_label_key;
                ttl_sec = float_label Keeper_sandbox_runtime.sandbox_ttl_sec_label_key;
                cpus = None; memory_bytes = None; hostname = None;
                ipv4_address = None; ipv6_address = None; gateway = None }
              : Keeper_sandbox_runtime.live_container)) rows)
    (nerdctl_inventory_of_json_lines raw)
;;

let nerdctl_sweep_candidates_of_json_lines ~base_path ~is_pid_alive raw =
  Result.map (fun rows ->
    List.filter_map (fun row ->
      let keeper_name = nerdctl_label row Keeper_sandbox_runtime.sandbox_keeper_label_key in
      match nerdctl_belongs_to_base ~base_path row, keeper_name, nerdctl_owner_pid row with
      | true, Some name, Some pid when String.trim name <> "" && not (is_pid_alive pid) ->
        Some { container_id = row.nerdctl_id; keeper_name; owner_pid = Some pid }
      | _ -> None) rows)
    (nerdctl_inventory_of_json_lines raw)
;;

(* ── Whether a guest name exists when inspect did not answer ────────── *)

(* Measured 2026-10-21 on container 1.3.1: [container inspect] exits 1 for a
   name that is not there ("container not found") and also exits 1 when the
   apiserver stalls before it can look ("failed to list containers ... XPC
   timeout", 31.5 s). msb 0.6.16 exits 1 for a missing name as well, and a
   timed-out inspect ends on a signal. The exit code cannot tell "absent"
   from "could not ask" (#44676), so the runtime's own listing settles it.

   msb is listed with its plain [msb list --format json]: the sweep cannot
   use those rows because they carry no labels, but they carry the name and
   the status a lookup by name needs. Measured 2026-10-21 on 0.6.16: stopped
   sandboxes are listed without a flag ([--running] and [--stopped] narrow
   it), and a row reads [{created_at, image, name, status}]. *)
let guest_listing_argv_for backend =
  match (backend : Backend.t) with
  | Backend.Apple_container -> apple_container_list_argv ()
  | Backend.Microsandbox -> command_argv_for backend @ [ "list"; "--format"; "json" ]
  | Backend.Nerdctl_kata -> nerdctl_inventory_argv ()
;;

(* What one listing row says about its guest. nerdctl's [ps] Status is
   display text ("Up 5 minutes"), not a state, so its rows report none. *)
type listed_state =
  | Listed_running
  | Listed_stopped
  | Listed_state_unreported

let apple_listing_rows raw =
  match Yojson.Safe.from_string raw with
  | exception Yojson.Json_error detail -> Error ("container list returned invalid JSON: " ^ detail)
  | `List entries ->
    List.fold_right
      (fun entry acc ->
         Result.bind acc (fun rows ->
           match entry with
           | `Assoc fields ->
             (match apple_listing_row_id fields with
              | None -> Error "container list has a row without a container id"
              | Some id ->
                let state =
                  match List.assoc_opt "status" fields with
                  | Some (`Assoc status) ->
                    (match List.assoc_opt "state" status with
                     | Some (`String state) ->
                       if String.equal state "running" then Listed_running else Listed_stopped
                     | Some _ | None -> Listed_state_unreported)
                  | Some _ | None -> Listed_state_unreported
                in
                Ok ((id, state) :: rows))
           | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) ->
             Error "container list has a row that is not an object"))
      entries
      (Ok [])
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _) ->
    Error "container list did not return a JSON array"
;;

let msb_listing_rows raw =
  match Yojson.Safe.from_string raw with
  | exception Yojson.Json_error detail -> Error ("msb list returned invalid JSON: " ^ detail)
  | `List entries ->
    List.fold_right
      (fun entry acc ->
         Result.bind acc (fun rows ->
           match entry with
           | `Assoc fields ->
             (match List.assoc_opt "name" fields with
              | Some (`String name) when String.trim name <> "" ->
                let state =
                  match List.assoc_opt "status" fields with
                  | Some (`String status) ->
                    if String.equal (String.lowercase_ascii status) "running"
                    then Listed_running
                    else Listed_stopped
                  | Some _ | None -> Listed_state_unreported
                in
                Ok ((name, state) :: rows)
              | Some _ | None -> Error "msb list has a row without a name")
           | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) ->
             Error "msb list has a row that is not an object"))
      entries
      (Ok [])
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _) ->
    Error "msb list did not return a JSON array"
;;

let nerdctl_listing_rows raw =
  Result.map
    (List.map (fun row -> row.nerdctl_name, Listed_state_unreported))
    (nerdctl_inventory_of_json_lines raw)
;;

(* Every row is decoded before the name is looked up: a row whose name cannot
   be read might be the guest asked about, so it fails the listing instead of
   being skipped. *)
let listing_rows_for backend raw =
  match (backend : Backend.t) with
  | Backend.Apple_container -> apple_listing_rows raw
  | Backend.Microsandbox -> msb_listing_rows raw
  | Backend.Nerdctl_kata -> nerdctl_listing_rows raw
;;

let classify_guest_probe_for backend ~container_name ~inspect ~listing =
  let inspect_status, inspect_output = inspect in
  match inspect_status with
  | Unix.WEXITED 0 ->
    (match running_of_inspect_json_for backend inspect_output with
     | Ok true -> Ok Keeper_sandbox_runtime.Docker_container_running
     | Ok false -> Ok Keeper_sandbox_runtime.Docker_container_stopped
     | Error _ as error -> error)
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
    let unknown reason =
      Error
        (Printf.sprintf
           "microvm_guest_state_unknown: %s inspect %s did not answer (%s): %s; %s"
           (Backend.cli_name backend)
           container_name
           (Keeper_sandbox_exec_failure.status_label inspect_status)
           (Keeper_sandbox_runtime.docker_failure_output_for_log inspect_output)
           reason)
    in
    (match listing with
     | None -> unknown "no listing was taken to confirm the guest is absent"
     | Some (Unix.WEXITED 0, stdout, _stderr) ->
       (match listing_rows_for backend stdout with
        | Error detail -> unknown ("the listing could not be read: " ^ detail)
        | Ok rows ->
          (match List.filter (fun (name, _) -> String.equal name container_name) rows with
           | [] -> Ok Keeper_sandbox_runtime.Docker_container_absent
           | [ (_, Listed_running) ] -> Ok Keeper_sandbox_runtime.Docker_container_running
           | [ (_, Listed_stopped) ] -> Ok Keeper_sandbox_runtime.Docker_container_stopped
           | [ (_, Listed_state_unreported) ] ->
             unknown "the listing shows the guest and does not report its state"
           | _ :: _ :: _ -> unknown "the listing names the guest more than once"))
     | Some (((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), stdout, stderr) ->
       unknown
         (Printf.sprintf
            "the listing failed too (%s): %s"
            (Keeper_sandbox_exec_failure.status_label status)
            (output_for_log ~stdout ~stderr)))
;;

let list_live_containers_for_with ~run backend ~base_path ~keeper_name ~timeout_sec =
  let open Result.Syntax in
  if not (Float.is_finite timeout_sec) || timeout_sec <= 0. then
    Error "microvm observation timeout is unavailable"
  else match container_listing_for backend with
  | Listing_not_established reason ->
    Error
      (Printf.sprintf
         "microvm_container_listing_unsupported: %s: %s"
         (Backend.to_string backend)
         reason)
  | (Labelled_json_array argv | Nerdctl_labelled_json_lines argv) as listing ->
    (match run ~timeout_sec argv with
     | Unix.WEXITED 0, stdout, _ ->
       (match listing with
        | Nerdctl_labelled_json_lines _ ->
          let* containers = nerdctl_live_containers_of_json_lines ~base_path ~keeper_name stdout in
          (* ps Status is display prose. Ask the existing typed bool inspect
             for each scoped guest so status does not misreport unknown as idle. *)
          List.fold_right (fun (container : Keeper_sandbox_runtime.live_container) acc ->
            let* rest = acc in
            match run ~timeout_sec (inspect_argv_for backend ~container_name:container.id) with
            | Unix.WEXITED 0, state, _ ->
              let* running = running_of_nerdctl_state_json state in
              Ok ({ container with running = Some running } :: rest)
            | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), out, err ->
              Error (Printf.sprintf "nerdctl inventory state for %s failed (%s): %s"
                       container.id (Keeper_sandbox_exec_failure.status_label status)
                       (output_for_log ~stdout:out ~stderr:err))) containers (Ok [])
        | Labelled_json_array _ ->
          (match Yojson.Safe.from_string stdout with
           | json -> live_containers_of_json ~base_path ~keeper_name json
           | exception Yojson.Json_error detail ->
             Error ("microvm container list returned invalid JSON: " ^ detail))
        | Listing_not_established reason -> Error reason)
     | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), stdout, stderr ->
       Error
         (Printf.sprintf
            "microvm container list failed (%s): %s"
            (Keeper_sandbox_exec_failure.status_label status)
            (output_for_log ~stdout ~stderr)))
;;

let list_live_containers_for ?env ?cwd backend ~base_path ~keeper_name ~timeout_sec =
  let run ~timeout_sec argv = Process_eio.run_argv_with_status_split ~timeout_sec ?env ?cwd argv in
  list_live_containers_for_with ~run backend ~base_path ~keeper_name ~timeout_sec
;;

module Kata_observation_for_testing = struct
  let observe = observe_kata_name_with
  let inventory = list_live_containers_for_with
end

type sweep_outcome =
  { removed : string list
  ; failed : (string * string) list
  }

(* One runtime's share of the sweep. Returns what it did rather than
   raising: a guest that refuses to stop is worth reporting, and is not a
   reason to fail whatever asked for the sweep. A listing that cannot be read
   removes nothing. *)
let sweep_one_backend backend ~base_path ~timeout_sec ~is_pid_alive ~run_argv listing =
  match run_argv ~timeout_sec listing with
  | Unix.WEXITED 0, out ->
    let candidates =
      match nerdctl_sweep_candidates_of_json_lines ~base_path ~is_pid_alive out with
      | Ok candidates -> candidates
      | Error detail ->
        Log.Keeper.warn "nerdctl abandoned guest inventory rejected: %s" detail;
        []
    in
    List.fold_left
      (fun acc candidate ->
        match
          run_argv
            ~timeout_sec
            (delete_force_argv_for backend ~container_name:candidate.container_id)
        with
        | Unix.WEXITED 0, _ -> { acc with removed = candidate.container_id :: acc.removed }
        | (Unix.WEXITED _, detail) | (Unix.WSIGNALED _, detail) | (Unix.WSTOPPED _, detail) ->
          { acc with failed = (candidate.container_id, detail) :: acc.failed })
      { removed = []; failed = [] }
      candidates
  | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), detail ->
    Log.Keeper.warn "microvm abandoned guest inventory failed backend=%s status=%s: %s"
      (Backend.to_string backend) (Keeper_sandbox_exec_failure.status_label status) detail;
    { removed = []; failed = [] }
;;

(* Apple selection belongs to the complete declaration-aware runtime sweep.
   Only Nerdctl retains process-bound dead-owner adoption and collection. *)
let sweep_abandoned_guests
      ~base_path
      ~command_available
      ~timeout_sec
      ~is_pid_alive
      ~run_argv
  =
  List.filter_map
    (fun backend ->
      if not (command_available (Backend.cli_name backend))
      then None
      else (
        match container_listing_for backend with
        | Listing_not_established _ -> None
        | Labelled_json_array listing | Nerdctl_labelled_json_lines listing ->
          Some
            ( backend
            , sweep_one_backend
                backend
                ~base_path
                ~timeout_sec
                ~is_pid_alive
                ~run_argv
                listing )))
    [Backend.Nerdctl_kata]
;;
