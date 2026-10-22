module Fs = Keeper_volume_filesystem
module Volume_map = Map.Make (String)

type failure =
  | Inspect_refused of string
  | Inspect_unparsed of Fs.inspect_failure
  | Image_unreadable of Fs.read_failure

type observation =
  { volume : string
  ; observed_at : float
  ; source : string option
  ; result : (Fs.state, failure) result
  }

let latest_by_volume : observation Volume_map.t Atomic.t = Atomic.make Volume_map.empty

let volumes_of_meta (meta : Keeper_meta_contract.keeper_meta) =
  match meta.sandbox_profile, meta.microvm_backend with
  | Keeper_types_profile.Micro_vm, Some Keeper_microvm_backend.Apple_container ->
    List.filter_map
      Result.to_option
      [ Keeper_sandbox_microvm.work_volume_name ~keeper_name:meta.name
      ; Keeper_sandbox_microvm.build_volume_name ~keeper_name:meta.name
      ]
  | ( Keeper_types_profile.Micro_vm
    , (None | Some (Keeper_microvm_backend.Microsandbox | Keeper_microvm_backend.Nerdctl_kata)) )
  | ( (Keeper_types_profile.Docker | Keeper_types_profile.Remote_ssh)
    , ( None
      | Some
          ( Keeper_microvm_backend.Apple_container
          | Keeper_microvm_backend.Microsandbox
          | Keeper_microvm_backend.Nerdctl_kata ) ) ) -> []
;;

let volumes_of_durable_meta ~base_path meta =
  Result.map volumes_of_meta (Keeper_meta_contract.effective_meta_result ~base_path meta)
;;

(* Only the map changes inside the CAS: a retry re-runs this, so the read and
   the clock stay outside. *)
let rec record observation =
  let current = Atomic.get latest_by_volume in
  let next = Volume_map.add observation.volume observation current in
  if Atomic.compare_and_set latest_by_volume current next
  then Volume_map.find_opt observation.volume current
  else record observation
;;

let latest ~volume = Volume_map.find_opt volume (Atomic.get latest_by_volume)

(* A volume's image path does not change while the volume exists, so only the
   first read, or the one after a failed read, asks the container CLI. *)
let image_source ~inspect ~volume =
  match latest ~volume with
  | Some { source = Some source; result = Ok (Fs.Clean | Fs.Errors_recorded _); _ } -> Ok source
  | Some
      { source = Some _
      ; result = Error (Inspect_refused _ | Inspect_unparsed _ | Image_unreadable _)
      ; _
      }
  | Some { source = None; _ }
  | None ->
    (match inspect ~volume with
     | Error detail -> Error (Inspect_refused detail)
     | Ok json ->
       (match Fs.image_of_inspect json with
        | Ok image -> Ok image.source
        | Error failure -> Error (Inspect_unparsed failure)))
;;

let observe ~now ~inspect ~read_image ~volume =
  let source, result =
    match image_source ~inspect ~volume with
    | Error failure -> None, Error failure
    | Ok source ->
      Some source, Result.map_error (fun failure -> Image_unreadable failure) (read_image ~path:source)
  in
  let observation = { volume; observed_at = now; source; result } in
  record observation, observation
;;

let damaged (observation : observation) =
  match observation.result with
  | Ok (Fs.Errors_recorded _) -> true
  | Ok Fs.Clean | Error (Inspect_refused _ | Inspect_unparsed _ | Image_unreadable _) -> false
;;

let damage_appeared ~previous current =
  damaged current && not (Option.fold ~none:false ~some:damaged previous)
;;

let failure_to_string = function
  | Inspect_refused detail -> "volume inspect refused: " ^ detail
  | Inspect_unparsed failure -> Fs.inspect_failure_to_string failure
  | Image_unreadable failure -> Fs.read_failure_to_string failure
;;

let observation_to_yojson observation =
  `Assoc
    [ "volume", `String observation.volume
    ; "observed_at", `Float observation.observed_at
    ; "image", Json_util.string_opt_to_json observation.source
    ; ( "filesystem"
      , match observation.result with
        | Ok state -> Fs.state_to_yojson state
        | Error (Inspect_refused _ | Inspect_unparsed _ | Image_unreadable _) -> `Null )
    ; ( "observation_failed"
      , match observation.result with
        | Ok (Fs.Clean | Fs.Errors_recorded _) -> `Null
        | Error failure -> `String (failure_to_string failure) )
    ]
;;
