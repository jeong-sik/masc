(** The containers a runtime reports for keepers: the sweep candidate, the
    listing each runtime answers in and the live containers read from it, the
    Kata name observation, and the nerdctl inventory with the live containers
    and sweep candidates read from it.

    [Keeper_sandbox_microvm] includes this module. *)

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

val live_containers_of_json :
  base_path:string ->
  keeper_name:string ->
  Yojson.Safe.t ->
  (Keeper_sandbox_runtime.live_container list, string) result

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

val nerdctl_inventory_argv : unit -> string list

type kata_name_observation =
  | Kata_name_absent
  | Kata_name_expected_runtime
  | Kata_name_other_runtime
  | Kata_name_runtime_unreported
  | Kata_name_unavailable

val kata_name_observation_of_json_lines :
  guest_name:string -> string -> kata_name_observation

val observe_kata_name_with :
  run:(timeout_sec:float ->
       env:'a ->
       cwd:'b ->
       argv:string list -> (Unix.process_status * string, unit) result) ->
  env:'a ->
  cwd:'b ->
  base_path:string ->
  keeper_name:string ->
  network_mode:Keeper_types_profile_sandbox.network_mode ->
  timeout_sec:float -> kata_name_observation

val observe_kata_name :
  env:string array -> cwd:string ->
  base_path:string -> keeper_name:string ->
  network_mode:Keeper_types_profile_sandbox.network_mode -> timeout_sec:float ->
  kata_name_observation

val container_listing_for : Keeper_microvm_backend.t -> container_listing

type nerdctl_inventory_entry =
  { nerdctl_id : string
  ; nerdctl_name : string
  ; nerdctl_image : string
  ; nerdctl_status : string
  ; nerdctl_created_at : string
  ; nerdctl_runtime : string
  ; nerdctl_labels : (string * string) list
  }

val nerdctl_inventory_of_json_lines :
  string -> (nerdctl_inventory_entry list, string) result

val nerdctl_live_containers_of_json_lines :
  base_path:string -> keeper_name:string -> string ->
  (Keeper_sandbox_runtime.live_container list, string) result

val nerdctl_sweep_candidates_of_json_lines :
  base_path:string -> is_pid_alive:(int -> bool) -> string ->
  (sweep_candidate list, string) result
