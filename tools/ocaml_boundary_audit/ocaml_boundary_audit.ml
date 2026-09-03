open Typedtree

type category =
  | Partial_extraction
  | Failure_erasure
  | Effect_in_pure_module

type site =
  { category : category
  ; path : string
  ; scope : string
  ; callee : string
  ; line : int
  ; column : int
  }

type entry =
  { category : category
  ; path : string
  ; scope : string
  ; callee : string
  ; count : int
  }

type report =
  { sites : site list
  ; entries : entry list
  ; scanned_sources : int
  ; scanned_cmt_files : int
  }

type drift =
  { entry : entry
  ; baseline_count : int
  ; current_count : int
  }

type comparison =
  { increases : drift list
  ; reductions : drift list
  }

let default_source_roots = [ "lib"; "bin"; "packages/agent_core/lib" ]

let category_to_string = function
  | Partial_extraction -> "partial_extraction"
  | Failure_erasure -> "failure_erasure"
  | Effect_in_pure_module -> "effect_in_pure_module"
;;

let category_of_string = function
  | "partial_extraction" -> Ok Partial_extraction
  | "failure_erasure" -> Ok Failure_erasure
  | "effect_in_pure_module" -> Ok Effect_in_pure_module
  | value -> Error (Printf.sprintf "unknown boundary-audit category %S" value)
;;

let ( let* ) = Result.bind

let normalize_resolved_callee value =
  let value =
    value |> String.to_seq |> Seq.filter (fun character -> character <> '!')
    |> String.of_seq
  in
  let buffer = Buffer.create (String.length value) in
  let rec copy index =
    if index >= String.length value
    then Buffer.contents buffer
    else if
      index + 1 < String.length value
      && Char.equal value.[index] '_'
      && Char.equal value.[index + 1] '_'
    then (
      Buffer.add_char buffer '.';
      copy (index + 2))
    else (
      Buffer.add_char buffer value.[index];
      copy (index + 1))
  in
  copy 0
;;

let category_for_resolved_callee raw =
  match normalize_resolved_callee raw with
  | "Stdlib.Option.get" | "Option.get"
  | "Stdlib.Result.get_ok" | "Result.get_ok" ->
    Some Partial_extraction
  | "Stdlib.Result.to_option" | "Result.to_option" -> Some Failure_erasure
  | callee when String.equal callee "Parse_outcome.to_option" ->
    Some Failure_erasure
  | callee when String.ends_with ~suffix:".Parse_outcome.to_option" callee ->
    Some Failure_erasure
  | _ -> None
;;

module String_set = Set.Make (String)

let effectful_exact =
  [ "Stdlib.close_in"
  ; "Stdlib.close_in_noerr"
  ; "Stdlib.close_out"
  ; "Stdlib.close_out_noerr"
  ; "Stdlib.flush"
  ; "Stdlib.input"
  ; "Stdlib.input_binary_int"
  ; "Stdlib.input_byte"
  ; "Stdlib.input_char"
  ; "Stdlib.input_line"
  ; "Stdlib.open_in"
  ; "Stdlib.open_in_bin"
  ; "Stdlib.open_in_gen"
  ; "Stdlib.open_out"
  ; "Stdlib.open_out_bin"
  ; "Stdlib.open_out_gen"
  ; "Stdlib.output"
  ; "Stdlib.output_binary_int"
  ; "Stdlib.output_byte"
  ; "Stdlib.output_char"
  ; "Stdlib.output_string"
  ; "Stdlib.Format.eprintf"
  ; "Stdlib.Format.fprintf"
  ; "Stdlib.Format.ifprintf"
  ; "Stdlib.Format.kfprintf"
  ; "Stdlib.Format.printf"
  ; "Stdlib.Printf.eprintf"
  ; "Stdlib.Printf.fprintf"
  ; "Stdlib.Printf.ifprintf"
  ; "Stdlib.Printf.kfprintf"
  ; "Stdlib.Printf.printf"
  ; "Stdlib.prerr_endline"
  ; "Stdlib.print_endline"
  ; "Stdlib.read_line"
  ; "Stdlib.Sys.chdir"
  ; "Stdlib.Sys.command"
  ; "Stdlib.Sys.file_exists"
  ; "Stdlib.Sys.getcwd"
  ; "Stdlib.Sys.getenv"
  ; "Stdlib.Sys.getenv_opt"
  ; "Stdlib.Sys.is_directory"
  ; "Stdlib.Sys.mkdir"
  ; "Stdlib.Sys.readdir"
  ; "Stdlib.Sys.remove"
  ; "Stdlib.Sys.rename"
  ; "Stdlib.Sys.rmdir"
  ; "Stdlib.Sys.time"
  ; "Unix.accept"
  ; "Unix.bind"
  ; "Unix.chdir"
  ; "Unix.close"
  ; "Unix.connect"
  ; "Unix.create_process"
  ; "Unix.create_process_env"
  ; "Unix.fsync"
  ; "Unix.gettimeofday"
  ; "Unix.kill"
  ; "Unix.link"
  ; "Unix.listen"
  ; "Unix.lseek"
  ; "Unix.lstat"
  ; "Unix.mkdir"
  ; "Unix.openfile"
  ; "Unix.pipe"
  ; "Unix.read"
  ; "Unix.readdir"
  ; "Unix.rename"
  ; "Unix.rmdir"
  ; "Unix.select"
  ; "Unix.sleep"
  ; "Unix.sleepf"
  ; "Unix.socket"
  ; "Unix.stat"
  ; "Unix.symlink"
  ; "Unix.time"
  ; "Unix.truncate"
  ; "Unix.unlink"
  ; "Unix.wait"
  ; "Unix.waitpid"
  ; "Unix.write"
  ]
  |> String_set.of_list
;;

let contains_path_segment path wanted =
  path |> String.split_on_char '.' |> List.exists (String.equal wanted)
;;

let effectful_resolved_callee raw =
  let callee = normalize_resolved_callee raw in
  String_set.mem callee effectful_exact
  || (String.starts_with ~prefix:"Stdlib.Sys." callee
      && not (String.equal callee "Stdlib.Sys.opaque_identity"))
  || (String.starts_with ~prefix:"Unix." callee
      && not (String.equal callee "Unix.gmtime"))
  || String.starts_with ~prefix:"Eio." callee
  || String.starts_with ~prefix:"Eio_main." callee
  || String.starts_with ~prefix:"Stdlib.Atomic." callee
  || String.starts_with ~prefix:"Stdlib.Domain." callee
  || String.starts_with ~prefix:"Stdlib.In_channel." callee
  || String.starts_with ~prefix:"Stdlib.Mutex." callee
  || String.starts_with ~prefix:"Stdlib.Out_channel." callee
  || String.starts_with ~prefix:"Stdlib.Random." callee
  || String.starts_with ~prefix:"Stdlib.Thread." callee
  || String.starts_with ~prefix:"Atomic." callee
  || String.starts_with ~prefix:"Domain." callee
  || String.starts_with ~prefix:"Fs_compat." callee
  || String.starts_with ~prefix:"In_channel." callee
  || String.starts_with ~prefix:"Mutex." callee
  || String.starts_with ~prefix:"Out_channel." callee
  || String.starts_with ~prefix:"Random." callee
  || String.starts_with ~prefix:"Thread." callee
  || String.starts_with ~prefix:"Time_compat.now" callee
  || String.starts_with ~prefix:"Mtime_clock." callee
  || String.starts_with ~prefix:"Ptime_clock." callee
  || String.starts_with ~prefix:"Mirage_crypto_rng." callee
  || contains_path_segment callee "Log"
  || contains_path_segment callee "Logs"
;;

let location_start location =
  let position = location.Location.loc_start in
  position.Lexing.pos_lnum, position.pos_cnum - position.pos_bol
;;

let rec pattern_scope_name (pattern : pattern) =
  match pattern.pat_desc with
  | Tpat_var (_, name, _) -> Some name.txt
  | Tpat_alias (nested, _, name, _, _) ->
    (match pattern_scope_name nested with
     | Some nested_name -> Some nested_name
     | None -> Some name.txt)
  | _ -> None
;;

let compare_site (left : site) (right : site) =
  let compare_field first second next =
    let ordering = String.compare first second in
    if ordering = 0 then next () else ordering
  in
  compare_field
    left.path
    right.path
    (fun () ->
       compare_field
         (category_to_string left.category)
         (category_to_string right.category)
         (fun () ->
            compare_field
              left.scope
              right.scope
              (fun () ->
                 compare_field
                   left.callee
                   right.callee
                   (fun () ->
                      let line_order = Int.compare left.line right.line in
                      if line_order = 0
                      then Int.compare left.column right.column
                      else line_order))))
;;

let audit_structure ~path ~pure structure =
  let sites = ref [] in
  let scopes = ref [] in
  let current_scope () =
    match List.rev !scopes with
    | [] -> "<toplevel>"
    | names -> String.concat "/" names
  in
  let add_site ~category ~callee location =
    let line, column = location_start location in
    sites :=
      { category; path; scope = current_scope (); callee; line; column }
      :: !sites
  in
  let with_scope name run =
    scopes := name :: !scopes;
    Fun.protect run ~finally:(fun () -> scopes := List.tl !scopes)
  in
  let iterator =
    { Tast_iterator.default_iterator with
      value_binding =
        (fun self binding ->
           let name =
             match pattern_scope_name binding.vb_pat with
             | Some name -> name
             | None ->
               let line, column = location_start binding.vb_loc in
               Printf.sprintf "<pattern@%d:%d>" line column
           in
           with_scope name (fun () ->
             Tast_iterator.default_iterator.value_binding self binding))
    ; module_binding =
        (fun self binding ->
           let name =
             match binding.mb_name.txt with
             | Some name -> "module:" ^ name
             | None ->
               let line, column = location_start binding.mb_loc in
               Printf.sprintf "module:<anonymous@%d:%d>" line column
           in
           with_scope name (fun () ->
             Tast_iterator.default_iterator.module_binding self binding))
    ; expr =
        (fun self expression ->
           (match expression.exp_desc with
            | Texp_apply
                ({ exp_desc = Texp_ident (resolved_path, _, _); _ }, _) ->
              let callee =
                resolved_path |> Path.name |> normalize_resolved_callee
              in
              Option.iter
                (fun category ->
                   add_site ~category ~callee expression.exp_loc)
                (category_for_resolved_callee callee);
              if pure && effectful_resolved_callee callee
              then
                add_site
                  ~category:Effect_in_pure_module
                  ~callee
                  expression.exp_loc
            | _ -> ());
           Tast_iterator.default_iterator.expr self expression)
    }
  in
  iterator.structure iterator structure;
  List.sort compare_site !sites
;;

module Entry_key = struct
  type t = category * string * string * string

  let compare = compare
end

module Entry_map = Map.Make (Entry_key)
module Entry_key_set = Set.Make (Entry_key)

let entry_key (entry : entry) =
  entry.category, entry.path, entry.scope, entry.callee
;;

let compare_entry (left : entry) (right : entry) =
  Entry_key.compare (entry_key left) (entry_key right)
;;

let entries_of_sites (sites : site list) : entry list =
  let counts =
    List.fold_left
      (fun acc (site : site) ->
         let key = site.category, site.path, site.scope, site.callee in
         let count = Option.value ~default:0 (Entry_map.find_opt key acc) in
         Entry_map.add key (count + 1) acc)
      Entry_map.empty
      sites
  in
  Entry_map.bindings counts
  |> List.map (fun ((category, path, scope, callee), count) ->
    { category; path; scope; callee; count })
;;

let rec files_with_suffix ~suffix directory acc =
  match Sys.readdir directory with
  | exception Sys_error _ -> acc
  | entries ->
    Array.fold_left
      (fun acc name ->
         let path = Filename.concat directory name in
         match (Unix.lstat path).st_kind with
         | Unix.S_DIR -> files_with_suffix ~suffix path acc
         | Unix.S_REG when Filename.check_suffix name suffix -> path :: acc
         | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
         | Unix.S_SOCK -> acc
         | exception Unix.Unix_error _ -> acc)
      acc
      entries
;;

let normalize_relative_path path =
  let path = if String.starts_with ~prefix:"./" path then String.sub path 2 (String.length path - 2) else path in
  let components = String.split_on_char '/' path in
  if path = ""
     || not (Filename.is_relative path)
     || List.exists (String.equal "..") components
  then Error (Printf.sprintf "expected repository-relative path, got %S" path)
  else Ok (String.concat "/" (List.filter (fun part -> part <> ".") components))
;;

let strip_root_prefix ~root path =
  let prefix = root ^ Filename.dir_sep in
  if String.starts_with ~prefix path
  then Some (String.sub path (String.length prefix) (String.length path - String.length prefix))
  else None
;;

let source_candidate_of_location ~root path =
  let path =
    if Filename.is_relative path
    then path
    else Option.value ~default:path (strip_root_prefix ~root path)
  in
  let candidates =
    if Filename.check_suffix path ".pp.ml"
    then
      [ String.sub path 0 (String.length path - String.length ".pp.ml") ^ ".ml"
      ; path
      ]
    else [ path ]
  in
  List.find_opt (fun candidate -> Sys.file_exists (Filename.concat root candidate)) candidates
;;

let source_path_of_structure ~root ~fallback (structure : structure) =
  let from_items =
    List.find_map
      (fun item ->
         source_candidate_of_location
           ~root
           item.str_loc.Location.loc_start.Lexing.pos_fname)
      structure.str_items
  in
  match from_items with
  | Some _ as source -> source
  | None -> Option.bind fallback (source_candidate_of_location ~root)
;;

let path_under_roots ~source_roots path =
  List.exists
    (fun root -> String.equal path root || String.starts_with ~prefix:(root ^ "/") path)
    source_roots
;;

module String_map = Map.Make (String)

let read_cmt_implementation path =
  try
    let info = Cmt_format.read_cmt path in
    match info.cmt_annots with
    | Cmt_format.Implementation structure -> Ok (Some (info, structure))
    | Packed _ | Interface _ | Partial_implementation _ | Partial_interface _ ->
      Ok None
  with
  | Sys_error message -> Error message
  | Cmt_format.Error _ as error ->
    Error (Format.asprintf "%a" Location.report_exception error)
  | exn -> Error (Printexc.to_string exn)
;;

let audit_repository ~root ~build_dir ~source_roots ~pure_modules =
  let* normalized_roots =
    List.fold_left
      (fun result path ->
         let* paths = result in
         let* path = normalize_relative_path path in
         Ok (path :: paths))
      (Ok [])
      source_roots
    |> Result.map List.rev
  in
  let* normalized_pure =
    List.fold_left
      (fun result path ->
         let* paths = result in
         let* path = normalize_relative_path path in
         Ok (path :: paths))
      (Ok [])
      pure_modules
    |> Result.map List.rev
  in
  let pure_set = String_set.of_list normalized_pure in
  let required_directories = build_dir :: List.map (Filename.concat root) normalized_roots in
  let missing_directories =
    List.filter
      (fun path ->
         try not (Sys.is_directory path) with
         | Sys_error _ -> true)
      required_directories
  in
  if missing_directories <> []
  then Error ("required audit directories are missing:\n" ^ String.concat "\n" missing_directories)
  else
  let production_sources =
    List.fold_left
      (fun acc source_root ->
         files_with_suffix ~suffix:".ml" (Filename.concat root source_root) acc)
      []
      normalized_roots
    |> List.filter_map (strip_root_prefix ~root)
    |> List.sort_uniq String.compare
  in
  let production_set = String_set.of_list production_sources in
  let unknown_pure = String_set.diff pure_set production_set |> String_set.elements in
  if unknown_pure <> []
  then
    Error
      ("pure-module registry contains non-production paths:\n"
       ^ String.concat "\n" unknown_pure)
  else (
    let cmt_files = files_with_suffix ~suffix:".cmt" build_dir [] |> List.sort String.compare in
    let* source_cmts =
      List.fold_left
        (fun result cmt_path ->
           let* source_cmts = result in
           let* implementation = read_cmt_implementation cmt_path in
           match implementation with
           | None -> Ok source_cmts
           | Some (info, structure) ->
             let fallback = info.Cmt_format.cmt_sourcefile in
             (match source_path_of_structure ~root ~fallback structure with
              | Some source when path_under_roots ~source_roots:normalized_roots source ->
                if String_map.mem source source_cmts
                then Ok source_cmts
                else Ok (String_map.add source (cmt_path, structure) source_cmts)
              | Some _ | None -> Ok source_cmts))
        (Ok String_map.empty)
        cmt_files
    in
    let compiled_set =
      source_cmts |> String_map.bindings |> List.map fst |> String_set.of_list
    in
    let missing = String_set.diff production_set compiled_set |> String_set.elements in
    if missing <> []
    then
      Error
        (Printf.sprintf
           "typed-tree coverage is incomplete: %d production source(s) have no .cmt:\n%s"
           (List.length missing)
           (String.concat "\n" missing))
    else (
      let sites =
        source_cmts
        |> String_map.bindings
        |> List.concat_map (fun (path, (_cmt_path, structure)) ->
          audit_structure ~path ~pure:(String_set.mem path pure_set) structure)
        |> List.sort compare_site
      in
      Ok
        { sites
        ; entries = entries_of_sites sites
        ; scanned_sources = List.length production_sources
        ; scanned_cmt_files = List.length cmt_files
        }))
;;

let trim = String.trim

let read_lines path =
  match In_channel.open_text path with
  | exception Sys_error message -> Error message
  | channel ->
    let rec loop line_number lines =
      match In_channel.input_line channel with
      | Some line -> loop (line_number + 1) ((line_number, line) :: lines)
      | None -> Ok (List.rev lines)
      | exception Sys_error message -> Error message
    in
    let result = loop 1 [] in
    In_channel.close channel;
    result
;;

let read_module_paths path =
  let* lines = read_lines path in
  let rec collect modules = function
    | [] -> Ok (List.sort_uniq String.compare modules)
    | (line_number, raw) :: rest ->
      let value = trim raw in
      if value = "" || value.[0] = '#'
      then collect modules rest
      else (
        match normalize_relative_path value with
        | Error message -> Error (Printf.sprintf "%s:%d: %s" path line_number message)
        | Ok relative -> collect (relative :: modules) rest)
  in
  collect [] lines
;;

let read_pure_modules ~root path =
  let* modules = read_module_paths path in
  match
    List.find_opt
      (fun relative -> not (Sys.file_exists (Filename.concat root relative)))
      modules
  with
  | None -> Ok modules
  | Some relative -> Error (Printf.sprintf "pure module does not exist: %s" relative)
;;

let parse_positive_int ~path ~line_number value =
  match int_of_string_opt value with
  | Some count when count > 0 -> Ok count
  | _ ->
    Error
      (Printf.sprintf
         "%s:%d: expected positive count, got %S"
         path
         line_number
         value)
;;

let read_baseline path =
  let* lines = read_lines path in
  let rec collect entries = function
    | [] -> Ok (List.sort compare_entry entries)
    | (line_number, raw) :: rest ->
      let value = trim raw in
      if value = "" || value.[0] = '#'
      then collect entries rest
      else (
        match String.split_on_char '\t' raw with
        | [ category; entry_path; scope; callee; count ] ->
          let* category = category_of_string category in
          let* count = parse_positive_int ~path ~line_number count in
          collect ({ category; path = entry_path; scope; callee; count } :: entries) rest
        | _ ->
          Error
            (Printf.sprintf
               "%s:%d: expected category<TAB>path<TAB>scope<TAB>callee<TAB>count"
               path
               line_number))
  in
  let* entries = collect [] lines in
  let rec reject_duplicates = function
    | left :: right :: _ when Entry_key.compare (entry_key left) (entry_key right) = 0 ->
      Error
        (Printf.sprintf
           "%s: duplicate baseline key: %s %s %s %s"
           path
           (category_to_string left.category)
           left.path
           left.scope
           left.callee)
    | _ :: rest -> reject_duplicates rest
    | [] -> Ok entries
  in
  reject_duplicates entries
;;

let write_baseline path entries =
  match Out_channel.open_text path with
  | exception Sys_error message -> Error message
  | channel ->
    let result =
      try
        output_string channel "# ocaml-boundary-audit-v2 typed-tree baseline\n";
        output_string channel "# category<TAB>path<TAB>scope<TAB>resolved-callee<TAB>count\n";
        entries
        |> List.sort compare_entry
        |> List.iter (fun entry ->
          Printf.fprintf
            channel
            "%s\t%s\t%s\t%s\t%d\n"
            (category_to_string entry.category)
            entry.path
            entry.scope
            entry.callee
            entry.count);
        Ok ()
      with
      | Sys_error message -> Error message
    in
    Out_channel.close channel;
    result
;;

let entry_map entries =
  List.fold_left
    (fun map entry -> Entry_map.add (entry_key entry) entry.count map)
    Entry_map.empty
    entries
;;

let compare ~baseline ~current =
  let baseline_map = entry_map baseline in
  let current_map = entry_map current in
  let keys =
    Entry_map.fold
      (fun key _ keys -> Entry_key_set.add key keys)
      baseline_map
      Entry_key_set.empty
  in
  let keys =
    Entry_map.fold (fun key _ keys -> Entry_key_set.add key keys) current_map keys
  in
  let increases, reductions =
    Entry_key_set.fold
      (fun ((category, path, scope, callee) as key) (increases, reductions) ->
         let baseline_count = Option.value ~default:0 (Entry_map.find_opt key baseline_map) in
         let current_count = Option.value ~default:0 (Entry_map.find_opt key current_map) in
         let entry = { category; path; scope; callee; count = current_count } in
         if current_count > baseline_count
         then { entry; baseline_count; current_count } :: increases, reductions
         else if current_count < baseline_count
         then increases, { entry; baseline_count; current_count } :: reductions
         else increases, reductions)
      keys
      ([], [])
  in
  { increases = List.rev increases; reductions = List.rev reductions }
;;

let site_to_text (site : site) =
  Printf.sprintf
    "%s:%d:%d [%s] %s (%s)"
    site.path
    site.line
    site.column
    (category_to_string site.category)
    site.callee
    site.scope
;;

let report_to_text report =
  let header =
    Printf.sprintf
      "typed sources=%d cmt files inspected=%d findings=%d\n"
      report.scanned_sources
      report.scanned_cmt_files
      (List.length report.sites)
  in
  header ^ String.concat "\n" (List.map site_to_text report.sites)
  ^ if report.sites = [] then "" else "\n"
;;

let report_to_json report =
  `Assoc
    [ "schema_version", `Int 2
    ; "scanned_sources", `Int report.scanned_sources
    ; "scanned_cmt_files", `Int report.scanned_cmt_files
    ; ( "sites"
      , `List
          (List.map
             (fun (site : site) ->
                `Assoc
                  [ "category", `String (category_to_string site.category)
                  ; "path", `String site.path
                  ; "scope", `String site.scope
                  ; "callee", `String site.callee
                  ; "line", `Int site.line
                  ; "column", `Int site.column
                  ])
             report.sites) )
    ]
  |> Yojson.Safe.to_string
;;

let drift_to_text direction drift =
  Printf.sprintf
    "%s %s %s %s %s: %d -> %d\n"
    direction
    (category_to_string drift.entry.category)
    drift.entry.path
    drift.entry.scope
    drift.entry.callee
    drift.baseline_count
    drift.current_count
;;

let comparison_to_text comparison =
  String.concat ""
    (List.map (drift_to_text "INCREASE") comparison.increases
     @ List.map (drift_to_text "REDUCTION") comparison.reductions)
;;
