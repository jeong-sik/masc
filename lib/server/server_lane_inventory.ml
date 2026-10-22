module Exact_projection = Server_standalone_lane_projection
module Config = Lane_addon_config
module Addon = Lane_addon_runtime

type selection =
  | Exact of Standalone_lane.t
  | Browser of Browser_lane.Lane_name.t
  | Machine of Machine_lane.t
  | Declaration of string
  | Manual_instance of { instance_id : string; incarnation : string }
type exact_output_source = Declared | Table_only
type exact_output = { output : string; source : exact_output_source; configuration : Exact_projection.lane_configuration }
type declaration =
  | Valid of { declaration : Config.declaration; exact_outputs : exact_output list; application : Lane_addon_application.t }
  | Invalid of string list | Absent | Unobserved
type machine_publication = No_screen | Stable | Running | Publication_unavailable
(* The server process holds no browser clients or executors of its own:
   since #44295 they live in the browser Add-on worker, so the built-in
   browser rows read its cached observation. *)
type 'a browser_reading =
  | Browser_observed of 'a
  | Browser_addon_absent
  | Browser_addon_off
  | Browser_addon_not_running
  | Browser_addon_unavailable of string
type state =
  | Exact_state of Exact_projection.lane_configuration
  | Browser_clients of Browser_lane.activity * int browser_reading
  | Browser_executor of Browser_lane.activity * bool browser_reading
  | Machine_state of Machine_configuration.activity * machine_publication
  | Package_state of { declaration : declaration option; instances : Addon.inventory_instance list }
type row = { id : string; label : string; purpose : string; selection : selection; state : state }
type t = {
  observed_at : float; rows : row list; exact : Exact_projection.observation;
  directory : string; complete : bool; owner_present : bool;
  issues : (string * string) list;
}

(* An output runtime.toml cannot name has no table to read; it is unbound,
   and the reason says why. *)
let exact_outputs ~configuration ~tables (d : Config.declaration) =
  let declared = List.map (fun (output : Lane_addon_types.exact_output) -> output.name) d.package.exact_outputs in
  let entry source output =
    let configuration = match Runtime_schema.addon_lane ~declaration_id:d.id ~output with
      | Ok addon -> configuration addon
      | Error reason -> Exact_projection.Unconfigured ("runtime.toml cannot name this output: " ^ reason) in
    {output; source; configuration} in
  List.map (entry Declared) declared
  @ List.map (entry Table_only)
      (List.filter (fun output -> not (List.mem output declared)) (tables ~declaration_id:d.id))

let package_rows ~(declarations : Config.snapshot) ~(instances : Addon.inventory_instance list) ~applications ~exact_outputs =
  let declaration_paths = declarations.paths
    @ List.map (fun (d : Config.declaration) -> d.source_path) declarations.declarations in
  let unresolved (i : Addon.inventory_instance) = match i.phase with
    | Lane_addon_types.Detached -> false
    | Attached | Observing | Failed _ | Detaching -> true in
  let paths = List.sort_uniq String.compare (declarations.paths
    @ List.map (fun (d : Config.declaration) -> d.source_path) declarations.declarations
    @ List.filter_map (fun (i : Addon.inventory_instance) ->
        Option.bind i.configuration (fun (owner : Addon.configuration_owner) ->
          if unresolved i || not declarations.complete || List.mem owner.source_path declaration_paths
          then Some owner.source_path else None)) instances) in
  let declared = List.map (fun source_path ->
    let installed = List.filter (fun (i : Addon.inventory_instance) ->
      unresolved i && Option.exists (fun (owner : Addon.configuration_owner) -> owner.source_path=source_path) i.configuration) instances in
    let declaration = match List.find_opt (fun (d : Config.declaration) -> d.source_path=source_path) declarations.declarations with
      | Some d ->
          let application = if not declarations.complete then
              Lane_addon_application.Unknown ["Declaration inventory is incomplete"]
            else match List.filter (fun (observed : Addon.configuration_application) ->
              observed.owner.id=d.id && observed.owner.source_path=d.source_path
              && observed.source_revision=d.source_revision && observed.owner.revision=d.revision
              && observed.enabled=d.enabled) applications with
              | [observed] -> observed.application
              | [] -> Lane_addon_application.Unknown ["No application observation matches this declaration revision"]
              | _ :: _ -> Lane_addon_application.Unknown ["Application observation identity is ambiguous"] in
          Valid {declaration=d; exact_outputs=exact_outputs d;application}
      | None ->
          (match List.filter_map (fun (issue : Config.issue) ->
             if issue.source_path=source_path then Some issue.message else None) declarations.issues with
           | _::_ as errors -> Invalid errors
           | [] when declarations.complete -> Absent
           | [] -> Unobserved) in
    {id="declaration/" ^ source_path; label=Filename.basename source_path;
     purpose="Package declaration and its owned observation workers.";
     selection=Declaration source_path;
     state=Package_state {declaration=Some declaration; instances=installed}}) paths in
  let manual = List.filter_map (fun (i : Addon.inventory_instance) -> match i.configuration with
    | Some _ -> None
    | None when not (unresolved i) -> None
    | None -> Some {id="instance/" ^ i.instance_id; label=i.title;
        purpose="Manual package attachment; no declaration file.";
        selection=Manual_instance {instance_id=i.instance_id;incarnation=i.incarnation};
        state=Package_state {declaration=None;instances=[i]}}) instances in
  declared @ manual

let machine_publication = function
  | Error _ -> Publication_unavailable
  | Ok None -> No_screen
  | Ok (Some (snapshot : Addon.export_observation)) ->
      let loaded = List.filter_map (fun (row : Lane_addon_types.row) ->
        List.assoc_opt "machine_loaded" row.fields) snapshot.output.rows in
      match loaded with
      | [`Bool false] -> No_screen
      | [`Bool true] -> if snapshot.refreshing then Running else Stable
      | _ -> Publication_unavailable

let machine_state ~config ~configuration machine =
  let activity = match configuration with
    | None -> Machine_configuration.Unobserved
    | Some configuration ->
        let enabled = match machine with
          | Machine_lane.Msx -> configuration.Machine_configuration.msx_enabled
          | Machine_lane.Dos -> configuration.Machine_configuration.dos_enabled in
        if enabled then Machine_configuration.Enabled else Disabled in
  let name = match machine with Machine_lane.Msx -> "masc_msx_screen" | Dos -> "masc_dos_screen" in
  let publication = Addon.observation_for_export ~config ~access:Lane_addon_sources.Unauthenticated ~name
    |> machine_publication in
  Machine_state (activity,publication)

(* With no observation, the declarations say which absence it is: none
   declared, one switched off, or one switched on that the runtime runs no
   installation of. A browser Add-on is a package whose worker serves the
   browser. *)
let browser_absence (declarations : Config.declaration list) =
  let browsers = List.filter (fun (d : Config.declaration) ->
    match d.package.worker_service with
    | Lane_addon_types.Browser_service -> true
    | Lane_addon_types.Mcp_tools -> false) declarations in
  if List.exists (fun (d : Config.declaration) -> d.enabled) browsers then Browser_addon_not_running
  else match browsers with [] -> Browser_addon_absent | _ :: _ -> Browser_addon_off
let browser_reading ~declarations = function
  | Error detail -> Browser_addon_unavailable detail
  | Ok None -> browser_absence declarations
  | Ok (Some (snapshot : Addon.export_observation)) ->
      (match Browser_addon_observation.read snapshot.output with
       | Ok published -> Browser_observed published
       | Error detail -> Browser_addon_unavailable ("its observation is unreadable: " ^ detail))
(* Read once per snapshot, so the three browser rows describe one
   observation. *)
let browser_publication ~config ~declarations =
  Addon.observation_for_export ~config ~access:Lane_addon_sources.Operator_configuration
    ~name:Browser_addon_tool.definition.name
  |> browser_reading ~declarations
let browser_map f = function
  | Browser_observed value -> Browser_observed (f value)
  | Browser_addon_absent -> Browser_addon_absent
  | Browser_addon_off -> Browser_addon_off
  | Browser_addon_not_running -> Browser_addon_not_running
  | Browser_addon_unavailable detail -> Browser_addon_unavailable detail
let browser_state ~activity publication = function
  | Browser_lane.Lane_name.Live ->
      Browser_clients (activity, browser_map (fun (p : Browser_addon_observation.published) ->
        List.length p.clients) publication)
  | Browser_lane.Lane_name.Automation ->
      Browser_executor (activity, browser_map (fun (p : Browser_addon_observation.published) ->
        p.automation.registered) publication)
  | Browser_lane.Lane_name.Stagehand ->
      Browser_executor (activity, browser_map (fun (p : Browser_addon_observation.published) ->
        p.stagehand.registered) publication)

let snapshot ~config =
  let exact = Exact_projection.observe () in
  let browser_activity = Server_browser_configuration.activity_snapshot () in
  let machine_configuration = Runtime.machine_configuration () in
  let resolution = Config_dir_resolver.resolve_for_base_path ~base_path:config.Workspace.base_path in
  let directory = Config.directory ~config_root:resolution.config_root.path in
  let declarations : Config.snapshot = match resolution.status with
    | Config_dir_resolver.Invalid_env_status ->
        {declarations=[];paths=[];complete=false;
         issues=[{source_path=directory;id=None;message=String.concat "; " resolution.warnings}]}
    | Ready | Warn | Missing_status ->
        Eio_unix.run_in_systhread (fun () -> Config.load ~directory) in
  let browser_publication = browser_publication ~config ~declarations:declarations.declarations in
  let builtin = Lane_id.all_of_builtin |> List.map (fun lane ->
    let selection,state = match lane with
      | Lane_id.Exact id -> Exact id,Exact_state (Exact_projection.configuration exact id)
      | Lane_id.Browser id ->
          Browser id,browser_state ~activity:(browser_activity id) browser_publication id
      | Lane_id.Machine id -> Machine id,machine_state ~config ~configuration:machine_configuration id in
    {id=Lane_id.to_wire (Lane_id.Builtin lane); label=Lane_manifest.label lane;
     purpose=Lane_manifest.purpose lane; selection; state}) in
  let packages = Addon.inventory ~config in
  let exact_outputs = exact_outputs ~configuration:(Exact_projection.addon_configuration exact)
      ~tables:(Exact_projection.addon_tables exact) in
  {observed_at=Time_compat.now (); rows=builtin @ package_rows ~declarations ~instances:packages.instances ~applications:packages.applications ~exact_outputs;
   exact;directory;complete=declarations.complete && packages.complete;
   owner_present=packages.owner_present;
   issues=List.map (fun (issue : Config.issue) -> issue.source_path,issue.message) declarations.issues
          @ List.map (fun (issue : Addon.inventory_issue) ->
              issue.issue_path,Addon.retained_fault_message issue.issue_reason) packages.issues}

let str s = `String s
let strings values = `List (List.map str values)
let optional f = function None -> `Null | Some value -> f value
let selection_json = function
  | Exact lane -> `Assoc ["kind",str "exact";"lane_id",str (Standalone_lane.to_id lane)]
  | Browser lane -> `Assoc ["kind",str "browser";"lane",str (Browser_lane.Lane_name.to_wire lane)]
  | Machine machine -> `Assoc ["kind",str "machine";"machine",str (Machine_lane.to_wire machine)]
  | Declaration path -> `Assoc ["kind",str "declaration";"source_path",str path]
  | Manual_instance {instance_id;incarnation} ->
      `Assoc ["kind",str "manual_instance";"instance_id",str instance_id;"incarnation",str incarnation]
let configuration_json = function
  | Exact_projection.Disabled c -> `Assoc ["kind",str "off";
      "declared_slots",strings c.declared_slots;"declared_cli_slots",strings c.declared_cli_slots]
  | Exact_projection.Configured c -> `Assoc ["kind",str "configured";
      "admitted_slots",strings c.admitted_slots;"cli_slots",strings c.cli_slots;
      "declared_slots",strings c.declared_slots;"declared_cli_slots",strings c.declared_cli_slots;
      "dropped_slots",strings c.dropped_slots;"admission_error",optional str c.admission_error]
  | Exact_projection.Unconfigured detail -> `Assoc ["kind",str "unconfigured";"detail",str detail]
  | Exact_projection.Registry_unavailable detail -> `Assoc ["kind",str "unavailable";"detail",str detail]
let exact_output_json {output;source;configuration} = `Assoc ["output",str output;
  "source",str (match source with Declared -> "declared" | Table_only -> "table_only");
  "configuration",configuration_json configuration]
let declaration_json = function
  | Valid {declaration=d;exact_outputs;application} -> `Assoc ["kind",str "valid";"enabled",`Bool d.enabled;"installation_id",str d.id;
      "run_id",str d.run_id;"package_id",str d.package.id;"title",str d.package.title;"desired_revision",str d.revision;
      "source_revision",str d.source_revision;"application",Lane_addon_application.to_json application;
      "exact_outputs",`List (List.map exact_output_json exact_outputs)]
  | Invalid messages -> `Assoc ["kind",str "invalid";"messages",strings messages]
  | Absent -> `Assoc ["kind",str "absent"]
  | Unobserved -> `Assoc ["kind",str "unobserved"]
let instance_json (i : Addon.inventory_instance) = `Assoc [
  "instance_id",str i.instance_id;"incarnation",str i.incarnation;"run_id",str i.run_id;
  "package_id",str i.package_id;"title",str i.title;"package_revision",str i.package_revision;
  "presence",str (match i.presence with Addon.Live -> "live" | Addon.Retained -> "retained");
  "phase",Lane_addon_types.phase_to_json i.phase;
  "applied_revision",optional (fun (o : Addon.configuration_owner) -> str o.revision) i.configuration]
let browser_activity_json = function
  | Browser_lane.Enabled -> str "on"
  | Disabled -> str "off"
  | Unobserved -> str "unobserved"
let browser_reading_json fields = function
  | Browser_observed value -> `Assoc (("kind",str "observed") :: fields value)
  | Browser_addon_absent -> `Assoc ["kind",str "absent"]
  | Browser_addon_off -> `Assoc ["kind",str "off"]
  | Browser_addon_not_running -> `Assoc ["kind",str "not_running"]
  | Browser_addon_unavailable detail -> `Assoc ["kind",str "unavailable";"detail",str detail]
let state_json = function
  | Exact_state configuration -> `Assoc ["kind",str "exact";"configuration",configuration_json configuration]
  | Browser_clients (activity,reading) -> `Assoc ["kind",str "browser_clients";"activity",browser_activity_json activity;
      "addon",browser_reading_json (fun count -> ["connected_clients",`Int count]) reading]
  | Browser_executor (activity,reading) -> `Assoc ["kind",str "browser_executor";"activity",browser_activity_json activity;
      "addon",browser_reading_json (fun registered -> ["registered",`Bool registered]) reading]
  | Machine_state (activity,publication) -> `Assoc ["kind",str "machine";
      "activity",str (Machine_configuration.activity_to_wire activity);
      "publication",str (match publication with No_screen -> "no_screen" | Stable -> "stable" | Running -> "running" | Publication_unavailable -> "unavailable")]
  | Package_state {declaration;instances} -> `Assoc ["kind",str "package";
      "declaration",optional declaration_json declaration;"instances",`List (List.map instance_json instances)]
let row_to_json row = `Assoc ["id",str row.id;"label",str row.label;"purpose",str row.purpose;
  "selection",selection_json row.selection;"state",state_json row.state]
let to_json t = `Assoc ["schema",str "masc.lane-inventory/v1";"observed_at",`Float t.observed_at;
  "rows",`List (List.map row_to_json t.rows);"exact_snapshot",Exact_projection.observation_to_json t.exact;
  "package_read",`Assoc ["directory",str t.directory;"complete",`Bool t.complete;
    "owner_present",`Bool t.owner_present;"issues",`List (List.map (fun (path,detail) ->
      `Assoc ["source_path",str path;"message",str detail]) t.issues)]]
module For_testing = struct
  let machine_publication = machine_publication
  let browser_reading = browser_reading
  let browser_state = browser_state
  let package_rows = package_rows
  let exact_outputs = exact_outputs
  let row_to_json = row_to_json
end
