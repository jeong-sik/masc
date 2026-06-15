(** Transport_bridge — Unified transport provider registry.

    Pure registry module. Has no dependencies on specific transport
    implementations — providers are registered via bootstrap. *)

module type PROVIDER = sig
  val name : string
  val protocol : Transport.protocol
  val is_enabled : unit -> bool
  val session_count : unit -> int
  val status_json : unit -> Yojson.Safe.t
  val reap_stale : unit -> int
end

(* ── Registry ─────────────────────────────────────────── *)

(* Providers stored in registration order. The registry is mutable only during
   bootstrap, but concurrent registration/read is possible, so the list is kept
   in an [Atomic.t]. [register_provider] uses compare-and-swap retry to keep
   updates race-free; after [seal] is called, further registration raises
   [Invalid_argument]. *)
let registry : (module PROVIDER) list Atomic.t = Atomic.make []
let sealed = Atomic.make false

let seal () = Atomic.set sealed true

let register_provider (p : (module PROVIDER)) =
  if Atomic.get sealed then
    invalid_arg "Transport_bridge.register_provider: registry sealed after bootstrap"
  else begin
    let module P = (val p : PROVIDER) in
    let rec update () =
      let cur = Atomic.get registry in
      (* Replace existing with same name *)
      let filtered =
        List.filter
          (fun m ->
             let module M = (val m : PROVIDER) in
             M.name <> P.name)
          cur
      in
      let next = filtered @ [ p ] in
      if not (Atomic.compare_and_set registry cur next) then update ()
    in
    update ()
  end

let providers () = Atomic.get registry

let provider_by_name name =
  List.find_opt
    (fun m ->
       let module M = (val m : PROVIDER) in
       M.name = name)
    (Atomic.get registry)

(* ── Aggregate Operations ─────────────────────────────── *)

let total_session_count () =
  List.fold_left
    (fun acc m ->
       let module M = (val m : PROVIDER) in
       if M.is_enabled () then acc + M.session_count () else acc)
    0
    (Atomic.get registry)

let status_all_json () =
  `Assoc
    (List.map
       (fun m ->
          let module M = (val m : PROVIDER) in
          ( M.name,
            `Assoc
              [
                "enabled", `Bool (M.is_enabled ());
                "protocol", `String (Transport.protocol_to_string M.protocol);
                "sessions", `Int (M.session_count ());
                "detail", M.status_json ();
              ] ))
       (Atomic.get registry))

let reap_all_stale () =
  List.fold_left
    (fun acc m ->
       let module M = (val m : PROVIDER) in
       if M.is_enabled () then acc + M.reap_stale () else acc)
    0
    (Atomic.get registry)

let enabled_protocols () =
  List.filter_map
    (fun m ->
       let module M = (val m : PROVIDER) in
       if M.is_enabled () then Some M.protocol else None)
    (Atomic.get registry)

(* ── Agent Card ───────────────────────────────────────── *)

let agent_card_transports_json ~host ~port =
  let entries =
    List.filter_map
      (fun m ->
         let module M = (val m : PROVIDER) in
         if M.is_enabled () then
           Some
             (`Assoc
                [
                  "protocol", `String (Transport.protocol_to_string M.protocol);
                  "name", `String M.name;
                  "sessions", `Int (M.session_count ());
                ])
         else None)
      (Atomic.get registry)
  in
  `Assoc [
    "host", `String host;
    "port", `Int port;
    "active_transports", `List entries;
    "total_sessions", `Int (total_session_count ());
  ]
