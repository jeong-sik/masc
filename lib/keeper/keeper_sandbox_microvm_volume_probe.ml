module Backend = Keeper_microvm_backend
open Keeper_sandbox_microvm_base
open Keeper_sandbox_microvm_work_volume

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
