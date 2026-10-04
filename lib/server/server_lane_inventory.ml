module Exact_projection = Server_standalone_lane_projection
module Config = Lane_addon_config
module Addon = Lane_addon_runtime

type selection =
  | Exact of Standalone_lane.t
  | Browser of Browser_lane.Lane_name.t
  | Machine of Machine_lane.t
  | Declaration of string
  | Manual_instance of { instance_id : string; incarnation : string }
type declaration = Valid of Config.declaration | Invalid of string list | Absent | Unobserved
type machine_publication = No_screen | Stable | Running
type state =
  | Exact_state of Exact_projection.lane_configuration
  | Browser_clients of Browser_lane.activity * int
  | Browser_executor of Browser_lane.activity * bool
  | Machine_state of Machine_configuration.activity * machine_publication
  | Package_state of { declaration : declaration option; instances : Addon.inventory_instance list }
type row = { id : string; label : string; purpose : string; selection : selection; state : state }
type t = {
  observed_at : float; rows : row list; exact : Exact_projection.observation;
  directory : string; complete : bool; owner_present : bool;
  issues : (string * string) list;
}

let package_rows ~(declarations : Config.snapshot) ~(instances : Addon.inventory_instance list) =
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
      | Some d -> Valid d
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
  | Machine_live_publication.No_screen -> No_screen
  | Machine_live_publication.Stable _ -> Stable
  | Machine_live_publication.Running _ -> Running

let snapshot ~config =
  let exact = Exact_projection.observe () in
  let builtin = Lane_id.all_of_builtin |> List.map (fun lane ->
    let selection,state = match lane with
      | Lane_id.Exact id -> Exact id,Exact_state (Exact_projection.configuration exact id)
      | Lane_id.Browser id ->
          Browser id,(match Browser_lane.inventory_observation id with
            | {Browser_lane.activity; backend=Live_clients count} -> Browser_clients (activity,count)
            | {Browser_lane.activity; backend=Executor_registered registered} -> Browser_executor (activity,registered))
      | Lane_id.Machine id -> Machine id,(match id with
          | Machine_lane.Msx -> Machine_state (Msx_lane.activity (), machine_publication (Msx_lane.current_publication ()))
          | Machine_lane.Dos -> Machine_state (Dos_lane.activity (), machine_publication (Dos_lane.current_publication ()))) in
    {id=Lane_id.to_wire (Lane_id.Builtin lane); label=Lane_manifest.label lane;
     purpose=Lane_manifest.purpose lane; selection; state}) in
  let resolution = Config_dir_resolver.resolve_for_base_path ~base_path:config.Workspace.base_path in
  let directory = Filename.concat resolution.config_root.path "lane-addons" in
  let declarations : Config.snapshot = match resolution.status with
    | Config_dir_resolver.Invalid_env_status ->
        {declarations=[];paths=[];complete=false;
         issues=[{source_path=directory;id=None;message=String.concat "; " resolution.warnings}]}
    | Ready | Warn | Missing_status ->
        Eio_unix.run_in_systhread (fun () -> Config.load ~directory) in
  let packages = Addon.inventory ~config in
  {observed_at=Time_compat.now (); rows=builtin @ package_rows ~declarations ~instances:packages.instances;
   exact;directory;complete=declarations.complete && packages.complete;
   owner_present=packages.owner_present;
   issues=List.map (fun (issue : Config.issue) -> issue.source_path,issue.message) declarations.issues @ packages.issues}

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
let declaration_json = function
  | Valid d -> `Assoc ["kind",str "valid";"enabled",`Bool d.enabled;"installation_id",str d.id;"run_id",str d.run_id;
      "package_id",str d.package.id;"title",str d.package.title;"desired_revision",str d.revision]
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
let state_json = function
  | Exact_state configuration -> `Assoc ["kind",str "exact";"configuration",configuration_json configuration]
  | Browser_clients (activity,count) -> `Assoc ["kind",str "browser_clients";"activity",browser_activity_json activity;"connected_clients",`Int count]
  | Browser_executor (activity,registered) -> `Assoc ["kind",str "browser_executor";"activity",browser_activity_json activity;"registered",`Bool registered]
  | Machine_state (activity,publication) -> `Assoc ["kind",str "machine";
      "activity",str (Machine_configuration.activity_to_wire activity);
      "publication",str (match publication with No_screen -> "no_screen" | Stable -> "stable" | Running -> "running")]
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
  let package_rows = package_rows
  let row_to_json = row_to_json
end
