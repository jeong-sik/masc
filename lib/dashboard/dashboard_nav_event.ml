(* RFC-0049 — dashboard surface/section open counters. *)

type event =
  { surface : string
  ; section : string option
  }

(* Mirror of dashboard/src/types/sse.ts:VALID_TABS. *)
let valid_surfaces =
  [ "overview"
  ; "monitoring"
  ; "keepers"
  ; "registry"
  ; "board"
  ; "schedule"
  ; "fusion"
  ; "command"
  ; "connectors"
  ; "workspace"
  ; "lab"
  ; "code"
  ; "logs"
  ; "settings"
  ; "approvals"
  ]
;;

(* Mirror of dashboard/src/config/navigation.ts:DASHBOARD_SECTION_ITEMS.
   Hidden support sections remain directly reachable and continue to fire
   telemetry. *)
let valid_sections =
  [ ( "monitoring"
    , [ "observatory"
      ; "agents"
      ; "runtime"
      ; "internal-agents"
      ; "fleet-health"
      ; "lanes"
      ; "lane-addons"
      ; "lane-inventory"
      ; "transport-health"
      ; "journey"
      ; "skills"
      ] )
  ; "command", [ "operations" ]
  ; "connectors", [ "connector-status" ]
  ; ( "workspace"
    , [ "board"
      ; "sub-boards"
      ; "planning"
      ; "repositories"
      ; "verification"
      ; "work"
      ; "artifacts"
      ] )
  ; "lab", [ "tools"; "harness"; "keeper-memory-health" ]
  ; "code", [ "ide-shell" ]
  ; ( "settings"
    , [ "account"
      ; "runtime"
      ; "routing"
      ; "runtimes"
      ; "paths"
      ; "mcp"
      ; "repositories"
      ; "notify"
      ; "prompts"
      ; "fusion"
      ; "logs"
      ; "display"
      ] )
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
  Otel_metric_store.register_counter
    ~name:counter_surface
    ~help:"Top-level dashboard surface opens (RFC-0049). Aggregate, no PII."
    ()
;;

let () =
  Otel_metric_store.register_counter
    ~name:counter_section
    ~help:"Section-level opens within a dashboard surface. Aggregate, no PII."
    ()
;;

let parse_event_json json =
  let m key = Option.value ~default:`Null (Json_util.assoc_member_opt key json) in
  try
    let surface =
      match m "surface" with
      | `String s -> s
      | `Null -> raise (Yojson.Safe.Util.Type_error ("missing surface", json))
      | _ -> raise (Yojson.Safe.Util.Type_error ("surface must be string", json))
    in
    if not (is_valid_surface surface)
    then Error (Printf.sprintf "unknown surface: %s" surface)
    else (
      let section =
        match m "section" with
        | `Null -> None
        | `String "" -> None
        | `String s -> Some s
        | _ -> raise (Yojson.Safe.Util.Type_error ("section must be string or null", json))
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
      | Ok () -> Ok { surface; section })
  with
  | Yojson.Safe.Util.Type_error (msg, _) -> Error msg
  | Yojson.Json_error msg -> Error msg
;;

let record { surface; section } =
  Otel_metric_store.inc_counter counter_surface ~labels:[ "surface", surface ] ~delta:1.0 ();
  match section with
  | None -> ()
  | Some s ->
    let labels = [ "surface", surface; "section", s ] in
    Otel_metric_store.inc_counter counter_section ~labels ~delta:1.0 ()
;;
