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
  | Browser_clients of int browser_reading
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
  | Error (Addon.Unready_installations _ | Not_yet_observed _ | Ambiguous_installations _) -> Publication_unavailable
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

let browser_map f = function
  | Browser_addon_presence.Observed published -> Browser_observed (f published)
  | Browser_addon_presence.Absent -> Browser_addon_absent
  | Browser_addon_presence.Off -> Browser_addon_off
  | Browser_addon_presence.Not_running
      Browser_addon_presence.(Attach_failed | Attaching | Not_known) -> Browser_addon_not_running
  (* The inventory is served to the operator alone (CanAdmin), so a failure is
     shown with its detail. *)
  | Browser_addon_presence.Unavailable reason ->
      Browser_addon_unavailable (Browser_addon_presence.unavailable_operator_message reason)
let browser_state publication = function
  | Browser_lane.Lane_name.Live ->
      Browser_clients (browser_map (fun (p : Browser_addon_observation.published) ->
        List.length p.clients) publication)

(* The Lane directory and what it declares, read off the server fiber. *)
let read_declarations ~config =
  let resolution = Config_dir_resolver.resolve_for_base_path ~base_path:config.Workspace.base_path in
  let directory = Config.directory ~config_root:resolution.config_root.path in
  let declarations : Config.snapshot = match resolution.status with
    | Config_dir_resolver.Invalid_env_status ->
        {declarations=[];paths=[];complete=false;
         issues=[{source_path=directory;id=None;message=String.concat "; " resolution.warnings}]}
    | Ready | Warn | Missing_status ->
        Eio_unix.run_in_systhread (fun () -> Config.load ~directory) in
  directory, declarations

let project ~config ~exact ~machine_configuration ~directory ~declarations
    ~(inventory : Addon.inventory) ~browser_observations =
  let browser_publication = Browser_addon_presence.of_observations ~declarations
      ~applications:(fun () -> inventory.applications) browser_observations in
  let builtin = Lane_id.all_of_builtin |> List.map (fun lane ->
    let selection,state = match lane with
      | Lane_id.Exact id -> Exact id,Exact_state (Exact_projection.configuration exact id)
      | Lane_id.Browser id ->
          Browser id,browser_state (Browser_addon_presence.lane browser_publication id) id
      | Lane_id.Machine id -> Machine id,machine_state ~config ~configuration:machine_configuration id in
    {id=Lane_id.to_wire (Lane_id.Builtin lane); label=Lane_manifest.label lane;
     purpose=Lane_manifest.purpose lane; selection; state}) in
  let exact_outputs = exact_outputs ~configuration:(Exact_projection.addon_configuration exact)
      ~tables:(Exact_projection.addon_tables exact) in
  {observed_at=Time_compat.now (); rows=builtin @ package_rows ~declarations ~instances:inventory.instances ~applications:inventory.applications ~exact_outputs;
   exact;directory;complete=declarations.complete && inventory.complete;
   owner_present=inventory.owner_present;
   issues=List.map (fun (issue : Config.issue) -> issue.source_path,issue.message) declarations.issues
          @ List.map (fun (issue : Addon.inventory_issue) ->
              issue.issue_path,Addon.retained_fault_message issue.issue_reason) inventory.issues}

type cached_sources = {
  directory : string;
  declarations : Config.snapshot;
  exact : Exact_projection.observation;
  machine_configuration : Machine_configuration.t option;
  inventory : Addon.inventory;
}

let read_snapshot_parts ~config =
  let exact = Exact_projection.observe () in
  let machine_configuration = Runtime.machine_configuration () in
  let directory, declarations = read_declarations ~config in
  let inventory = Addon.inventory ~config in
  let applications = Addon.configuration_applications ~config ~inventory in
  let browser_observations = Addon.browser_observations ~config
      ~access:Lane_addon_sources.Operator_configuration in
  let sources = { directory; declarations; exact; machine_configuration;
    inventory = { inventory with applications } } in
  let next = project ~config ~exact ~machine_configuration ~directory ~declarations
      ~inventory:sources.inventory ~browser_observations in
  sources, next

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
let exact_output_json ?observation ~declaration_id {output;source;configuration} =
  let diagnostics = match observation with
    | None -> []
    | Some observation -> (match Runtime_schema.addon_lane ~declaration_id ~output with
        | Error _ -> [] (* An invalid manifest output has no configured route owner. *)
        | Ok addon ->
          let owner = Runtime_schema.Addon addon in
          ["lane_key",str (Runtime_schema.exact_lane_key owner);
           "slot_states",Exact_projection.slot_states observation owner;
           "slot_observation_unavailable_runs",`Int
             (Exact_projection.slot_observation_unavailable_run_count observation)]) in
  `Assoc (["output",str output;
  "source",str (match source with Declared -> "declared" | Table_only -> "table_only");
  "configuration",configuration_json configuration] @ diagnostics)
let declaration_json ?observation = function
  | Valid {declaration=d;exact_outputs;application} -> `Assoc (["kind",str "valid";"enabled",`Bool d.enabled;"installation_id",str d.id;
      "run_id",str d.run_id;"package_id",str d.package.id;"title",str d.package.title;"desired_revision",str d.revision;
      "source_revision",str d.source_revision;"application",Lane_addon_application.to_json application;
      "exact_outputs",`List (List.map (exact_output_json ?observation ~declaration_id:d.id) exact_outputs)]
      @ (match d.package.ui_category with None -> []
         | Some category -> ["ui_category",Lane_addon_category.to_json category]))
  | Invalid messages -> `Assoc ["kind",str "invalid";"messages",strings messages]
  | Absent -> `Assoc ["kind",str "absent"]
  | Unobserved -> `Assoc ["kind",str "unobserved"]
let instance_json (i : Addon.inventory_instance) = `Assoc ([
  "instance_id",str i.instance_id;"incarnation",str i.incarnation;"run_id",str i.run_id;
  "package_id",str i.package_id;"title",str i.title;"package_revision",str i.package_revision;
  "presence",str (match i.presence with Addon.Live -> "live" | Addon.Retained -> "retained");
  "phase",Lane_addon_types.phase_to_json i.phase;
  "applied_revision",optional (fun (o : Addon.configuration_owner) -> str o.revision) i.configuration]
  @ (match i.ui_category with None -> []
     | Some category -> ["ui_category",Lane_addon_category.to_json category]))
let browser_reading_json fields = function
  | Browser_observed value -> `Assoc (("kind",str "observed") :: fields value)
  | Browser_addon_absent -> `Assoc ["kind",str "absent"]
  | Browser_addon_off -> `Assoc ["kind",str "off"]
  | Browser_addon_not_running -> `Assoc ["kind",str "not_running"]
  | Browser_addon_unavailable detail -> `Assoc ["kind",str "unavailable";"detail",str detail]
let state_json ?observation = function
  | Exact_state configuration -> `Assoc ["kind",str "exact";"configuration",configuration_json configuration]
  | Browser_clients reading -> `Assoc ["kind",str "browser_clients";
      "addon",browser_reading_json (fun count -> ["connected_clients",`Int count]) reading]
  | Machine_state (activity,publication) -> `Assoc ["kind",str "machine";
      "activity",str (Machine_configuration.activity_to_wire activity);
      "publication",str (match publication with No_screen -> "no_screen" | Stable -> "stable" | Running -> "running" | Publication_unavailable -> "unavailable")]
  | Package_state {declaration;instances} -> `Assoc ["kind",str "package";
      "declaration",optional (declaration_json ?observation) declaration;"instances",`List (List.map instance_json instances)]
(* This is display metadata only. Selection and state retain their independent
   contracts; clients must not reconstruct a role from their technical names. *)
let builtin_category = function
  | Exact (Standalone_lane.Librarian | Hitl_auto_judge | Board_attention | Verifier | Candle_appraiser) ->
      Some Lane_addon_category.Memory_and_judgment
  | Browser _ -> Some Lane_addon_category.Browser
  | Machine _ -> Some Lane_addon_category.Execution_environment
  | Declaration _ | Manual_instance _ -> None
let row_to_json_with ?observation row = `Assoc (["id",str row.id;"label",str row.label;"purpose",str row.purpose;
  "selection",selection_json row.selection;"state",state_json ?observation row.state]
  @ (match builtin_category row.selection with None -> []
     | Some category -> ["ui_category",Lane_addon_category.to_json category]))
let row_to_json row = row_to_json_with row
let inventory_fields t = ["schema",str "masc.lane-inventory/v1";"observed_at",`Float t.observed_at;
  "rows",`List (List.map (row_to_json_with ~observation:t.exact) t.rows);"exact_snapshot",Exact_projection.observation_to_json t.exact;
  "package_read",`Assoc ["directory",str t.directory;"complete",`Bool t.complete;
    "owner_present",`Bool t.owner_present;"issues",`List (List.map (fun (path,detail) ->
      `Assoc ["source_path",str path;"message",str detail]) t.issues)]]
let to_json t = `Assoc (inventory_fields t)
let without_fields names fields =
  List.filter (fun (name, _) -> not (List.mem name names)) fields

let display_json t =
  let fields = without_fields ["observed_at"] (inventory_fields t) in
  `Assoc (List.map (fun (name, json) ->
    name, match name, json with
      | "exact_snapshot", `Assoc exact ->
          `Assoc (without_fields ["generated_at"; "observed_at_unix"] exact)
      | _, _ -> json) fields)

let publish_if_changed ~base_path before after =
  let changed = match before with
    | None -> true
    | Some previous -> not (Yojson.Safe.equal (display_json previous) (display_json after)) in
  if changed then
    Workspace_dataset_event.announce ~base_path Workspace_dataset_event.Lanes;
  changed

type cache = {
  mutex : Eio.Mutex.t;
  mutable previous : t option;
  mutable announced : t option;
  mutable sources : cached_sources option;
}

let caches : (string, cache) Hashtbl.t = Hashtbl.create 4
let caches_lock = Mutex.create ()

let with_workspace_cache base_path f =
  let cache = Stdlib.Mutex.lock caches_lock;
    Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock caches_lock) (fun () ->
      match Hashtbl.find_opt caches base_path with
      | Some cache -> cache
      | None ->
          let cache = { mutex = Eio.Mutex.create (); previous = None; announced = None; sources = None } in
          Hashtbl.add caches base_path cache;
          cache) in
  Eio.Mutex.use_rw ~protect:true cache.mutex (fun () -> f cache)

let merge_inventory ~(live : Addon.inventory) ~(retained : Addon.inventory) =
  let live_ids = List.map (fun (item : Addon.inventory_instance) -> item.instance_id) live.instances in
  let retained_filtered = List.filter (fun (item : Addon.inventory_instance) ->
    item.presence = Addon.Retained && not (List.mem item.instance_id live_ids)) retained.instances in
  { Addon.owner_present = live.owner_present
  ; instances = List.sort (fun (left : Addon.inventory_instance) right ->
      String.compare left.instance_id right.instance_id) (live.instances @ retained_filtered)
  ; issues = live.issues @ retained.issues
  ; complete = live.complete && retained.complete
  ; applications = [] }

let publish_projection ~base_path ~announce cache next =
  let changed = match cache.announced with
    | Some previous -> not (Yojson.Safe.equal (display_json previous) (display_json next))
    | None -> true in
  cache.previous <- Some next;
  if announce && changed then begin
    cache.announced <- Some next;
    Workspace_dataset_event.announce ~base_path Workspace_dataset_event.Lanes
  end

let refresh_full ~base_path ~announce cache ~config =
  let sources, next = read_snapshot_parts ~config in
  cache.sources <- Some sources;
  publish_projection ~base_path ~announce cache next

let refresh_live ~base_path ~announce cache ~config =
  match cache.sources with
  | None -> refresh_full ~base_path ~announce cache ~config
  | Some sources ->
      let retained = { (sources.inventory) with instances =
        List.filter (fun (item : Addon.inventory_instance) ->
          item.presence = Addon.Retained) sources.inventory.instances } in
      let live = Addon.inventory_live ~config in
      let inventory = merge_inventory ~live ~retained in
      let applications = Addon.configuration_applications ~config ~inventory in
      let browser_observations = Addon.browser_observations ~config
          ~access:Lane_addon_sources.Operator_configuration in
      let next = project ~config ~exact:sources.exact
          ~machine_configuration:sources.machine_configuration
          ~directory:sources.directory ~declarations:sources.declarations
          ~inventory:{ inventory with applications } ~browser_observations in
      publish_projection ~base_path ~announce cache next

let refresh ~base_path kind =
  let config = Workspace.default_config base_path in
  with_workspace_cache base_path (fun cache ->
    match kind with
    | Addon.Observation_commit -> refresh_live ~base_path ~announce:true cache ~config
    | Addon.Configuration_changed | Addon.Retained_changed ->
        refresh_full ~base_path ~announce:true cache ~config)

let snapshot ~config =
  with_workspace_cache config.Workspace.base_path (fun cache ->
    let cold = Option.is_none cache.previous in
    refresh_full ~base_path:config.base_path ~announce:false cache ~config;
    if cold && Option.is_none cache.announced then cache.announced <- cache.previous;
    Option.get cache.previous)

let install () =
  Addon.install_inventory_change_observer (fun ~base_path kind -> refresh ~base_path kind)

module For_testing = struct
  let runtime_snapshot ~config ~declarations ~inventory ~browser_observations =
    let directory, _ = read_declarations ~config in
    project ~config ~exact:(Exact_projection.observe ())
      ~machine_configuration:(Runtime.machine_configuration ())
      ~directory ~declarations ~inventory ~browser_observations
  let publish_if_changed = publish_if_changed
  let merge_inventory = merge_inventory
  let machine_publication = machine_publication
  let browser_state = browser_state
  let package_rows = package_rows
  let exact_outputs = exact_outputs
  let row_to_json = row_to_json
end
