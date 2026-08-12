type action = Report | Check | Write_baseline
type output_format = Text | Json

let usage =
  "ocaml_boundary_audit [--root DIR] [--build-dir DIR] [--pure-modules FILE] \
   [--previous-pure-modules FILE] [--baseline FILE] [--previous-baseline FILE] \
   [--check|--write-baseline] [--format text|json]"
;;

let () =
  let root = ref "." in
  let build_dir = ref "_build/default" in
  let pure_modules_path = ref "scripts/ocaml-pure-modules.txt" in
  let previous_pure_modules_path = ref None in
  let baseline_path = ref "scripts/ocaml-boundary-baseline.tsv" in
  let previous_baseline_path = ref None in
  let action = ref Report in
  let output_format = ref Text in
  let set_action next () =
    match !action with
    | Report -> action := next
    | Check | Write_baseline ->
      raise (Arg.Bad "--check and --write-baseline are mutually exclusive")
  in
  let set_format = function
    | "text" -> output_format := Text
    | "json" -> output_format := Json
    | value -> raise (Arg.Bad (Printf.sprintf "unknown format %S" value))
  in
  Arg.parse
    [ "--root", Arg.Set_string root, "DIR repository root"
    ; "--build-dir", Arg.Set_string build_dir, "DIR Dune build directory containing .cmt files"
    ; ( "--pure-modules"
      , Arg.Set_string pure_modules_path
      , "FILE repository-relative pure-module registry" )
    ; ( "--previous-pure-modules"
      , Arg.String (fun path -> previous_pure_modules_path := Some path)
      , "FILE PR-base pure-module registry; living entries may not be removed" )
    ; "--baseline", Arg.Set_string baseline_path, "FILE exact-site baseline"
    ; ( "--previous-baseline"
      , Arg.String (fun path -> previous_baseline_path := Some path)
      , "FILE base revision baseline; current baseline may only decrease" )
    ; "--check", Arg.Unit (set_action Check), "fail on any baseline drift"
    ; ( "--write-baseline"
      , Arg.Unit (set_action Write_baseline)
      , "write only an initial or downward baseline" )
    ; "--format", Arg.String set_format, "text|json report format"
    ]
    (fun value -> raise (Arg.Bad (Printf.sprintf "unexpected argument %S" value)))
    usage;
  let run () =
    let open Result.Syntax in
    let* root =
      match Unix.realpath !root with
      | root -> Ok root
      | exception Unix.Unix_error (error, operation, target) ->
        Error
          (Printf.sprintf
             "%s(%s): %s"
             operation
             target
             (Unix.error_message error))
    in
    let resolve path =
      if Filename.is_relative path then Filename.concat root path else path
    in
    let* pure_modules =
      Ocaml_boundary_audit.read_pure_modules ~root (resolve !pure_modules_path)
    in
    let* () =
      match !previous_pure_modules_path with
      | None -> Ok ()
      | Some path ->
        let* previous = Ocaml_boundary_audit.read_module_paths (resolve path) in
        let current = List.sort_uniq String.compare pure_modules in
        let removed_living_modules =
          List.filter
            (fun module_path ->
               Sys.file_exists (Filename.concat root module_path)
               && not (List.mem module_path current))
            previous
        in
        if removed_living_modules = []
        then Ok ()
        else
          Error
            ("The pure-module registry may only grow; these living modules were removed:\n"
             ^ String.concat "\n" removed_living_modules)
    in
    let* report =
      Ocaml_boundary_audit.audit_repository
        ~root
        ~build_dir:(resolve !build_dir)
        ~source_roots:Ocaml_boundary_audit.default_source_roots
        ~pure_modules
    in
    let hard_entries =
      List.filter
        (fun (entry : Ocaml_boundary_audit.entry) ->
           entry.category <> Ocaml_boundary_audit.Effect_in_pure_module)
        report.entries
    in
    let pure_effect_sites =
      List.filter
        (fun (site : Ocaml_boundary_audit.site) ->
           site.category = Ocaml_boundary_audit.Effect_in_pure_module)
        report.sites
    in
    let validate_baseline baseline =
      match
        List.find_opt
          (fun (entry : Ocaml_boundary_audit.entry) ->
             entry.category = Ocaml_boundary_audit.Effect_in_pure_module)
          baseline
      with
      | None -> Ok ()
      | Some entry ->
        Error
          (Printf.sprintf
             "pure-module effects cannot be baselined: %s %s\n"
             entry.path
             entry.callee)
    in
    let validate_baseline_direction baseline =
      let* () = validate_baseline baseline in
      match !previous_baseline_path with
      | None -> Ok ()
      | Some path ->
        let* previous = Ocaml_boundary_audit.read_baseline (resolve path) in
        let* () = validate_baseline previous in
        let comparison =
          Ocaml_boundary_audit.compare ~baseline:previous ~current:baseline
        in
        if comparison.increases = []
        then Ok ()
        else
          Error
            (Ocaml_boundary_audit.comparison_to_text comparison
             ^ "The committed baseline may only decrease from its base revision.\n")
    in
    match !action with
    | Report ->
      let output =
        match !output_format with
        | Text -> Ocaml_boundary_audit.report_to_text report
        | Json -> Ocaml_boundary_audit.report_to_json report ^ "\n"
      in
      print_string output;
      Ok ()
    | Check ->
      if pure_effect_sites <> []
      then
        Error
          ("A registered pure module performs an external effect:\n"
           ^ Ocaml_boundary_audit.report_to_text
               { report with sites = pure_effect_sites })
      else (
        let baseline_path = resolve !baseline_path in
        let* baseline = Ocaml_boundary_audit.read_baseline baseline_path in
        let* () = validate_baseline_direction baseline in
        let comparison =
          Ocaml_boundary_audit.compare ~baseline ~current:hard_entries
        in
        if comparison.increases = [] && comparison.reductions = []
        then (
          Printf.printf
            "ocaml-boundary-audit: PASS (%d typed sources, %d mechanical debt buckets)\n"
            report.scanned_sources
            (List.length hard_entries);
          Ok ())
        else
          Error
            (Ocaml_boundary_audit.comparison_to_text comparison
             ^ (if comparison.increases <> []
                then
                  "New partial extraction or failure erasure is forbidden. Resolve the boundary instead of raising the baseline.\n"
                else "")
             ^ (if comparison.reductions <> []
                then
                  "Debt decreased; run --write-baseline and commit the downward baseline update.\n"
                else "")))
    | Write_baseline ->
      if pure_effect_sites <> []
      then Error "Refusing to baseline effects inside a registered pure module.\n"
      else (
        let baseline_path = resolve !baseline_path in
        let* () =
          if Sys.file_exists baseline_path
          then
            let* baseline = Ocaml_boundary_audit.read_baseline baseline_path in
            let* () = validate_baseline_direction baseline in
            let comparison =
              Ocaml_boundary_audit.compare ~baseline ~current:hard_entries
            in
            if comparison.increases = []
            then Ok ()
            else
              Error
                (Ocaml_boundary_audit.comparison_to_text comparison
                 ^ "Refusing to raise the mechanical-debt baseline.\n")
          else (
            match !previous_baseline_path with
            | None -> Ok ()
            | Some _ ->
              Error
                "The current baseline is missing although the base revision has one.\n")
        in
        let* () = Ocaml_boundary_audit.write_baseline baseline_path hard_entries in
        Printf.printf
          "ocaml-boundary-audit: wrote %d typed mechanical buckets to %s\n"
          (List.length hard_entries)
          baseline_path;
        Ok ())
  in
  match run () with
  | Ok () -> ()
  | Error message ->
    prerr_endline ("ocaml-boundary-audit: FAIL\n" ^ message);
    exit 1
;;
