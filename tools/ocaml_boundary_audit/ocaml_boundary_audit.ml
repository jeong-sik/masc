type category =
  | Partial_extraction
  | Failure_erasure
  | Implicit_default
  | Catch_all_exception
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
  | Implicit_default -> "implicit_default"
  | Catch_all_exception -> "catch_all_exception"
  | Effect_in_pure_module -> "effect_in_pure_module"
;;

let category_of_string = function
  | "partial_extraction" -> Ok Partial_extraction
  | "failure_erasure" -> Ok Failure_erasure
  | "implicit_default" -> Ok Implicit_default
  | "catch_all_exception" -> Ok Catch_all_exception
  | "effect_in_pure_module" -> Ok Effect_in_pure_module
  | value -> Error (Printf.sprintf "unknown boundary-audit category %S" value)
;;

let ( let* ) = Result.bind

let rec longident_to_string : Longident.t -> string = function
  | Lident name -> name
  | Ldot (parent, name) ->
    longident_to_string parent.Location.txt ^ "." ^ name.Location.txt
  | Lapply (left, right) ->
    Printf.sprintf
      "%s(%s)"
      (longident_to_string left.Location.txt)
      (longident_to_string right.Location.txt)
;;

let location_start location =
  let position = location.Location.loc_start in
  position.Lexing.pos_lnum, position.pos_cnum - position.pos_bol
;;

let pattern_scope_name pattern =
  let rec loop (pattern : Parsetree.pattern) =
    match pattern.ppat_desc with
    | Ppat_var name -> Some name.txt
    | Ppat_alias (_, name) -> Some name.txt
    | Ppat_constraint (nested, _) | Ppat_open (_, nested) -> loop nested
    | _ -> None
  in
  match loop pattern with
  | Some name -> name
  | None ->
    let line, column = location_start pattern.ppat_loc in
    Printf.sprintf "<pattern@%d:%d>" line column
;;

let rec catches_every_exception (pattern : Parsetree.pattern) =
  match pattern.ppat_desc with
  | Ppat_any | Ppat_var _ -> true
  | Ppat_alias (nested, _)
  | Ppat_constraint (nested, _)
  | Ppat_open (_, nested) -> catches_every_exception nested
  | Ppat_or (left, right) ->
    catches_every_exception left || catches_every_exception right
  | _ -> false
;;

let rec is_catch_all_exception_pattern (pattern : Parsetree.pattern) =
  match pattern.ppat_desc with
  | Ppat_exception nested -> catches_every_exception nested
  | Ppat_alias (nested, _)
  | Ppat_constraint (nested, _)
  | Ppat_open (_, nested) -> is_catch_all_exception_pattern nested
  | Ppat_or (left, right) ->
    is_catch_all_exception_pattern left
    || is_catch_all_exception_pattern right
  | _ -> false
;;

let category_for_callee = function
  | "Option.get" | "Result.get_ok" -> Some Partial_extraction
  | "Result.to_option" | "Parse_outcome.to_option" -> Some Failure_erasure
  | "Option.value" -> Some Implicit_default
  | _ -> None
;;

let starts_with ~prefix value =
  let prefix_length = String.length prefix in
  String.length value >= prefix_length
  && String.equal (String.sub value 0 prefix_length) prefix
;;

let effectful_callee callee =
  let exact =
    [ "open_in"
    ; "open_in_bin"
    ; "open_out"
    ; "open_out_bin"
    ; "close_in"
    ; "close_out"
    ; "read_line"
    ; "print_endline"
    ; "prerr_endline"
    ; "Random.bits"
    ; "Random.bool"
    ; "Random.float"
    ; "Random.full_int"
    ; "Random.int"
    ; "Random.int32"
    ; "Random.int64"
    ; "Random.nativebits"
    ; "Random.self_init"
    ; "Random.set_state"
    ; "Random.State.make_self_init"
    ; "Sys.chdir"
    ; "Sys.command"
    ; "Sys.file_exists"
    ; "Sys.getcwd"
    ; "Sys.getenv"
    ; "Sys.getenv_opt"
    ; "Sys.is_directory"
    ; "Sys.mkdir"
    ; "Sys.readdir"
    ; "Sys.remove"
    ; "Sys.rename"
    ; "Sys.rmdir"
    ; "Sys.time"
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
    ; "Unix.truncate"
    ; "Unix.unlink"
    ; "Unix.wait"
    ; "Unix.waitpid"
    ; "Unix.write"
    ]
  in
  List.mem callee exact
  || starts_with ~prefix:"Eio." callee
  || starts_with ~prefix:"Eio_main." callee
  || starts_with ~prefix:"In_channel." callee
  || starts_with ~prefix:"Out_channel." callee
  || starts_with ~prefix:"Domain.spawn" callee
  || starts_with ~prefix:"Thread.create" callee
;;

let parse_implementation ~path source =
  let lexbuf = Lexing.from_string source in
  Location.init lexbuf path;
  try Ok (Parse.implementation lexbuf) with
  | (Syntaxerr.Error _ as error)
  | (Syntaxerr.Escape_error as error)
  | (Lexer.Error _ as error) ->
    Error (Format.asprintf "%a" Location.report_exception error)
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

let audit_source ~path ~pure source =
  let* structure = parse_implementation ~path source in
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
    { Ast_iterator.default_iterator with
      value_binding =
        (fun self binding ->
           with_scope
             (pattern_scope_name binding.pvb_pat)
             (fun () ->
                Ast_iterator.default_iterator.value_binding self binding))
    ; module_binding =
        (fun self binding ->
           let name =
             match binding.pmb_name.txt with
             | Some name -> "module:" ^ name
             | None ->
               let line, column = location_start binding.pmb_loc in
               Printf.sprintf "module:<anonymous@%d:%d>" line column
           in
           with_scope name (fun () ->
             Ast_iterator.default_iterator.module_binding self binding))
    ; expr =
        (fun self expression ->
           (match expression.pexp_desc with
            | Pexp_apply
                ({ pexp_desc = Pexp_ident identifier; _ }, _) ->
              let callee = longident_to_string identifier.txt in
              Option.iter
                (fun category ->
                   add_site ~category ~callee expression.pexp_loc)
                (category_for_callee callee);
              if pure && effectful_callee callee
              then
                add_site
                  ~category:Effect_in_pure_module
                  ~callee
                  expression.pexp_loc
            | Pexp_try (_, cases) ->
              List.iter
                (fun (case : Parsetree.case) ->
                   if Option.is_none case.pc_guard
                      && catches_every_exception case.pc_lhs
                   then
                     add_site
                       ~category:Catch_all_exception
                       ~callee:"try-with-catch-all"
                       case.pc_lhs.ppat_loc)
                cases
            | Pexp_match (_, cases) ->
              List.iter
                (fun (case : Parsetree.case) ->
                   if Option.is_none case.pc_guard
                      && is_catch_all_exception_pattern case.pc_lhs
                   then
                     add_site
                       ~category:Catch_all_exception
                       ~callee:"match-exception-catch-all"
                       case.pc_lhs.ppat_loc)
                cases
            | _ -> ());
           Ast_iterator.default_iterator.expr self expression)
    }
  in
  iterator.structure iterator structure;
  Ok (List.sort compare_site !sites)
;;

module Entry_key = struct
  type t = category * string * string * string

  let compare = compare
end

module Entry_map = Map.Make (Entry_key)

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
         let count =
           match Entry_map.find_opt key acc with
           | Some count -> count
           | None -> 0
         in
         Entry_map.add key (count + 1) acc)
      Entry_map.empty
      sites
  in
  Entry_map.bindings counts
  |> List.map (fun ((category, path, scope, callee), count) ->
    { category; path; scope; callee; count })
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

let read_file path =
  match In_channel.open_bin path with
  | exception Sys_error message -> Error message
  | channel ->
    let result =
      try Ok (In_channel.input_all channel) with
      | Sys_error message -> Error message
    in
    In_channel.close channel;
    result
;;

let normalize_relative_path path =
  let components = String.split_on_char '/' path in
  if path = ""
     || not (Filename.is_relative path)
     || List.exists (fun component -> component = "..") components
  then Error (Printf.sprintf "expected repository-relative path, got %S" path)
  else Ok (String.concat "/" (List.filter (( <> ) ".") components))
;;

let read_pure_modules ~root path =
  let* lines = read_lines path in
  let rec collect modules = function
    | [] -> Ok (List.sort_uniq String.compare modules)
    | (line_number, raw) :: rest ->
      let value = trim raw in
      if value = "" || value.[0] = '#'
      then collect modules rest
      else (
        match normalize_relative_path value with
        | Error message ->
          Error (Printf.sprintf "%s:%d: %s" path line_number message)
        | Ok relative ->
          let absolute = Filename.concat root relative in
          if Sys.file_exists absolute
          then collect (relative :: modules) rest
          else
            Error
              (Printf.sprintf
                 "%s:%d: pure module does not exist: %s"
                 path
                 line_number
                 relative))
  in
  collect [] lines
;;

let has_suffix ~suffix value = Filename.check_suffix value suffix

let rec implementation_files directory =
  let* names =
    match Sys.readdir directory with
    | names -> Ok (Array.to_list names |> List.sort String.compare)
    | exception Sys_error message -> Error message
  in
  let rec collect files = function
    | [] -> Ok files
    | name :: rest ->
      let path = Filename.concat directory name in
      let* kind =
        match (Unix.lstat path).Unix.st_kind with
        | kind -> Ok kind
        | exception Unix.Unix_error (error, operation, target) ->
          Error
            (Printf.sprintf
               "%s(%s): %s"
               operation
               target
               (Unix.error_message error))
      in
      (match kind with
       | Unix.S_DIR ->
         let* nested = implementation_files path in
         collect (List.rev_append nested files) rest
       | Unix.S_REG when has_suffix ~suffix:".ml" name ->
         collect (path :: files) rest
       | _ -> collect files rest)
  in
  let* files = collect [] names in
  Ok (List.sort String.compare files)
;;

let relative_path ~root path =
  let root =
    if has_suffix ~suffix:Filename.dir_sep root
    then root
    else root ^ Filename.dir_sep
  in
  if starts_with ~prefix:root path
  then String.sub path (String.length root) (String.length path - String.length root)
  else path
;;

let audit_repository ~root ~source_roots ~pure_modules =
  let rec collect_roots files = function
    | [] -> Ok files
    | source_root :: rest ->
      let* source_root = normalize_relative_path source_root in
      let directory = Filename.concat root source_root in
      if not (Sys.file_exists directory)
      then Error (Printf.sprintf "source root does not exist: %s" source_root)
      else
        let* found = implementation_files directory in
        collect_roots (List.rev_append found files) rest
  in
  let* files = collect_roots [] source_roots in
  let files = List.sort_uniq String.compare files in
  let rec audit_files sites = function
    | [] -> Ok sites
    | absolute :: rest ->
      let path = relative_path ~root absolute in
      let* source = read_file absolute in
      let* file_sites =
        audit_source ~path ~pure:(List.mem path pure_modules) source
      in
      audit_files (List.rev_append file_sites sites) rest
  in
  let* sites = audit_files [] files in
  let sites = List.sort compare_site sites in
  Ok { sites; entries = entries_of_sites sites }
;;

let split_tabs value = String.split_on_char '\t' value

let validate_baseline_field ~path ~line_number ~name value =
  if value = "" || String.contains value '\n' || String.contains value '\r'
  then
    Error
      (Printf.sprintf
         "%s:%d: invalid empty or multiline %s"
         path
         line_number
         name)
  else Ok value
;;

let read_baseline path =
  let* lines = read_lines path in
  let rec collect seen entries = function
    | [] -> Ok (List.sort compare_entry entries)
    | (line_number, raw) :: rest ->
      let line = trim raw in
      if line = "" || line.[0] = '#'
      then collect seen entries rest
      else (
        match split_tabs raw with
        | [ category; entry_path; scope; callee; count ] ->
          let* category =
            match category_of_string category with
            | Ok value -> Ok value
            | Error message ->
              Error (Printf.sprintf "%s:%d: %s" path line_number message)
          in
          let* entry_path =
            validate_baseline_field
              ~path
              ~line_number
              ~name:"path"
              entry_path
          in
          let* scope =
            validate_baseline_field ~path ~line_number ~name:"scope" scope
          in
          let* callee =
            validate_baseline_field ~path ~line_number ~name:"callee" callee
          in
          let* count =
            match int_of_string_opt count with
            | Some count when count > 0 -> Ok count
            | _ ->
              Error
                (Printf.sprintf
                   "%s:%d: count must be a positive integer"
                   path
                   line_number)
          in
          let entry = { category; path = entry_path; scope; callee; count } in
          let key = entry_key entry in
          if Entry_map.mem key seen
          then
            Error
              (Printf.sprintf "%s:%d: duplicate boundary baseline entry" path line_number)
          else collect (Entry_map.add key count seen) (entry :: entries) rest
        | _ ->
          Error
            (Printf.sprintf
               "%s:%d: expected 5 tab-separated fields"
               path
               line_number))
  in
  collect Entry_map.empty [] lines
;;

let baseline_header =
  "# ocaml-boundary-audit-v1\n\
   # category<TAB>path<TAB>scope<TAB>callee<TAB>count\n\
   # Regenerate downward: bash scripts/ocaml-boundary-ratchet.sh --regenerate\n"
;;

let entry_to_line (entry : entry) =
  Printf.sprintf
    "%s\t%s\t%s\t%s\t%d\n"
    (category_to_string entry.category)
    entry.path
    entry.scope
    entry.callee
    entry.count
;;

let write_baseline path (entries : entry list) =
  let invalid (entry : entry) =
    List.exists
      (fun value ->
         value = ""
         || String.contains value '\t'
         || String.contains value '\n'
         || String.contains value '\r')
      [ entry.path; entry.scope; entry.callee ]
    || entry.count <= 0
  in
  match List.find_opt invalid entries with
  | Some entry ->
    Error
      (Printf.sprintf
         "cannot serialize invalid baseline entry %s:%s"
         entry.path
         entry.scope)
  | None ->
    let contents =
      List.sort compare_entry entries
      |> List.map entry_to_line
      |> String.concat ""
      |> ( ^ ) baseline_header
    in
    let directory = Filename.dirname path in
    (match Filename.open_temp_file ~temp_dir:directory "ocaml-boundary-" ".tmp" with
     | exception Sys_error message -> Error message
     | temporary_path, channel ->
       let cleanup_message () =
         match Sys.remove temporary_path with
         | () -> ""
         | exception Sys_error cleanup_error ->
           "; temporary-file cleanup failed: " ^ cleanup_error
       in
       (match Out_channel.output_string channel contents with
        | () ->
          (match Out_channel.close channel with
           | () ->
             (match Sys.rename temporary_path path with
              | () -> Ok ()
              | exception Sys_error message ->
                Error (message ^ cleanup_message ()))
           | exception Sys_error message ->
             Error (message ^ cleanup_message ()))
        | exception Sys_error message ->
          Out_channel.close_noerr channel;
          Error (message ^ cleanup_message ())))
;;

let entry_map entries =
  List.fold_left
    (fun map entry -> Entry_map.add (entry_key entry) entry.count map)
    Entry_map.empty
    entries
;;

let entry_of_key (category, path, scope, callee) count =
  { category; path; scope; callee; count }
;;

let compare ~baseline ~current =
  let baseline_map = entry_map baseline in
  let current_map = entry_map current in
  let keys =
    Entry_map.fold (fun key _ keys -> Entry_map.add key () keys) baseline_map Entry_map.empty
    |> fun keys ->
    Entry_map.fold (fun key _ keys -> Entry_map.add key () keys) current_map keys
  in
  let increases, reductions =
    Entry_map.fold
      (fun key () (increases, reductions) ->
         let baseline_count =
           match Entry_map.find_opt key baseline_map with
           | Some count -> count
           | None -> 0
         in
         let current_count =
           match Entry_map.find_opt key current_map with
           | Some count -> count
           | None -> 0
         in
         if current_count > baseline_count
         then
           ( { entry = entry_of_key key current_count
             ; baseline_count
             ; current_count
             }
             :: increases
           , reductions )
         else if current_count < baseline_count
         then
           ( increases
           , { entry = entry_of_key key current_count
             ; baseline_count
             ; current_count
             }
             :: reductions )
         else increases, reductions)
      keys
      ([], [])
  in
  let compare_drift left right = compare_entry left.entry right.entry in
  { increases = List.sort compare_drift increases
  ; reductions = List.sort compare_drift reductions
  }
;;

let report_to_text (report : report) =
  let buffer = Buffer.create 4096 in
  List.iter
    (fun (site : site) ->
       Printf.bprintf
         buffer
         "%s:%d:%d: %s [%s] scope=%s\n"
         site.path
         site.line
         site.column
         site.callee
         (category_to_string site.category)
         site.scope)
    report.sites;
  let totals =
    List.fold_left
      (fun totals entry ->
         let current =
           match List.assoc_opt entry.category totals with
           | Some count -> count
           | None -> 0
         in
         (entry.category, current + entry.count)
         :: List.remove_assoc entry.category totals)
      []
      report.entries
  in
  List.iter
    (fun category ->
       let total =
         match List.assoc_opt category totals with
         | Some count -> count
         | None -> 0
       in
       Printf.bprintf
         buffer
         "total.%s=%d\n"
         (category_to_string category)
         total)
    [ Partial_extraction
    ; Failure_erasure
    ; Implicit_default
    ; Catch_all_exception
    ; Effect_in_pure_module
    ];
  Buffer.contents buffer
;;

let site_to_yojson (site : site) =
  `Assoc
    [ "category", `String (category_to_string site.category)
    ; "path", `String site.path
    ; "scope", `String site.scope
    ; "callee", `String site.callee
    ; "line", `Int site.line
    ; "column", `Int site.column
    ]
;;

let report_to_json (report : report) =
  `Assoc
    [ "schema", `String "ocaml_boundary_audit.v1"
    ; "site_count", `Int (List.length report.sites)
    ; "sites", `List (List.map site_to_yojson report.sites)
    ]
  |> Yojson.Safe.pretty_to_string
;;

let drift_line label (drift : drift) =
  Printf.sprintf
    "%s %s:%s:%s:%s baseline=%d current=%d\n"
    label
    drift.entry.path
    drift.entry.scope
    (category_to_string drift.entry.category)
    drift.entry.callee
    drift.baseline_count
    drift.current_count
;;

let comparison_to_text (comparison : comparison) =
  let buffer = Buffer.create 1024 in
  List.iter
    (fun drift -> Buffer.add_string buffer (drift_line "INCREASE" drift))
    comparison.increases;
  List.iter
    (fun drift -> Buffer.add_string buffer (drift_line "REDUCTION" drift))
    comparison.reductions;
  Buffer.contents buffer
;;
