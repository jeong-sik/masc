type t =
  | Guest_builds
  | Remote_workspace
[@@deriving enumerate]

(* Steps are names: no constructor carries a value. *)
let equal (left : t) (right : t) = left = right

let to_string = function
  | Guest_builds -> "guest_builds"
  | Remote_workspace -> "remote_workspace"
;;

let of_string name = List.find_opt (fun step -> String.equal (to_string step) name) all

type admission =
  | Idle_owner
  | Beside_turns

(* Only [Guest_builds] waits for an idle Keeper: its turns and the payload
   share the guest build locks. A workspace entry carries its own keep rules
   on the endpoint, and review Keepers run turns back to back: at the first
   pass on 2026-11-09 (00:08Z) at least five of the seven running reviewers
   were mid-turn, so an idle-only sweep removed nothing while a report run
   found 13,525 stale entries. *)
let admission = function
  | Guest_builds -> Idle_owner
  | Remote_workspace -> Beside_turns
;;

(* The backend is spelled out where the step depends on it, so a new microVM
   backend has to say whether its guests hold Dune output this step can
   reach. Only the Apple guest has the attach path the payload runs through. *)
let applies_to step ~sandbox_profile ~microvm_backend =
  match
    ( step
    , (sandbox_profile : Keeper_types_profile.sandbox_profile)
    , (microvm_backend : Keeper_microvm_backend.t option) )
  with
  | Guest_builds, Keeper_types_profile.Micro_vm, Some Keeper_microvm_backend.Apple_container
    -> true
  | ( Guest_builds
    , Keeper_types_profile.Micro_vm
    , (Some Keeper_microvm_backend.(Microsandbox | Nerdctl_kata) | None) ) -> false
  | Guest_builds, Keeper_types_profile.(Docker | Remote_ssh), (Some _ | None) -> false
  | Remote_workspace, Keeper_types_profile.Remote_ssh, (Some _ | None) -> true
  | Remote_workspace, Keeper_types_profile.(Docker | Micro_vm), (Some _ | None) -> false
;;
