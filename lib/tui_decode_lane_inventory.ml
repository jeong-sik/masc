type selection =
  | Exact of Standalone_lane.t
  | Browser of Browser_lane.Lane_name.t
  | Machine of Machine_lane.t
  | Declaration of string
  | Manual_instance of { instance_id : string; incarnation : string }

type configuration =
  | Configured of {
      admitted_slots : string list; cli_slots : string list;
      declared_slots : string list; declared_cli_slots : string list;
      dropped_slots : string list; admission_error : string option;
    }
  | Unconfigured of string
  | Registry_unavailable of string

type declaration =
  | Valid of {
      installation_id : string; run_id : string; package_id : string;
      title : string; desired_revision : string;
    }
  | Invalid of string list
  | Absent
  | Unobserved

type phase = Lane_addon_types.phase = Attached | Observing | Failed of string | Detaching | Detached
type presence = Live | Retained
type instance = {
  instance_id : string; incarnation : string; run_id : string;
  package_id : string; title : string; package_revision : string;
  presence : presence; phase : phase; applied_revision : string option;
}
type machine_publication = No_screen | Stable | Running
type state =
  | Exact_state of configuration
  | Browser_clients of int
  | Browser_executor of bool
  | Machine_state of machine_publication
  | Package_state of { declaration : declaration option; instances : instance list }
type row = { id : string; label : string; purpose : string; selection : selection; state : state }
type package_read = {
  directory : string; complete : bool; owner_present : bool;
  issues : (string * string) list;
}
type snapshot = {
  observed_at : float; rows : row list;
  exact_snapshot : Tui_decode.standalone_lanes_snapshot; package_read : package_read;
}

let ( let* ) = Result.bind
let error message = Error ("Lane inventory: " ^ message)
let rec traverse f = function
  | [] -> Ok []
  | item :: rest -> let* value = f item in let* rest = traverse f rest in Ok (value :: rest)

let rec unique_keys = function
  | `Assoc fields ->
      let names = List.map fst fields in
      if List.length names <> List.length (List.sort_uniq String.compare names)
      then error "duplicate JSON field"
      else let* _ = traverse (fun (_, value) -> unique_keys value) fields in Ok ()
  | `List items -> let* _ = traverse unique_keys items in Ok ()
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ -> Ok ()
  | `Tuple _ | `Variant _ -> error "non-JSON value"

let fields names = function
  | `Assoc values when List.sort String.compare (List.map fst values) = List.sort String.compare names -> Ok values
  | `Assoc _ -> error ("expected exactly " ^ String.concat ", " names)
  | _ -> error "expected object"
let get decode name values =
  match List.assoc_opt name values with None -> error ("missing " ^ name) | Some value -> decode value
let string = function `String value -> Ok value | _ -> error "expected string"
let nonblank value = let* value = string value in
  if String.trim value = "" then error "expected nonblank string" else Ok value
let bool = function `Bool value -> Ok value | _ -> error "expected boolean"
let count = function `Int value when value >= 0 -> Ok value | _ -> error "expected nonnegative count"
let number = function
  | `Int value -> Ok (float_of_int value)
  | `Float value when Float.is_finite value -> Ok value
  | _ -> error "expected finite timestamp"
let list decode = function `List values -> traverse decode values | _ -> error "expected array"
let nullable decode = function `Null -> Ok None | value -> Result.map Option.some (decode value)
let kind = function `Assoc values -> get nonblank "kind" values | _ -> error "expected tagged object"
let named lookup raw = let* name = nonblank raw in
  match lookup name with Some value -> Ok value | None -> error ("unknown name " ^ name)
let machine raw = named (fun name -> List.find_opt (fun item -> Machine_lane.to_wire item = name) Machine_lane.all) raw

let selection json =
  let* tag = kind json in
  match tag with
  | "exact" -> let* f = fields ["kind"; "lane_id"] json in
      Result.map (fun lane -> Exact lane) (get (named Standalone_lane.of_id) "lane_id" f)
  | "browser" -> let* f = fields ["kind"; "lane"] json in
      Result.map (fun lane -> Browser lane) (get (named Browser_lane.Lane_name.of_wire) "lane" f)
  | "machine" -> let* f = fields ["kind"; "machine"] json in
      Result.map (fun lane -> Machine lane) (get machine "machine" f)
  | "declaration" -> let* f = fields ["kind"; "source_path"] json in
      Result.map (fun path -> Declaration path) (get nonblank "source_path" f)
  | "manual_instance" -> let* f = fields ["kind"; "instance_id"; "incarnation"] json in
      let* instance_id = get nonblank "instance_id" f in let* incarnation = get nonblank "incarnation" f in
      Ok (Manual_instance {instance_id;incarnation})
  | other -> error ("unknown selection " ^ other)

let configuration json =
  let* tag = kind json in
  match tag with
  | "configured" ->
      let* f = fields ["kind";"admitted_slots";"cli_slots";"declared_slots";"declared_cli_slots";"dropped_slots";"admission_error"] json in
      let* admitted_slots = get (list nonblank) "admitted_slots" f in
      let* cli_slots = get (list nonblank) "cli_slots" f in
      let* declared_slots = get (list nonblank) "declared_slots" f in
      let* declared_cli_slots = get (list nonblank) "declared_cli_slots" f in
      let* dropped_slots = get (list nonblank) "dropped_slots" f in
      let* admission_error = get (nullable string) "admission_error" f in
      Ok (Configured {admitted_slots;cli_slots;declared_slots;declared_cli_slots;dropped_slots;admission_error})
  | "unconfigured" -> let* f = fields ["kind";"detail"] json in Result.map (fun detail -> Unconfigured detail) (get string "detail" f)
  | "unavailable" -> let* f = fields ["kind";"detail"] json in Result.map (fun detail -> Registry_unavailable detail) (get string "detail" f)
  | other -> error ("unknown exact configuration " ^ other)

let declaration json =
  let* tag = kind json in
  match tag with
  | "valid" ->
      let* f = fields ["kind";"installation_id";"run_id";"package_id";"title";"desired_revision"] json in
      let* installation_id = get nonblank "installation_id" f in let* run_id = get nonblank "run_id" f in
      let* package_id = get nonblank "package_id" f in let* title = get nonblank "title" f in
      let* desired_revision = get nonblank "desired_revision" f in
      Ok (Valid {installation_id;run_id;package_id;title;desired_revision})
  | "invalid" -> let* f = fields ["kind";"messages"] json in
      let* messages = get (list string) "messages" f in
      if messages = [] then error "invalid declaration has no diagnostics" else Ok (Invalid messages)
  | "absent" -> let* _ = fields ["kind"] json in Ok Absent
  | "unobserved" -> let* _ = fields ["kind"] json in Ok Unobserved
  | other -> error ("unknown declaration state " ^ other)

let instance json =
  let* f = fields ["instance_id";"incarnation";"run_id";"package_id";"title";"package_revision";"presence";"phase";"applied_revision"] json in
  let* instance_id = get nonblank "instance_id" f in let* incarnation = get nonblank "incarnation" f in
  let* run_id = get nonblank "run_id" f in let* package_id = get nonblank "package_id" f in
  let* title = get nonblank "title" f in let* package_revision = get nonblank "package_revision" f in
  let* presence = get (function `String "live" -> Ok Live | `String "retained" -> Ok Retained | _ -> error "unknown instance presence") "presence" f in
  let* phase = get Lane_addon_types.phase_of_json "phase" f in
  let* applied_revision = get (nullable nonblank) "applied_revision" f in
  Ok {instance_id;incarnation;run_id;package_id;title;package_revision;presence;phase;applied_revision}

let state json =
  let* tag = kind json in
  match tag with
  | "exact" -> let* f = fields ["kind";"configuration"] json in Result.map (fun c -> Exact_state c) (get configuration "configuration" f)
  | "browser_clients" -> let* f = fields ["kind";"connected_clients"] json in Result.map (fun n -> Browser_clients n) (get count "connected_clients" f)
  | "browser_executor" -> let* f = fields ["kind";"registered"] json in Result.map (fun value -> Browser_executor value) (get bool "registered" f)
  | "machine" -> let* f = fields ["kind";"publication"] json in
      let* value = get (function `String "no_screen" -> Ok No_screen | `String "stable" -> Ok Stable | `String "running" -> Ok Running | _ -> error "unknown machine publication") "publication" f in
      Ok (Machine_state value)
  | "package" -> let* f = fields ["kind";"declaration";"instances"] json in
      let* declaration = get (nullable declaration) "declaration" f in let* instances = get (list instance) "instances" f in
      Ok (Package_state {declaration;instances})
  | other -> error ("unknown row state " ^ other)

let selection_id = function
  | Exact lane -> Lane_id.to_wire (Lane_id.Builtin (Lane_id.Exact lane))
  | Browser lane -> Lane_id.to_wire (Lane_id.Builtin (Lane_id.Browser lane))
  | Machine lane -> Lane_id.to_wire (Lane_id.Builtin (Lane_id.Machine lane))
  | Declaration path -> "declaration/" ^ path
  | Manual_instance {instance_id;_} -> "instance/" ^ instance_id
let compatible selection state = match selection,state with
  | Exact _,Exact_state _ | Browser Browser_lane.Lane_name.Live,Browser_clients _
  | Browser (Browser_lane.Lane_name.Automation | Browser_lane.Lane_name.Stagehand),Browser_executor _
  | Machine _,Machine_state _ -> true
  | Declaration _,Package_state {declaration=Some _;instances} ->
      List.for_all (fun (item : instance) -> Option.is_some item.applied_revision) instances
  | Manual_instance {instance_id;incarnation},Package_state {declaration=None;instances=[item]} ->
      item.instance_id=instance_id && item.incarnation=incarnation && item.applied_revision=None
  | _ -> false
let row json =
  let* f = fields ["id";"label";"purpose";"selection";"state"] json in
  let* id = get nonblank "id" f in let* label = get nonblank "label" f in let* purpose = get string "purpose" f in
  let* selection = get selection "selection" f in let* state = get state "state" f in
  if id <> selection_id selection then error "row id disagrees with selection"
  else if not (compatible selection state) then error "row state disagrees with selection"
  else Ok {id;label;purpose;selection;state}
let package_read json =
  let* f = fields ["directory";"complete";"owner_present";"issues"] json in
  let* directory = get nonblank "directory" f in let* complete = get bool "complete" f in
  let* owner_present = get bool "owner_present" f in
  let issue json = let* f = fields ["source_path";"message"] json in
    let* path = get nonblank "source_path" f in let* message = get string "message" f in Ok (path,message) in
  let* issues = get (list issue) "issues" f in Ok {directory;complete;owner_present;issues}
let unique_ids name ids =
  if List.length ids = List.length (List.sort_uniq String.compare ids) then Ok () else error ("duplicate " ^ name)

let exact_matches snapshot (row : row) = match row.selection,row.state with
  | Exact lane,Exact_state configuration ->
      (match List.find_opt (fun (item : Tui_decode.standalone_lane) -> Standalone_lane.equal item.sl_lane lane) snapshot.Tui_decode.sls_lanes with
       | None -> false
       | Some item ->
           match configuration with
           | Unconfigured detail -> item.sl_configuration_state=Tui_decode.Lane_unconfigured
               && item.sl_admission_error=Some detail
           | Registry_unavailable detail -> item.sl_configuration_state=Tui_decode.Lane_registry_unavailable
               && item.sl_admission_error=Some detail
           | Configured c ->
               let state = if Option.is_some c.admission_error || c.admitted_slots=[] && c.cli_slots=[]
                 then Tui_decode.Lane_slotless else Tui_decode.Lane_ready in
               item.sl_configuration_state=state && item.sl_admitted_slots=c.admitted_slots
               && item.sl_cli_slots=c.cli_slots && item.sl_declared_slots=c.declared_slots
               && item.sl_declared_cli_slots=c.declared_cli_slots && item.sl_dropped_slots=c.dropped_slots
               && item.sl_admission_error=c.admission_error)
  | (Browser _ | Machine _ | Declaration _ | Manual_instance _),_ -> true
  | Exact _,_ -> false

let decode json =
  let* () = unique_keys json in
  let* f = fields ["schema";"observed_at";"rows";"exact_snapshot";"package_read"] json in
  let* schema = get string "schema" f in
  let* () = if schema="masc.lane-inventory/v1" then Ok () else error ("unknown schema " ^ schema) in
  let* observed_at = get number "observed_at" f in
  let* rows = get (list row) "rows" f in
  let* () = unique_ids "row id" (List.map (fun (row : row) -> row.id) rows) in
  let* () = unique_ids "instance id" (List.concat_map (fun (row : row) -> match row.state with
    | Package_state {instances;_} -> List.map (fun (i : instance) -> i.instance_id) instances
    | Exact_state _ | Browser_clients _ | Browser_executor _ | Machine_state _ -> []) rows) in
  let* () = if List.for_all (fun lane ->
    List.exists (fun (row : row) -> row.id=Lane_id.to_wire (Lane_id.Builtin lane)) rows) Lane_id.all_of_builtin
    then Ok () else error "missing built-in lane" in
  let* exact_snapshot = get Tui_decode.decode_standalone_lanes_snapshot "exact_snapshot" f in
  let* () = if List.for_all (exact_matches exact_snapshot) rows then Ok ()
    else error "exact overview disagrees with embedded exact snapshot" in
  let* package_read = get package_read "package_read" f in
  Ok {observed_at;rows;exact_snapshot;package_read}
