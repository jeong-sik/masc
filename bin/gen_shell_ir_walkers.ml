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
    then parse flags path rest
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
    then parse case_sensitive pattern path rest
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
  | _ :: rest -> parse short rest
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
  | arg :: rest when String.length arg > 8 && String.sub arg 0 8 = "--depth=" ->
    let n = String.sub arg 8 (String.length arg - 8) in
    (match int_of_string_opt n with
     | Some d -> parse (Some d) branch repo rest
     | None -> parse depth branch repo rest)
  | arg :: rest when String.length arg > 9 && String.sub arg 0 9 = "--branch=" ->
    let b = String.sub arg 9 (String.length arg - 9) in
    parse depth (Some b) repo rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse depth branch repo rest
    else (
      match repo with
      | None -> parse depth branch (Some arg) rest
      | Some _ -> None)
in
parse None None None args|}
    }
  ; { name = "Curl"
    ; anon_pattern = "Curl _"
    ; bind_pattern = "Curl { url; method_; headers; body; output_file; follow_redirects; insecure }"
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
      let output_args = match output_file with None -> [] | Some o -> [ "-o"; o ] in
      let follow_args = if follow_redirects then [ "-L" ] else [] in
      let insecure_args = if insecure then [ "-k" ] else [] in
      let args = method_args @ header_args @ body_args @ output_args @ follow_args @ insecure_args @ [ url ] in
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
let rec parse method_ headers body url output_file follow_redirects insecure = function
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
               ; output_file
               ; follow_redirects
               ; insecure
               }))
     | None -> None)
  | "-X" :: m :: rest | "--request" :: m :: rest ->
    (match String.uppercase_ascii m with
     | "GET" -> parse `GET headers body url output_file follow_redirects insecure rest
     | "POST" -> parse `POST headers body url output_file follow_redirects insecure rest
     | "PUT" -> parse `PUT headers body url output_file follow_redirects insecure rest
     | "DELETE" -> parse `DELETE headers body url output_file follow_redirects insecure rest
     | _ -> None)
  (* --request=METHOD form *)
  | arg :: rest
    when String.length arg > 10
         && String.sub arg 0 10 = "--request=" ->
    let m = String.uppercase_ascii (String.sub arg 10 (String.length arg - 10)) in
    (match m with
     | "GET" -> parse `GET headers body url output_file follow_redirects insecure rest
     | "POST" -> parse `POST headers body url output_file follow_redirects insecure rest
     | "PUT" -> parse `PUT headers body url output_file follow_redirects insecure rest
     | "DELETE" -> parse `DELETE headers body url output_file follow_redirects insecure rest
     | _ -> None)
  | "-H" :: h :: rest | "--header" :: h :: rest ->
    (match String.index_opt h ':' with
     | Some i ->
       let key = String.trim (String.sub h 0 i) in
       let value = String.trim (String.sub h (i + 1) (String.length h - i - 1)) in
       parse method_ ((key, value) :: headers) body url output_file follow_redirects insecure rest
     | None -> None)
  | "-d" :: d :: rest | "--data" :: d :: rest ->
    (match body with
     | None -> parse method_ headers (Some d) url output_file follow_redirects insecure rest
     | Some _ -> None)
  (* --data=VALUE form *)
  | arg :: rest
    when String.length arg > 7
         && String.sub arg 0 7 = "--data=" ->
    let d = String.sub arg 7 (String.length arg - 7) in
    (match body with
     | None -> parse method_ headers (Some d) url output_file follow_redirects insecure rest
     | Some _ -> None)
  | "-o" :: o :: rest | "--output" :: o :: rest ->
    parse method_ headers body url (Some o) follow_redirects insecure rest
  (* --output=FILE form *)
  | arg :: rest
    when String.length arg > 9
         && String.sub arg 0 9 = "--output=" ->
    let o = String.sub arg 9 (String.length arg - 9) in
    parse method_ headers body url (Some o) follow_redirects insecure rest
  | "-L" :: rest | "--location" :: rest ->
    parse method_ headers body url output_file true insecure rest
  | "-k" :: rest | "--insecure" :: rest ->
    parse method_ headers body url output_file follow_redirects true rest
  (* Flags that take an argument value *)
  | ( "--retry" | "--retry-max" | "--connect-timeout" | "--max-time"
    | "--max-filesize" | "--limit-rate" | "--retry-delay" | "--retry-count"
    | "-w" | "--write-out" | "-e" | "--referer"
    | "-A" | "--user-agent" | "-U" | "--proxy-user" | "-x" | "--proxy"
    | "--dns-servers" | "--resolve" | "--interface" | "-Y" | "--speed-limit"
    | "-y" | "--speed-time" | "--keepalive-time"
    | "-b" | "--cookie" | "-c" | "--cookie-jar"
    | "-E" | "--cert" | "--cacert" | "--cert-type" | "--key"
    | "-F" | "--form" | "-T" | "--upload-file"
    | "-K" | "--config" | "--proto" | "--proto-default"
    | "--data-raw" | "--data-binary" | "--data-urlencode"
    | "-m" | "--max-redirs"
    | "-t" | "--telnet-option" | "-z" | "--time-cond"
    | "--netrc-file"
    | "-P" | "--ftp-port" | "-Q" | "--quote"
    | "--random-file"
    | "--socks4" | "--socks4a"
    | "--socks5" | "--socks5-hostname" | "--stderr"
    | "--tls-max" | "--tlsauthtype" | "--tlspassword"
    | "--tlsuser" | "--tlsv1.0" | "--tlsv1.1" | "--tlsv1.2"
    | "--trace" | "--trace-ascii" | "-u" | "--user" )
    :: _val :: rest ->
    parse method_ headers body url output_file follow_redirects insecure rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse method_ headers body url output_file follow_redirects insecure rest
    else (
      match url with
      | None -> parse method_ headers body (Some arg) output_file follow_redirects insecure rest
      | Some _ -> None)
in
parse `GET [] None None None false false args|}
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
  (* Combined short flags: -rf, -fr, -rfr, etc. *)
  | arg :: rest
    when String.length arg > 2
         && arg.[0] = '-'
         && arg.[1] <> '-'
         && String.for_all (fun c -> c = 'r' || c = 'R' || c = 'f')
              (String.sub arg 1 (String.length arg - 1)) ->
    let has_r = String.contains arg 'r' || String.contains arg 'R' in
    let has_f = String.contains arg 'f' in
    parse (recursive || has_r) (force || has_f) paths rest
  (* POSIX end-of-options: all remaining are paths *)
  | "--" :: rest ->
    let remaining = List.filter (fun a -> String.length a > 0) rest in
    Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Rm { paths = List.rev paths @ remaining; recursive; force }))
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse recursive force paths rest
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
    ; bind_pattern = "Find { path; name; type_; maxdepth }"
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
        @ (match maxdepth with None -> [] | Some d -> [ "-maxdepth"; string_of_int d ])
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
(* find -exec / -ok consume all args until ";" or "+"; skip them entirely *)
let rec skip_exec = function
  | [] -> []
  | ";" :: rest -> rest
  | "+" :: rest -> rest
  | _ :: rest -> skip_exec rest
in
(* Flags that take the next argument as a value *)
let value_flags =
  [ "-newer"; "-newermt"; "-newerct"; "-neweraa"
  ; "-perm"; "-user"; "-group"; "-uid"; "-gid"
  ; "-size"; "-mtime"; "-mmin"; "-atime"; "-amin"
  ; "-ctime"; "-cmin"; "-maxdepth"; "-mindepth"
  ; "-regex"; "-path"; "-lname"; "-ilname"; "-iname"
  ; "-samefile"; "-inum"; "-links"; "-used"; "-fstype"
  ; "-printf"; "-fprintf"; "-fls"; "-fprint0"; "-fprint"
  ]
in
let rec parse name type_ maxdepth path = function
  | [] ->
    let resolved = match path with Some p -> p | None -> "." in
    Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Find { path = resolved; name; type_; maxdepth }))
  | "-name" :: n :: rest -> parse (Some n) type_ maxdepth path rest
  | "-type" :: "f" :: rest -> parse name (Some `File) maxdepth path rest
  | "-type" :: "d" :: rest -> parse name (Some `Dir) maxdepth path rest
  | "-maxdepth" :: d :: rest ->
    (match int_of_string_opt d with
     | Some n -> parse name type_ (Some n) path rest
     | None -> parse name type_ maxdepth path rest)
  | "-exec" :: rest | "-ok" :: rest
  | "-execdir" :: rest | "-okdir" :: rest -> parse name type_ maxdepth path (skip_exec rest)
  (* POSIX end-of-options: treat all remaining as path *)
  | "--" :: rest ->
    let resolved = match path with Some p -> p | None ->
      (match List.find_opt (fun a -> String.length a > 0) rest with
       | Some p -> p | None -> ".")
    in
    Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Find { path = resolved; name; type_; maxdepth }))
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then (
      (* Skip unknown flag; consume next arg if it's a known value-flag *)
      if List.mem arg value_flags
      then (
        match rest with
        | _ :: rest' -> parse name type_ maxdepth path rest'
        | [] -> parse name type_ maxdepth path rest)
      else parse name type_ maxdepth path rest)
    else (
      match path with
      | None -> parse name type_ maxdepth (Some arg) rest
      | Some _ -> None)
in
parse None None None None args|}
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
  (* Combined form: -n5 → lines = 5 *)
  | arg :: rest
    when String.length arg > 2
         && arg.[0] = '-'
         && arg.[1] = 'n'
         && String.for_all (fun c -> c >= '0' && c <= '9')
              (String.sub arg 2 (String.length arg - 2)) ->
    let l = int_of_string (String.sub arg 2 (String.length arg - 2)) in
    parse l path rest
  (* POSIX shorthand: -5 → lines = 5 *)
  | arg :: rest
    when String.length arg > 1
         && arg.[0] = '-'
         && String.for_all (fun c -> c >= '0' && c <= '9')
              (String.sub arg 1 (String.length arg - 1)) ->
    let l = int_of_string (String.sub arg 1 (String.length arg - 1)) in
    parse l path rest
  (* --lines=N form *)
  | arg :: rest
    when String.length arg > 8
         && String.sub arg 0 8 = "--lines=" ->
    let n_str = String.sub arg 8 (String.length arg - 8) in
    (match int_of_string_opt n_str with
     | Some l -> parse l path rest
     | None -> parse lines path rest)
  (* POSIX end-of-options: next non-empty arg is the path *)
  | "--" :: rest ->
    (match List.find_opt (fun a -> String.length a > 0) rest with
     | Some p -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Head { path = p; lines }))
     | None -> None)
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse lines path rest
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
  (* Combined form: -n5 → lines = 5 *)
  | arg :: rest
    when String.length arg > 2
         && arg.[0] = '-'
         && arg.[1] = 'n'
         && String.for_all (fun c -> c >= '0' && c <= '9')
              (String.sub arg 2 (String.length arg - 2)) ->
    let l = int_of_string (String.sub arg 2 (String.length arg - 2)) in
    parse l path rest
  (* POSIX shorthand: -5 → lines = 5 *)
  | arg :: rest
    when String.length arg > 1
         && arg.[0] = '-'
         && String.for_all (fun c -> c >= '0' && c <= '9')
              (String.sub arg 1 (String.length arg - 1)) ->
    let l = int_of_string (String.sub arg 1 (String.length arg - 1)) in
    parse l path rest
  (* --lines=N form *)
  | arg :: rest
    when String.length arg > 8
         && String.sub arg 0 8 = "--lines=" ->
    let n_str = String.sub arg 8 (String.length arg - 8) in
    (match int_of_string_opt n_str with
     | Some l -> parse l path rest
     | None -> parse lines path rest)
  (* POSIX end-of-options: next non-empty arg is the path *)
  | "--" :: rest ->
    (match List.find_opt (fun a -> String.length a > 0) rest with
     | Some p -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Tail { path = p; lines }))
     | None -> None)
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse lines path rest
    else (
      match path with
      | None -> parse lines (Some arg) rest
      | Some _ -> None)
in
parse 10 None args|}
    }
  ; { name = "Grep"
    ; anon_pattern = "Grep _"
    ; bind_pattern = "Grep { pattern; path; recursive; case_sensitive; files_with_matches }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let flag_args =
        (if recursive then [ "-r" ] else [])
        @ (if case_sensitive then [] else [ "-i" ])
        @ (if files_with_matches then [ "-l" ] else [])
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
let rec parse recursive case_sensitive files_with_matches pattern path = function
  | [] ->
    (match pattern with
     | Some p -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Grep { pattern = p; path; recursive; case_sensitive; files_with_matches }))
     | None -> None)
  | "-r" :: rest | "-R" :: rest | "--recursive" :: rest ->
    parse true case_sensitive files_with_matches pattern path rest
  | "-i" :: rest | "--ignore-case" :: rest ->
    parse recursive false files_with_matches pattern path rest
  | "-l" :: rest | "--files-with-matches" :: rest ->
    parse recursive case_sensitive true pattern path rest
  (* POSIX end-of-options: treat all remaining as positional *)
  | "--" :: rest ->
    let rec collect pattern path = function
      | [] ->
        (match pattern with
         | Some p -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Grep { pattern = p; path; recursive; case_sensitive; files_with_matches }))
         | None -> None)
      | a :: tl ->
        if String.length a = 0
        then collect pattern path tl
        else (
          match pattern with
          | None -> collect (Some a) path tl
          | Some _ -> collect pattern (Some a) tl)
    in collect pattern path rest
  | arg :: rest ->
    if String.length arg >= 2 && arg.[0] = '-' && arg.[1] <> '-'
    then (
      (* Combined flags: -ri, -ir, -rli, etc. *)
      let has_r = ref false in
      let has_i = ref false in
      let has_l = ref false in
      for j = 1 to String.length arg - 1 do
        match arg.[j] with
        | 'r' | 'R' -> has_r := true
        | 'i' -> has_i := true
        | 'l' -> has_l := true
        | _ -> ()
      done;
      let r' = recursive || !has_r in
      let cs' = if !has_i then false else case_sensitive in
      let l' = files_with_matches || !has_l in
      parse r' cs' l' pattern path rest)
    else if String.length arg > 0 && arg.[0] = '-'
    then parse recursive case_sensitive files_with_matches pattern path rest
    else (
      match pattern with
      | None -> parse recursive case_sensitive files_with_matches (Some arg) path rest
      | Some _ ->
        (match path with
         | None -> parse recursive case_sensitive files_with_matches pattern (Some arg) rest
         | Some _ -> None))
in
parse false true false None None args|}
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
    then parse parents path rest
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
  (* POSIX end-of-options: next non-empty arg is the path *)
  | "--" :: rest ->
    (match List.find_opt (fun a -> String.length a > 0) rest with
     | Some p -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Wc { path = p; mode }))
     | None -> None)
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse mode path rest
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
  (* --max-count=N form *)
  | arg :: rest
    when String.length arg > 12
         && String.sub arg 0 12 = "--max-count=" ->
    (match int_of_string_opt (String.sub arg 12 (String.length arg - 12)) with
     | Some c -> parse oneline (Some c) rest
     | None -> parse oneline max_count rest)
  (* Combined form: -n5 → max_count = Some 5 *)
  | arg :: rest
    when String.length arg > 2
         && arg.[0] = '-'
         && arg.[1] = 'n'
         && String.for_all (fun c -> c >= '0' && c <= '9')
              (String.sub arg 2 (String.length arg - 2)) ->
    let c = int_of_string (String.sub arg 2 (String.length arg - 2)) in
    parse oneline (Some c) rest
  (* POSIX shorthand: -5 → max_count = Some 5 *)
  | arg :: rest
    when String.length arg > 1
         && arg.[0] = '-'
         && String.for_all (fun c -> c >= '0' && c <= '9')
              (String.sub arg 1 (String.length arg - 1)) ->
    let c = int_of_string (String.sub arg 1 (String.length arg - 1)) in
    parse oneline (Some c) rest
  | "--graph" :: rest | "--all" :: rest | "--decorate" :: rest -> parse oneline max_count rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse oneline max_count rest
    else parse oneline max_count rest
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
  | "-t" :: _ :: rest -> parse reverse numeric unique key file rest  (* -t SEP — consume separator *)
  (* --key=N form *)
  | arg :: rest
    when String.length arg > 6
         && String.sub arg 0 6 = "--key=" ->
    let n_str = String.sub arg 6 (String.length arg - 6) in
    (match int_of_string_opt n_str with
     | Some n -> parse reverse numeric unique (Some n) file rest
     | None -> parse reverse numeric unique key file rest)
  (* POSIX end-of-options: treat all remaining as positional *)
  | "--" :: rest ->
    let rec collect file = function
      | [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Sort { reverse; numeric; unique; key; file }))
      | a :: tl ->
        if String.length a = 0
        then collect file tl
        else (match file with
          | None -> collect (Some a) tl
          | Some _ -> collect file tl)
    in collect file rest
  | arg :: rest ->
    (* Combined form: -k2, -k3rn — digits after -k, then optional flag chars *)
    if String.length arg >= 3 && arg.[0] = '-' && arg.[1] = 'k'
    then (
      let suffix = String.sub arg 2 (String.length arg - 2) in
      (* Extract leading digits *)
      let digit_end = ref 0 in
      while !digit_end < String.length suffix
            && Char.code suffix.[!digit_end] >= Char.code '0'
            && Char.code suffix.[!digit_end] <= Char.code '9'
      do incr digit_end done;
      if !digit_end > 0
      then (
        let n = int_of_string (String.sub suffix 0 !digit_end) in
        let flags = String.sub suffix !digit_end (String.length suffix - !digit_end) in
        let r = reverse || String.contains flags 'r' in
        let n_num = numeric || String.contains flags 'n' in
        parse r n_num unique (Some n) file rest)
      else parse reverse numeric unique key file rest)
    (* Combined short flags: -rn, -ru, -nu, -rnu, etc. *)
    else if String.length arg > 2
         && arg.[0] = '-'
         && arg.[1] <> '-'
         && String.for_all (fun c -> c = 'r' || c = 'n' || c = 'u')
              (String.sub arg 1 (String.length arg - 1))
    then (
      let r' = reverse || String.contains arg 'r' in
      let n' = numeric || String.contains arg 'n' in
      let u' = unique || String.contains arg 'u' in
      parse r' n' u' key file rest)
    else if String.length arg > 0 && arg.[0] = '-'
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
  | "-d" :: d :: rest | "--delimiter" :: d :: rest -> parse (Some d) fields file rest
  | "-f" :: f :: rest | "--fields" :: f :: rest -> parse delimiter (Some f) file rest
  | arg :: rest when String.length arg >= 3 && arg.[0] = '-' && arg.[1] = 'd' ->
    (* Combined form: -d: means -d : *)
    parse (Some (String.sub arg 2 (String.length arg - 2))) fields file rest
  | arg :: rest when String.length arg >= 3 && arg.[0] = '-' && arg.[1] = 'f' ->
    (* Combined form: -f1 means -f 1 *)
    parse delimiter (Some (String.sub arg 2 (String.length arg - 2))) file rest
  (* POSIX end-of-options: treat all remaining as positional *)
  | "--" :: rest ->
    (match fields with
     | Some f ->
       let file = List.find_opt (fun a -> String.length a > 0) rest in
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Cut { delimiter; fields = f; file }))
     | None -> None)
  | arg :: rest ->
    (match String.split_on_char '=' arg with
     | [ "--delimiter"; d ] -> parse (Some d) fields file rest
     | [ "--fields"; f ] -> parse delimiter (Some f) file rest
     | _ ->
       if String.length arg > 0 && arg.[0] = '-'
       then parse delimiter fields file rest
       else (
         match file with
         | None -> parse delimiter fields (Some arg) rest
         | Some _ -> None))
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
    ; bind_pattern = "Uniq { count; duplicates; unique; skip_fields; skip_chars; file }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
  let flag_args =
    (if count then [ Shell_ir.Lit ("-c", Shell_ir.default_meta) ] else [])
    @ (if duplicates then [ Shell_ir.Lit ("-d", Shell_ir.default_meta) ] else [])
    @ (if unique then [ Shell_ir.Lit ("-u", Shell_ir.default_meta) ] else [])
    @ (match skip_fields with Some n -> [ Shell_ir.Lit ("-f", Shell_ir.default_meta); Shell_ir.Lit (string_of_int n, Shell_ir.default_meta) ] | None -> [])
    @ (match skip_chars with Some n -> [ Shell_ir.Lit ("-s", Shell_ir.default_meta); Shell_ir.Lit (string_of_int n, Shell_ir.default_meta) ] | None -> [])
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
let rec parse count duplicates unique skip_fields skip_chars file = function
  | [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Uniq { count; duplicates; unique; skip_fields; skip_chars; file }))
  | "-c" :: rest -> parse true duplicates unique skip_fields skip_chars file rest
  | "-d" :: rest -> parse count true unique skip_fields skip_chars file rest
  | "-u" :: rest -> parse count duplicates true skip_fields skip_chars file rest
  | "-f" :: n_str :: rest ->
    (match int_of_string_opt n_str with
     | Some n -> parse count duplicates unique (Some n) skip_chars file rest
     | None -> parse count duplicates unique skip_fields skip_chars file rest)
  | "-s" :: n_str :: rest ->
    (match int_of_string_opt n_str with
     | Some n -> parse count duplicates unique skip_fields (Some n) file rest
     | None -> parse count duplicates unique skip_fields skip_chars file rest)
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse count duplicates unique skip_fields skip_chars file rest
    else parse count duplicates unique skip_fields skip_chars (Some arg) rest
in
parse false false false None None None args|}
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
  | "-f" :: f :: rest
    when String.length f > 0
         && (f.[0] = '%' || String.contains f '%') ->
    (* -f format: next token is a format string (contains %) *)
    parse (Some f) rest
  | "-f" :: rest ->
    (* -f flag without format string *)
    parse format rest
  | "-c" :: c :: rest ->
    (* -c format (GNU stat) *)
    parse (Some c) rest
  (* POSIX end-of-options: next non-empty arg is the path *)
  | "--" :: rest ->
    (match List.find_opt (fun a -> String.length a > 0) rest with
     | Some p -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Stat { format; path = p }))
     | None -> None)
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse format rest
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
  | "--max-depth" :: n :: rest ->
    (match int_of_string_opt n with
     | Some d -> parse human_readable summary (Some d) rest
     | None -> None)
  (* POSIX end-of-options: next non-empty arg is the path *)
  | "--" :: rest ->
    let remaining = List.filter (fun a -> String.length a > 0) rest in
    (match remaining with
     | p :: _ ->
       Some
         (Shell_ir_typed_types.W
            (Shell_ir_typed_types.Du
               { path = Some p; human_readable; summary; max_depth }))
     | [] ->
       Some
         (Shell_ir_typed_types.W
            (Shell_ir_typed_types.Du
               { path = None; human_readable; summary; max_depth })))
  | arg :: rest ->
    (match String.split_on_char '=' arg with
     | [ "--max-depth"; n ] ->
       (match int_of_string_opt n with
        | Some d -> parse human_readable summary (Some d) rest
        | None -> None)
     | _ ->
       (* Combined short flags: -hs, -sh *)
       if String.length arg > 2
            && arg.[0] = '-'
            && arg.[1] <> '-'
            && String.for_all (fun c -> c = 'h' || c = 's')
                 (String.sub arg 1 (String.length arg - 1))
       then (
         let h' = human_readable || String.contains arg 'h' in
         let s' = summary || String.contains arg 's' in
         parse h' s' max_depth rest)
       else if String.length arg > 0 && arg.[0] = '-'
       then parse human_readable summary max_depth rest
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
  (* POSIX end-of-options: next non-empty arg is the path *)
  | "--" :: rest ->
    let remaining = List.filter (fun a -> String.length a > 0) rest in
    (match remaining with
     | p :: _ ->
       Some
         (Shell_ir_typed_types.W
            (Shell_ir_typed_types.Df
               { path = Some p; human_readable; filesystem_type = fs_type }))
     | [] ->
       Some
         (Shell_ir_typed_types.W
            (Shell_ir_typed_types.Df
               { path = None; human_readable; filesystem_type = fs_type })))
  | arg :: rest ->
    (match String.split_on_char '=' arg with
     | [ "--type"; t ] -> parse human_readable (Some t) rest
     | _ ->
       if String.length arg >= 3 && arg.[0] = '-' && arg.[1] = 't'
       then parse human_readable (Some (String.sub arg 2 (String.length arg - 2))) rest
       else if String.length arg > 0 && arg.[0] = '-'
       then parse human_readable fs_type rest
       else
         Some
           (Shell_ir_typed_types.W
              (Shell_ir_typed_types.Df
                 { path = Some arg; human_readable; filesystem_type = fs_type })))
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
  | arg :: rest ->
    if String.length arg >= 2 && arg.[0] = '-' && arg.[1] <> '-'
    then (
      (* Combined flags: -bi, -ib, etc. *)
      let m' = ref mime in
      let b' = ref brief in
      for j = 1 to String.length arg - 1 do
        match arg.[j] with
        | 'b' -> b' := true
        | 'i' -> m' := true
        | _ -> ()
      done;
      parse !m' !b' rest)
    else if String.length arg > 0 && arg.[0] = '-'
    then parse mime brief rest
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
  | arg :: rest ->
    if String.length arg >= 2 && arg.[0] = '-' && arg.[1] <> '-'
    then (
      (* Combined flags: -srm, -arsm, etc. *)
      let a' = ref all in
      let s' = ref kn in
      let r' = ref rel in
      let m' = ref mach in
      for j = 1 to String.length arg - 1 do
        match arg.[j] with
        | 'a' -> a' := true
        | 's' -> s' := true
        | 'r' -> r' := true
        | 'm' -> m' := true
        | _ -> ()
      done;
      parse !a' !s' !r' !m' rest)
    else parse all kn rel mach rest
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
  | "-u" :: u :: rest when not (String.length u > 0 && u.[0] = '-') -> parse all full (Some u) rest
  | arg :: rest ->
    if String.length arg >= 2 && arg.[0] = '-' && arg.[1] <> '-'
    then (
      (* Combined flags: -ef, -aux, -eF, etc. *)
      (* -uUSER: user flag with attached value *)
      if arg.[1] = 'u' && String.length arg > 2
      then parse all full (Some (String.sub arg 2 (String.length arg - 2))) rest
      else (
        let a' = ref all in
        let f' = ref full in
        for j = 1 to String.length arg - 1 do
          match arg.[j] with
          | 'e' | 'A' | 'a' -> a' := true
          | 'f' | 'F' -> f' := true
          | _ -> ()
        done;
        parse !a' !f' user rest))
    else parse all full user rest
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
    ; bind_pattern = "Wget { url; output; continue_; no_check_certificate }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        (if continue_ then [ "--continue" ] else [])
        @ (if no_check_certificate then [ "--no-check-certificate" ] else [])
        @ (match output with None -> [] | Some o -> [ "-O"; o ])
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
let rec parse output continue_ ncc url = function
  | [] ->
    (match url with
     | Some u ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Wget { url = u; output; continue_; no_check_certificate = ncc }))
     | None -> None)
  | "-O" :: o :: rest -> parse (Some o) continue_ ncc url rest
  | "--output-document" :: o :: rest -> parse (Some o) continue_ ncc url rest
  | "-c" :: rest -> parse output true ncc url rest
  | "--continue" :: rest -> parse output true ncc url rest
  | "--no-check-certificate" :: rest -> parse output continue_ true url rest
  | arg :: rest ->
    (match String.split_on_char '=' arg with
     | [ "--output-document"; o ] -> parse (Some o) continue_ ncc url rest
     | _ ->
       if String.length arg > 0 && arg.[0] = '-'
       then parse output continue_ ncc url rest
       else (
         match url with
         | None -> parse output continue_ ncc (Some arg) rest
         | Some _ -> None))
in
parse None false false None args|}
    }
  ; { name = "Ssh"
    ; anon_pattern = "Ssh _"
    ; bind_pattern = "Ssh { host; user; command; port; identity_file }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let host_str =
        match user with
        | None -> host
        | Some u -> u ^ "@" ^ host
      in
      let port_args = match port with Some p -> [ "-p"; string_of_int p ] | None -> [] in
      let id_args = match identity_file with Some f -> [ "-i"; f ] | None -> [] in
      let args =
        port_args
        @ id_args
        @ [ host_str ]
        @ (match command with None -> [] | Some c -> [ c ])
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
let rec parse port id_file host user command = function
  | [] ->
    (match host with
     | Some h ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Ssh { host = h; user; command; port; identity_file = id_file }))
     | None -> None)
  | "-p" :: p_str :: rest ->
    (match int_of_string_opt p_str with
     | Some p -> parse (Some p) id_file host user command rest
     | None -> parse port id_file host user command rest)
  | "-i" :: f :: rest -> parse port (Some f) host user command rest
  | "-o" :: _ :: rest -> parse port id_file host user command rest
  | "-L" :: _ :: rest -> parse port id_file host user command rest
  | "-R" :: _ :: rest -> parse port id_file host user command rest
  | "-D" :: _ :: rest -> parse port id_file host user command rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse port id_file host user command rest
    else (
      match host with
      | None ->
        (* First positional: [user@]host *)
        let u, h =
          match String.split_on_char '@' arg with
          | [ u; h ] -> (Some u, h)
          | _ -> (None, arg)
        in
        parse port id_file (Some h) u command rest
      | Some _ ->
        (* Remaining positional tokens are the remote command *)
        let cmd = String.concat " " (arg :: rest) in
        Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Ssh
          { host = (match host with Some h -> h | None -> ""); user; command = Some cmd; port; identity_file = id_file })))
in
parse None None None None None args|}
    }
  ; { name = "Scp"
    ; anon_pattern = "Scp _"
    ; bind_pattern = "Scp { source; dest; recursive; port }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        (match port with Some p -> [ "-P"; string_of_int p ] | None -> [])
        @ (if recursive then [ "-r" ] else [])
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
let rec parse recursive port src dest = function
  | [] ->
    (match src, dest with
     | Some s, Some d ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Scp { source = s; dest = d; recursive; port }))
     | _ -> None)
  | "-r" :: rest -> parse true port src dest rest
  | "-P" :: p_str :: rest ->
    (match int_of_string_opt p_str with
     | Some p -> parse recursive (Some p) src dest rest
     | None -> parse recursive port src dest rest)
  | "-p" :: rest -> parse recursive port src dest rest
  | "-C" :: rest -> parse recursive port src dest rest
  | "-v" :: rest -> parse recursive port src dest rest
  | "-q" :: rest -> parse recursive port src dest rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse recursive port src dest rest
    else (
      match src with
      | None -> parse recursive port (Some arg) dest rest
      | Some _ ->
        match dest with
        | None -> parse recursive port src (Some arg) rest
        | Some _ -> None)
in
parse false None None None args|}
    }
  ; { name = "Tar"
    ; anon_pattern = "Tar _"
    ; bind_pattern = "Tar { action; archive; paths; compression }"
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
      let compression_flag =
        match compression with
        | `None -> []
        | `Gzip -> [ "-z" ]
        | `Bzip2 -> [ "-j" ]
        | `Xz -> [ "-J" ]
        | `Zstd -> [ "--zstd" ]
      in
      let args =
        [ action_flag ]
        @ compression_flag
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
let is_valid_tar_flag_char c =
  match c with
  | 'c' | 't' | 'x' | 'r' | 'u' | 'v' | 'f' | 'w'
  | 'z' | 'j' | 'J' | 'Z' | 'a' | 'o' | 'p' | 'k'
  | 'L' | 'N' | 'P' | 'C' | 'S' | 'h' -> true
  | _ -> false
in
(* Only expand the first positional arg as bare tar flags.
   Subsequent positional args are archive or paths, NOT flags.
   This prevents corruption of all-alphabetic filenames like README. *)
let expand_bare_tar_flags args =
  let found_positional = ref false in
  List.concat_map
    (fun arg ->
       if !found_positional
       then [ arg ]
       else if String.length arg >= 2
               && arg.[0] <> '-'
               && String.for_all is_valid_tar_flag_char arg
       then (
         found_positional := true;
         List.init (String.length arg) (fun i ->
           Printf.sprintf "-%c" arg.[i]))
       else [ arg ])
    args
in
let args = expand_bare_tar_flags args in
let rec parse action compression archive paths = function
  | [] ->
    (match action, archive with
     | Some a, Some f ->
       Some
         (Shell_ir_typed_types.W
            (Shell_ir_typed_types.Tar
               { action = a; archive = f; paths = List.rev paths; compression }))
     | _ -> None)
  | "-c" :: rest -> parse (Some `Create) compression archive paths rest
  | "-x" :: rest -> parse (Some `Extract) compression archive paths rest
  | "-t" :: rest -> parse (Some `List) compression archive paths rest
  | "-z" :: rest -> parse action `Gzip archive paths rest
  | "-j" :: rest -> parse action `Bzip2 archive paths rest
  | "-J" :: rest -> parse action `Xz archive paths rest
  | "--zstd" :: rest -> parse action `Zstd archive paths rest
  | "-f" :: f :: rest -> parse action compression (Some f) paths rest
  | arg :: rest ->
    if String.length arg >= 3 && arg.[0] = '-'
    then (
      (* -fARCHIVE combined form: find 'f' in flag string, extract archive *)
      let f_pos = ref (-1) in
      for j = 1 to String.length arg - 1 do
        if arg.[j] = 'f' && !f_pos = -1 then f_pos := j
      done;
      if !f_pos >= 0
      then (
        let prefix = String.sub arg 1 (!f_pos - 1) in
        let archive_name = String.sub arg (!f_pos + 1) (String.length arg - !f_pos - 1) in
        (* Re-parse prefix flags *)
        let rec apply_flags a c paths = function
          | [] -> parse a c (Some archive_name) paths rest
          | ch :: tl ->
            (match ch with
             | 'c' -> apply_flags (Some `Create) c paths tl
             | 'x' -> apply_flags (Some `Extract) c paths tl
             | 't' -> apply_flags (Some `List) c paths tl
             | 'z' -> apply_flags a `Gzip paths tl
             | 'j' -> apply_flags a `Bzip2 paths tl
             | 'J' -> apply_flags a `Xz paths tl
             | _ -> apply_flags a c paths tl)
        in
        let prefix_chars = List.init (String.length prefix) (fun i -> prefix.[i]) in
        apply_flags action compression paths prefix_chars)
      else parse action compression archive paths rest)
    else if String.length arg > 0 && arg.[0] = '-'
    then parse action compression archive paths rest
    else parse action compression archive (arg :: paths) rest
in
parse None `None None [] args|}
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
  (* Combined form: -j4 → jobs = Some 4 *)
  | arg :: rest
    when String.length arg > 2
         && String.length arg <= 5
         && arg.[0] = '-'
         && arg.[1] = 'j'
         && String.for_all (fun c -> c >= '0' && c <= '9')
              (String.sub arg 2 (String.length arg - 2)) ->
    let j = int_of_string (String.sub arg 2 (String.length arg - 2)) in
    parse (Some j) target rest
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
    ; bind_pattern = "Diff { file1; file2; unified; brief }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        (if unified then [ "-u" ] else [])
        @ (if brief then [ "--brief" ] else [])
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
let rec parse unified brief files = function
  | [] ->
    (match files with
     | [ f1; f2 ] ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Diff { file1 = f1; file2 = f2; unified; brief }))
     | _ -> None)
  | "-u" :: rest -> parse true brief files rest
  | "--unified" :: rest -> parse true brief files rest
  | "-q" :: rest -> parse unified true files rest
  | "--brief" :: rest -> parse unified true files rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse unified brief files rest
    else parse unified brief (files @ [ arg ]) rest
in
parse false false [] args|}
    }
  ; { name = "Sed"
    ; anon_pattern = "Sed _"
    ; bind_pattern = "Sed { expression; file; in_place; extended_regex; suppress_output }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        (if in_place then [ "-i" ] else [])
        @ (if extended_regex then [ "-E" ] else [])
        @ (if suppress_output then [ "-n" ] else [])
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
let rec parse in_place ext_re suppress expr file = function
  | [] ->
    (match expr, file with
     | Some e, Some f ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Sed { expression = e; file = f; in_place; extended_regex = ext_re; suppress_output = suppress }))
     | _ -> None)
  | "-i" :: rest ->
    (* macOS sed -i '' takes an empty suffix; GNU sed -i has no suffix.
       Only skip the next token if it's an explicit empty string (macOS style).
       Non-empty non-flag tokens are the expression, not a suffix. *)
    (match rest with
     | "" :: rest' -> parse true ext_re suppress expr file rest'   (* -i '' — macOS empty suffix *)
     | _ -> parse true ext_re suppress expr file rest)              (* -i at end or GNU style *)
  | "-e" :: e :: rest -> parse in_place ext_re suppress (Some e) file rest  (* explicit expression *)
  | "-E" :: rest | "--regexp-extended" :: rest -> parse in_place true suppress expr file rest
  | "-n" :: rest | "--quiet" :: rest | "--silent" :: rest -> parse in_place ext_re true expr file rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse in_place ext_re suppress expr file rest
    else (
      match expr with
      | None -> parse in_place ext_re suppress (Some arg) file rest
      | Some _ ->
        match file with
        | None -> parse in_place ext_re suppress expr (Some arg) rest
        | Some _ -> None)
in
parse false false false None None args|}
    }
  ; { name = "Rsync"
    ; anon_pattern = "Rsync _"
    ; bind_pattern = "Rsync { source; dest; archive; delete; dry_run; compress; flags }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let typed_flags =
        (if archive then [ "-a" ] else [])
        @ (if delete then [ "--delete" ] else [])
        @ (if dry_run then [ "--dry-run" ] else [])
        @ (if compress then [ "-z" ] else [])
      in
      let args = typed_flags @ flags @ [ source; dest ] in
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
(* Value-flags that consume the next token as their argument *)
let rsync_value_flags =
  [ "-e"; "--rsh"
  ; "--exclude"; "--include"; "--filter"
  ; "--backup-dir"; "--compare-dest"; "--link-dest"; "--copy-dest"
  ; "--partial-dir"; "--log-file"; "--address"; "--port"
  ; "--sockopts"; "--out-format"; "--password-file"
  ; "--bwlimit"; "--max-size"; "--min-size"; "--files-from"
  ; "--usermap"; "--groupmap"; "--chmod"
  ; "-M"; "--remote-option"; "--rsync-path"
  ; "--timeout"; "--contimeout"; "--temp-dir"
  ; "--suffix"; "--info"; "--debug"
  ; "--block-size"; "--checksum-choice"
  ]
in
let rec parse flags archive delete dry_run compress src dst = function
  | [] ->
    (match src, dst with
     | Some s, Some d ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Rsync { source = s; dest = d; archive; delete; dry_run; compress; flags = List.rev flags }))
     | _ -> None)
  | "-a" :: rest -> parse flags true delete dry_run compress src dst rest
  | "--archive" :: rest -> parse flags true delete dry_run compress src dst rest
  | "--delete" :: rest -> parse flags archive true dry_run compress src dst rest
  | "--dry-run" :: rest -> parse flags archive delete true compress src dst rest
  | "-n" :: rest -> parse flags archive delete true compress src dst rest
  | "-z" :: rest -> parse flags archive delete dry_run true src dst rest
  | "--compress" :: rest -> parse flags archive delete dry_run true src dst rest
  | arg :: val_ :: rest
    when String.length arg > 0 && arg.[0] = '-'
         && List.mem arg rsync_value_flags ->
    parse (val_ :: arg :: flags) archive delete dry_run compress src dst rest
  | arg :: rest ->
    (match String.split_on_char '=' arg with
     | [ flag; value ] when List.mem flag rsync_value_flags ->
       parse (value :: flag :: flags) archive delete dry_run compress src dst rest
     | _ ->
       if String.length arg > 0 && arg.[0] = '-'
       then parse (arg :: flags) archive delete dry_run compress src dst rest
       else (
         match src with
         | None -> parse flags archive delete dry_run compress (Some arg) dst rest
         | Some _ ->
           match dst with
           | None -> parse flags archive delete dry_run compress src (Some arg) rest
           | Some _ -> None))
in
parse [] false false false false None None args|}
    }
  ; { name = "Node"
    ; anon_pattern = "Node _"
    ; bind_pattern = "Node { script; args; inline }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let all_args =
        match inline with
        | Some code -> [ "-e"; code ] @ args
        | None -> script :: args
      in
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
let rec parse inline script extra = function
  | [] ->
    (match inline, script with
     | Some code, _ ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Node { script = ""; args = List.rev extra; inline = Some code }))
     | None, Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Node { script = s; args = List.rev extra; inline = None }))
     | None, None -> None)
  | "-e" :: code :: rest -> parse (Some code) script extra rest
  | arg :: rest ->
    (match inline, script with
     | Some _, _ -> parse inline script (arg :: extra) rest
     | None, Some _ -> parse inline script (arg :: extra) rest
     | None, None ->
       if String.length arg > 0 && arg.[0] = '-'
       then parse inline script extra rest
       else parse inline (Some arg) extra rest)
in
parse None None [] args|}
    }
  ; { name = "Python"
    ; anon_pattern = "Python _"
    ; bind_pattern = "Python { script; args; inline }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let all_args =
        match inline with
        | Some code -> [ "-c"; code ] @ args
        | None -> script :: args
      in
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
let rec parse inline script extra = function
  | [] ->
    (match inline, script with
     | Some code, _ ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Python { script = ""; args = List.rev extra; inline = Some code }))
     | None, Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Python { script = s; args = List.rev extra; inline = None }))
     | None, None -> None)
  | "-c" :: code :: rest -> parse (Some code) script extra rest
  | arg :: rest ->
    (match inline, script with
     | Some _, _ -> parse inline script (arg :: extra) rest
     | None, Some _ -> parse inline script (arg :: extra) rest
     | None, None ->
       if String.length arg > 0 && arg.[0] = '-'
       then parse inline script extra rest
       else parse inline (Some arg) extra rest)
in
parse None None [] args|}
    }
  ; { name = "Python3"
    ; anon_pattern = "Python3 _"
    ; bind_pattern = "Python3 { script; args; inline }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let all_args =
        match inline with
        | Some code -> [ "-c"; code ] @ args
        | None -> script :: args
      in
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
let rec parse inline script extra = function
  | [] ->
    (match inline, script with
     | Some code, _ ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Python3 { script = ""; args = List.rev extra; inline = Some code }))
     | None, Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Python3 { script = s; args = List.rev extra; inline = None }))
     | None, None -> None)
  | "-c" :: code :: rest -> parse (Some code) script extra rest
  | arg :: rest ->
    (match inline, script with
     | Some _, _ -> parse inline script (arg :: extra) rest
     | None, Some _ -> parse inline script (arg :: extra) rest
     | None, None ->
       if String.length arg > 0 && arg.[0] = '-'
       then parse inline script extra rest
       else parse inline (Some arg) extra rest)
in
parse None None [] args|}
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
  ; { name = "Npm"
    ; anon_pattern = "Npm _"
    ; bind_pattern = "Npm { subcommand; save_dev; global; force; rest }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        let base = [ subcommand ] in
        let base = if save_dev then base @ [ "--save-dev" ] else base in
        let base = if global then base @ [ "--global" ] else base in
        let base = if force then base @ [ "--force" ] else base in
        base @ rest
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Npm
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Npm"
    ; parse_body =
        Some
          {|
let rec parse subcmd sd glb frc = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Npm { subcommand = s; save_dev = sd; global = glb; force = frc; rest = [] }))
     | None -> None)
  | "--save-dev" :: rest -> parse subcmd true glb frc rest
  | "-D" :: rest -> parse subcmd true glb frc rest
  | "--global" :: rest -> parse subcmd sd true frc rest
  | "-g" :: rest -> parse subcmd sd true frc rest
  | "--force" :: rest -> parse subcmd sd glb true rest
  | arg :: rest ->
    (match subcmd with
     | None -> parse (Some arg) sd glb frc rest
     | Some _ ->
       let rec collect acc = function
         | [] -> List.rev acc
         | x :: xs -> collect (x :: acc) xs
       in
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Npm {
         subcommand = (match subcmd with Some s -> s | None -> "");
         save_dev = sd; global = glb; force = frc;
         rest = collect [ arg ] rest
       })))
in
parse None false false false args|}
    }
  ; { name = "Cargo"
    ; anon_pattern = "Cargo _"
    ; bind_pattern = "Cargo { subcommand; release; verbose; features; rest }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        let base = [ subcommand ] in
        let base = if release then base @ [ "--release" ] else base in
        let base = if verbose then base @ [ "--verbose" ] else base in
        let base = match features with Some f -> base @ [ "--features"; f ] | None -> base in
        base @ rest
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Cargo
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Cargo"
    ; parse_body =
        Some
          {|
let rec parse subcmd rel verb feat = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Cargo { subcommand = s; release = rel; verbose = verb; features = feat; rest = [] }))
     | None -> None)
  | "--release" :: rest -> parse subcmd true verb feat rest
  | "--verbose" :: rest -> parse subcmd rel true feat rest
  | "-v" :: rest -> parse subcmd rel true feat rest
  | "--features" :: f :: rest -> parse subcmd rel verb (Some f) rest
  | arg :: rest ->
    (* Handle --features=VALUE *)
    if String.length arg > 11 && String.sub arg 0 11 = "--features="
    then (
      let f = String.sub arg 11 (String.length arg - 11) in
      parse subcmd rel verb (Some f) rest)
    else (
      match subcmd with
      | None -> parse (Some arg) rel verb feat rest
      | Some _ ->
        let rec collect acc = function
          | [] -> List.rev acc
          | x :: xs -> collect (x :: acc) xs
        in
        Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Cargo {
          subcommand = (match subcmd with Some s -> s | None -> "");
          release = rel; verbose = verb; features = feat;
          rest = collect [ arg ] rest
        })))
in
parse None false false None args|}
    }
  ; { name = "Go"
    ; anon_pattern = "Go _"
    ; bind_pattern = "Go { subcommand; verbose; race; rest }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        let base = [ subcommand ] in
        let base = if verbose then base @ [ "-v" ] else base in
        let base = if race then base @ [ "-race" ] else base in
        base @ rest
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Go
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Go"
    ; parse_body =
        Some
          {|
let rec parse subcmd v race = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Go { subcommand = s; verbose = v; race; rest = [] }))
     | None -> None)
  | "-v" :: rest -> parse subcmd true race rest
  | "-race" :: rest -> parse subcmd v true rest
  | arg :: rest ->
    (match subcmd with
     | None -> parse (Some arg) v race rest
     | Some _ ->
       let rec collect acc = function
         | [] -> List.rev acc
         | x :: xs -> collect (x :: acc) xs
       in
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Go {
         subcommand = (match subcmd with Some s -> s | None -> "");
         verbose = v; race;
         rest = collect [ arg ] rest
       })))
in
parse None false false args|}
    }
  ; { name = "Gh"
    ; anon_pattern = "Gh _"
    ; bind_pattern = "Gh { subcommand; action; draft; squash; delete_branch; body; title; rest }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args = [ subcommand ] in
      let args = match action with Some a -> args @ [ a ] | None -> args in
      let args = if draft then args @ [ "--draft" ] else args in
      let args = if squash then args @ [ "--squash" ] else args in
      let args = if delete_branch then args @ [ "--delete-branch" ] else args in
      let args = match body with Some b -> args @ [ "--body"; b ] | None -> args in
      let args = match title with Some t -> args @ [ "--title"; t ] | None -> args in
      let args = args @ rest in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Gh
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Gh"
    ; parse_body =
        Some
          {|
let rec parse subcmd act draft squash del_branch body title rest = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some
         (Shell_ir_typed_types.W
            (Shell_ir_typed_types.Gh
               { subcommand = s
               ; action = act
               ; draft
               ; squash
               ; delete_branch = del_branch
               ; body
               ; title
               ; rest = List.rev rest
               }))
     | None -> None)
  | arg :: args ->
    (match subcmd with
     | None -> parse (Some arg) act draft squash del_branch body title rest args
     | Some _ when act = None && String.length arg > 0 && arg.[0] <> '-' ->
       parse subcmd (Some arg) draft squash del_branch body title rest args
     | Some _ ->
       (match arg with
        | "--draft" -> parse subcmd act true squash del_branch body title rest args
        | "--squash" -> parse subcmd act draft true del_branch body title rest args
        | "--delete-branch" -> parse subcmd act draft squash true body title rest args
        | "--body" ->
          (match args with
           | v :: rest' -> parse subcmd act draft squash del_branch (Some v) title rest rest'
           | [] -> parse subcmd act draft squash del_branch body title rest args)
        | "--title" ->
          (match args with
           | v :: rest' -> parse subcmd act draft squash del_branch body (Some v) rest rest'
           | [] -> parse subcmd act draft squash del_branch body title rest args)
        | arg when String.length arg > 7 && String.sub arg 0 7 = "--body=" ->
          let v = String.sub arg 7 (String.length arg - 7) in
          parse subcmd act draft squash del_branch (Some v) title rest args
        | arg when String.length arg > 8 && String.sub arg 0 8 = "--title=" ->
          let v = String.sub arg 8 (String.length arg - 8) in
          parse subcmd act draft squash del_branch body (Some v) rest args
        | "--repo" | "--assignee" | "--label" | "--milestone" | "--project"
        | "--reviewer" | "--base" | "--head" | "--editor" | "--hostname"
        | "--jq" | "--template" | "--limit" | "--state" | "--web"
        | "-R" | "-a" | "-l" | "-p" | "-r" | "-B" | "-H" ->
          (match args with
           | _ :: rest' -> parse subcmd act draft squash del_branch body title rest rest'
           | [] -> parse subcmd act draft squash del_branch body title rest args)
        | _ when String.length arg > 1 && arg.[0] = '-' && arg.[1] = '-' ->
          (match String.index_opt arg '=' with
           | Some _ -> parse subcmd act draft squash del_branch body title rest args
           | None ->
             (match args with
              | v :: rest' when String.length v > 0 && v.[0] <> '-' ->
                parse subcmd act draft squash del_branch body title rest rest'
              | _ -> parse subcmd act draft squash del_branch body title rest args))
        | _ -> parse subcmd act draft squash del_branch body title (arg :: rest) args))
in
parse None None false false false None None [] args|}
    }
  ; { name = "Chmod"
    ; anon_pattern = "Chmod _"
    ; bind_pattern = "Chmod { mode; path; recursive }"
    ; risk = "`Privileged"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        (if recursive then [ "-R" ] else [])
        @ [ mode; path ]
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Chmod
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Chmod"
    ; parse_body =
        Some
          {|
let rec parse recursive mode path = function
  | [] ->
    (match mode, path with
     | Some m, Some p ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Chmod { mode = m; path = p; recursive }))
     | _ -> None)
  | "-R" :: rest -> parse true mode path rest
  | "--recursive" :: rest -> parse true mode path rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse recursive mode path rest
    else (
      match mode with
      | None -> parse recursive (Some arg) path rest
      | Some _ ->
        (match path with
         | None -> parse recursive mode (Some arg) rest
         | Some _ -> None))
in
parse false None None args|}
    }
  ; { name = "Chown"
    ; anon_pattern = "Chown _"
    ; bind_pattern = "Chown { owner; path; recursive }"
    ; risk = "`Privileged"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        (if recursive then [ "-R" ] else [])
        @ [ owner; path ]
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Chown
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Chown"
    ; parse_body =
        Some
          {|
let rec parse recursive owner path = function
  | [] ->
    (match owner, path with
     | Some o, Some p ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Chown { owner = o; path = p; recursive }))
     | _ -> None)
  | "-R" :: rest -> parse true owner path rest
  | "--recursive" :: rest -> parse true owner path rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse recursive owner path rest
    else (
      match owner with
      | None -> parse recursive (Some arg) path rest
      | Some _ ->
        (match path with
         | None -> parse recursive owner (Some arg) rest
         | Some _ -> None))
in
parse false None None args|}
    }
  ; { name = "Docker"
    ; anon_pattern = "Docker _"
    ; bind_pattern = "Docker { subcommand; rm; privileged; detach; rest }"
    ; risk = "`Audited"
    ; sandbox = "`Docker"
    ; to_simple_body =
        {|
      let args =
        let base = [ subcommand ] in
        let base = if rm then base @ [ "--rm" ] else base in
        let base = if privileged then base @ [ "--privileged" ] else base in
        let base = if detach then base @ [ "-d" ] else base in
        base @ rest
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Docker
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Docker"
    ; parse_body =
        Some
          {|
let rec parse subcmd rm priv det = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Docker { subcommand = s; rm; privileged = priv; detach = det; rest = [] }))
     | None -> None)
  | "--rm" :: rest -> parse subcmd true priv det rest
  | "--privileged" :: rest -> parse subcmd rm true det rest
  | "-d" :: rest -> parse subcmd rm priv true rest
  | "--detach" :: rest -> parse subcmd rm priv true rest
  | arg :: rest ->
    (match subcmd with
     | None -> parse (Some arg) rm priv det rest
     | Some _ ->
       (* accumulate remaining args in rest *)
       let rec collect acc = function
         | [] -> List.rev acc
         | x :: xs -> collect (x :: acc) xs
       in
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Docker {
         subcommand = (match subcmd with Some s -> s | None -> "");
         rm; privileged = priv; detach = det;
         rest = collect [ arg ] rest
       })))
in
parse None false false false args|}
    }
  ; { name = "Opam"
    ; anon_pattern = "Opam _"
    ; bind_pattern = "Opam { subcommand; yes; rest }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        let base = [ subcommand ] in
        let base = if yes then base @ [ "-y" ] else base in
        base @ rest
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Opam
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Opam"
    ; parse_body =
        Some
          {|
  let rec parse subcmd y = function
    | [] ->
      (match subcmd with
       | Some s ->
         Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Opam { subcommand = s; yes = y; rest = [] }))
       | None -> None)
    | "-y" :: rest -> parse subcmd true rest
    | "--yes" :: rest -> parse subcmd true rest
    | arg :: rest ->
      (match subcmd with
       | None -> parse (Some arg) y rest
       | Some _ ->
         let rec collect acc = function
           | [] -> List.rev acc
           | x :: xs -> collect (x :: acc) xs
         in
         Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Opam {
           subcommand = (match subcmd with Some s -> s | None -> "");
           yes = y;
           rest = collect [ arg ] rest
         })))
  in
  parse None false args|}
    }
  ; { name = "Npx"
    ; anon_pattern = "Npx _"
    ; bind_pattern = "Npx { subcommand; yes; rest }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        let base = [ subcommand ] in
        let base = if yes then base @ [ "-y" ] else base in
        base @ rest
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Npx
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Npx"
    ; parse_body =
        Some
          {|
  let rec parse subcmd y = function
    | [] ->
      (match subcmd with
       | Some s ->
         Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Npx { subcommand = s; yes = y; rest = [] }))
       | None -> None)
    | "-y" :: rest -> parse subcmd true rest
    | "--yes" :: rest -> parse subcmd true rest
    | arg :: rest ->
      (match subcmd with
       | None -> parse (Some arg) y rest
       | Some _ ->
         let rec collect acc = function
           | [] -> List.rev acc
           | x :: xs -> collect (x :: acc) xs
         in
         Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Npx {
           subcommand = (match subcmd with Some s -> s | None -> "");
           yes = y;
           rest = collect [ arg ] rest
         })))
  in
  parse None false args|}
    }
  ; { name = "Yarn"
    ; anon_pattern = "Yarn _"
    ; bind_pattern = "Yarn { subcommand; dev; global; production; frozen_lockfile; rest }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        let base = [ subcommand ] in
        let base = if dev then base @ [ "--dev" ] else base in
        let base = if global then base @ [ "--global" ] else base in
        let base = if production then base @ [ "--production" ] else base in
        let base = if frozen_lockfile then base @ [ "--frozen-lockfile" ] else base in
        base @ rest
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Yarn
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Yarn"
    ; parse_body =
        Some
          {|
let rec parse subcmd dev glb prod fl = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Yarn { subcommand = s; dev; global = glb; production = prod; frozen_lockfile = fl; rest = [] }))
     | None -> None)
  | "--dev" :: rest -> parse subcmd true glb prod fl rest
  | "-D" :: rest -> parse subcmd true glb prod fl rest
  | "--global" :: rest -> parse subcmd dev true prod fl rest
  | "-g" :: rest -> parse subcmd dev true prod fl rest
  | "--production" :: rest -> parse subcmd dev glb true fl rest
  | "--prod" :: rest -> parse subcmd dev glb true fl rest
  | "--frozen-lockfile" :: rest -> parse subcmd dev glb prod true rest
  | arg :: rest ->
    (match subcmd with
     | None -> parse (Some arg) dev glb prod fl rest
     | Some _ ->
       let rec collect acc = function
         | [] -> List.rev acc
         | x :: xs -> collect (x :: acc) xs
       in
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Yarn {
         subcommand = (match subcmd with Some s -> s | None -> "");
         dev; global = glb; production = prod; frozen_lockfile = fl;
         rest = collect [ arg ] rest
       })))
in
parse None false false false false args|}
    }
  ; { name = "Pnpm"
    ; anon_pattern = "Pnpm _"
    ; bind_pattern = "Pnpm { subcommand; save_dev; global; force; production; rest }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        let base = [ subcommand ] in
        let base = if save_dev then base @ [ "--save-dev" ] else base in
        let base = if global then base @ [ "--global" ] else base in
        let base = if force then base @ [ "--force" ] else base in
        let base = if production then base @ [ "--production" ] else base in
        base @ rest
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Pnpm
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Pnpm"
    ; parse_body =
        Some
          {|
let rec parse subcmd sd glb frc prod = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Pnpm { subcommand = s; save_dev = sd; global = glb; force = frc; production = prod; rest = [] }))
     | None -> None)
  | "--save-dev" :: rest -> parse subcmd true glb frc prod rest
  | "-D" :: rest -> parse subcmd true glb frc prod rest
  | "--global" :: rest -> parse subcmd sd true frc prod rest
  | "-g" :: rest -> parse subcmd sd true frc prod rest
  | "--force" :: rest -> parse subcmd sd glb true prod rest
  | "--production" :: rest -> parse subcmd sd glb frc true rest
  | "--prod" :: rest -> parse subcmd sd glb frc true rest
  | arg :: rest ->
    (match subcmd with
     | None -> parse (Some arg) sd glb frc prod rest
     | Some _ ->
       let rec collect acc = function
         | [] -> List.rev acc
         | x :: xs -> collect (x :: acc) xs
       in
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Pnpm {
         subcommand = (match subcmd with Some s -> s | None -> "");
         save_dev = sd; global = glb; force = frc; production = prod;
         rest = collect [ arg ] rest
       })))
in
parse None false false false false args|}
    }
  ; { name = "Uv"
    ; anon_pattern = "Uv _"
    ; bind_pattern = "Uv { subcommand; no_cache; system; rest }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        let base = [ subcommand ] in
        let base = if no_cache then base @ [ "--no-cache" ] else base in
        let base = if system then base @ [ "--system" ] else base in
        base @ rest
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Uv
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Uv"
    ; parse_body =
        Some
          {|
let rec parse subcmd nc sys = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Uv { subcommand = s; no_cache = nc; system = sys; rest = [] }))
     | None -> None)
  | "--no-cache" :: rest -> parse subcmd true sys rest
  | "-n" :: rest -> parse subcmd true sys rest
  | "--system" :: rest -> parse subcmd nc true rest
  | arg :: rest ->
    (match subcmd with
     | None -> parse (Some arg) nc sys rest
     | Some _ ->
       let rec collect acc = function
         | [] -> List.rev acc
         | x :: xs -> collect (x :: acc) xs
       in
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Uv {
         subcommand = (match subcmd with Some s -> s | None -> "");
         no_cache = nc; system = sys;
         rest = collect [ arg ] rest
       })))
in
parse None false false args|}
    }
  ; { name = "Glab"
    ; anon_pattern = "Glab _"
    ; bind_pattern = "Glab { subcommand; yes; force; rest }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        let base = [ subcommand ] in
        let base = if yes then base @ [ "--yes" ] else base in
        let base = if force then base @ [ "--force" ] else base in
        base @ rest
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Glab
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Glab"
    ; parse_body =
        Some
          {|
let rec parse subcmd y f = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Glab { subcommand = s; yes = y; force = f; rest = [] }))
     | None -> None)
  | "--yes" :: rest -> parse subcmd true f rest
  | "-y" :: rest -> parse subcmd true f rest
  | "--force" :: rest -> parse subcmd y true rest
  | "-f" :: rest -> parse subcmd y true rest
  | arg :: rest ->
    (match subcmd with
     | None -> parse (Some arg) y f rest
     | Some _ ->
       let rec collect acc = function
         | [] -> List.rev acc
         | x :: xs -> collect (x :: acc) xs
       in
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Glab {
         subcommand = (match subcmd with Some s -> s | None -> "");
         yes = y; force = f;
         rest = collect [ arg ] rest
       })))
in
parse None false false args|}
    }
  ; { name = "Pytest"
    ; anon_pattern = "Pytest _"
    ; bind_pattern = "Pytest { subcommand; verbose; exitfirst; rest }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        let base = [ subcommand ] in
        let base = if verbose then base @ [ "-v" ] else base in
        let base = if exitfirst then base @ [ "-x" ] else base in
        base @ rest
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Pytest
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Pytest"
    ; parse_body =
        Some
          {|
let rec parse subcmd v x = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Pytest { subcommand = s; verbose = v; exitfirst = x; rest = [] }))
     | None -> None)
  | "-v" :: rest -> parse subcmd true x rest
  | "-x" :: rest -> parse subcmd v true rest
  | arg :: rest ->
    (match subcmd with
     | None -> parse (Some arg) v x rest
     | Some _ ->
       let rec collect acc = function
         | [] -> List.rev acc
         | x :: xs -> collect (x :: acc) xs
       in
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Pytest {
         subcommand = (match subcmd with Some s -> s | None -> "");
         verbose = v; exitfirst = x;
         rest = collect [ arg ] rest
       })))
in
parse None false false args|}
    }
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
  ; { name = "Ruff"
    ; anon_pattern = "Ruff _"
    ; bind_pattern = "Ruff { subcommand; fix; show_source; rest }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        let base = [ subcommand ] in
        let base = if fix then base @ [ "--fix" ] else base in
        let base = if show_source then base @ [ "--show-source" ] else base in
        base @ rest
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Ruff
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Ruff"
    ; parse_body =
        Some
          {|
let rec parse subcmd f s = function
  | [] ->
    (match subcmd with
     | Some sc ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Ruff { subcommand = sc; fix = f; show_source = s; rest = [] }))
     | None -> None)
  | "--fix" :: rest -> parse subcmd true s rest
  | "--show-source" :: rest -> parse subcmd f true rest
  | arg :: rest ->
    (match subcmd with
     | None -> parse (Some arg) f s rest
     | Some _ ->
       let rec collect acc = function
         | [] -> List.rev acc
         | x :: xs -> collect (x :: acc) xs
       in
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Ruff {
         subcommand = (match subcmd with Some sc -> sc | None -> "");
         fix = f; show_source = s;
         rest = collect [ arg ] rest
       })))
in
parse None false false args|}
    }
  ; { name = "Pyright"
    ; anon_pattern = "Pyright _"
    ; bind_pattern = "Pyright { subcommand; strict; rest }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        let base = [ subcommand ] in
        let base = if strict then base @ [ "--strict" ] else base in
        base @ rest
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Pyright
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Pyright"
    ; parse_body =
        Some
          {|
let rec parse subcmd st = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Pyright { subcommand = s; strict = st; rest = [] }))
     | None -> None)
  | "--strict" :: rest -> parse subcmd true rest
  | arg :: rest ->
    (match subcmd with
     | None -> parse (Some arg) st rest
     | Some _ ->
       let rec collect acc = function
         | [] -> List.rev acc
         | x :: xs -> collect (x :: acc) xs
       in
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Pyright {
         subcommand = (match subcmd with Some s -> s | None -> "");
         strict = st;
         rest = collect [ arg ] rest
       })))
in
parse None false args|}
    }
  ; { name = "Tsc"
    ; anon_pattern = "Tsc _"
    ; bind_pattern = "Tsc { subcommand; no_emit; watch; rest }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        let base = [ subcommand ] in
        let base = if no_emit then base @ [ "--noEmit" ] else base in
        let base = if watch then base @ [ "--watch" ] else base in
        base @ rest
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Tsc
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Tsc"
    ; parse_body =
        Some
          {|
let rec parse subcmd nw w = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Tsc { subcommand = s; no_emit = nw; watch = w; rest = [] }))
     | None -> None)
  | "--noEmit" :: rest -> parse subcmd true w rest
  | "--watch" :: rest -> parse subcmd nw true rest
  | arg :: rest ->
    (match subcmd with
     | None -> parse (Some arg) nw w rest
     | Some _ ->
       let rec collect acc = function
         | [] -> List.rev acc
         | x :: xs -> collect (x :: acc) xs
       in
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Tsc {
         subcommand = (match subcmd with Some s -> s | None -> "");
         no_emit = nw; watch = w;
         rest = collect [ arg ] rest
       })))
in
parse None false false args|}
    }
  ; subcommand_args_ctor ~name:"Ocamlfind" ~risk:"`Audited" ~sandbox:"`Host"
  ; { name = "Rustc"
    ; anon_pattern = "Rustc _"
    ; bind_pattern = "Rustc { subcommand; optimize; test; rest }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        let base = [ subcommand ] in
        let base = if optimize then base @ [ "-O" ] else base in
        let base = if test then base @ [ "--test" ] else base in
        base @ rest
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Rustc
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Rustc"
    ; parse_body =
        Some
          {|
let rec parse subcmd opt tst = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Rustc { subcommand = s; optimize = opt; test = tst; rest = [] }))
     | None -> None)
  | "-O" :: rest -> parse subcmd true tst rest
  | "--test" :: rest -> parse subcmd opt true rest
  | arg :: rest ->
    (match subcmd with
     | None -> parse (Some arg) opt tst rest
     | Some _ ->
       let rec collect acc = function
         | [] -> List.rev acc
         | x :: xs -> collect (x :: acc) xs
       in
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Rustc {
         subcommand = (match subcmd with Some s -> s | None -> "");
         optimize = opt; test = tst;
         rest = collect [ arg ] rest
       })))
in
parse None false false args|}
    }
  ; { name = "Gofmt"
    ; anon_pattern = "Gofmt _"
    ; bind_pattern = "Gofmt { subcommand; write; list_files; rest }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        let base = [ subcommand ] in
        let base = if write then base @ [ "-w" ] else base in
        let base = if list_files then base @ [ "-l" ] else base in
        base @ rest
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Gofmt
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Gofmt"
    ; parse_body =
        Some
          {|
let rec parse subcmd w lf = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Gofmt { subcommand = s; write = w; list_files = lf; rest = [] }))
     | None -> None)
  | "-w" :: rest -> parse subcmd true lf rest
  | "-l" :: rest -> parse subcmd w true rest
  | arg :: rest ->
    (match subcmd with
     | None -> parse (Some arg) w lf rest
     | Some _ ->
       let rec collect acc = function
         | [] -> List.rev acc
         | x :: xs -> collect (x :: acc) xs
       in
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Gofmt {
         subcommand = (match subcmd with Some s -> s | None -> "");
         write = w; list_files = lf;
         rest = collect [ arg ] rest
       })))
in
parse None false false args|}
    }
  ; { name = "Gradle"
    ; anon_pattern = "Gradle _"
    ; bind_pattern = "Gradle { subcommand; no_daemon; parallel; rest }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        let base = [ subcommand ] in
        let base = if no_daemon then base @ [ "--no-daemon" ] else base in
        let base = if parallel then base @ [ "--parallel" ] else base in
        base @ rest
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Gradle
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Gradle"
    ; parse_body =
        Some
          {|
let rec parse subcmd nd p = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Gradle { subcommand = s; no_daemon = nd; parallel = p; rest = [] }))
     | None -> None)
  | "--no-daemon" :: rest -> parse subcmd true p rest
  | "--parallel" :: rest -> parse subcmd nd true rest
  | arg :: rest ->
    (match subcmd with
     | None -> parse (Some arg) nd p rest
     | Some _ ->
       let rec collect acc = function
         | [] -> List.rev acc
         | x :: xs -> collect (x :: acc) xs
       in
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Gradle {
         subcommand = (match subcmd with Some s -> s | None -> "");
         no_daemon = nd; parallel = p;
         rest = collect [ arg ] rest
       })))
in
parse None false false args|}
    }
  ; { name = "Ninja"
    ; anon_pattern = "Ninja _"
    ; bind_pattern = "Ninja { subcommand; jobs; rest }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        let base = [ subcommand ] in
        let base =
          match jobs with
          | Some n -> base @ [ Printf.sprintf "-j%d" n ]
          | None -> base
        in
        base @ rest
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Ninja
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Ninja"
    ; parse_body =
        Some
          {|
  let rec parse subcmd j = function
    | [] ->
      (match subcmd with
       | Some s ->
         Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Ninja { subcommand = s; jobs = j; rest = [] }))
       | None -> None)
    | arg :: rest ->
      if String.length arg > 2 && String.sub arg 0 2 = "-j"
      then
        (try parse subcmd (Some (int_of_string (String.sub arg 2 (String.length arg - 2)))) rest
         with Failure _ ->
           match subcmd with
           | None -> parse (Some arg) j rest
           | Some _ ->
             let rec collect acc = function
               | [] -> List.rev acc
               | x :: xs -> collect (x :: acc) xs
             in
             Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Ninja {
               subcommand = (match subcmd with Some s -> s | None -> ""); jobs = j;
               rest = collect [ arg ] rest
             })))
      else
        match subcmd with
        | None -> parse (Some arg) j rest
        | Some _ ->
          let rec collect acc = function
            | [] -> List.rev acc
            | x :: xs -> collect (x :: acc) xs
          in
          Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Ninja {
            subcommand = (match subcmd with Some s -> s | None -> ""); jobs = j;
            rest = collect [ arg ] rest
          }))
  in
  parse None None args|}
    }
  ; subcommand_args_ctor ~name:"Java" ~risk:"`Audited" ~sandbox:"`Host"
  ; subcommand_args_ctor ~name:"Javac" ~risk:"`Audited" ~sandbox:"`Host"
  ; { name = "Mvn"
    ; anon_pattern = "Mvn _"
    ; bind_pattern = "Mvn { subcommand; offline; batch_mode; quiet; args }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        let base = [ subcommand ] in
        let base = if offline then base @ [ "-o" ] else base in
        let base = if batch_mode then base @ [ "-B" ] else base in
        let base = if quiet then base @ [ "-q" ] else base in
        base @ args
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Mvn
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Mvn"
    ; parse_body =
        Some
          {|
  let rec parse subcmd off bat q = function
    | [] ->
      (match subcmd with
       | Some s ->
         Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Mvn {
           subcommand = s; offline = off; batch_mode = bat; quiet = q; args = [] }))
       | None -> None)
    | "-o" :: rest -> parse subcmd true bat q rest
    | "--offline" :: rest -> parse subcmd true bat q rest
    | "-B" :: rest -> parse subcmd off true q rest
    | "--batch-mode" :: rest -> parse subcmd off true q rest
    | "-q" :: rest -> parse subcmd off bat true rest
    | "--quiet" :: rest -> parse subcmd off bat true rest
    | arg :: rest ->
      (match subcmd with
       | None -> parse (Some arg) off bat q rest
       | Some _ ->
         let rec collect acc = function
           | [] -> List.rev acc
           | x :: xs -> collect (x :: acc) xs
         in
         Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Mvn {
           subcommand = (match subcmd with Some s -> s | None -> "");
           offline = off; batch_mode = bat; quiet = q;
           args = collect [ arg ] rest })))
  in
  parse None false false false args|}
    }
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

let emit_flag_expander buf =
  Buffer.add_string
    buf
    {|(** Expand combined short flags into individual flags.
    ["-la"] → ["-l"; "-a"]; ["-rf"] → ["-r"; "-f"].
    Long flags (--foo), flag+value (-n5), and bare "-" are unchanged. *)
let expand_combined_short_flags (args : string list) : string list =
  List.concat_map
    (fun arg ->
       if String.length arg >= 3
          && String.length arg <= 4
          && Char.code arg.[0] = Char.code '-'
          && Char.code arg.[1] <> Char.code '-'
          && String.for_all (fun c -> (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) (String.sub arg 1 (String.length arg - 1))
       then
         List.init (String.length arg - 1) (fun i ->
           Printf.sprintf "-%c" arg.[i + 1])
       else [ arg ])
    args
;;

|}
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
            "           | %S :: rest -> %s (expand_combined_short_flags rest)\n" subcmd_name parse_fn))
    git_entries;
  Buffer.add_string buf "           | _ -> None)\n";
  (* Non-Git entries with parse_body — auto-generated from spec.
     Commands that store raw flag strings (rsync, ssh, docker, etc.)
     skip expansion to preserve round-trip fidelity. *)
  let no_expand_variants =
    [ "Rsync"; "Ssh"; "Docker"; "Make"; "Npm"; "Cargo"; "Go"; "Gh"
    ; "Glab"; "Opam"; "Npx"; "Yarn"; "Pnpm"; "Uv"; "Pip"; "Python"
    ; "Python3"; "Pytest"; "Pyright"; "Ruff"; "Ocamlfind"; "Tsc"
    ; "Rustc"; "Gofmt"; "Gradle"; "Ninja"; "Java"; "Javac"; "Mvn"
    ; "Cmake"; "Node"; "Dune_local_sh"; "Osascript"; "Terminal_notifier"
    ; "Play"; "Rec"; "Ffplay"; "Mpg123"; "Open"
    ; "Curl"; "Wget"; "Sudo"; "Su"; "Dd"; "Mkfs"
    ; "Find"
    ]
  in
  List.iter
    (fun (variant, parse_name) ->
       let do_expand = not (List.mem variant no_expand_variants) in
       let arg_expr =
         if do_expand
         then "(expand_combined_short_flags lit_argv)"
         else "lit_argv"
       in
       Buffer.add_string
         buf
         (Printf.sprintf
            "        | Some Exec_program.%s -> gen_parse_%s %s\n"
            variant parse_name arg_expr))
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
  emit_flag_expander buf;
  emit_of_simple buf shell_ir_typed_spec;
  emit_constructor_names buf shell_ir_typed_spec;
  print_string (Buffer.contents buf)
;;
