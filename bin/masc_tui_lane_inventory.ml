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
let declaration_summary = function
  | Valid value -> if value.enabled then "enabled" else "configured off"
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
      let declared = match declaration, instances with
        | None, _ -> "manual attachment"
        | Some (Valid {enabled=false;_}), _::_ -> "off requested"
        | Some value, _ -> declaration_summary value in
      declared ^ " · " ^ (match instances with
        | [] -> "no worker observed"
        | values -> String.concat "; " (List.map instance_summary values))

let instance_lines (item : instance) =
  ["Instance: " ^ item.instance_id; "Incarnation: " ^ item.incarnation;
   "Run: " ^ item.run_id; "Package: " ^ item.package_id ^ " · " ^ item.package_revision;
   "Worker: " ^ instance_summary item]
  @ (match item.applied_revision with None -> [] | Some revision -> ["Applied declaration revision: " ^ revision])
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
         ["Declared HTTP slots: " ^ String.concat ", " c.declared_slots;
          "Declared CLI slots: " ^ String.concat ", " c.declared_cli_slots]
         @ (match c.dropped_slots with [] -> [] | values -> ["Dropped HTTP slots: " ^ String.concat ", " values])
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
              "Package: " ^ value.package_id ^ " · " ^ value.title; "Desired revision: " ^ value.desired_revision]
          | Some (Invalid messages) -> List.map (fun message -> "Declaration error: " ^ message) messages
          | Some Absent -> ["No declaration was observed in the complete directory reading; retained worker state is separate."]
          | Some Unobserved -> ["Directory reading is incomplete; declaration absence is not established."])
         @ List.concat_map instance_lines instances)

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
