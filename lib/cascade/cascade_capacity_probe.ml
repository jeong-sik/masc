(** Provider-agnostic capacity probe adapter.

    Decouples keeper callers from provider-specific capacity probe
    implementations.  Each provider (Ollama, vLLM, etc.) registers a
    {!Probe}-conforming module; the resolution chain iterates registered
    probes in registration order.

    Resolution chain (identical semantics to the previous hardcoded chain):
    {ol
     {- [Cascade_throttle.capacity url]}
     {- Registered probes' [cached ~url]}
     {- [Cascade_client_capacity.capacity url]}}
    @since 0.10.0  *)

(* ── Module type ─────────────────────────────────────────────── *)

module type Probe = sig
  (** [can_probe ~url] is [true] when this probe knows how to query [url]. *)
  val can_probe : url:string -> bool

  (** [probe ~sw ~net ~url ?timeout_s ()] performs a live probe against [url],
      updates the probe's internal cache, and returns the result.
      Returns [None] on timeout, network error, or parse failure. *)
  val probe
    :  sw:Eio.Switch.t
    -> net:[> [> `Generic ] Eio.Net.ty ] Eio.Resource.t
    -> url:string
    -> ?timeout_s:float
    -> unit
    -> Cascade_throttle.capacity_info option

  (** [cached ~url ?now ()] reads the probe's cache.  Pure: no IO. *)
  val cached : url:string -> ?now:float -> unit -> Cascade_throttle.capacity_info option

  (** [refresh_many ~sw ~net ~urls ?timeout_s ()] probes every URL in [urls]
      that [can_probe] accepts and whose cache entry has expired. *)
  val refresh_many
    :  sw:Eio.Switch.t
    -> net:[> [> `Generic ] Eio.Net.ty ] Eio.Resource.t
    -> urls:string list
    -> ?timeout_s:float
    -> unit
    -> unit
end

(* ── Registry ────────────────────────────────────────────────── *)

type t = (module Probe)

(* Registry is stored as a reverse-order list and read via List.rev once
   per query. Append-only registration is O(1) instead of the previous
   O(n) [list @ [probe]] which reallocated the whole list each call. *)
let registered_probes_rev : t list ref = ref []
let registry_mutex = Stdlib.Mutex.create ()

let register (probe : t) =
  Stdlib.Mutex.protect registry_mutex (fun () ->
    registered_probes_rev := probe :: !registered_probes_rev)
;;

let probes () =
  Stdlib.Mutex.protect registry_mutex (fun () -> List.rev !registered_probes_rev)
;;

(* ── Resolution chain ────────────────────────────────────────── *)

let can_probe ~url = List.exists (fun (module P : Probe) -> P.can_probe ~url) (probes ())

let cached ~url ?now () =
  List.find_map
    (fun (module P : Probe) -> if P.can_probe ~url then P.cached ~url ?now () else None)
    (probes ())
;;

let capacity url =
  match Cascade_throttle.capacity url with
  | Some _ as v -> v
  | None ->
    (match cached ~url () with
     | Some _ as v -> v
     | None -> Cascade_client_capacity.capacity url)
;;

let probe ~sw ~net ~url ?timeout_s () =
  List.find_map
    (fun (module P : Probe) ->
       if P.can_probe ~url then P.probe ~sw ~net ~url ?timeout_s () else None)
    (probes ())
;;

let refresh_many ~sw ~net ~urls ?timeout_s () =
  List.iter
    (fun (module P : Probe) -> P.refresh_many ~sw ~net ~urls ?timeout_s ())
    (probes ())
;;

module For_testing = struct
  let clear_registry () =
    Stdlib.Mutex.protect registry_mutex (fun () -> registered_probes_rev := [])
  ;;

  let with_registry probes f =
    Stdlib.Mutex.protect registry_mutex (fun () ->
      let saved = !registered_probes_rev in
      registered_probes_rev := List.rev probes;
      let restore () =
        Stdlib.Mutex.protect registry_mutex (fun () -> registered_probes_rev := saved)
      in
      Fun.protect ~finally:restore f)
  ;;
end

(* ── Built-in probe registration ─────────────────────────────── *)

let () = register (module Cascade_http_probe.Http_probe)
