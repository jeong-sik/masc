(** Sandbox target helpers for typed Shell IR dispatch. *)

type target_error =
  { message : string
  ; fields : (string * Yojson.Safe.t) list
  ; class_ : Tool_result.tool_failure_class
  }

(** Where a request can be run boxed before the judge is asked (RFC-0422).
    [Boxed] carries a target whose runner asks the endpoint's shim for the
    observe box; [No_box] says why there is none, in the operator's words —
    a Docker guest runs no shim, a shim may advertise no box, the endpoint
    may not be reachable. Resolved lazily: the microvm route acquires the
    guest, which may boot it, and that is spent only when the gate has
    declined every cheaper authority and would otherwise pay the judge. *)
type observe_route =
  | Boxed of
      { target : Masc_exec.Sandbox_target.t
      ; run : Keeper_types_profile_sandbox.observation_run
      }
  | No_box of string

val protocol_mode_of_run :
  Keeper_types_profile_sandbox.observation_run -> Exec_ssh_protocol.mode
(** The box the keeper TOML names, in the words the shim's request takes:
    [Observe] asks for the shim's observe box, [Guest_local] for the one that
    lets writes land inside the guest. *)

val observation_run_for :
  base_path:string ->
  keeper_name:string ->
  (Keeper_types_profile_sandbox.observation_run, string) result
(** Which box this keeper's operator chose (RFC-0422 §3.4), read from the
    keeper TOML when the route is resolved — as [remote_endpoint] is — and
    {!Keeper_types_profile_sandbox.default_observation_run} when the TOML
    says nothing. A TOML that fails to load is the [Error], and the route
    that asked becomes [No_box] with that reason. *)

type guest_dispatch =
  { target : Masc_exec.Sandbox_target.t
  ; runtime : Keeper_turn_sandbox_runtime.t
  ; sandbox_profile : Keeper_types_profile_sandbox.sandbox_profile
  ; observe_route : unit -> observe_route
  }

type ssh_dispatch =
  { target : Masc_exec.Sandbox_target.t
  ; observe_route : unit -> observe_route
  }

val target_error
  :  ?fields:(string * Yojson.Safe.t) list
  -> ?class_:Tool_result.tool_failure_class
  -> string
  -> target_error

val profile_contract_mismatch
  :  expected:Keeper_types_profile_sandbox.sandbox_profile
  -> actual:Keeper_types_profile_sandbox.sandbox_profile
  -> target_error
(** A typed pre-effect rejection for a caller meta that disagrees with the
    turn factory. *)

(** Build the Shell IR target from the factory's immutable runtime binding.
    A Docker guest runs stages by [docker exec] into its mounted tree; a
    microvm guest runs them over the remote lane into the tree it owns on
    its work volume (RFC-0400), with no pipeline runner. Neither starts its
    container here: the first stage does, and each runtime owns its
    creation-time image check. A caller meta that disagrees with the factory
    fails before dispatch. *)
val guest_target
  :  binding:Keeper_sandbox_factory.runtime_binding
  -> meta:Keeper_meta_contract.keeper_meta
  -> cwd:string
  -> timeout_sec:float
  -> base_path:string
  -> unit
  -> (guest_dispatch, target_error) result

val ssh_target
  :  base_path:string
  -> meta:Keeper_meta_contract.keeper_meta
  -> timeout_sec:float
  -> ?ssh_bin:string
  -> unit
  -> (ssh_dispatch, target_error) result
(** Resolve the keeper's endpoint and construct a fail-closed SSH target.
    Pipeline dispatch remains unsupported until a native remote pipeline
    contract exists. *)
