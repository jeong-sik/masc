module Backend = Keeper_microvm_backend
open Keeper_sandbox_microvm_base
open Keeper_sandbox_microvm_guest_argv
open Keeper_sandbox_microvm_work_volume
open Keeper_sandbox_microvm_shim
open Keeper_sandbox_microvm_volume_probe

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
