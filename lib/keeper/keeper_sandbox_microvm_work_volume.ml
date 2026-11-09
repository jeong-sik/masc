module Backend = Keeper_microvm_backend
open Keeper_sandbox_microvm_base
open Keeper_sandbox_microvm_guest_argv

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
