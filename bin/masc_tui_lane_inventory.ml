module Inventory = Masc.Tui_decode_lane_inventory
open Inventory

let family_label = function
  | Exact _ -> "Exact-output"
  | Browser _ -> "Browser"
  | Machine _ -> "Machines"
  | Declaration _ | Manual_instance _ -> "Packages"
let phase = function
  | Attached -> "attached"
  | Observing -> "observing"
  | Failed detail -> "failed: " ^ detail
  | Detaching -> "cleanup pending"
  | Detached -> "detached history"
let instance_summary (item : instance) =
  (match item.presence with Live -> "live " | Retained -> "retained ") ^ phase item.phase
let application_summary : Masc.Lane_addon_application.t -> string = function
  | Starting_worker -> "worker startup pending"
  | Cleaning_workers -> "worker cleanup pending"
  | Applied id -> "worker running: " ^ id
  | Inactive -> "worker cleanup confirmed"
  | Failed messages -> "application failed: " ^ String.concat "; " messages
  | Unknown messages -> "application unknown: " ^ String.concat "; " messages
let declaration_summary = function
  | Valid value -> (if value.enabled then "configured on" else "configured off") ^ "; " ^ application_summary value.application
  | Invalid _ -> "declaration invalid"
  | Absent -> "declaration absent"
  | Unobserved -> "declaration not observed"
let browser_activity_label = function
  | Browser_enabled -> "on"
  | Browser_disabled -> "off; configuration retained"
  | Browser_unobserved -> "activity unavailable"
let machine_activity_label = function
  | Machine_enabled -> "on"
  | Machine_disabled -> "off; machine state retained"
  | Machine_unobserved -> "activity unavailable"
let machine_publication_label = function
  | No_screen -> "no screen published"
  | Stable -> "screen stable"
  | Running -> "machine running"
  | Publication_unavailable -> "worker observation unavailable"
let row_summary (row : row) = match row.state with
  | Exact_state (Disabled _) -> "off; candidates retained"
  | Exact_state (Unconfigured _) -> "unconfigured"
  | Exact_state (Registry_unavailable _) -> "registry unavailable"
  | Exact_state (Configured c) ->
      if c.admitted_slots=[] && c.cli_slots=[] then "no admitted slots"
      else if Option.is_some c.admission_error then "admission issue"
      else Printf.sprintf "%d admitted slots" (List.length c.admitted_slots + List.length c.cli_slots)
  | Browser_clients (activity,n) -> browser_activity_label activity ^ "; " ^ Printf.sprintf "%d connected clients" n
  | Browser_executor (activity,registered) -> browser_activity_label activity ^ "; "
      ^ (if registered then "executor registered" else "executor not registered")
  | Machine_state (activity,publication) -> machine_activity_label activity ^ "; " ^ machine_publication_label publication
  | Package_state {declaration;instances} ->
      let declared = match declaration with
        | None -> "manual attachment"
        | Some value -> declaration_summary value in
      declared ^ " · " ^ (match instances with
        | [] -> "no worker observed"
        | values -> String.concat "; " (List.map instance_summary values))

let instance_lines (item : instance) =
  ["Instance: " ^ item.instance_id; "Incarnation: " ^ item.incarnation;
   "Run: " ^ item.run_id; "Package: " ^ item.package_id ^ " · " ^ item.package_revision;
   "Worker: " ^ instance_summary item]
  @ (match item.applied_revision with None -> [] | Some revision -> ["Applied declaration revision: " ^ revision])
let refused_cli_slot_lines
    (values : Masc.Keeper_lane_cli_oneshot.refused_slot list)
  =
  match values with
  | [] -> []
  | values ->
    [ "Refused CLI slots: "
      ^ String.concat
          ", "
          (List.map
             (fun (r : Masc.Keeper_lane_cli_oneshot.refused_slot) ->
                r.slot ^ " (" ^ Runtime.refusal_to_string r.refusal ^ ")")
             values)
    ]

let detail_lines (row : row) =
  [row.label; row.purpose; "Identity: " ^ row.id; "Reading: " ^ row_summary row]
  @ (match row.selection with
     | Exact _ -> ["Exact-output admission and retained run evidence are separate readings."]
     | Browser _ -> ["Opening this row reads the selected browser backend; it does not open a new session."]
     | Machine _ -> ["Activity configuration and the last published screen are separate readings."]
     | Declaration path -> ["TOML: " ^ path]
     | Manual_instance _ -> ["No declaration file; this is a manual attachment."])
  @ (match row.state with
     | Exact_state (Disabled c) ->
         ["New work is off; accepted runs finish with their acquired candidates.";
          "Declared HTTP slots: " ^ String.concat ", " c.declared_slots;
          "Declared CLI slots: " ^ String.concat ", " c.declared_cli_slots]
     | Exact_state (Configured c) ->
         let refused_cli =
           List.filter
             (fun slot -> not (List.mem slot c.cli_slots))
             c.declared_cli_slots
         in
         let refused_cli_lines =
           match row.selection, refused_cli with
           | _, [] -> []
           | Exact lane, refused ->
             let partitioned =
               Masc.Keeper_lane_cli_oneshot.partition_cli_slots
                 ~lane:(Runtime.requirement_of_exact_lane lane)
                 refused
             in
             (match partitioned.refused_cli_slots with
              | _ :: _ as typed_refusals -> refused_cli_slot_lines typed_refusals
              | [] -> ["Refused CLI slots: " ^ String.concat ", " refused])
           | (Browser _ | Machine _ | Declaration _ | Manual_instance _), refused ->
             ["Refused CLI slots: " ^ String.concat ", " refused]
         in
         ["Declared HTTP slots: " ^ String.concat ", " c.declared_slots;
          "Declared CLI slots: " ^ String.concat ", " c.declared_cli_slots]
         @ (match c.dropped_slots with [] -> [] | values -> ["Dropped HTTP slots: " ^ String.concat ", " values])
         @ refused_cli_lines
         @ (match c.admission_error with None -> [] | Some detail -> ["Admission: " ^ detail])
     | Exact_state (Unconfigured detail | Registry_unavailable detail) -> [detail]
     | Browser_clients _ -> ["Off refuses new requests while accepted requests finish."]
     | Browser_executor _ -> ["Off retains configuration and sessions; status and close remain available.";
         "Registration does not prove browser process health or an open session.";
         "Activity follows saved settings; executable and profile paths are installed at server startup."]
     | Machine_state _ -> ["Off refuses new execution and input; existing machine state and checkpoints are retained.";
         "Select this machine in All Lanes and press Space for activity settings."]
     | Package_state {declaration;instances} ->
         (match declaration with
          | None -> []
          | Some (Valid value) -> ["Installation: " ^ value.installation_id; "Run: " ^ value.run_id;
              "Package: " ^ value.package_id ^ " · " ^ value.title; "Desired revision: " ^ value.desired_revision; "Source revision: " ^ value.source_revision]
          | Some (Invalid messages) -> List.map (fun message -> "Declaration error: " ^ message) messages
          | Some Absent -> ["No declaration was observed in the complete directory reading; retained worker state is separate."]
          | Some Unobserved -> ["Directory reading is incomplete; declaration absence is not established."])
         @ List.concat_map instance_lines instances)

(* A package row's exact outputs, first and the rest, with the installation
   id their runtime.toml tables are named by. Only a valid declaration that
   lists one has any. *)
let exact_outputs (row : row) = match row.state with
  | Package_state {declaration = Some (Valid value); _} -> (match value.exact_outputs with
      | [] -> None
      | first :: rest -> Some (value.installation_id, first, rest))
  | Package_state {declaration = Some (Invalid _ | Absent | Unobserved) | None; _}
  | Exact_state _ | Browser_clients _ | Browser_executor _ | Machine_state _ -> None

let selected_exact_output ~selected (row : row) =
  Option.map (fun (installation_id, first, rest) ->
    let chosen = Option.bind selected (fun name ->
      List.find_opt (fun (o : exact_output) -> String.equal o.output name) (first :: rest)) in
    installation_id, Option.value chosen ~default:first) (exact_outputs row)

let step_exact_output ~selected ~direction (row : row) =
  Option.map (fun (installation_id, first, rest) ->
    let outputs = Array.of_list (first :: rest) in
    let current = match selected_exact_output ~selected row with
      | Some (_, chosen) ->
          Option.value ~default:0
            (Array.find_index (fun (o : exact_output) -> String.equal o.output chosen.output) outputs)
      | None -> 0 in
    let next = max 0 (min (Array.length outputs - 1) (current + direction)) in
    installation_id, outputs.(next).output) (exact_outputs row)

let exact_output_table_path ~installation_id (o : exact_output) =
  Result.map (fun addon -> Runtime_schema.exact_lane_table_path (Runtime_schema.Addon addon))
    (Runtime_schema.addon_lane ~declaration_id:installation_id ~output:o.output)

let exact_output_state (o : exact_output) =
  (match o.configuration with
   | Configured c -> (match c.admitted_slots @ c.cli_slots with
       | [] -> "bound, no admitted slot"
       | slots -> "bound: " ^ String.concat ", " slots)
   | Disabled _ -> "off"
   | Unconfigured _ -> "unbound"
   | Registry_unavailable detail -> "unavailable: " ^ detail)
  ^ (match o.source with Declared -> "" | Table_only -> " · the package declares no such output")

let exact_output_lines ~selected (row : row) =
  match selected_exact_output ~selected row, exact_outputs row with
  | Some (_, chosen), Some (_, first, rest) ->
      "Exact outputs ([ / ] choose, e opens its runtime.toml table):"
      :: List.map (fun (o : exact_output) ->
           (if String.equal o.output chosen.output then "› " else "  ") ^ o.output ^ " · " ^ exact_output_state o)
           (first :: rest)
  | None, _ | _, None -> []

let reading_notices (snapshot : snapshot) =
  (if snapshot.package_read.complete then [] else ["Package inventory is incomplete; missing entries do not prove removal."])
  @ (if snapshot.package_read.owner_present then [] else ["Package runtime owner has not been observed; declarations and retained bindings remain listed."])

let exact_notices (snapshot : snapshot) =
  if snapshot.exact_snapshot.sls_exact_run_projection_truncated then
    [Printf.sprintf "Exact run observations are windowed: %d/%d retained runs. Counts and timings describe this window."
      snapshot.exact_snapshot.sls_exact_run_projection_count snapshot.exact_snapshot.sls_exact_run_source_total]
  else []

let overview_notices (snapshot : snapshot) =
  exact_notices snapshot @
  reading_notices snapshot
  @ (match snapshot.package_read.issues with
     | [] -> []
     | issues -> [Printf.sprintf "%d inventory issues · i: details" (List.length issues)])
let snapshot_notices (snapshot : snapshot) =
  exact_notices snapshot @
  reading_notices snapshot
  @ List.map (fun (path,message) -> path ^ ": " ^ message) snapshot.package_read.issues

let row_summary_in (snapshot : snapshot) (row : row) =
  let admission = row_summary row in
  match row.selection with
  | Exact target ->
      (match List.find_opt (fun (lane : Masc.Tui_decode.standalone_lane) ->
           Standalone_lane.equal lane.sl_lane target) snapshot.exact_snapshot.sls_lanes with
       | None -> admission
       | Some lane ->
           let observation = match lane.sl_status with
             | Masc.Tui_decode.Standalone_off -> Printf.sprintf "off · %d finishing" lane.sl_running_count
             | Masc.Tui_decode.Standalone_running -> Printf.sprintf "%d running" lane.sl_running_count
             | Standalone_idle -> "idle"
             | Standalone_degraded -> "needs attention"
             | Standalone_unavailable -> "unavailable"
             | Standalone_no_retained_observation -> "no retained runs" in
           observation ^ " · " ^ admission)
  | Browser _ | Machine _ | Declaration _ | Manual_instance _ -> admission
