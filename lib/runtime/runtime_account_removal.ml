module D = Runtime_account_declaration
module E = Toml_line_editor
module S = Runtime_schema

type change =
  | Table of string
  | Lane_candidate of
      { lane : string
      ; runtime : string
      }
  | Exact_lane_slot of
      { lane : string
      ; runtime : string
      }
  | Vision_runtime of string
  | Assignment of
      { keeper : string
      ; runtime : string
      }

type removed =
  { text : string
  ; changes : change list
  ; login_store : string option
  }

type error =
  | Unparsable of string
  | Unknown_account of string
  | Default_runtime of string
  | Lane_emptied of string
  | Exact_lane_emptied of string
  | Unsupported_layout of string
  | Rejected of Runtime_toml.parse_error list

let ( let* ) = Result.bind

let error_message = function
  | Unparsable detail -> detail
  | Unknown_account id -> Printf.sprintf "%s is not an official-client provider" id
  | Default_runtime runtime ->
    Printf.sprintf "[runtime].default is %s; point it at another runtime first" runtime
  | Lane_emptied lane ->
    Printf.sprintf
      "lane %s has no other candidate; give it one or remove the lane first"
      lane
  | Exact_lane_emptied lane ->
    Printf.sprintf
      "exact-output lane %s has no other slot; give it one or remove the lane first"
      lane
  | Unsupported_layout detail -> detail
  | Rejected errors ->
    String.concat
      "; "
      (List.map
         (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message)
         errors)
;;

(* A table path as a header spells it, so a model id with a dot in it stays
   one segment. *)
let spell segments = String.concat "." (List.map E.render_key segments)

(* The standard tables the text opens, in file order. A header inside a
   multi-line string is data, not a table. *)
let table_paths text =
  let lines, _ = E.split_lines text in
  List.concat
    (List.map2
       (fun line structural ->
          match structural, E.header_of_line line with
          | true, Some (E.Table path) -> [ path ]
          | true, Some (E.Table_array _) | true, None | false, _ -> [])
       lines
       (E.structural_lines lines))
;;

let rec is_prefix prefix path =
  match prefix, path with
  | [], _ -> true
  | _ :: _, [] -> false
  | p :: prefix, s :: path -> String.equal p s && is_prefix prefix path
;;

let cannot_reach id what =
  Unsupported_layout
    (Printf.sprintf
       "%s of %s is not written as its own table, so it cannot be removed here; \
        remove %s with the editor"
       what
       id
       id)
;;

(* [path] and the tables under it that follow it. Every path under
   [providers.<id>] is asked for in turn, so a [credentials] table written
   apart from its provider goes too; one already removed with its parent
   answers [Table_absent] and is not listed twice. *)
let remove_tables text paths =
  List.fold_left
    (fun (text, removed) path ->
       match E.remove_table text ~path:(spell path) with
       | E.Table_removed text -> text, Table (spell path) :: removed
       | E.Table_absent -> text, removed)
    (text, [])
    paths
;;

let edit_list text ~table ~key ~values ~what =
  let path = spell table in
  if List.mem table (table_paths text)
  then Ok (E.edit_table_multiline_array text ~path ~key ~values)
  else
    Error
      (Unsupported_layout
         (Printf.sprintf
            "%s is not written as its own [%s] table, so it cannot be edited here; \
             edit it with the editor"
            what
            path))
;;

let rec fold_result f acc = function
  | [] -> Ok acc
  | x :: rest ->
    let* acc = f acc x in
    fold_result f acc rest
;;

let login_store_of (provider : S.provider) =
  match provider.account_home, provider.credentials with
  | Some home, _ -> Some home
  | None, Some (S.File path) -> Some path
  | None, (Some (S.Env _ | S.Inline _) | None) -> None
;;

let remove text ~id =
  let* declaration =
    match D.parse text with
    | Ok declaration -> Ok declaration
    | Error (D.Unparsable detail) -> Error (Unparsable ("runtime.toml does not parse: " ^ detail))
    | Error other -> Error (Unparsable (D.error_message other))
  in
  let* () =
    if List.exists (fun (base : D.base) -> String.equal base.id id) (D.bases declaration)
    then Ok ()
    else Error (Unknown_account id)
  in
  let* config = Result.map_error (fun errors -> Rejected errors) (Runtime_toml.parse_string text) in
  let* provider =
    Option.to_result
      ~none:(cannot_reach id "the provider table")
      (List.find_opt (fun (p : S.provider) -> String.equal p.id id) config.providers)
  in
  let own = List.filter (fun (b : S.binding) -> String.equal b.provider_id id) config.bindings in
  let runtimes = List.map S.binding_key own in
  let lane_ids = List.map (fun (lane : S.lane_decl) -> lane.id) config.lane_decls in
  (* Candidates and slots name runtimes. A default or an assignment names a
     lane first, so one spelled like a runtime of this account is still the
     lane's. *)
  let is_runtime r = List.mem r runtimes in
  let routes_here r = is_runtime r && not (List.mem r lane_ids) in
  let others = List.filter (fun r -> not (is_runtime r)) in
  let* () =
    match config.default_runtime_id with
    | Some r when routes_here r -> Error (Default_runtime r)
    | Some _ | None -> Ok ()
  in
  let lanes =
    List.filter_map
      (fun (lane : S.lane_decl) ->
         match List.filter is_runtime lane.candidate_ids with
         | [] -> None
         | gone -> Some (lane, others lane.candidate_ids, gone))
      config.lane_decls
  in
  let* () =
    match List.find_opt (fun (_, kept, _) -> kept = []) lanes with
    | Some ((lane : S.lane_decl), _, _) -> Error (Lane_emptied lane.id)
    | None -> Ok ()
  in
  let exact_lanes =
    List.filter_map
      (fun (lane : S.exact_output_lane_decl) ->
         match List.filter is_runtime (lane.slot_ids @ lane.cli_slot_ids) with
         | [] -> None
         | gone -> Some (lane, others lane.slot_ids, others lane.cli_slot_ids, gone))
      config.exact_output_lane_decls
  in
  let* () =
    match List.find_opt (fun ((lane : S.exact_output_lane_decl), slots, cli, _) -> lane.enabled && slots = [] && cli = []) exact_lanes with
    | Some ((lane : S.exact_output_lane_decl), _, _, _) -> Error (Exact_lane_emptied lane.id)
    | None -> Ok ()
  in
  let vision_gone = List.filter is_runtime config.media_failover in
  let assignments = List.filter (fun (_, r) -> routes_here r) config.keeper_assignments in
  (* Only explicit bindings have source tables to remove. A model-set's
     bindings disappear with its provider, while its shared declaration and
     model specifications remain for the other providers. Read the source
     keys rather than guessing whether a missing header was generated: an
     explicit inline or dotted binding still has to be refused below. *)
  let* binding_paths =
    match Otoml.Parser.from_string_result text with
    | Error detail -> Error (Unparsable ("runtime.toml does not parse: " ^ detail))
    | Ok source ->
      (match Otoml.find_opt source Fun.id [ id ] with
       | None -> Ok []
       | Some (Otoml.TomlTable entries | Otoml.TomlInlineTable entries) ->
         Ok (List.map (fun (model_id, _) -> [ id; model_id ]) entries)
       | Some _ -> Error (cannot_reach id "the binding table"))
  in
  let provider_paths = List.filter (is_prefix [ "providers"; id ]) (table_paths text) in
  let* () =
    if provider_paths = [] then Error (cannot_reach id "the provider table") else Ok ()
  in
  let edited, removed_provider = remove_tables text provider_paths in
  let* edited, removed_bindings =
    fold_result
      (fun (text, removed) path ->
         match E.remove_table text ~path:(spell path) with
         | E.Table_removed text -> Ok (text, Table (spell path) :: removed)
         | E.Table_absent -> Error (cannot_reach id ("binding " ^ spell path)))
      (edited, [])
      binding_paths
  in
  let* edited =
    fold_result
      (fun text ((lane : S.lane_decl), kept, _) ->
         edit_list text ~table:[ "runtime"; "lanes"; lane.id ] ~key:"candidates" ~values:kept
           ~what:("lane " ^ lane.id))
      edited
      lanes
  in
  let* edited =
    fold_result
      (fun text ((lane : S.exact_output_lane_decl), slots, cli, _) ->
         let table = [ "runtime"; "exact_output_lanes"; lane.id ] in
         let what = "exact-output lane " ^ lane.id in
         let* text =
           if slots = lane.slot_ids then Ok text
           else edit_list text ~table ~key:"slots" ~values:slots ~what
         in
         if cli = lane.cli_slot_ids then Ok text
         else edit_list text ~table ~key:"cli_slots" ~values:cli ~what)
      edited
      exact_lanes
  in
  let* edited =
    if vision_gone = [] then Ok edited
    else
      edit_list edited ~table:[ "runtime" ] ~key:"media_failover"
        ~values:(others config.media_failover) ~what:"[runtime].media_failover"
  in
  let edited =
    List.fold_left
      (fun text (keeper, _) ->
         E.edit_table_scalar text ~path:"runtime.assignments" ~key:keeper ~value:None)
      edited
      assignments
  in
  let changes =
    List.rev removed_provider
    @ List.rev removed_bindings
    @ List.concat_map
        (fun ((lane : S.lane_decl), _, gone) ->
           List.map (fun runtime -> Lane_candidate { lane = lane.id; runtime }) gone)
        lanes
    @ List.concat_map
        (fun ((lane : S.exact_output_lane_decl), _, _, gone) ->
           List.map (fun runtime -> Exact_lane_slot { lane = lane.id; runtime }) gone)
        exact_lanes
    @ List.map (fun runtime -> Vision_runtime runtime) vision_gone
    @ List.map (fun (keeper, runtime) -> Assignment { keeper; runtime }) assignments
  in
  let* after = Result.map_error (fun errors -> Rejected errors) (Runtime_toml.parse_string edited) in
  (* What the text says now has to be the original less exactly [changes]. A
     key the line editor did not reach -- an assignment written inline, a
     vision list written as a dotted key -- shows up here rather than in a
     saved file. *)
  let expected_lane (lane : S.lane_decl) =
    { lane with candidate_ids = others lane.candidate_ids }
  in
  let expected_exact (lane : S.exact_output_lane_decl) =
    { lane with slot_ids = others lane.slot_ids; cli_slot_ids = others lane.cli_slot_ids }
  in
  let kept_assignments = List.filter (fun (_, r) -> not (routes_here r)) config.keeper_assignments in
  let as_expected =
    (not (List.exists (fun (p : S.provider) -> String.equal p.id id) after.providers))
    && List.length after.providers = List.length config.providers - 1
    && List.filter (fun (b : S.binding) -> not (String.equal b.provider_id id)) config.bindings
       = after.bindings
    && after.models = config.models
    && after.default_runtime_id = config.default_runtime_id
    && List.equal S.equal_lane_decl (List.map expected_lane config.lane_decls) after.lane_decls
    && List.equal
         S.equal_exact_output_lane_decl
         (List.map expected_exact config.exact_output_lane_decls)
         after.exact_output_lane_decls
    && after.media_failover = others config.media_failover
    && after.keeper_assignments = kept_assignments
  in
  if as_expected
  then Ok { text = edited; changes; login_store = login_store_of provider }
  else
    Error
      (Unsupported_layout
         (Printf.sprintf
            "%s or something routing to it is written where this edit cannot reach; \
             remove %s with the editor"
            id
            id))
;;
