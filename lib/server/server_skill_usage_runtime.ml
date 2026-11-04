type session_entry = {
  mutex : Mutex.t;
  mutable ledger : Keeper_skill_activation_ledger.t option;
  mutable unavailable : string option;
  usage : (string, Keeper_skill_activation_ledger.catalog_usage option) Hashtbl.t;
}

let sessions : (string * string, session_entry) Hashtbl.t = Hashtbl.create 16
let sessions_mutex = Mutex.create ()
let ledger_loader = ref (fun ~config ~trace_id ->
  Keeper_skill_activation_ledger.load ~config ~trace_id)
let usage_projection = ref Keeper_skill_activation_ledger.usage_for_reference

let entry ~config trace_id =
  let key = config.Workspace.base_path, Keeper_id.Trace_id.to_string trace_id in
  Stdlib.Mutex.protect sessions_mutex (fun () ->
    match Hashtbl.find_opt sessions key with
    | Some entry -> entry
    | None ->
        let entry = { mutex = Mutex.create (); ledger = None; unavailable = None;
          usage = Hashtbl.create 8 } in
        Hashtbl.add sessions key entry;
        entry)

let read_session ~config (keeper_name, trace_id) =
  let entry = entry ~config trace_id in
  Stdlib.Mutex.protect entry.mutex (fun () ->
    match entry.ledger, entry.unavailable with
    | Some ledger, _ -> Some (keeper_name, ledger), []
    | None, Some detail -> None, [detail]
    | None, None ->
        (match !ledger_loader ~config ~trace_id with
         | Ok ledger ->
             entry.ledger <- Some ledger;
             Some (keeper_name, ledger), []
         | Error error ->
             let detail = keeper_name ^ ": "
               ^ Keeper_skill_activation_ledger.store_error_code error in
             entry.unavailable <- Some detail;
             None, [detail]))

let read_sessions ~config sessions_to_read =
  List.fold_left (fun (loaded, unavailable) session ->
    let ledger, errors = read_session ~config session in
    (match ledger with Some ledger -> ledger :: loaded | None -> loaded),
    errors @ unavailable) ([], []) sessions_to_read
  |> fun (loaded, unavailable) -> List.rev loaded, unavailable

let usage_for_reference ~config ~trace_id ~reference =
  let entry = entry ~config trace_id in
  Stdlib.Mutex.protect entry.mutex (fun () ->
    match entry.ledger with
    | None -> None
    | Some ledger ->
        let key = Yojson.Safe.to_string (Skill_reference.to_yojson reference) in
        (match Hashtbl.find_opt entry.usage key with
         | Some usage -> usage
         | None ->
             let usage = !usage_projection ledger reference in
             Hashtbl.add entry.usage key usage;
             usage))

let retain_committed ~config ~keeper_name:_ ~trace_id ledger =
  let entry = entry ~config trace_id in
  Stdlib.Mutex.protect entry.mutex (fun () ->
    entry.ledger <- Some ledger;
    entry.unavailable <- None;
    Hashtbl.reset entry.usage)

let install () =
  let retained = ref [] in
  retained := (Keeper_skill_activation_ledger.install_commit_observer retain_committed) :: !retained

module For_testing = struct
  let with_runtime ?usage_projection:projection ~ledger_loader:loader f =
    let previous_loader = !ledger_loader in
    let previous_projection = !usage_projection in
    Stdlib.Mutex.protect sessions_mutex (fun () -> Hashtbl.reset sessions);
    ledger_loader := loader;
    usage_projection := Option.value ~default:Keeper_skill_activation_ledger.usage_for_reference projection;
    let restore = Keeper_skill_activation_ledger.install_commit_observer retain_committed in
    Fun.protect ~finally:(fun () ->
      restore ();
      ledger_loader := previous_loader;
      usage_projection := previous_projection) f
end
