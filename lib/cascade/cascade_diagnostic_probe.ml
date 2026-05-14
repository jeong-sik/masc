(** See {!Cascade_diagnostic_probe} (.mli) for the contract. *)

module type Diagnostic_probe = sig
  val can_probe : url:string -> bool

  val loaded_models_json
    :  sw:Eio.Switch.t
    -> net:[> [> `Generic ] Eio.Net.ty ] Eio.Resource.t
    -> url:string
    -> ?timeout_sec:int
    -> unit
    -> Yojson.Safe.t

  val runtime_probe_json
    :  sw:Eio.Switch.t
    -> net:[> [> `Generic ] Eio.Net.ty ] Eio.Resource.t
    -> url:string
    -> probe_runs:int
    -> max_tokens:int
    -> ?think_enabled:bool
    -> unit
    -> Yojson.Safe.t
end

type t = (module Diagnostic_probe)

let registry_mutex = Stdlib.Mutex.create ()
let registered_probes_rev : t list ref = ref []

let probes () =
  Stdlib.Mutex.protect registry_mutex (fun () -> List.rev !registered_probes_rev)
;;

let register probe =
  Stdlib.Mutex.protect registry_mutex (fun () ->
    registered_probes_rev := probe :: !registered_probes_rev)
;;

let find_owner ~url =
  List.find_opt (fun (module P : Diagnostic_probe) -> P.can_probe ~url) (probes ())
;;

let loaded_models_json ~sw ~net ~url ?timeout_sec () =
  match find_owner ~url with
  | None -> `Null
  | Some (module P) -> P.loaded_models_json ~sw ~net ~url ?timeout_sec ()
;;

let runtime_probe_json ~sw ~net ~url ~probe_runs ~max_tokens ?think_enabled () =
  match find_owner ~url with
  | None -> `Null
  | Some (module P) -> P.runtime_probe_json ~sw ~net ~url ~probe_runs ~max_tokens ?think_enabled ()
;;

module For_testing = struct
  let clear_registry () =
    Stdlib.Mutex.protect registry_mutex (fun () -> registered_probes_rev := [])
  ;;

  let with_registry probes f =
    (* Atomic swap: read-and-replace under a single critical section so a
       concurrent [register] between save and install cannot be lost. *)
    let saved =
      Stdlib.Mutex.protect registry_mutex (fun () ->
        let s = !registered_probes_rev in
        registered_probes_rev := List.rev probes;
        s)
    in
    let restore () =
      Stdlib.Mutex.protect registry_mutex (fun () -> registered_probes_rev := saved)
    in
    Fun.protect ~finally:restore f
  ;;
end
