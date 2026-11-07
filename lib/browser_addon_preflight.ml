(* The server reads declarations from the config root's Lane directory
   whatever the root's status is, so this does too. *)
let declaration_directory ~base_path =
  let resolution = Config_dir_resolver.resolve_for_base_path ~base_path in
  Lane_addon_config.directory
    ~config_root:resolution.Config_dir_resolver.config_root.Config_dir_resolver.path
;;

type doubled = { source : Browser_lane.Backend.t; ids : string list }

(* An owned route names a backend, so that source requires one declaration.
   Ego routes retain their exact publisher. *)
let doubled_sources ~base_path =
  let snapshot = Lane_addon_config.load ~directory:(declaration_directory ~base_path) in
  let browsers =
    List.filter_map
      (fun (declaration : Lane_addon_config.declaration) ->
        match declaration.enabled, Lane_addon_config.browser_source declaration with
        | true, Some Browser_lane.Backend.Ego -> None
        | true, Some (Owned_firefox as backend) -> Some (declaration.id, backend)
        | false, (Some _ | None) | true, None -> None)
      snapshot.Lane_addon_config.declarations
  in
  List.filter_map
    (fun source ->
      match List.filter (fun (_, backend) -> backend = source) browsers with
      | _ :: _ :: _ as serving -> Some { source; ids = List.map fst serving }
      | [] | [ _ ] -> None)
    Browser_lane.Backend.all
;;

let report_doubled = function
  | [] -> Ok ()
  | doubled ->
    Error
      (Printf.sprintf
         "more than one enabled browser Add-on declaration serves the same source (%s), so that \
          source is not used until all but one are disabled. Keep one declaration per source."
         (String.concat "; "
            (List.map
               (fun { source; ids } ->
                 Browser_lane.Backend.to_wire source ^ ": " ^ String.concat ", " ids)
               doubled)))
;;
