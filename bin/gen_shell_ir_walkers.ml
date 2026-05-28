(* RFC-0054 PR-3 + PR-4 — codegen-based walker generator for
   [lib/exec/shell_ir_typed.ml].

   Approach: emits OCaml source text to stdout. A [dune (rule ...)] in
   [lib/exec/dune] runs this binary at build time and writes the output
   as [shell_ir_typed_walkers_gen.ml]. The standard parser handles the
   generated file — no ppxlib involvement, so the AST-vs-source
   divergence that broke RFC-0054 PR-1 / PR-1b is impossible here.

   PR-3 added [gen_risk] / [gen_sandbox] / [gen_to_simple] for
   parallel verification.
   PR-4 adds [gen_of_simple] (untyped → typed). The hand-written
   [Shell_ir_typed.of_simple] is replaced by delegation to
   [gen_of_simple]; all [parse_*] helpers are retired.
   PR-5 removed the hand-written walkers entirely. *)

(* ─── Spec: per-constructor metadata ─────────────────────────────── *)

type ctor =
  { name : string (* OCaml constructor name *)
  ; anon_pattern : string (* match pattern under [W (...)], anonymous fields *)
  ; risk : string (* polymorphic-variant value *)
  ; sandbox : string (* polymorphic-variant value *)
  ; to_simple_body : string
    (* OCaml expression returning Shell_ir.simple, given the
           field-binding pattern provides the constructor's payload.
           [arg_of_string] is inlined as [Shell_ir.Lit]; module names
           are unqualified inside masc_exec. *)
  ; bind_pattern : string
    (* match pattern that binds the constructor's payload, e.g.
           "Ls { path; flags }". Used for [gen_to_simple]. *)
  ; bin_variant : string option
    (* [Exec_program.known] constructor that triggers this parser in
       [gen_of_simple], e.g. "Ls". [None] for [Generic] (fallback). *)
  ; parse_body : string option
    (* OCaml expression of type [string list -> Shell_ir_typed_types.wrapped option].
       The parameter is named [args].  For Git sub-commands [args] is
       the remainder after the sub-command has already been stripped.
       [None] for [Generic]. *)
  }

(* Helper for the ~27 constructors that share the standard
   subcommand+args parse pattern: first token becomes [subcommand],
   the rest becomes [args].  [of_simple ∘ to_simple] round-trip
   invariant is satisfied by construction. *)
let subcommand_args_ctor ~name ~risk ~sandbox =
  { name
  ; anon_pattern = Printf.sprintf "%s _" name
  ; bind_pattern = Printf.sprintf "%s { subcommand; args }" name
  ; risk
  ; sandbox
  ; to_simple_body =
      Printf.sprintf
        {|
      let all_args = subcommand :: args in
      { Shell_ir.bin = Exec_program.of_known Exec_program.%s
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) all_args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
        name
  ; bin_variant = Some name
  ; parse_body =
      Some
        (Printf.sprintf
           {|
let rec parse subcmd extra = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.%s { subcommand = s; args = List.rev extra }))
     | None -> None)
  | arg :: rest ->
    (match subcmd with
     | None -> parse (Some arg) extra rest
     | Some _ -> parse subcmd (arg :: extra) rest)
in
parse None [] args|}
           name)
  }

(* Order mirrors lib/exec/shell_ir_typed.{ml,mli} declaration order
   (Ls, Cat, Rg, Git_status, Git_clone, Curl, Rm, Sudo, Find, Head,
   Tail, Grep, Mkdir, Wc, Git_diff, Git_log, Git_commit, Git_push,
   Git_pull, Pwd, Echo, Which, Sort, Cut, Tr, Date,
   Env, Printenv, Uniq, Basename, Dirname, Test, Stat, Hostname, Whoami,
   Generic). *)
let shell_ir_typed_spec : ctor list =
  [ { name = "Ls"
    ; anon_pattern = "Ls _"
    ; bind_pattern = "Ls { path; flags }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let flag_args =
        List.map
          (function `Long -> "-l" | `All -> "-a" | `Human -> "-h")
          flags
      in
      let args =
        match path with None -> flag_args | Some p -> flag_args @ [ p ]
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Ls
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Ls"
    ; parse_body =
        Some
          {|
let rec parse flags path = function
  | [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Ls { path; flags = List.rev flags }))
  | "-l" :: rest | "--long" :: rest -> parse (`Long :: flags) path rest
  | "-a" :: rest | "--all" :: rest -> parse (`All :: flags) path rest
  | "-h" :: rest | "--human-readable" :: rest -> parse (`Human :: flags) path rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then None
    else (
      match path with
      | None -> parse flags (Some arg) rest
      | Some _ -> None)
in
parse [] None args|}
    }
  ; { name = "Cat"
    ; anon_pattern = "Cat _"
    ; bind_pattern = "Cat { path }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      { Shell_ir.bin = Exec_program.of_known Exec_program.Cat
      ; args = [ Shell_ir.Lit (path, Shell_ir.default_meta) ]
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Cat"
    ; parse_body =
        Some
          {|match args with
| [ path ] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Cat { path }))
| _ -> None|}
    }
  ; { name = "Rg"
    ; anon_pattern = "Rg _"
    ; bind_pattern = "Rg { pattern; path; case_sensitive }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let flag_args = if case_sensitive then [] else [ "-i" ] in
      let args =
        flag_args
        @ [ pattern ]
        @ (match path with None -> [] | Some p -> [ p ])
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Rg
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Rg"
    ; parse_body =
        Some
          {|
let rec parse case_sensitive pattern path = function
  | [] ->
    (match pattern with
     | Some p -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Rg { pattern = p; path; case_sensitive }))
     | None -> None)
  | "-i" :: rest | "--ignore-case" :: rest -> parse false pattern path rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then None
    else (
      match pattern with
      | None -> parse case_sensitive (Some arg) path rest
      | Some _ ->
        (match path with
         | None -> parse case_sensitive pattern (Some arg) rest
         | Some _ -> None))
in
parse true None None args|}
    }
  ; { name = "Git_status"
    ; anon_pattern = "Git_status _"
    ; bind_pattern = "Git_status { short }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args = if short then [ "-s" ] else [] in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Git
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) ("status" :: args)
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Git"
    ; parse_body =
        Some
          {|
let rec parse short = function
  | [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_status { short }))
  | "-s" :: rest | "--short" :: rest -> parse true rest
  | "--porcelain" :: rest -> parse true rest
  | _ :: _ -> None
in
parse false args|}
    }
  ; { name = "Git_clone"
    ; anon_pattern = "Git_clone _"
    ; bind_pattern = "Git_clone { repo; branch; depth }"
    ; risk = "`Audited"
    ; sandbox = "`Docker"
    ; to_simple_body =
        {|
      let args =
        (match depth with Some d -> [ "--depth"; string_of_int d ] | None -> [])
        @ (match branch with None -> [] | Some b -> [ "-b"; b ])
        @ [ repo ]
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Git
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) ("clone" :: args)
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Git"
    ; parse_body =
        Some
          {|
let rec parse depth branch repo = function
  | [] ->
    (match repo with
     | Some r -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_clone { repo = r; branch; depth }))
     | None -> None)
  | "--depth" :: n :: rest ->
    (match int_of_string_opt n with
     | Some d -> parse (Some d) branch repo rest
     | None -> None)
  | "-b" :: b :: rest | "--branch" :: b :: rest -> parse depth (Some b) repo rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then None
    else (
      match repo with
      | None -> parse depth branch (Some arg) rest
      | Some _ -> None)
in
parse None None None args|}
    }
  ; { name = "Curl"
    ; anon_pattern = "Curl _"
    ; bind_pattern = "Curl { url; method_; headers; body }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let method_args =
        match method_ with
        | `GET -> []
        | `POST -> [ "-X"; "POST" ]
        | `PUT -> [ "-X"; "PUT" ]
        | `DELETE -> [ "-X"; "DELETE" ]
      in
      let header_args =
        match headers with
        | None -> []
        | Some hs ->
          List.concat_map (fun (k, v) -> [ "-H"; k ^ ": " ^ v ]) hs
      in
      let body_args = match body with None -> [] | Some d -> [ "-d"; d ] in
      let args = method_args @ header_args @ body_args @ [ url ] in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Curl
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Curl"
    ; parse_body =
        Some
          {|
let rec parse method_ headers body url = function
  | [] ->
    (match url with
     | Some u ->
       Some
         (Shell_ir_typed_types.W
            (Shell_ir_typed_types.Curl
               { url = u
               ; method_
               ; headers =
                   (match headers with
                    | [] -> None
                    | _ -> Some (List.rev headers))
               ; body
               }))
     | None -> None)
  | "-X" :: m :: rest | "--request" :: m :: rest ->
    (match String.uppercase_ascii m with
     | "GET" -> parse `GET headers body url rest
     | "POST" -> parse `POST headers body url rest
     | "PUT" -> parse `PUT headers body url rest
     | "DELETE" -> parse `DELETE headers body url rest
     | _ -> None)
  | "-H" :: h :: rest | "--header" :: h :: rest ->
    (match String.index_opt h ':' with
     | Some i ->
       let key = String.trim (String.sub h 0 i) in
       let value = String.trim (String.sub h (i + 1) (String.length h - i - 1)) in
       parse method_ ((key, value) :: headers) body url rest
     | None -> None)
  | "-d" :: d :: rest | "--data" :: d :: rest ->
    (match body with
     | None -> parse method_ headers (Some d) url rest
     | Some _ -> None)
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then None
    else (
      match url with
      | None -> parse method_ headers body (Some arg) rest
      | Some _ -> None)
in
parse `GET [] None None args|}
    }
  ; { name = "Rm"
    ; anon_pattern = "Rm _"
    ; bind_pattern = "Rm { paths; recursive; force }"
    ; risk = "`Privileged"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let flag_args =
        (if recursive then [ "-r" ] else [])
        @ (if force then [ "-f" ] else [])
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Rm
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) (flag_args @ paths)
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Rm"
    ; parse_body =
        Some
          {|
let rec parse recursive force paths = function
  | [] ->
    (match paths with
     | [] -> None
     | _ -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Rm { paths = List.rev paths; recursive; force })))
  | "-r" :: rest | "-R" :: rest | "--recursive" :: rest -> parse true force paths rest
  | "-f" :: rest | "--force" :: rest -> parse recursive true paths rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then None
    else parse recursive force (arg :: paths) rest
in
parse false false [] args|}
    }
  ; { name = "Sudo"
    ; anon_pattern = "Sudo _"
    ; bind_pattern = "Sudo { target_argv }"
    ; risk = "`Privileged"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      { Shell_ir.bin = Exec_program.of_known Exec_program.Sudo
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) target_argv
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Sudo"
    ; parse_body =
        Some
          {|match args with
| [] -> None
| args -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Sudo { target_argv = args }))|}
    }
  ; { name = "Find"
    ; anon_pattern = "Find _"
    ; bind_pattern = "Find { path; name; type_ }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        [ path ]
        @ (match name with None -> [] | Some n -> [ "-name"; n ])
        @ (match type_ with
           | None -> []
           | Some `File -> [ "-type"; "f" ]
           | Some `Dir -> [ "-type"; "d" ])
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Find
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Find"
    ; parse_body =
        Some
          {|
let rec parse name type_ path = function
  | [] ->
    (match path with
     | Some p -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Find { path = p; name; type_ }))
     | None -> None)
  | "-name" :: n :: rest -> parse (Some n) type_ path rest
  | "-type" :: "f" :: rest -> parse name (Some `File) path rest
  | "-type" :: "d" :: rest -> parse name (Some `Dir) path rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then None
    else (
      match path with
      | None -> parse name type_ (Some arg) rest
      | Some _ -> None)
in
parse None None None args|}
    }
  ; { name = "Head"
    ; anon_pattern = "Head _"
    ; bind_pattern = "Head { path; lines }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args = [ "-n"; string_of_int lines; path ] in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Head
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Head"
    ; parse_body =
        Some
          {|
let rec parse lines path = function
  | [] ->
    (match path with
     | Some p -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Head { path = p; lines }))
     | None -> None)
  | "-n" :: n :: rest ->
    (match int_of_string_opt n with
     | Some l -> parse l path rest
     | None -> None)
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then None
    else (
      match path with
      | None -> parse lines (Some arg) rest
      | Some _ -> None)
in
parse 10 None args|}
    }
  ; { name = "Tail"
    ; anon_pattern = "Tail _"
    ; bind_pattern = "Tail { path; lines }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args = [ "-n"; string_of_int lines; path ] in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Tail
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Tail"
    ; parse_body =
        Some
          {|
let rec parse lines path = function
  | [] ->
    (match path with
     | Some p -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Tail { path = p; lines }))
     | None -> None)
  | "-n" :: n :: rest ->
    (match int_of_string_opt n with
     | Some l -> parse l path rest
     | None -> None)
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then None
    else (
      match path with
      | None -> parse lines (Some arg) rest
      | Some _ -> None)
in
parse 10 None args|}
    }
  ; { name = "Grep"
    ; anon_pattern = "Grep _"
    ; bind_pattern = "Grep { pattern; path; recursive; case_sensitive }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let flag_args =
        (if recursive then [ "-r" ] else [])
        @ (if case_sensitive then [] else [ "-i" ])
      in
      let args =
        flag_args
        @ [ pattern ]
        @ (match path with None -> [] | Some p -> [ p ])
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Grep
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Grep"
    ; parse_body =
        Some
          {|
let rec parse recursive case_sensitive pattern path = function
  | [] ->
    (match pattern with
     | Some p -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Grep { pattern = p; path; recursive; case_sensitive }))
     | None -> None)
  | "-r" :: rest | "-R" :: rest | "--recursive" :: rest ->
    parse true case_sensitive pattern path rest
  | "-i" :: rest | "--ignore-case" :: rest ->
    parse recursive false pattern path rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then None
    else (
      match pattern with
      | None -> parse recursive case_sensitive (Some arg) path rest
      | Some _ ->
        (match path with
         | None -> parse recursive case_sensitive pattern (Some arg) rest
         | Some _ -> None))
in
parse false true None None args|}
    }
  ; { name = "Mkdir"
    ; anon_pattern = "Mkdir _"
    ; bind_pattern = "Mkdir { path; parents }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let flag_args = if parents then [ "-p" ] else [] in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Mkdir
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) (flag_args @ [ path ])
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Mkdir"
    ; parse_body =
        Some
          {|
let rec parse parents path = function
  | [] ->
    (match path with
     | Some p -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Mkdir { path = p; parents }))
     | None -> None)
  | "-p" :: rest | "--parents" :: rest -> parse true path rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then None
    else (
      match path with
      | None -> parse parents (Some arg) rest
      | Some _ -> None)
in
parse false None args|}
    }
  ; { name = "Wc"
    ; anon_pattern = "Wc _"
    ; bind_pattern = "Wc { path; mode }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let flag_args =
        match mode with
        | Some `Lines -> [ "-l" ]
        | Some `Words -> [ "-w" ]
        | Some `Chars -> [ "-c" ]
        | None -> []
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Wc
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) (flag_args @ [ path ])
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Wc"
    ; parse_body =
        Some
          {|
let rec parse mode path = function
  | [] ->
    (match path with
     | Some p -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Wc { path = p; mode }))
     | None -> None)
  | "-l" :: rest | "--lines" :: rest -> parse (Some `Lines) path rest
  | "-w" :: rest | "--words" :: rest -> parse (Some `Words) path rest
  | "-c" :: rest | "--bytes" :: rest | "--chars" :: rest -> parse (Some `Chars) path rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then None
    else (
      match path with
      | None -> parse mode (Some arg) rest
      | Some _ -> None)
in
parse None None args|}
    }
  ; { name = "Git_diff"
    ; anon_pattern = "Git_diff _"
    ; bind_pattern = "Git_diff { stat; cached; paths }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let flag_args =
        (if stat then [ "--stat" ] else [])
        @ (if cached then [ "--cached" ] else [])
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Git
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) ("diff" :: flag_args @ paths)
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Git"
    ; parse_body =
        Some
          {|
let rec parse stat cached paths = function
  | [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_diff { stat; cached; paths = List.rev paths }))
  | "--stat" :: rest -> parse true cached paths rest
  | "--cached" :: rest | "--staged" :: rest -> parse stat true paths rest
  | "--name-only" :: rest | "--name-status" :: rest -> parse stat cached paths rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse stat cached paths rest
    else parse stat cached (arg :: paths) rest
in
parse false false [] args|}
    }
  ; { name = "Git_log"
    ; anon_pattern = "Git_log _"
    ; bind_pattern = "Git_log { oneline; max_count }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let flag_args =
        (if oneline then [ "--oneline" ] else [])
        @ (match max_count with None -> [] | Some n -> [ "-n"; string_of_int n ])
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Git
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) ("log" :: flag_args)
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Git"
    ; parse_body =
        Some
          {|
let rec parse oneline max_count = function
  | [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_log { oneline; max_count }))
  | "--oneline" :: rest -> parse true max_count rest
  | "-n" :: n :: rest | "--max-count" :: n :: rest ->
    (match int_of_string_opt n with
     | Some c -> parse oneline (Some c) rest
     | None -> None)
  | "--graph" :: rest | "--all" :: rest | "--decorate" :: rest -> parse oneline max_count rest
  | _ :: _ -> None
in
parse false None args|}
    }
  ; { name = "Git_commit"
    ; anon_pattern = "Git_commit _"
    ; bind_pattern = "Git_commit { message; amend }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let flag_args =
        (if amend then [ "--amend" ] else [])
        @ [ "-m"; message ]
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Git
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) ("commit" :: flag_args)
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Git"
    ; parse_body =
        Some
          {|
let rec parse message amend = function
  | [] ->
    (match message with
     | Some m -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_commit { message = m; amend }))
     | None -> None)
  | "--amend" :: rest -> parse message true rest
  | "-m" :: m :: rest ->
    (match message with
     | None -> parse (Some m) amend rest
     | Some _ -> None)
  | "-a" :: rest | "--all" :: rest -> parse message amend rest
  | "--no-edit" :: rest -> parse message amend rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse message amend rest
    else parse message amend rest
in
parse None false args|}
    }
  ; { name = "Git_push"
    ; anon_pattern = "Git_push _"
    ; bind_pattern = "Git_push { force; force_with_lease; set_upstream; remote; branch }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let flag_args =
        (if force then [ "--force" ] else [])
        @ (if force_with_lease then [ "--force-with-lease" ] else [])
        @ (if set_upstream then [ "-u" ] else [])
      in
      let positional =
        (match remote with None -> [] | Some r -> [ r ])
        @ (match branch with None -> [] | Some b -> [ b ])
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Git
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) ("push" :: flag_args @ positional)
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Git"
    ; parse_body =
        Some
          {|
let rec parse force force_with_lease set_upstream remote branch = function
  | [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_push { force; force_with_lease; set_upstream; remote; branch }))
  | "--force" :: rest | "-f" :: rest -> parse true force_with_lease set_upstream remote branch rest
  | "--force-with-lease" :: rest -> parse force true set_upstream remote branch rest
  | "-u" :: rest | "--set-upstream" :: rest -> parse force force_with_lease true remote branch rest
  | "--delete" :: rest -> parse force force_with_lease set_upstream remote branch rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse force force_with_lease set_upstream remote branch rest
    else (
      match remote with
      | None -> parse force force_with_lease set_upstream (Some arg) branch rest
      | Some _ ->
        (match branch with
         | None -> parse force force_with_lease set_upstream remote (Some arg) rest
         | Some _ -> parse force force_with_lease set_upstream remote branch rest))
in
parse false false false None None args|}
    }
  ; { name = "Git_pull"
    ; anon_pattern = "Git_pull _"
    ; bind_pattern = "Git_pull { rebase; remote; branch }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let flag_args = if rebase then [ "--rebase" ] else [] in
      let positional =
        (match remote with None -> [] | Some r -> [ r ])
        @ (match branch with None -> [] | Some b -> [ b ])
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Git
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) ("pull" :: flag_args @ positional)
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Git"
    ; parse_body =
        Some
          {|
let rec parse rebase remote branch = function
  | [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_pull { rebase; remote; branch }))
  | "--rebase" :: rest -> parse true remote branch rest
  | "--ff-only" :: rest -> parse rebase remote branch rest
  | "--no-rebase" :: rest -> parse false remote branch rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse rebase remote branch rest
    else (
      match remote with
      | None -> parse rebase (Some arg) branch rest
      | Some _ ->
        (match branch with
         | None -> parse rebase remote (Some arg) rest
         | Some _ -> parse rebase remote branch rest))
in
parse false None None args|}
    }
  ; { name = "Pwd"
    ; anon_pattern = "Pwd _"
    ; bind_pattern = "Pwd ()"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      { Shell_ir.bin = Exec_program.of_known Exec_program.Pwd
      ; args = []
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Pwd"
    ; parse_body =
        Some
          {|match args with
| [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Pwd ()))
| _ -> None|}
    }
  ; { name = "Echo"
    ; anon_pattern = "Echo _"
    ; bind_pattern = "Echo { args = echo_args }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      { Shell_ir.bin = Exec_program.of_known Exec_program.Echo
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) echo_args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Echo"
    ; parse_body =
        Some
          {|Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Echo { args = args }))|}
    }
  ; { name = "Which"
    ; anon_pattern = "Which _"
    ; bind_pattern = "Which { names }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      { Shell_ir.bin = Exec_program.of_known Exec_program.Which
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) names
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Which"
    ; parse_body =
        Some
          {|match args with
| [] -> None
| names -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Which { names }))|}
    }
  ; { name = "Sort"
    ; anon_pattern = "Sort _"
    ; bind_pattern = "Sort { reverse; numeric; unique; key; file }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let flag_args =
        (if reverse then [ "-r" ] else [])
        @ (if numeric then [ "-n" ] else [])
        @ (if unique then [ "-u" ] else [])
        @ (match key with None -> [] | Some k -> [ "-k"; string_of_int k ])
      in
      let file_args = match file with None -> [] | Some f -> [ f ] in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Sort
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) (flag_args @ file_args)
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Sort"
    ; parse_body =
        Some
          {|
let rec parse reverse numeric unique key file = function
  | [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Sort { reverse; numeric; unique; key; file }))
  | "-r" :: rest | "--reverse" :: rest -> parse true numeric unique key file rest
  | "-n" :: rest | "--numeric-sort" :: rest -> parse reverse true unique key file rest
  | "-u" :: rest | "--unique" :: rest -> parse reverse numeric true key file rest
  | "-k" :: n :: rest | "--key" :: n :: rest ->
    (try parse reverse numeric unique (Some (int_of_string n)) file rest
     with Failure _ -> None)
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse reverse numeric unique key file rest
    else (
      match file with
      | None -> parse reverse numeric unique key (Some arg) rest
      | Some _ -> None)
in
parse false false false None None args|}
    }
  ; { name = "Cut"
    ; anon_pattern = "Cut _"
    ; bind_pattern = "Cut { delimiter; fields; file }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let flag_args =
        (match delimiter with None -> [] | Some d -> [ "-d"; d ])
        @ [ "-f"; fields ]
      in
      let file_args = match file with None -> [] | Some f -> [ f ] in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Cut
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) (flag_args @ file_args)
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Cut"
    ; parse_body =
        Some
          {|
let rec parse delimiter fields file = function
  | [] ->
    (match fields with
     | Some f -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Cut { delimiter; fields = f; file }))
     | None -> None)
  | "-d" :: d :: rest -> parse (Some d) fields file rest
  | "-f" :: f :: rest -> parse delimiter (Some f) file rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse delimiter fields file rest
    else (
      match file with
      | None -> parse delimiter fields (Some arg) rest
      | Some _ -> None)
in
parse None None None args|}
    }
  ; { name = "Tr"
    ; anon_pattern = "Tr _"
    ; bind_pattern = "Tr { set1; set2; delete; squeeze }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let flag_args =
        (if delete then [ "-d" ] else [])
        @ (if squeeze then [ "-s" ] else [])
      in
      let set_args = match set2 with None -> [ set1 ] | Some s -> [ set1; s ] in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Tr
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) (flag_args @ set_args)
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Tr"
    ; parse_body =
        Some
          {|
let rec parse delete squeeze set1 set2 = function
  | [] ->
    (match set1 with
     | Some s1 -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Tr { set1 = s1; set2; delete; squeeze }))
     | None -> None)
  | "-d" :: rest -> parse true squeeze set1 set2 rest
  | "-s" :: rest -> parse delete true set1 set2 rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse delete squeeze set1 set2 rest
    else (
      match set1 with
      | None -> parse delete squeeze (Some arg) set2 rest
      | Some _ ->
        (match set2 with
         | None -> parse delete squeeze set1 (Some arg) rest
         | Some _ -> None))
in
parse false false None None args|}
    }
  ; { name = "Date"
    ; anon_pattern = "Date _"
    ; bind_pattern = "Date { format; utc }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let flag_args = if utc then [ "-u" ] else [] in
      let format_args = match format with None -> [] | Some f -> [ f ] in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Date
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) (flag_args @ format_args)
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Date"
    ; parse_body =
        Some
          {|
let rec parse utc format = function
  | [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Date { format; utc }))
  | "-u" :: rest | "--utc" :: rest | "--universal" :: rest -> parse true format rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse utc format rest
    else parse utc (Some arg) rest
in
parse false None args|}
    }
  ; { name = "Env"
    ; anon_pattern = "Env _"
    ; bind_pattern = "Env ()"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
  { Shell_ir.bin = Exec_program.of_known Exec_program.Env
  ; args = []
  ; env = []
  ; cwd = None
  ; redirects = []
  ; sandbox = Sandbox_target.host ()
  }|}
    ; bin_variant = Some "Env"
    ; parse_body =
        Some
          {|
match args with
| [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Env ()))
| _ -> None|}
    }
  ; { name = "Printenv"
    ; anon_pattern = "Printenv _"
    ; bind_pattern = "Printenv { name }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
  let args = match name with None -> [] | Some n -> [ Shell_ir.Lit (n, Shell_ir.default_meta) ] in
  { Shell_ir.bin = Exec_program.of_known Exec_program.Printenv
  ; args
  ; env = []
  ; cwd = None
  ; redirects = []
  ; sandbox = Sandbox_target.host ()
  }|}
    ; bin_variant = Some "Printenv"
    ; parse_body =
        Some
          {|
match args with
| [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Printenv { name = None }))
| [ n ] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Printenv { name = Some n }))
| _ -> None|}
    }
  ; { name = "Uniq"
    ; anon_pattern = "Uniq _"
    ; bind_pattern = "Uniq { count; duplicates; unique; file }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
  let flag_args =
    (if count then [ Shell_ir.Lit ("-c", Shell_ir.default_meta) ] else [])
    @ (if duplicates then [ Shell_ir.Lit ("-d", Shell_ir.default_meta) ] else [])
    @ (if unique then [ Shell_ir.Lit ("-u", Shell_ir.default_meta) ] else [])
  in
  let file_args = match file with None -> [] | Some f -> [ Shell_ir.Lit (f, Shell_ir.default_meta) ] in
  { Shell_ir.bin = Exec_program.of_known Exec_program.Uniq
  ; args = flag_args @ file_args
  ; env = []
  ; cwd = None
  ; redirects = []
  ; sandbox = Sandbox_target.host ()
  }|}
    ; bin_variant = Some "Uniq"
    ; parse_body =
        Some
          {|
let rec parse count duplicates unique file = function
  | [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Uniq { count; duplicates; unique; file }))
  | "-c" :: rest -> parse true duplicates unique file rest
  | "-d" :: rest -> parse count true unique file rest
  | "-u" :: rest -> parse count duplicates true file rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse count duplicates unique file rest
    else parse count duplicates unique (Some arg) rest
in
parse false false false None args|}
    }
  ; { name = "Basename"
    ; anon_pattern = "Basename _"
    ; bind_pattern = "Basename { path; suffix }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
  let args =
    Shell_ir.Lit (path, Shell_ir.default_meta)
    :: (match suffix with None -> [] | Some s -> [ Shell_ir.Lit (s, Shell_ir.default_meta) ])
  in
  { Shell_ir.bin = Exec_program.of_known Exec_program.Basename
  ; args
  ; env = []
  ; cwd = None
  ; redirects = []
  ; sandbox = Sandbox_target.host ()
  }|}
    ; bin_variant = Some "Basename"
    ; parse_body =
        Some
          {|
match args with
| [ path ] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Basename { path; suffix = None }))
| [ path; suffix ] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Basename { path; suffix = Some suffix }))
| _ -> None|}
    }
  ; { name = "Dirname"
    ; anon_pattern = "Dirname _"
    ; bind_pattern = "Dirname { path }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
  { Shell_ir.bin = Exec_program.of_known Exec_program.Dirname
  ; args = [ Shell_ir.Lit (path, Shell_ir.default_meta) ]
  ; env = []
  ; cwd = None
  ; redirects = []
  ; sandbox = Sandbox_target.host ()
  }|}
    ; bin_variant = Some "Dirname"
    ; parse_body =
        Some
          {|
match args with
| [ path ] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Dirname { path }))
| _ -> None|}
    }
  ; { name = "Test"
    ; anon_pattern = "Test _"
    ; bind_pattern = "Test { expression }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
  { Shell_ir.bin = Exec_program.of_known Exec_program.Test
  ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) expression
  ; env = []
  ; cwd = None
  ; redirects = []
  ; sandbox = Sandbox_target.host ()
  }|}
    ; bin_variant = Some "Test"
    ; parse_body =
        Some
          {|
match args with
| [] -> None
| expression -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Test { expression }))
    |}
    }
  ; { name = "Stat"
    ; anon_pattern = "Stat _"
    ; bind_pattern = "Stat { format; path }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
  let args =
    (match format with None -> [] | Some f -> [ Shell_ir.Lit ("-f", Shell_ir.default_meta); Shell_ir.Lit (f, Shell_ir.default_meta) ])
    @ [ Shell_ir.Lit (path, Shell_ir.default_meta) ]
  in
  { Shell_ir.bin = Exec_program.of_known Exec_program.Stat
  ; args
  ; env = []
  ; cwd = None
  ; redirects = []
  ; sandbox = Sandbox_target.host ()
  }|}
    ; bin_variant = Some "Stat"
    ; parse_body =
        Some
          {|
let rec parse format = function
  | [] -> None
  | [ path ] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Stat { format; path }))
  | "-f" :: f :: rest -> parse (Some f) rest
  | arg :: _ ->
    if String.length arg > 0 && arg.[0] = '-'
    then None
    else Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Stat { format; path = arg }))
in
parse None args|}
    }
  ; { name = "Hostname"
    ; anon_pattern = "Hostname _"
    ; bind_pattern = "Hostname { short }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
  let args = if short then [ Shell_ir.Lit ("-s", Shell_ir.default_meta) ] else [] in
  { Shell_ir.bin = Exec_program.of_known Exec_program.Hostname
  ; args
  ; env = []
  ; cwd = None
  ; redirects = []
  ; sandbox = Sandbox_target.host ()
  }|}
    ; bin_variant = Some "Hostname"
    ; parse_body =
        Some
          {|
let rec parse short = function
  | [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Hostname { short }))
  | "-s" :: rest -> parse true rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse short rest
    else parse short rest
in
parse false args|}
    }
  ; { name = "Whoami"
    ; anon_pattern = "Whoami _"
    ; bind_pattern = "Whoami ()"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
  { Shell_ir.bin = Exec_program.of_known Exec_program.Whoami
  ; args = []
  ; env = []
  ; cwd = None
  ; redirects = []
  ; sandbox = Sandbox_target.host ()
  }|}
    ; bin_variant = Some "Whoami"
    ; parse_body =
        Some
          {|
match args with
| [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Whoami ()))
| _ -> None|}
    }
  ; { name = "Du"
    ; anon_pattern = "Du _"
    ; bind_pattern = "Du { path; human_readable; summary; max_depth }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
  let flag_args =
    (if human_readable then [ Shell_ir.Lit ("-h", Shell_ir.default_meta) ] else [])
    @ (if summary then [ Shell_ir.Lit ("-s", Shell_ir.default_meta) ] else [])
    @ (match max_depth with
       | None -> []
       | Some d ->
         [ Shell_ir.Lit
             ("--max-depth=" ^ string_of_int d, Shell_ir.default_meta)
         ])
  in
  let path_args =
    match path with
    | None -> []
    | Some p -> [ Shell_ir.Lit (p, Shell_ir.default_meta) ]
  in
  { Shell_ir.bin = Exec_program.of_known Exec_program.Du
  ; args = flag_args @ path_args
  ; env = []
  ; cwd = None
  ; redirects = []
  ; sandbox = Sandbox_target.host ()
  }|}
    ; bin_variant = Some "Du"
    ; parse_body =
        Some
          {|
let rec parse human_readable summary max_depth = function
  | [] ->
    Some
      (Shell_ir_typed_types.W
         (Shell_ir_typed_types.Du
            { path = None; human_readable; summary; max_depth }))
  | "-h" :: rest -> parse true summary max_depth rest
  | "-s" :: rest -> parse human_readable true max_depth rest
  | arg :: rest ->
    (match String.split_on_char '=' arg with
     | [ "--max-depth"; n ] ->
       (match int_of_string_opt n with
        | Some d -> parse human_readable summary (Some d) rest
        | None -> None)
     | _ ->
       if String.length arg > 0 && arg.[0] = '-'
       then None
       else
         Some
           (Shell_ir_typed_types.W
              (Shell_ir_typed_types.Du
                 { path = Some arg
                 ; human_readable
                 ; summary
                 ; max_depth
                 })))
in
parse false false None args|}
    }
  ; { name = "Df"
    ; anon_pattern = "Df _"
    ; bind_pattern = "Df { path; human_readable; filesystem_type }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
  let flag_args =
    (if human_readable then [ Shell_ir.Lit ("-h", Shell_ir.default_meta) ] else [])
    @ (match filesystem_type with
       | None -> []
       | Some t ->
         [ Shell_ir.Lit ("-t", Shell_ir.default_meta)
         ; Shell_ir.Lit (t, Shell_ir.default_meta)
         ])
  in
  let path_args =
    match path with
    | None -> []
    | Some p -> [ Shell_ir.Lit (p, Shell_ir.default_meta) ]
  in
  { Shell_ir.bin = Exec_program.of_known Exec_program.Df
  ; args = flag_args @ path_args
  ; env = []
  ; cwd = None
  ; redirects = []
  ; sandbox = Sandbox_target.host ()
  }|}
    ; bin_variant = Some "Df"
    ; parse_body =
        Some
          {|
let rec parse human_readable fs_type = function
  | [] ->
    Some
      (Shell_ir_typed_types.W
         (Shell_ir_typed_types.Df
            { path = None; human_readable; filesystem_type = fs_type }))
  | "-h" :: rest -> parse true fs_type rest
  | "-t" :: t :: rest -> parse human_readable (Some t) rest
  | arg :: _ ->
    if String.length arg > 0 && arg.[0] = '-'
    then None
    else
      Some
        (Shell_ir_typed_types.W
           (Shell_ir_typed_types.Df
              { path = Some arg; human_readable; filesystem_type = fs_type }))
in
parse false None args|}
    }
  ; { name = "File"
    ; anon_pattern = "File _"
    ; bind_pattern = "File { path; mime; brief }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
  let flag_args =
    (if brief then [ Shell_ir.Lit ("-b", Shell_ir.default_meta) ] else [])
    @ (if mime then [ Shell_ir.Lit ("-i", Shell_ir.default_meta) ] else [])
  in
  { Shell_ir.bin = Exec_program.of_known Exec_program.File
  ; args = flag_args @ [ Shell_ir.Lit (path, Shell_ir.default_meta) ]
  ; env = []
  ; cwd = None
  ; redirects = []
  ; sandbox = Sandbox_target.host ()
  }|}
    ; bin_variant = Some "File"
    ; parse_body =
        Some
          {|
let rec parse mime brief = function
  | [] -> None
  | [ path ] ->
    Some
      (Shell_ir_typed_types.W
         (Shell_ir_typed_types.File { path; mime; brief }))
  | "-b" :: rest -> parse mime true rest
  | "-i" :: rest -> parse true brief rest
  | arg :: _ ->
    if String.length arg > 0 && arg.[0] = '-'
    then None
    else
      Some
        (Shell_ir_typed_types.W
           (Shell_ir_typed_types.File { path = arg; mime; brief }))
in
parse false false args|}
    }
  ; { name = "Printf"
    ; anon_pattern = "Printf _"
    ; bind_pattern = "Printf { format; args = fmt_args }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
  { Shell_ir.bin = Exec_program.of_known Exec_program.Printf
  ; args =
      Shell_ir.Lit (format, Shell_ir.default_meta)
      :: List.map
           (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta))
           fmt_args
  ; env = []
  ; cwd = None
  ; redirects = []
  ; sandbox = Sandbox_target.host ()
  }|}
    ; bin_variant = Some "Printf"
    ; parse_body =
        Some
          {|
match args with
| [] -> None
| format :: rest ->
  Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Printf { format; args = rest }))
|}
    }
  ; { name = "Uname"
    ; anon_pattern = "Uname _"
    ; bind_pattern = "Uname { all; kernel_name; release; machine }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
  let args =
    (if all then [ Shell_ir.Lit ("-a", Shell_ir.default_meta) ] else [])
    @ (if kernel_name
       then [ Shell_ir.Lit ("-s", Shell_ir.default_meta) ]
       else [])
    @ (if release
       then [ Shell_ir.Lit ("-r", Shell_ir.default_meta) ]
       else [])
    @ (if machine
       then [ Shell_ir.Lit ("-m", Shell_ir.default_meta) ]
       else [])
  in
  { Shell_ir.bin = Exec_program.of_known Exec_program.Uname
  ; args
  ; env = []
  ; cwd = None
  ; redirects = []
  ; sandbox = Sandbox_target.host ()
  }|}
    ; bin_variant = Some "Uname"
    ; parse_body =
        Some
          {|
let rec parse all kn rel mach = function
  | [] ->
    Some
      (Shell_ir_typed_types.W
         (Shell_ir_typed_types.Uname
            { all; kernel_name = kn; release = rel; machine = mach }))
  | "-a" :: rest -> parse true kn rel mach rest
  | "-s" :: rest -> parse all true rel mach rest
  | "-r" :: rest -> parse all kn true mach rest
  | "-m" :: rest -> parse all kn rel true rest
  | arg :: _ ->
    if String.length arg > 0 && arg.[0] = '-'
    then None
    else None
in
parse false false false false args|}
    }
  ; { name = "Ps"
    ; anon_pattern = "Ps _"
    ; bind_pattern = "Ps { all; full; user }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
  let flag_args =
    (if all then [ Shell_ir.Lit ("-e", Shell_ir.default_meta) ] else [])
    @ (if full then [ Shell_ir.Lit ("-f", Shell_ir.default_meta) ] else [])
    @ (match user with
       | None -> []
       | Some u ->
         [ Shell_ir.Lit ("-u", Shell_ir.default_meta)
         ; Shell_ir.Lit (u, Shell_ir.default_meta)
         ])
  in
  { Shell_ir.bin = Exec_program.of_known Exec_program.Ps
  ; args = flag_args
  ; env = []
  ; cwd = None
  ; redirects = []
  ; sandbox = Sandbox_target.host ()
  }|}
    ; bin_variant = Some "Ps"
    ; parse_body =
        Some
          {|
let rec parse all full user = function
  | [] ->
    Some
      (Shell_ir_typed_types.W
         (Shell_ir_typed_types.Ps { all; full; user }))
  | "-e" :: rest | "-A" :: rest -> parse true full user rest
  | "-f" :: rest -> parse all true user rest
  | "-u" :: u :: rest -> parse all full (Some u) rest
  | arg :: _ ->
    if String.length arg > 0 && arg.[0] = '-'
    then None
    else None
in
parse false false None args|}
    }
  ; { name = "Tty"
    ; anon_pattern = "Tty _"
    ; bind_pattern = "Tty ()"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
  { Shell_ir.bin = Exec_program.of_known Exec_program.Tty
  ; args = []
  ; env = []
  ; cwd = None
  ; redirects = []
  ; sandbox = Sandbox_target.host ()
  }|}
    ; bin_variant = Some "Tty"
    ; parse_body =
        Some
          {|
match args with
| [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Tty ()))
| _ -> None|}
    }
  ; { name = "Wget"
    ; anon_pattern = "Wget _"
    ; bind_pattern = "Wget { url; output }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        (match output with None -> [] | Some o -> [ "-O"; o ])
        @ [ url ]
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Wget
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Wget"
    ; parse_body =
        Some
          {|
let rec parse output url = function
  | [] ->
    (match url with
     | Some u ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Wget { url = u; output }))
     | None -> None)
  | "-O" :: o :: rest -> parse (Some o) url rest
  | "--output-document" :: o :: rest -> parse (Some o) url rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then None
    else (
      match url with
      | None -> parse output (Some arg) rest
      | Some _ -> None)
in
parse None None args|}
    }
  ; { name = "Ssh"
    ; anon_pattern = "Ssh _"
    ; bind_pattern = "Ssh { host; user; command }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let host_str =
        match user with
        | None -> host
        | Some u -> u ^ "@" ^ host
      in
      let args =
        [ host_str ] @ (match command with None -> [] | Some c -> [ c ])
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Ssh
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Ssh"
    ; parse_body =
        Some
          {|
let parse host_arg rest =
  let user, host =
    match String.split_on_char '@' host_arg with
    | [ u; h ] -> (Some u, h)
    | _ -> (None, host_arg)
  in
  let command =
    match rest with
    | [] -> None
    | cmd_parts -> Some (String.concat " " cmd_parts)
  in
  Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Ssh { host; user; command }))
in
match args with
| [] -> None
| host_arg :: rest -> parse host_arg rest|}
    }
  ; { name = "Scp"
    ; anon_pattern = "Scp _"
    ; bind_pattern = "Scp { source; dest; recursive }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        (if recursive then [ "-r" ] else [])
        @ [ source; dest ]
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Scp
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Scp"
    ; parse_body =
        Some
          {|
let rec parse recursive src dest = function
  | [] ->
    (match src, dest with
     | Some s, Some d ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Scp { source = s; dest = d; recursive }))
     | _ -> None)
  | "-r" :: rest -> parse true src dest rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then None
    else (
      match src with
      | None -> parse recursive (Some arg) dest rest
      | Some _ ->
        match dest with
        | None -> parse recursive src (Some arg) rest
        | Some _ -> None)
in
parse false None None args|}
    }
  ; { name = "Tar"
    ; anon_pattern = "Tar _"
    ; bind_pattern = "Tar { action; archive; paths; gzip }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let action_flag =
        match action with
        | `Create -> "-c"
        | `Extract -> "-x"
        | `List -> "-t"
      in
      let args =
        [ action_flag ]
        @ (if gzip then [ "-z" ] else [])
        @ [ "-f"; archive ]
        @ paths
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Tar
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Tar"
    ; parse_body =
        Some
          {|
let rec parse action gzip archive paths = function
  | [] ->
    (match action, archive with
     | Some a, Some f ->
       Some
         (Shell_ir_typed_types.W
            (Shell_ir_typed_types.Tar
               { action = a; archive = f; paths = List.rev paths; gzip }))
     | _ -> None)
  | "-c" :: rest -> parse (Some `Create) gzip archive paths rest
  | "-x" :: rest -> parse (Some `Extract) gzip archive paths rest
  | "-t" :: rest -> parse (Some `List) gzip archive paths rest
  | "-z" :: rest -> parse action true archive paths rest
  | "-f" :: f :: rest -> parse action gzip (Some f) paths rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse action gzip archive paths rest
    else parse action gzip archive (arg :: paths) rest
in
parse None false None [] args|}
    }
  ; { name = "Make"
    ; anon_pattern = "Make _"
    ; bind_pattern = "Make { target; jobs }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        (match jobs with None -> [] | Some j -> [ "-j"; string_of_int j ])
        @ (match target with None -> [] | Some t -> [ t ])
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Make
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Make"
    ; parse_body =
        Some
          {|
let rec parse jobs target = function
  | [] ->
    Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Make { target; jobs }))
  | "-j" :: n :: rest ->
    (match int_of_string_opt n with
     | Some j -> parse (Some j) target rest
     | None -> None)
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse jobs target rest
    else (
      match target with
      | None -> parse jobs (Some arg) rest
      | Some _ -> None)
in
parse None None args|}
    }
  ; { name = "Diff"
    ; anon_pattern = "Diff _"
    ; bind_pattern = "Diff { file1; file2; unified }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        (if unified then [ "-u" ] else [])
        @ [ file1; file2 ]
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Diff
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Diff"
    ; parse_body =
        Some
          {|
let rec parse unified files = function
  | [] ->
    (match files with
     | [ f1; f2 ] ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Diff { file1 = f1; file2 = f2; unified }))
     | _ -> None)
  | "-u" :: rest -> parse true files rest
  | "--unified" :: rest -> parse true files rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse unified files rest
    else parse unified (files @ [ arg ]) rest
in
parse false [] args|}
    }
  ; { name = "Sed"
    ; anon_pattern = "Sed _"
    ; bind_pattern = "Sed { expression; file; in_place }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        (if in_place then [ "-i" ] else [])
        @ [ expression; file ]
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Sed
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Sed"
    ; parse_body =
        Some
          {|
let rec parse in_place expr file = function
  | [] ->
    (match expr, file with
     | Some e, Some f ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Sed { expression = e; file = f; in_place }))
     | _ -> None)
  | "-i" :: rest -> parse true expr file rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse in_place expr file rest
    else (
      match expr with
      | None -> parse in_place (Some arg) file rest
      | Some _ ->
        match file with
        | None -> parse in_place expr (Some arg) rest
        | Some _ -> None)
in
parse false None None args|}
    }
  ; { name = "Rsync"
    ; anon_pattern = "Rsync _"
    ; bind_pattern = "Rsync { source; dest; flags }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args = flags @ [ source; dest ] in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Rsync
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Rsync"
    ; parse_body =
        Some
          {|
let rec parse flags src dst = function
  | [] ->
    (match src, dst with
     | Some s, Some d ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Rsync { source = s; dest = d; flags = List.rev flags }))
     | _ -> None)
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse (arg :: flags) src dst rest
    else (
      match src with
      | None -> parse flags (Some arg) dst rest
      | Some _ ->
        match dst with
        | None -> parse flags src (Some arg) rest
        | Some _ -> None)
in
parse [] None None args|}
    }
  ; { name = "Node"
    ; anon_pattern = "Node _"
    ; bind_pattern = "Node { script; args }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let all_args = script :: args in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Node
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) all_args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Node"
    ; parse_body =
        Some
          {|
let rec parse script extra = function
  | [] ->
    (match script with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Node { script = s; args = List.rev extra }))
     | None -> None)
  | arg :: rest ->
    (match script with
     | None -> parse (Some arg) extra rest
     | Some _ -> parse script (arg :: extra) rest)
in
parse None [] args|}
    }
  ; { name = "Python"
    ; anon_pattern = "Python _"
    ; bind_pattern = "Python { script; args }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let all_args = script :: args in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Python
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) all_args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Python"
    ; parse_body =
        Some
          {|
let rec parse script extra = function
  | [] ->
    (match script with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Python { script = s; args = List.rev extra }))
     | None -> None)
  | arg :: rest ->
    (match script with
     | None -> parse (Some arg) extra rest
     | Some _ -> parse script (arg :: extra) rest)
in
parse None [] args|}
    }
  ; { name = "Python3"
    ; anon_pattern = "Python3 _"
    ; bind_pattern = "Python3 { script; args }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let all_args = script :: args in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Python3
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) all_args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Python3"
    ; parse_body =
        Some
          {|
let rec parse script extra = function
  | [] ->
    (match script with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Python3 { script = s; args = List.rev extra }))
     | None -> None)
  | arg :: rest ->
    (match script with
     | None -> parse (Some arg) extra rest
     | Some _ -> parse script (arg :: extra) rest)
in
parse None [] args|}
    }
  ; { name = "Pip"
    ; anon_pattern = "Pip _"
    ; bind_pattern = "Pip { subcommand; packages }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args = subcommand :: packages in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Pip
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Pip"
    ; parse_body =
        Some
          {|
let rec parse subcmd pkgs = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Pip { subcommand = s; packages = List.rev pkgs }))
     | None -> None)
  | arg :: rest ->
    (match subcmd with
     | None -> parse (Some arg) pkgs rest
     | Some _ -> parse subcmd (arg :: pkgs) rest)
in
parse None [] args|}
    }
  ; { name = "Patch"
    ; anon_pattern = "Patch _"
    ; bind_pattern = "Patch { file; patchfile; strip; reverse }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let strip_args = if strip = 0 then [] else [ "-p" ^ string_of_int strip ] in
      let rev_args = if reverse then [ "-R" ] else [] in
      let file_args = match file with None -> [] | Some f -> [ f ] in
      let patch_args = match patchfile with None -> [] | Some p -> [ "-i"; p ] in
      let args = strip_args @ rev_args @ patch_args @ file_args in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Patch
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Patch"
    ; parse_body =
        Some
          {|
let rec parse file patchfile strip reverse = function
  | [] ->
    Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Patch { file; patchfile; strip; reverse }))
  | "-R" :: rest -> parse file patchfile strip true rest
  | "-i" :: p :: rest -> parse file (Some p) strip reverse rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then (
      (* Try to parse -pN *)
      if String.length arg > 2 && arg.[1] = 'p'
      then (
        match int_of_string_opt (String.sub arg 2 (String.length arg - 2)) with
        | Some n -> parse file patchfile n reverse rest
        | None -> parse file patchfile strip reverse rest)
      else parse file patchfile strip reverse rest)
    else (
      match file with
      | None -> parse (Some arg) patchfile strip reverse rest
      | Some _ -> None)
in
parse None None 0 false args|}
    }
  ; subcommand_args_ctor ~name:"Npm" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Cargo" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Go" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Gh" ~risk:"`Audited" ~sandbox:"`Host"
  ; { name = "Chmod"
    ; anon_pattern = "Chmod _"
    ; bind_pattern = "Chmod { mode; path }"
    ; risk = "`Privileged"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      { Shell_ir.bin = Exec_program.of_known Exec_program.Chmod
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) [ mode; path ]
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Chmod"
    ; parse_body =
        Some
          {|
let rec parse mode path = function
  | [] ->
    (match mode, path with
     | Some m, Some p ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Chmod { mode = m; path = p }))
     | _ -> None)
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse mode path rest
    else (
      match mode with
      | None -> parse (Some arg) path rest
      | Some _ ->
        (match path with
         | None -> parse mode (Some arg) rest
         | Some _ -> None))
in
parse None None args|}
    }
  ; { name = "Chown"
    ; anon_pattern = "Chown _"
    ; bind_pattern = "Chown { owner; path }"
    ; risk = "`Privileged"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      { Shell_ir.bin = Exec_program.of_known Exec_program.Chown
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) [ owner; path ]
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Chown"
    ; parse_body =
        Some
          {|
let rec parse owner path = function
  | [] ->
    (match owner, path with
     | Some o, Some p ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Chown { owner = o; path = p }))
     | _ -> None)
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse owner path rest
    else (
      match owner with
      | None -> parse (Some arg) path rest
      | Some _ ->
        (match path with
         | None -> parse owner (Some arg) rest
         | Some _ -> None))
in
parse None None args|}
    }
  ; subcommand_args_ctor ~name:"Docker" ~risk:"`Audited" ~sandbox:"`Docker"
  ; subcommand_args_ctor ~name:"Opam" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Npx" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Yarn" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Pnpm" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Uv" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Glab" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Pytest" ~risk:"`Audited" ~sandbox:"`Host"
  ; { name = "Terminal_notifier"
    ; anon_pattern = "Terminal_notifier _"
    ; bind_pattern = "Terminal_notifier { title; message }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      { Shell_ir.bin = Exec_program.of_known Exec_program.Terminal_notifier
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) [ title; message ]
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Terminal_notifier"
    ; parse_body =
        Some
          {|
let rec parse title message = function
  | [] ->
    (match title, message with
     | Some t, Some m ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Terminal_notifier { title = t; message = m }))
     | _ -> None)
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse title message rest
    else (match title with
          | None -> parse (Some arg) message rest
          | Some _ -> (match message with
                       | None -> parse title (Some arg) rest
                       | Some _ -> None))
in
parse None None args|}
    }
  ; subcommand_args_ctor ~name:"Ruff" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Pyright" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Tsc" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Ocamlfind" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Rustc" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Gofmt" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Gradle" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Ninja" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Java" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Javac" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Mvn" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Cmake" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Dune_local_sh" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Osascript" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Play" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Rec" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Ffplay" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Mpg123" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Open" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Su" ~risk:"`Privileged" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Dd" ~risk:"`Privileged" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Mkfs" ~risk:"`Privileged" ~sandbox:"`Host"
  ; { name = "Generic"
    ; anon_pattern = "Generic _"
    ; bind_pattern = "Generic simple"
    ; risk = "`Privileged"
    ; sandbox = "`Host"
    ; to_simple_body = " simple"
    ; bin_variant = None
    ; parse_body = None
    }
  ]
;;

(* ─── Generator: emit OCaml source ───────────────────────────────── *)

let emit_header buf =
  Buffer.add_string
    buf
    "(* RFC-0054 PR-3 + PR-4 — auto-generated by bin/gen_shell_ir_walkers.\n\
    \   DO NOT EDIT.  Regenerated from the spec on every build.\n\
    \   The spec lives in bin/gen_shell_ir_walkers.ml; the dune rule\n\
    \   in lib/exec/dune re-emits this file when the generator changes.\n\n\
    \   This file provides parallel-verification walkers\n\
    \   (gen_risk, gen_sandbox, gen_to_simple, gen_of_simple) that\n\
    \   replace the hand-written equivalents in [Shell_ir_typed]. *)\n\n"
;;

let emit_risk buf spec =
  Buffer.add_string
    buf
    "let gen_risk : Shell_ir_typed_types.wrapped -> Shell_ir_typed_types.risk = function\n";
  List.iter
    (fun c ->
       Buffer.add_string
         buf
         (Printf.sprintf
            "  | Shell_ir_typed_types.W (Shell_ir_typed_types.%s) -> %s\n"
            c.anon_pattern
            c.risk))
    spec;
  Buffer.add_string buf "\n"
;;

let emit_sandbox buf spec =
  Buffer.add_string
    buf
    "let gen_sandbox : Shell_ir_typed_types.wrapped -> Shell_ir_typed_types.sandbox = \
     function\n";
  List.iter
    (fun c ->
       Buffer.add_string
         buf
         (Printf.sprintf
            "  | Shell_ir_typed_types.W (Shell_ir_typed_types.%s) -> %s\n"
            c.anon_pattern
            c.sandbox))
    spec;
  Buffer.add_string buf "\n"
;;

let emit_to_simple buf spec =
  Buffer.add_string
    buf
    "let gen_to_simple\n\
    \  : type i o r s. (i, o, r, s) Shell_ir_typed_types.command -> Shell_ir.simple\n\
    \  = function\n";
  List.iter
    (fun c ->
       Buffer.add_string
         buf
         (Printf.sprintf
            "  | Shell_ir_typed_types.%s ->%s\n"
            c.bind_pattern
            c.to_simple_body))
    spec;
  Buffer.add_string buf "\n"
;;

let emit_parse_functions buf spec =
  List.iter
    (fun c ->
       match c.parse_body with
       | None -> ()
       | Some body ->
         Buffer.add_string
           buf
           (Printf.sprintf
              "let gen_parse_%s (args : string list) : Shell_ir_typed_types.wrapped \
               option =\n\
               %s\n\
               ;;\n\n"
              c.name
              body))
    spec
;;

let emit_of_simple buf spec =
  (* Collect entries that have parse_body, grouped by bin_variant.
     Git entries are special-cased for subcommand dispatch. *)
  let git_entries =
    List.filter_map
      (fun c ->
         match c.bin_variant, c.parse_body with
         | Some "Git", Some _ ->
           (* Strip "Git_" prefix to get the subcommand name used in args *)
           let subcmd =
             if String.starts_with ~prefix:"Git_" c.name
             then String.sub c.name 4 (String.length c.name - 4)
             else c.name
           in
           Some (subcmd, c.name)
         | _ -> None)
      spec
  in
  let non_git_with_parse =
    List.filter_map
      (fun c ->
         match c.bin_variant, c.parse_body with
         | Some v, Some _ when v <> "Git" -> Some (v, c.name)
         | _ -> None)
      spec
  in
  let spec_variants =
    List.filter_map (fun c -> c.bin_variant) spec
    |> List.sort_uniq String.compare
  in
  (* All Exec_program.known variants — keep in sync with exec_program.mli *)
  let all_known_variants =
    [ "Ls"; "Cat"; "Pwd"; "Echo"; "Head"; "Tail"; "Rg"; "Grep"; "Find"
    ; "Which"; "Test"; "Basename"; "Dirname"; "Stat"; "Du"; "Df"; "Sort"
    ; "Uniq"; "Wc"; "Cut"; "Tr"; "File"; "Printf"; "Date"; "Env"; "Printenv"
    ; "Hostname"; "Whoami"; "Uname"; "Ps"; "Tty"
    ; "Git"; "Docker"; "Curl"; "Wget"; "Ssh"; "Scp"; "Tar"; "Rsync"
    ; "Make"; "Cmake"; "Dune_local_sh"; "Diff"; "Patch"; "Mkdir"
    ; "Npm"; "Node"; "Npx"; "Yarn"; "Pnpm"; "Pip"; "Python"; "Python3"
    ; "Pytest"; "Pyright"; "Ruff"; "Opam"; "Ocamlfind"; "Tsc"; "Cargo"
    ; "Rustc"; "Go"; "Gofmt"; "Gradle"; "Java"; "Javac"; "Mvn"; "Ninja"
    ; "Sed"; "Uv"; "Gh"; "Glab"; "Terminal_notifier"; "Osascript"
    ; "Play"; "Rec"; "Ffplay"; "Mpg123"; "Open"
    ; "Sudo"; "Su"; "Chmod"; "Chown"; "Rm"; "Dd"; "Mkfs"
    ]
  in
  let unhandled =
    List.filter
      (fun v -> not (List.mem v spec_variants))
      all_known_variants
  in
  (* Header *)
  Buffer.add_string
    buf
    "let gen_of_simple (s : Shell_ir.simple) : Shell_ir_typed_types.wrapped =\n\
    \  let generic () = Shell_ir_typed_types.W (Shell_ir_typed_types.Generic s) in\n\
    \  let lit_of_arg = function\n\
    \    | Shell_ir.Lit (s, _) -> Some s\n\
    \    | Shell_ir.Var (_, _) | Shell_ir.Concat _ -> None\n\
    \  in\n\
    \  let rec all_lits_opt args =\n\
    \    let rec go acc = function\n\
    \      | [] -> Some (List.rev acc)\n\
    \      | a :: rest ->\n\
    \        (match lit_of_arg a with\n\
    \         | Some s -> go (s :: acc) rest\n\
    \         | None -> None)\n\
    \    in\n\
    \    go [] args\n\
    \  in\n\
    \  if not (s.Shell_ir.env = [] && s.Shell_ir.redirects = [])\n\
    \  then generic ()\n\
    \  else (\n\
    \    match all_lits_opt s.Shell_ir.args with\n\
    \    | None -> generic ()\n\
    \    | Some lit_argv ->\n\
    \      let parsed : Shell_ir_typed_types.wrapped option =\n\
    \        match Exec_program.known s.Shell_ir.bin with\n";
  (* Git subcommand dispatch *)
  Buffer.add_string buf "        | Some Exec_program.Git ->\n";
  Buffer.add_string buf "          (match lit_argv with\n";
  List.iter
    (fun (subcmd_name, ctor_name) ->
       let parse_fn = Printf.sprintf "gen_parse_%s" ctor_name in
       Buffer.add_string
         buf
         (Printf.sprintf
            "           | %S :: rest -> %s rest\n" subcmd_name parse_fn))
    git_entries;
  Buffer.add_string buf "           | _ -> None)\n";
  (* Non-Git entries with parse_body — auto-generated from spec *)
  List.iter
    (fun (variant, parse_name) ->
       Buffer.add_string
         buf
         (Printf.sprintf
            "        | Some Exec_program.%s -> gen_parse_%s lit_argv\n"
            variant parse_name))
    non_git_with_parse;
  (* Untyped variants — grouped into None *)
  (match unhandled with
   | [] -> ()
   | _ ->
     Buffer.add_string buf "        | Some\n";
     Buffer.add_string buf "            ( ";
     Buffer.add_string buf
       (String.concat "\n            | "
          (List.map (fun v -> Printf.sprintf "Exec_program.%s" v) unhandled));
     Buffer.add_string buf " ) -> None\n");
  Buffer.add_string
    buf
    "        | None -> None\n\
    \      in\n\
    \      match parsed with\n\
    \      | Some w -> w\n\
    \      | None -> generic ())\n\
     ;;\n\n"
;;

let emit_constructor_names buf spec =
  Buffer.add_string buf "let gen_constructor_names : string list =\n  [ ";
  let names = List.map (fun c -> Printf.sprintf "%S" c.name) spec in
  Buffer.add_string buf (String.concat "\n  ; " names);
  Buffer.add_string buf "\n  ]\n"
;;

let () =
  let buf = Buffer.create 4096 in
  emit_header buf;
  emit_risk buf shell_ir_typed_spec;
  emit_sandbox buf shell_ir_typed_spec;
  emit_to_simple buf shell_ir_typed_spec;
  emit_parse_functions buf shell_ir_typed_spec;
  emit_of_simple buf shell_ir_typed_spec;
  emit_constructor_names buf shell_ir_typed_spec;
  print_string (Buffer.contents buf)
;;
