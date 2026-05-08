(* RFC-0049 — dashboard surface/section open counters. *)

type event =
  { surface : string
  ; section : string option
  ; redirected_from : string option
  }

(* Mirror of dashboard/src/types/sse.ts:VALID_TABS. *)
let valid_surfaces =
  [ "cockpit"
  ; "overview"
  ; "monitoring"
  ; "command"
  ; "connectors"
  ; "workspace"
  ; "lab"
  ; "code"
  ; "logs"
  ]
;;

(* Mirror of dashboard/src/config/navigation.ts:DASHBOARD_SECTION_ITEMS.
   Includes hidden sections (observatory, memory-subsystems) because they
   remain reachable via redirects and continue to fire telemetry. *)
let valid_sections =
  [ ( "monitoring"
    , [ "journey"
      ; "observatory"
      ; "agents"
      ; "cognition"
      ; "runtime"
      ; "goal-loop"
      ; "fleet-health"
      ; "memory-subsystems"
      ] )
  ; "command", [ "operations" ]
  ; "connectors", [ "connector-status" ]
  ; "workspace", [ "board"; "sub-boards"; "planning"; "repositories"; "verification" ]
  ; "lab", [ "tools"; "autoresearch"; "harness" ]
  ; "code", [ "ide-shell" ]
  ]
;;

let is_valid_surface s = List.mem s valid_surfaces

let is_valid_section ~surface section =
  match List.assoc_opt surface valid_sections with
  | None -> false
  | Some sections -> List.mem section sections
;;

let counter_surface = "dashboard_surface_open_total"
let counter_section = "dashboard_section_open_total"

let () =
  Prometheus.register_counter
    ~name:counter_surface
    ~help:"Top-level dashboard surface opens (RFC-0049). Aggregate, no PII."
    ()
;;

let () =
  Prometheus.register_counter
    ~name:counter_section
    ~help:
      "Section-level opens within a dashboard surface (RFC-0049). redirected_from \
       carries the original surface:section key when the route arrived through \
       CROSS_SURFACE_SECTION_REDIRECTS, otherwise \"none\". Aggregate, no PII."
    ()
;;

let parse_redirected_from ~target_surface ~target_section raw =
  match String.index_opt raw ':' with
  | None -> Error (Printf.sprintf "redirected_from missing ':' separator: %s" raw)
  | Some idx ->
    let from_surface = String.sub raw 0 idx in
    let from_section = String.sub raw (idx + 1) (String.length raw - idx - 1) in
    if not (is_valid_surface from_surface)
    then
      Error (Printf.sprintf "redirected_from references unknown surface: %s" from_surface)
    else if from_surface = target_surface && Some from_section = target_section
    then Error "redirected_from must differ from the resolved (surface, section)"
    else if not (is_valid_section ~surface:from_surface from_section)
    then
      (* The original section may have been deleted but the redirect
           survives; we still require the surface to be known. Allowlist
           is "known surfaces", not "known sections" for the *from* side. *)
      Ok raw
    else Ok raw
;;

let parse_event_json json =
  let open Yojson.Safe.Util in
  try
    let surface =
      match member "surface" json with
      | `String s -> s
      | `Null -> raise (Type_error ("missing surface", json))
      | _ -> raise (Type_error ("surface must be string", json))
    in
    if not (is_valid_surface surface)
    then Error (Printf.sprintf "unknown surface: %s" surface)
    else (
      let section =
        match member "section" json with
        | `Null -> None
        | `String "" -> None
        | `String s -> Some s
        | _ -> raise (Type_error ("section must be string or null", json))
      in
      let section_ok =
        match section with
        | None -> Ok ()
        | Some s ->
          if is_valid_section ~surface s
          then Ok ()
          else Error (Printf.sprintf "unknown section %s for surface %s" s surface)
      in
      match section_ok with
      | Error e -> Error e
      | Ok () ->
        let redirected_from_result =
          match member "redirected_from" json with
          | `Null -> Ok None
          | `String "" -> Ok None
          | `String "none" -> Ok None
          | `String raw ->
            (match
               parse_redirected_from ~target_surface:surface ~target_section:section raw
             with
             | Ok v -> Ok (Some v)
             | Error e -> Error e)
          | _ -> Error "redirected_from must be string or null"
        in
        (match redirected_from_result with
         | Error e -> Error e
         | Ok redirected_from -> Ok { surface; section; redirected_from }))
  with
  | Type_error (msg, _) -> Error msg
  | Yojson.Json_error msg -> Error msg
;;

let record { surface; section; redirected_from } =
  Prometheus.inc_counter counter_surface ~labels:[ "surface", surface ] ~delta:1.0 ();
  match section with
  | None -> ()
  | Some s ->
    let labels =
      [ "surface", surface
      ; "section", s
      ; "redirected_from", Option.value ~default:"none" redirected_from
      ]
    in
    Prometheus.inc_counter counter_section ~labels ~delta:1.0 ()
;;
