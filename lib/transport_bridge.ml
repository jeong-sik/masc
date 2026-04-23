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

(* Providers stored in registration order.
   The registry is mutable only during bootstrap (single fiber).
   After [seal] is called, further registration raises [Invalid_argument].
   Reads from multiple fibers are safe because OCaml ref reads are
   atomic at the word level, and the list is never mutated post-seal. *)
let registry : (module PROVIDER) list ref = ref []
let sealed = ref false

let seal () = sealed := true

let register_provider (p : (module PROVIDER)) =
  if !sealed then
    invalid_arg "Transport_bridge.register_provider: registry sealed after bootstrap"
  else begin
    let module P = (val p : PROVIDER) in
    (* Replace existing with same name *)
    registry := List.filter (fun m ->
      let module M = (val m : PROVIDER) in
      M.name <> P.name
    ) !registry;
    registry := !registry @ [ p ]
  end

let providers () = !registry

let provider_by_name name =
  List.find_opt (fun m ->
    let module M = (val m : PROVIDER) in
    M.name = name
  ) !registry

(* ── Aggregate Operations ─────────────────────────────── *)

let total_session_count () =
  List.fold_left (fun acc m ->
    let module M = (val m : PROVIDER) in
    if M.is_enabled () then acc + M.session_count ()
    else acc
  ) 0 !registry

let status_all_json () =
  `Assoc (List.map (fun m ->
    let module M = (val m : PROVIDER) in
    (M.name, `Assoc [
      "enabled", `Bool (M.is_enabled ());
      "protocol", `String (Transport.protocol_to_string M.protocol);
      "sessions", `Int (M.session_count ());
      "detail", M.status_json ();
    ])
  ) !registry)

let reap_all_stale () =
  List.fold_left (fun acc m ->
    let module M = (val m : PROVIDER) in
    if M.is_enabled () then acc + M.reap_stale ()
    else acc
  ) 0 !registry

let enabled_protocols () =
  List.filter_map (fun m ->
    let module M = (val m : PROVIDER) in
    if M.is_enabled () then Some M.protocol
    else None
  ) !registry

(* ── Agent Card ───────────────────────────────────────── *)

let agent_card_transports_json ~host ~port =
  let entries = List.filter_map (fun m ->
    let module M = (val m : PROVIDER) in
    if M.is_enabled () then
      Some (`Assoc [
        "protocol", `String (Transport.protocol_to_string M.protocol);
        "name", `String M.name;
        "sessions", `Int (M.session_count ());
      ])
    else None
  ) !registry in
  `Assoc [
    "host", `String host;
    "port", `Int port;
    "active_transports", `List entries;
    "total_sessions", `Int (total_session_count ());
  ]
