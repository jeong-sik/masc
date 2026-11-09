module Backend = Keeper_microvm_backend
open Keeper_sandbox_microvm_base
open Keeper_sandbox_microvm_guest_argv
open Keeper_sandbox_microvm_work_volume
open Keeper_sandbox_microvm_inspect
open Keeper_sandbox_microvm_inventory

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
