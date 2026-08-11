type action = Report | Check | Write_baseline
type output_format = Text | Json

let usage =
  "ocaml_boundary_audit [--root DIR] [--pure-modules FILE] \
   [--baseline FILE] [--previous-baseline FILE] \
   [--check|--write-baseline] [--format text|json]"
;;

let () =
  let root = ref "." in
  let pure_modules_path = ref "scripts/ocaml-pure-modules.txt" in
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
    ; ( "--pure-modules"
      , Arg.Set_string pure_modules_path
      , "FILE repository-relative pure-module registry" )
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
      Ocaml_boundary_audit.read_pure_modules
        ~root
        (resolve !pure_modules_path)
    in
    let* report =
      Ocaml_boundary_audit.audit_repository
        ~root
        ~source_roots:Ocaml_boundary_audit.default_source_roots
        ~pure_modules
    in
    let pure_effects =
      List.filter
        (fun (entry : Ocaml_boundary_audit.entry) ->
           entry.Ocaml_boundary_audit.category
           = Ocaml_boundary_audit.Effect_in_pure_module)
        report.entries
    in
    let pure_effect_sites =
      List.filter
        (fun (site : Ocaml_boundary_audit.site) ->
           site.Ocaml_boundary_audit.category
           = Ocaml_boundary_audit.Effect_in_pure_module)
        report.sites
    in
    let validate_baseline_direction baseline =
      match !previous_baseline_path with
      | None -> Ok ()
      | Some path ->
        let* previous = Ocaml_boundary_audit.read_baseline (resolve path) in
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
      if pure_effects <> []
      then
        Error
          ("A registered pure module performs an external effect:\n"
           ^ Ocaml_boundary_audit.report_to_text
               { sites = pure_effect_sites; entries = pure_effects })
      else (
        let baseline_path = resolve !baseline_path in
        let* baseline = Ocaml_boundary_audit.read_baseline baseline_path in
        let* () = validate_baseline_direction baseline in
        let comparison =
          Ocaml_boundary_audit.compare ~baseline ~current:report.entries
        in
        if comparison.increases = [] && comparison.reductions = []
        then (
          Printf.printf
            "ocaml-boundary-audit: PASS (%d exact semantic buckets)\n"
            (List.length report.entries);
          Ok ())
        else
          Error
            (Ocaml_boundary_audit.comparison_to_text comparison
             ^ (if comparison.increases <> []
                then
                  "New boundary debt is forbidden; move the decision/effect to "
                  ^ "the boundary instead of raising the baseline.\n"
                else "")
             ^ (if comparison.reductions <> []
                then
                  "Debt decreased; run --write-baseline and commit the downward "
                  ^ "baseline update.\n"
                else "")))
    | Write_baseline ->
      if pure_effects <> []
      then
        Error
          "Refusing to baseline effects inside a registered pure module.\n"
      else (
        let baseline_path = resolve !baseline_path in
        let* () =
          if Sys.file_exists baseline_path
          then
            let* baseline = Ocaml_boundary_audit.read_baseline baseline_path in
            let* () = validate_baseline_direction baseline in
            let comparison =
              Ocaml_boundary_audit.compare ~baseline ~current:report.entries
            in
            if comparison.increases = []
            then Ok ()
            else
              Error
                (Ocaml_boundary_audit.comparison_to_text comparison
                 ^ "Refusing to raise the boundary-debt baseline.\n")
          else (
            match !previous_baseline_path with
            | None -> Ok ()
            | Some _ ->
              Error
                "The current baseline is missing although the base revision has one.\n")
        in
        let* () =
          Ocaml_boundary_audit.write_baseline baseline_path report.entries
        in
        Printf.printf
          "ocaml-boundary-audit: wrote %d exact semantic buckets to %s\n"
          (List.length report.entries)
          baseline_path;
        Ok ())
  in
  match run () with
  | Ok () -> ()
  | Error message ->
    prerr_endline ("ocaml-boundary-audit: FAIL\n" ^ message);
    exit 1
;;
