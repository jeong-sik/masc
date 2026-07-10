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
  ; no_expand_combined : bool
    (* If true, skip [expand_combined_short_flags] pre-processing before
       calling the parse body.  Use when the parser has its own combined-
       flag handler that needs to see the original combined token (e.g.
       [git commit -am MESSAGE] where [-am] must not be split). *)
  }

(* Helper for the ~27 constructors that share the standard
   subcommand+args parse pattern: first token becomes [subcommand],
   the rest becomes [args].  [of_simple ∘ to_simple] round-trip
   invariant is satisfied by construction. *)
let subcommand_args_ctor ~name ~risk ~sandbox ?(value_flags = []) () =
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
        (if value_flags = [] then
           Printf.sprintf
             {|
let rec parse subcmd extra dd = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.%s { subcommand = s; args = List.rev extra }))
     | None -> None)
  | "--" :: rest -> parse subcmd extra true rest
  | arg :: rest ->
    (match subcmd with
     | None when not dd -> parse (Some arg) extra dd rest
     | _ -> parse subcmd (arg :: extra) dd rest)
in
parse None [] false args|}
             name
         else
           let flags_str =
             String.concat "; " (List.map (fun s -> Printf.sprintf "%S" s) value_flags)
           in
           Printf.sprintf
             {|
let rec parse subcmd extra dd = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.%s { subcommand = s; args = List.rev extra }))
     | None -> None)
  | "--" :: rest -> parse subcmd extra true rest
  | arg :: _val :: rest
    when not dd && List.mem arg [ %s ] ->
    parse subcmd (_val :: extra) dd rest
  | arg :: rest
    when not dd
         && (List.mem arg [ %s ]
             || Shell_ir_typed_types.is_eq_form_flag arg [ %s ]) ->
    let extra' =
      match Shell_ir_typed_types.eq_form_flag_value arg [ %s ] with
      | Some v -> v :: extra
      | None -> extra
    in
    parse subcmd extra' dd rest
  | arg :: rest ->
    match subcmd with
    | None when not dd -> parse (Some arg) extra dd rest
    | _ -> parse subcmd (arg :: extra) dd rest
in
parse None [] false args|}
             name flags_str flags_str flags_str flags_str)
  ; no_expand_combined = false
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
  (* POSIX end-of-options: next non-empty arg is the path *)
  | "--" :: rest ->
    (match List.find_opt (fun a -> String.length a > 0) rest with
     | Some p -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Ls { path = Some p; flags = List.rev flags }))
     | None -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Ls { path; flags = List.rev flags })))
  (* Combined short flags: -lah, -al, -lh, etc. *)
  | arg :: rest
    when String.length arg > 2
         && arg.[0] = '-'
         && arg.[1] <> '-'
         && String.for_all (fun c -> c = 'l' || c = 'a' || c = 'h')
              (String.sub arg 1 (String.length arg - 1)) ->
    let flags' = flags
      @ (if String.contains arg 'l' then [ `Long ] else [])
      @ (if String.contains arg 'a' then [ `All ] else [])
      @ (if String.contains arg 'h' then [ `Human ] else [])
    in parse flags' path rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse flags path rest
    else (
      match path with
      | None -> parse flags (Some arg) rest
      | Some _ -> None)
in
parse [] None args|}
    ; no_expand_combined = false
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
| "--" :: rest ->
  (match List.find_opt (fun a -> String.length a > 0) rest with
   | Some p -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Cat { path = p }))
   | None -> None)
| _ -> None|}
    ; no_expand_combined = false
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
(* rg flags that consume the next argument as a value *)
let rg_value_flags =
  [ "--type"; "--glob"; "--max-depth"; "--max-filesize"
  ; "--replace"; "--context"; "--before-context"; "--after-context"
  ; "--encoding"; "--engine"; "--path-separator"
  ; "--sort"; "--sortr"; "--threads"; "--regex"
  ; "--files-with"; "--files-without"
  ; "-g"; "-M"; "-r"; "-j"; "-e"; "-A"; "-B"; "-C"
  ]
in
let rec parse case_sensitive pattern path dd = function
  | [] ->
    (match pattern with
     | Some p -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Rg { pattern = p; path; case_sensitive }))
     | None -> None)
  | "-i" :: rest | "--ignore-case" :: rest when not dd -> parse false pattern path dd rest
  | "--" :: rest -> parse case_sensitive pattern path true rest
  (* value-consuming flags: skip flag + its value (space-separated) *)
  | flag :: _ :: rest when not dd && List.mem flag rg_value_flags ->
    parse case_sensitive pattern path dd rest
  (* Eq-form value flags: --flag=VALUE *)
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg rg_value_flags ->
    let ev = Shell_ir_typed_types.eq_form_flag_value arg rg_value_flags in
    parse case_sensitive pattern path dd (match ev with Some evv -> evv :: rest | None -> rest)
  | arg :: rest ->
    if not dd && String.length arg > 0 && arg.[0] = '-'
    then parse case_sensitive pattern path dd rest
    else (
      match pattern with
      | None -> parse case_sensitive (Some arg) path dd rest
      | Some _ ->
        (match path with
         | None -> parse case_sensitive pattern (Some arg) dd rest
         | Some _ -> None))
in
parse true None None false args|}
    ; no_expand_combined = false
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
  | "--" :: rest -> parse short rest
  | _ :: rest -> parse short rest
in
parse false args|}
    ; no_expand_combined = false
    }
  ; { name = "Git_clone"
    ; anon_pattern = "Git_clone _"
    ; bind_pattern = "Git_clone { repo; branch; depth; dest_dir }"
    ; risk = "`Audited"
    ; sandbox = "`Docker"
    ; to_simple_body =
        {|
      let args =
        (match depth with Some d -> [ "--depth"; string_of_int d ] | None -> [])
        @ (match branch with None -> [] | Some b -> [ "-b"; b ])
        @ [ repo ]
        @ (match dest_dir with None -> [] | Some d -> [ d ])
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
let rec parse depth branch repo dest_dir dd = function
  | [] ->
    (match repo with
     | Some r -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_clone { repo = r; branch; depth; dest_dir }))
     | None -> None)
  | "--depth" :: n :: rest when not dd ->
    (match int_of_string_opt n with
     | Some d -> parse (Some d) branch repo dest_dir dd rest
     | None -> None)
  | "-b" :: b :: rest | "--branch" :: b :: rest when not dd -> parse depth (Some b) repo dest_dir dd rest
  | arg :: rest when not dd && Shell_ir_typed_types.is_eq_form_flag arg ["--depth"] ->
    let n = Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--depth"]) in
    (match int_of_string_opt n with
     | Some d -> parse (Some d) branch repo dest_dir dd rest
     | None -> parse depth branch repo dest_dir dd rest)
  | arg :: rest when not dd && Shell_ir_typed_types.is_eq_form_flag arg ["--branch"] ->
    let b = Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--branch"]) in
    parse depth (Some b) repo dest_dir dd rest
  | "--" :: rest -> parse depth branch repo dest_dir true rest
  | arg :: rest ->
    if not dd && String.length arg > 0 && arg.[0] = '-'
    then parse depth branch repo dest_dir dd rest
    else (
      match repo with
      | None -> parse depth branch (Some arg) dest_dir dd rest
      | Some _ ->
        (match dest_dir with
         | None -> parse depth branch repo (Some arg) dd rest
         | Some _ -> None))
in
parse None None None None false args|}
    ; no_expand_combined = false
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
let rec parse method_ headers body url output_file follow_redirects insecure dd = function
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
  | "-X" :: m :: rest | "--request" :: m :: rest when not dd ->
    (match String.uppercase_ascii m with
     | "GET" -> parse `GET headers body url output_file follow_redirects insecure dd rest
     | "POST" -> parse `POST headers body url output_file follow_redirects insecure dd rest
     | "PUT" -> parse `PUT headers body url output_file follow_redirects insecure dd rest
     | "DELETE" -> parse `DELETE headers body url output_file follow_redirects insecure dd rest
     | _ -> None)
  (* --request=METHOD form *)
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg ["--request"] ->
    let m = String.uppercase_ascii (Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--request"])) in
    (match m with
     | "GET" -> parse `GET headers body url output_file follow_redirects insecure dd rest
     | "POST" -> parse `POST headers body url output_file follow_redirects insecure dd rest
     | "PUT" -> parse `PUT headers body url output_file follow_redirects insecure dd rest
     | "DELETE" -> parse `DELETE headers body url output_file follow_redirects insecure dd rest
     | _ -> None)
  | "-H" :: h :: rest | "--header" :: h :: rest when not dd ->
    (match String.index_opt h ':' with
     | Some i ->
       let key = String.trim (String.sub h 0 i) in
       let value = String.trim (String.sub h (i + 1) (String.length h - i - 1)) in
       parse method_ ((key, value) :: headers) body url output_file follow_redirects insecure dd rest
     | None -> None)
  (* --header=VALUE form *)
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg ["--header"] ->
    let h = Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--header"]) in
    (match String.index_opt h ':' with
     | Some i ->
       let key = String.trim (String.sub h 0 i) in
       let value = String.trim (String.sub h (i + 1) (String.length h - i - 1)) in
       parse method_ ((key, value) :: headers) body url output_file follow_redirects insecure dd rest
     | None -> None)
  | "-d" :: d :: rest | "--data" :: d :: rest when not dd ->
    (match body with
     | None -> parse method_ headers (Some d) url output_file follow_redirects insecure dd rest
     | Some _ -> None)
  (* --data=VALUE form *)
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg ["--data"] ->
    let d = Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--data"]) in
    (match body with
     | None -> parse method_ headers (Some d) url output_file follow_redirects insecure dd rest
     | Some _ -> None)
  | "-o" :: o :: rest | "--output" :: o :: rest when not dd ->
    parse method_ headers body url (Some o) follow_redirects insecure dd rest
  (* --output=FILE form *)
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg ["--output"] ->
    let o = Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--output"]) in
    parse method_ headers body url (Some o) follow_redirects insecure dd rest
  | "-L" :: rest | "--location" :: rest when not dd ->
    parse method_ headers body url output_file true insecure dd rest
  | "-k" :: rest | "--insecure" :: rest when not dd ->
    parse method_ headers body url output_file follow_redirects true dd rest
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
    :: _val :: rest when not dd ->
    parse method_ headers body url output_file follow_redirects insecure dd rest
  (* Combined short flags: -Lk, -kL, etc. (boolean flags only) *)
  | arg :: rest
    when not dd && String.length arg > 2
         && arg.[0] = '-'
         && arg.[1] <> '-'
         && String.for_all (fun c -> c = 'L' || c = 'k')
              (String.sub arg 1 (String.length arg - 1)) ->
    let fr' = ref follow_redirects and ins' = ref insecure in
    for j = 1 to String.length arg - 1 do
      match arg.[j] with
      | 'L' -> fr' := true
      | 'k' -> ins' := true
      | _ -> ()
    done;
    parse method_ headers body url output_file !fr' !ins' dd rest
  | "--" :: rest -> parse method_ headers body url output_file follow_redirects insecure true rest
  | arg :: rest ->
    if not dd && String.length arg > 0 && arg.[0] = '-'
    then parse method_ headers body url output_file follow_redirects insecure dd rest
    else (
      match url with
      | None -> parse method_ headers body (Some arg) output_file follow_redirects insecure dd rest
      | Some _ -> None)
in
parse `GET [] None None None false false false args|}
    ; no_expand_combined = false
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
    ; no_expand_combined = false
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
| args ->
  (* POSIX end-of-options: strip leading -- *)
  let args = match args with "--" :: rest -> rest | _ -> args in
  Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Sudo { target_argv = args }))|}
    ; no_expand_combined = false
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
  | arg :: rest
    when Shell_ir_typed_types.is_eq_form_flag arg ["-maxdepth"] ->
    (match int_of_string_opt (Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["-maxdepth"])) with
     | Some n -> parse name type_ (Some n) path rest
     | None -> parse name type_ maxdepth path rest)
  (* Eq-form value flags: -flag=VALUE — extract prefix and skip *)
  | arg :: rest
    when Shell_ir_typed_types.is_eq_form_flag arg value_flags ->
    let ev = Shell_ir_typed_types.eq_form_flag_value arg value_flags in
    parse name type_ maxdepth path (match ev with Some evv -> evv :: rest | None -> rest)
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
    ; no_expand_combined = false
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
  | "-n" :: n :: rest | "--lines" :: n :: rest ->
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
    when Shell_ir_typed_types.is_eq_form_flag arg ["--lines"] ->
    let n_str = Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--lines"]) in
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
    ; no_expand_combined = false
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
  | "-n" :: n :: rest | "--lines" :: n :: rest ->
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
    when Shell_ir_typed_types.is_eq_form_flag arg ["--lines"] ->
    let n_str = Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--lines"]) in
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
    ; no_expand_combined = false
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
      let pat_args =
        if String.length pattern > 0 && pattern.[0] = '-'
        then [ "-e"; pattern ]
        else [ pattern ]
      in
      let args =
        flag_args
        @ pat_args
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
  (* -e/--regexp PATTERN: explicit pattern (allows patterns starting with -) *)
  | "-e" :: p :: rest | "--regexp" :: p :: rest ->
    parse recursive case_sensitive files_with_matches (Some p) path rest
  (* -ePATTERN combined form *)
  | arg :: rest
    when String.length arg > 2
         && arg.[0] = '-' && arg.[1] = 'e' ->
    let p = String.sub arg 2 (String.length arg - 2) in
    parse recursive case_sensitive files_with_matches (Some p) path rest
  (* --regexp=PATTERN eq-form *)
  | arg :: rest
    when Shell_ir_typed_types.is_eq_form_flag arg ["--regexp"] ->
    let p = Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--regexp"]) in
    parse recursive case_sensitive files_with_matches (Some p) path rest
  (* --color=auto and similar --flag=VALUE forms: skip *)
  | arg :: rest
    when String.length arg > 2
         && arg.[0] = '-' && arg.[1] = '-'
         && String.contains arg '=' ->
    parse recursive case_sensitive files_with_matches pattern path rest
  (* --include, --exclude, --exclude-dir: value-consuming flags (skip both) *)
  | ("--include" | "--exclude" | "--exclude-dir") :: _ :: rest ->
    parse recursive case_sensitive files_with_matches pattern path rest
  (* -A/-B/-C/-m NUM: context and max-count flags (consume the next arg) *)
  | ("-A" | "-B" | "-C" | "-m") :: _ :: rest ->
    parse recursive case_sensitive files_with_matches pattern path rest
  (* --after-context, --before-context, --context, --max-count: value-consuming long flags *)
  | ("--after-context" | "--before-context" | "--context" | "--max-count") :: _ :: rest ->
    parse recursive case_sensitive files_with_matches pattern path rest
  (* --after-context=NUM etc. eq-form *)
  | arg :: rest
    when String.length arg > 2
         && arg.[0] = '-' && arg.[1] = '-'
         && (let k = try String.index arg '=' with Not_found -> -1 in
             k > 0 && let pre = String.sub arg 0 k in
             List.mem pre [ "--after-context"; "--before-context"; "--context"; "--max-count" ]) ->
    parse recursive case_sensitive files_with_matches pattern path rest
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
    ; no_expand_combined = false
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
  | "--" :: rest ->
    (* POSIX end-of-options: next non-empty arg is the path *)
    (match List.find_opt (fun a -> String.length a > 0) rest with
     | Some p ->
       (match path with
        | None -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Mkdir { path = p; parents }))
        | Some _ -> None)
     | None ->
       (match path with
        | Some p -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Mkdir { path = p; parents }))
        | None -> None))
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse parents path rest
    else (
      match path with
      | None -> parse parents (Some arg) rest
      | Some _ -> None)
in
parse false None args|}
    ; no_expand_combined = false
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
  (* Combined short flags: -lw, -wc, -lc, etc. (last wins for mutually exclusive mode) *)
  | arg :: rest
    when String.length arg > 2
         && arg.[0] = '-'
         && arg.[1] <> '-'
         && String.for_all (fun c -> c = 'l' || c = 'w' || c = 'c')
              (String.sub arg 1 (String.length arg - 1)) ->
    let mode' = ref mode in
    for j = 1 to String.length arg - 1 do
      match arg.[j] with
      | 'l' -> mode' := Some `Lines
      | 'w' -> mode' := Some `Words
      | 'c' -> mode' := Some `Chars
      | _ -> ()
    done;
    parse !mode' path rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse mode path rest
    else (
      match path with
      | None -> parse mode (Some arg) rest
      | Some _ -> None)
in
parse None None args|}
    ; no_expand_combined = false
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
  | "--" :: rest ->
    (* POSIX end-of-options: remaining args are all paths *)
    Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_diff { stat; cached; paths = List.rev paths @ rest }))
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse stat cached paths rest
    else parse stat cached (arg :: paths) rest
in
parse false false [] args|}
    ; no_expand_combined = false
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
(* git log flags that consume the next argument as a value (--flag VALUE form) *)
let git_log_value_flags_no_eq =
  [ "--format"; "--pretty"; "--date"; "--since"; "--until"; "--before"; "--after"
  ; "--author"; "--committer"; "--grep"; "--grep-reflog"
  ; "--diff-filter"; "--encoding"; "--output"
  ; "--diff-merges"
  ]
in
let rec parse oneline max_count = function
  | [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_log { oneline; max_count }))
  | "--oneline" :: rest -> parse true max_count rest
  | "-n" :: n :: rest | "--max-count" :: n :: rest ->
    (match int_of_string_opt n with
     | Some c -> parse oneline (Some c) rest
     | None -> None)
  (* --max-count=N form *)
  | arg :: rest
    when Shell_ir_typed_types.is_eq_form_flag arg ["--max-count"] ->
    (match int_of_string_opt (Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--max-count"])) with
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
  | "--graph" :: rest | "--all" :: rest | "--decorate" :: rest
  | "--stat" :: rest | "--name-only" :: rest | "--name-status" :: rest
  | "--summary" :: rest | "--shortstat" :: rest
  | "--no-merges" :: rest | "--merges" :: rest | "--first-parent" :: rest
  | "--full-history" :: rest | "--simplify-merges" :: rest
  | "--topo-order" :: rest | "--date-order" :: rest | "--reverse" :: rest
  | "--follow" :: rest | "--full-diff" :: rest
  | "--ignore-submodules" :: rest
  | "--no-walk" :: rest | "--no-decorate" :: rest
  | "--no-patch" :: rest | "-s" :: rest | "--sparse" :: rest
  | "--show-signature" :: rest
  | "--pickaxe-all" :: rest | "--pickaxe-regex" :: rest
  | "--break-rewrites" :: rest | "--remerge-diff" :: rest
  | "-M" :: rest | "-C" :: rest | "-D" :: rest ->
    parse oneline max_count rest
  (* --flag VALUE form: flag in list (exact match) — MUST precede generic arg arm *)
  | flag :: _ :: rest when List.mem flag git_log_value_flags_no_eq ->
    parse oneline max_count rest
  (* --flag=VALUE form: extract prefix before = and check against no_eq list *)
  | arg :: rest
    when Shell_ir_typed_types.is_eq_form_flag arg git_log_value_flags_no_eq ->
    let ev = Shell_ir_typed_types.eq_form_flag_value arg git_log_value_flags_no_eq in
    parse oneline max_count (match ev with Some evv -> evv :: rest | None -> rest)
  | "--" :: rest -> parse oneline max_count rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse oneline max_count rest
    else parse oneline max_count rest
in
parse false None args|}
    ; no_expand_combined = false
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
  | "-m" :: m :: rest | "--message" :: m :: rest ->
    (match message with
     | None -> parse (Some m) amend rest
     | Some _ -> None)
  | "-a" :: rest | "--all" :: rest -> parse message amend rest
  | "--no-edit" :: rest -> parse message amend rest
  (* Combined short flags: -am MESSAGE, -ma MESSAGE *)
  | arg :: rest
    when String.length arg >= 3
         && arg.[0] = '-'
         && arg.[1] <> '-'
         && String.contains arg 'm'
         && String.contains arg 'a' ->
    let has_a = ref amend in
    let msg_buf = Buffer.create 16 in
    let m_seen = ref false in
    for j = 1 to String.length arg - 1 do
      match arg.[j] with
      | 'a' when !m_seen ->
        (* 'a' after 'm' is a flag, not part of the message *)
        has_a := true
      | 'a' -> has_a := true
      | 'm' -> m_seen := true
      | c when !m_seen -> Buffer.add_char msg_buf c
      | _ -> ()
    done;
    let msg_from_combined =
      if Buffer.length msg_buf > 0 then Some (Buffer.contents msg_buf) else None
    in
    (match msg_from_combined with
     | Some prefix ->
       (* -m consumed the rest of this token; next arg is message continuation or standalone *)
       (match rest with
        | next :: rest' when String.length next > 0 && next.[0] <> '-' ->
          parse (Some (prefix ^ " " ^ next)) !has_a rest'
        | _ -> parse (Some prefix) !has_a rest)
     | None ->
       (* -m found but no inline text; next arg is the message *)
       (match rest with
        | m :: rest' -> parse (Some m) !has_a rest'
        | _ -> None))
  | arg :: rest
    when Shell_ir_typed_types.is_eq_form_flag arg ["--message"] ->
    let m = Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--message"]) in
    (match message with
     | None -> parse (Some m) amend rest
     | Some _ -> None)
  | "--" :: rest -> parse message amend rest
  (* --message=MSG eq-form *)
  | arg :: rest
    when Shell_ir_typed_types.is_eq_form_flag arg ["--message"] ->
    let m = Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--message"]) in
    (match message with
     | None -> parse (Some m) amend rest
     | Some _ -> None)
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse message amend rest
    else parse message amend rest
in
parse None false args|}
    ; no_expand_combined = true
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
(* git push flags that consume the next argument as a value (--flag VALUE form) *)
let git_push_value_flags_no_eq =
  [ "--repo"; "--receive-pack"; "--upload-pack"; "--exec"
  ; "--set-upstream-to"
  ; "-o"; "--push-option"   (* push option *)
  ]
in
let rec parse force force_with_lease set_upstream remote branch = function
  | [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_push { force; force_with_lease; set_upstream; remote; branch }))
  | "--force" :: rest | "-f" :: rest -> parse true force_with_lease set_upstream remote branch rest
  | "--force-with-lease" :: rest -> parse force true set_upstream remote branch rest
  (* --force-with-lease=VALUE form: sets force_with_lease AND skips value *)
  | arg :: rest
    when Shell_ir_typed_types.is_eq_form_flag arg ["--force-with-lease"] ->
    parse force true set_upstream remote branch rest
  | "-u" :: rest | "--set-upstream" :: rest -> parse force force_with_lease true remote branch rest
  | "--delete" :: rest -> parse force force_with_lease set_upstream remote branch rest
  (* --flag VALUE form: flag in list (exact match) — MUST precede generic arg arm *)
  | flag :: _ :: rest when List.mem flag git_push_value_flags_no_eq ->
    parse force force_with_lease set_upstream remote branch rest
  (* --flag=VALUE form: extract prefix before = and check against no_eq list *)
  | arg :: rest
    when Shell_ir_typed_types.is_eq_form_flag arg git_push_value_flags_no_eq ->
    let ev = Shell_ir_typed_types.eq_form_flag_value arg git_push_value_flags_no_eq in
    parse force force_with_lease set_upstream remote branch (match ev with Some evv -> evv :: rest | None -> rest)
  | "--tags" :: rest | "--mirror" :: rest | "--prune" :: rest
  | "--follow-tags" :: rest | "--atomic" :: rest | "--quiet" :: rest
  | "-q" :: rest | "--verbose" :: rest | "-v" :: rest
  | "--dry-run" :: rest | "-n" :: rest | "--porcelain" :: rest
  | "--no-verify" :: rest | "--reset-author" :: rest
  | "--all" :: rest | "--thin" :: rest | "--no-thin" :: rest
  | "--no-force-with-lease" :: rest ->
    parse force force_with_lease set_upstream remote branch rest
  (* Combined short flags: -fu, -uf (force + set_upstream) *)
  | arg :: rest
    when String.length arg > 2
         && arg.[0] = '-'
         && arg.[1] <> '-'
         && String.for_all (fun c -> c = 'f' || c = 'u')
              (String.sub arg 1 (String.length arg - 1)) ->
    let f' = ref force and u' = ref set_upstream in
    for j = 1 to String.length arg - 1 do
      match arg.[j] with
      | 'f' -> f' := true
      | 'u' -> u' := true
      | _ -> ()
    done;
    parse !f' force_with_lease !u' remote branch rest
  | "--" :: rest ->
    (* POSIX end-of-options: remaining args are all positional *)
    (match rest with
     | [ r; b ] -> parse force force_with_lease set_upstream (Some r) (Some b) []
     | [ r ] -> parse force force_with_lease set_upstream (Some r) branch []
     | _ -> parse force force_with_lease set_upstream remote branch [])
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
    ; no_expand_combined = false
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
(* git pull flags that consume the next argument as a value (--flag VALUE form) *)
let git_pull_value_flags_no_eq =
  [ "--repo"; "--upload-pack"; "--receive-pack"; "--depth"
  ; "--jobs"
  ; "-o"; "--option"   (* transport option *)
  ]
in
(* git pull boolean flags that do NOT consume a value *)
let git_pull_bool_flags =
  [ "--tags"; "--no-tags"; "--rebase"; "--no-rebase"
  ; "--ff-only"; "--no-ff"
  ; "--stat"; "--no-stat"; "--squash"; "--no-squash"
  ; "--autostash"; "--no-autostash"
  ; "--quiet"; "-q"; "--verbose"; "-v"
  ; "--dry-run"; "-n"; "--force"; "-f"
  ; "--all"; "--append"; "--prune"; "--no-prune"
  ; "--verify"; "--no-verify"
  ; "--allow-unrelated-histories"
  ; "--no-recurse-submodules"
  ]
in
let rec parse rebase remote branch = function
  | [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_pull { rebase; remote; branch }))
  (* --flag VALUE form: flag in list (exact match) — MUST precede generic arg arm *)
  | flag :: _ :: rest when List.mem flag git_pull_value_flags_no_eq ->
    parse rebase remote branch rest
  (* --flag=VALUE form: extract prefix before = and check against no_eq list *)
  | arg :: rest
    when Shell_ir_typed_types.is_eq_form_flag arg git_pull_value_flags_no_eq ->
    let ev = Shell_ir_typed_types.eq_form_flag_value arg git_pull_value_flags_no_eq in
    parse rebase remote branch (match ev with Some evv -> evv :: rest | None -> rest)
  (* boolean flags: specific exact-match arms *)
  | "--rebase" :: rest -> parse true remote branch rest
  | "--no-rebase" :: rest -> parse false remote branch rest
  | "--ff-only" :: rest -> parse rebase remote branch rest
  (* boolean flags: catch-all from list *)
  | flag :: rest when List.mem flag git_pull_bool_flags ->
    parse rebase remote branch rest
  | "--" :: rest ->
    (match rest with
     | [ r; b ] -> parse rebase (Some r) (Some b) []
     | [ r ] -> parse rebase (Some r) branch []
     | _ -> parse rebase remote branch [])
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
    ; no_expand_combined = false
    }
  ; { name = "Git_stash"
    ; anon_pattern = "Git_stash _"
    ; bind_pattern = "Git_stash { action; message }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let subcmd, extra =
        match action with
        | `Push -> "push", (match message with None -> [] | Some m -> [ "-m"; m ])
        | `Pop -> "pop", []
        | `Drop -> "drop", []
        | `List -> "list", []
        | `Show -> "show", []
      in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Git
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) ("stash" :: subcmd :: extra)
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Git"
    ; parse_body =
        Some
          {|
let rec parse message = function
  | [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_stash { action = `List; message }))
  | "push" :: rest ->
    let rec find_msg acc = function
      | "-m" :: m :: rest' -> find_msg (Some m) rest'
      | _ :: rest' -> find_msg acc rest'
      | [] -> acc
    in
    let msg = find_msg None rest in
    Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_stash { action = `Push; message = msg }))
  | "pop" :: _ -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_stash { action = `Pop; message }))
  | "drop" :: _ -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_stash { action = `Drop; message }))
  | "show" :: _ -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_stash { action = `Show; message }))
  | "list" :: _ -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_stash { action = `List; message }))
  | _ :: rest -> parse message rest
in
parse None args|}
    ; no_expand_combined = false
    }
  ; { name = "Git_rebase"
    ; anon_pattern = "Git_rebase _"
    ; bind_pattern = "Git_rebase { interactive; onto; branch; continue_; abort }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let parts = [ "rebase" ] in
      let parts = if continue_ then parts @ [ "--continue" ] else parts in
      let parts = if abort then parts @ [ "--abort" ] else parts in
      let parts = if interactive then parts @ [ "--interactive" ] else parts in
      let parts = match onto with Some t -> parts @ [ "--onto"; t ] | None -> parts in
      let parts = match branch with Some b -> parts @ [ b ] | None -> parts in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Git
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) parts
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Git"
    ; parse_body =
        Some
          {|
let rec parse interactive onto branch continue_ abort = function
  | [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_rebase { interactive; onto; branch; continue_; abort }))
  | "--interactive" :: rest | "-i" :: rest -> parse true onto branch continue_ abort rest
  | "--onto" :: t :: rest -> parse interactive (Some t) branch continue_ abort rest
  | "--continue" :: rest -> parse interactive onto branch true abort rest
  | "--abort" :: rest -> parse interactive onto branch continue_ true rest
  | arg :: rest when String.length arg > 0 && arg.[0] = '-' -> parse interactive onto branch continue_ abort rest
  | arg :: rest -> parse interactive onto (Some arg) continue_ abort rest
in
parse false None None false false args|}
    ; no_expand_combined = false
    }
  ; { name = "Git_merge"
    ; anon_pattern = "Git_merge _"
    ; bind_pattern = "Git_merge { no_ff; squash; branch; abort; continue_ }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let parts = [ "merge" ] in
      let parts = if no_ff then parts @ [ "--no-ff" ] else parts in
      let parts = if squash then parts @ [ "--squash" ] else parts in
      let parts = if abort then parts @ [ "--abort" ] else parts in
      let parts = if continue_ then parts @ [ "--continue" ] else parts in
      let parts = parts @ [ branch ] in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Git
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) parts
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Git"
    ; parse_body =
        Some
          {|
let rec parse no_ff squash branch abort continue_ = function
  | [] ->
    (match branch, abort, continue_ with
     | Some b, false, false ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_merge { no_ff; squash; branch = b; abort; continue_ }))
     | _, true, _ ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_merge { no_ff; squash; branch = ""; abort = true; continue_ }))
     | _, _, true ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_merge { no_ff; squash; branch = ""; abort; continue_ = true }))
     | None, false, false -> None)
  | "--no-ff" :: rest -> parse true squash branch abort continue_ rest
  | "--squash" :: rest -> parse no_ff true branch abort continue_ rest
  | "--abort" :: rest -> parse no_ff squash branch true continue_ rest
  | "--continue" :: rest -> parse no_ff squash branch abort true rest
  | arg :: rest when String.length arg > 0 && arg.[0] = '-' -> parse no_ff squash branch abort continue_ rest
  | arg :: rest -> parse no_ff squash (Some arg) abort continue_ rest
in
parse false false None false false args|}
    ; no_expand_combined = false
    }
  ; { name = "Git_branch"
    ; anon_pattern = "Git_branch _"
    ; bind_pattern = "Git_branch { delete; list_all; rename }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let parts = [ "branch" ] in
      let parts = if list_all then parts @ [ "-a" ] else parts in
      let parts = match delete with Some d -> parts @ [ "-d"; d ] | None -> parts in
      let parts = match rename with Some r -> parts @ [ "-m"; r ] | None -> parts in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Git
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) parts
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Git"
    ; parse_body =
        Some
          {|
let rec parse delete list_all rename = function
  | [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_branch { delete; list_all; rename }))
  | "-a" :: rest | "--all" :: rest -> parse delete true rename rest
  | "-d" :: d :: rest | "--delete" :: d :: rest -> parse (Some d) list_all rename rest
  | "-m" :: r :: rest | "--move" :: r :: rest -> parse delete list_all (Some r) rest
  | "-D" :: d :: rest -> parse (Some d) list_all rename rest
  | arg :: rest when String.length arg > 0 && arg.[0] = '-' -> parse delete list_all rename rest
  | _ :: rest -> parse delete list_all rename rest
in
parse None false None args|}
    ; no_expand_combined = false
    }
  ; { name = "Git_checkout"
    ; anon_pattern = "Git_checkout _"
    ; bind_pattern = "Git_checkout { new_branch; branch }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let parts = [ "checkout" ] in
      let parts = if new_branch then parts @ [ "-b" ] else parts in
      let parts = parts @ [ branch ] in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Git
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) parts
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Git"
    ; parse_body =
        Some
          {|
let rec parse new_branch branch = function
  | [] ->
    (match branch with
     | Some b -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_checkout { new_branch; branch = b }))
     | None -> None)
  | "-b" :: rest -> parse true branch rest
  | arg :: rest when String.length arg > 0 && arg.[0] = '-' -> parse new_branch branch rest
  | arg :: rest -> parse new_branch (Some arg) rest
in
parse false None args|}
    ; no_expand_combined = false
    }
  ; { name = "Git_fetch"
    ; anon_pattern = "Git_fetch _"
    ; bind_pattern = "Git_fetch { remote; branch; prune; all }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let parts = [ "fetch" ] in
      let parts = if prune then parts @ [ "--prune" ] else parts in
      let parts = if all then parts @ [ "--all" ] else parts in
      let parts = match remote with Some r -> parts @ [ r ] | None -> parts in
      let parts = match branch with Some b -> parts @ [ b ] | None -> parts in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Git
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) parts
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Git"
    ; parse_body =
        Some
          {|
let rec parse prune all remote branch = function
  | [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_fetch { remote; branch; prune; all }))
  | "--prune" :: rest -> parse true all remote branch rest
  | "--all" :: rest -> parse prune true remote branch rest
  | arg :: rest when String.length arg > 0 && arg.[0] = '-' -> parse prune all remote branch rest
  | arg :: rest ->
    (match remote with
     | None -> parse prune all (Some arg) branch rest
     | Some _ -> parse prune all remote (Some arg) rest)
in
parse false false None None args|}
    ; no_expand_combined = false
    }
  ; { name = "Git_show"
    ; anon_pattern = "Git_show _"
    ; bind_pattern = "Git_show { commit; stat }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let parts = [ "show" ] in
      let parts = if stat then parts @ [ "--stat" ] else parts in
      let parts = parts @ [ commit ] in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Git
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) parts
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Git"
    ; parse_body =
        Some
          {|
let rec parse stat commit = function
  | [] ->
    (match commit with
     | Some c -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_show { commit = c; stat }))
     | None -> None)
  | "--stat" :: rest -> parse true commit rest
  | arg :: rest when String.length arg > 0 && arg.[0] = '-' -> parse stat commit rest
  | arg :: rest -> parse stat (Some arg) rest
in
parse false None args|}
    ; no_expand_combined = false
    }
  ; { name = "Git_reset"
    ; anon_pattern = "Git_reset _"
    ; bind_pattern = "Git_reset { mode; target }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let mode_str = match mode with `Soft -> "--soft" | `Mixed -> "--mixed" | `Hard -> "--hard" in
      let parts = [ "reset"; mode_str ] in
      let parts = match target with Some t -> parts @ [ t ] | None -> parts in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Git
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) parts
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Git"
    ; parse_body =
        Some
          {|
let rec parse mode target = function
  | [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_reset { mode; target }))
  | "--soft" :: rest -> parse `Soft target rest
  | "--mixed" :: rest -> parse `Mixed target rest
  | "--hard" :: rest -> parse `Hard target rest
  | arg :: rest when String.length arg > 0 && arg.[0] = '-' -> parse mode target rest
  | arg :: rest -> parse mode (Some arg) rest
in
parse `Mixed None args|}
    ; no_expand_combined = false
    }
  ; { name = "Git_blame"
    ; anon_pattern = "Git_blame _"
    ; bind_pattern = "Git_blame { file; range }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let parts = [ "blame" ] in
      let parts = match range with Some r -> parts @ [ "-L"; r ] | None -> parts in
      let parts = parts @ [ file ] in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Git
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) parts
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Git"
    ; parse_body =
        Some
          {|
let rec parse range file = function
  | [] ->
    (match file with
     | Some f -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_blame { file = f; range }))
     | None -> None)
  | "-L" :: r :: rest -> parse (Some r) file rest
  | arg :: rest when String.length arg > 0 && arg.[0] = '-' -> parse range file rest
  | arg :: rest -> parse range (Some arg) rest
in
parse None None args|}
    ; no_expand_combined = false
    }
  ; { name = "Git_add"
    ; anon_pattern = "Git_add _"
    ; bind_pattern = "Git_add { paths; force; update }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let parts = [ "add" ] in
      let parts = if force then parts @ [ "--force" ] else parts in
      let parts = if update then parts @ [ "-u" ] else parts in
      let parts = parts @ paths in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Git
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) parts
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Git"
    ; parse_body =
        Some
          {|
let rec parse force update acc = function
  | [] ->
    (match acc with
     | [] -> None
     | _ -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Git_add { paths = List.rev acc; force; update })))
  | "--force" :: rest | "-f" :: rest -> parse true update acc rest
  | "-u" :: rest | "--update" :: rest -> parse force true acc rest
  | arg :: rest when String.length arg > 0 && arg.[0] = '-' -> parse force update acc rest
  | arg :: rest -> parse force update (arg :: acc) rest
in
parse false false [] args|}
    ; no_expand_combined = false
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
    ; no_expand_combined = false
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
          {|(* POSIX end-of-options: strip leading -- *)
let args = match args with "--" :: rest -> rest | _ -> args in
Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Echo { args = args }))|}
    ; no_expand_combined = false
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
| names ->
  (* POSIX end-of-options: strip leading -- *)
  let names = match names with "--" :: rest -> rest | _ -> names in
  Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Which { names }))|}
    ; no_expand_combined = false
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
  | "-t" :: _ :: rest | "--field-separator" :: _ :: rest -> parse reverse numeric unique key file rest  (* -t/--field-separator SEP *)
  (* --field-separator=SEP *)
  | arg :: rest
    when Shell_ir_typed_types.is_eq_form_flag arg ["--field-separator"] ->
    parse reverse numeric unique key file rest
  (* --key=N form *)
  | arg :: rest
    when Shell_ir_typed_types.is_eq_form_flag arg ["--key"] ->
    let n_str = Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--key"]) in
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
    else if String.length arg > 2 && arg.[0] = '-' && arg.[1] = '-'
    then (
      (* eq-form: --field-separator=SEP *)
      match Shell_ir_typed_types.eq_form_flag_value arg [ "--field-separator" ] with
      | Some _sep -> parse reverse numeric unique key file rest
      | None -> parse reverse numeric unique key file rest)
    else if String.length arg > 0 && arg.[0] = '-'
    then parse reverse numeric unique key file rest
    else (
      match file with
      | None -> parse reverse numeric unique key (Some arg) rest
      | Some _ -> None)
in
parse false false false None None args|}
    ; no_expand_combined = false
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
    (match Shell_ir_typed_types.eq_form_flag_value arg [ "--delimiter" ] with
     | Some d -> parse (Some d) fields file rest
     | None ->
       (match Shell_ir_typed_types.eq_form_flag_value arg [ "--fields" ] with
        | Some f -> parse delimiter (Some f) file rest
        | None ->
          if String.length arg > 0 && arg.[0] = '-'
          then parse delimiter fields file rest
          else (
            match file with
            | None -> parse delimiter fields (Some arg) rest
            | Some _ -> None)))
in
parse None None None args|}
    ; no_expand_combined = false
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
  (* POSIX end-of-options: remaining are set1/set2 *)
  | "--" :: rest ->
    let remaining = List.filter (fun a -> String.length a > 0) rest in
    (match remaining with
     | [ s1 ] ->
       (match set1 with
        | None -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Tr { set1 = s1; set2; delete; squeeze }))
        | Some _ -> None)
     | [ s1; s2 ] ->
       (match set1 with
        | None -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Tr { set1 = s1; set2 = Some s2; delete; squeeze }))
        | Some _ -> None)
     | _ -> None)
  (* Combined short flags: -ds, -sd, etc. *)
  | arg :: rest
    when String.length arg > 2
         && arg.[0] = '-'
         && arg.[1] <> '-'
         && String.for_all (fun c -> c = 'd' || c = 's')
              (String.sub arg 1 (String.length arg - 1)) ->
    let delete' = ref delete and squeeze' = ref squeeze in
    for j = 1 to String.length arg - 1 do
      match arg.[j] with
      | 'd' -> delete' := true
      | 's' -> squeeze' := true
      | _ -> ()
    done;
    parse !delete' !squeeze' set1 set2 rest
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
    ; no_expand_combined = false
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
  | "--" :: rest ->
    (* POSIX end-of-options: next arg is format string *)
    (match rest with
     | fmt :: _ -> parse utc (Some fmt) []
     | _ -> parse utc format [])
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse utc format rest
    else parse utc (Some arg) rest
in
parse false None args|}
    ; no_expand_combined = false
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
    ; no_expand_combined = false
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
(* POSIX end-of-options: strip leading -- *)
let args = match args with "--" :: rest -> rest | _ -> args in
match args with
| [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Printenv { name = None }))
| [ n ] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Printenv { name = Some n }))
| _ -> None|}
    ; no_expand_combined = false
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
  | "--" :: rest ->
    (* POSIX end-of-options: next non-empty arg is the file *)
    (match List.find_opt (fun a -> String.length a > 0) rest with
     | Some f -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Uniq { count; duplicates; unique; skip_fields; skip_chars; file = Some f }))
     | None -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Uniq { count; duplicates; unique; skip_fields; skip_chars; file })))
  (* Combined short flags: -cd, -cu, -dc, -du, -uc, -ud, etc. *)
  | arg :: rest
    when String.length arg > 2
         && arg.[0] = '-'
         && arg.[1] <> '-'
         && String.for_all (fun c -> c = 'c' || c = 'd' || c = 'u')
              (String.sub arg 1 (String.length arg - 1)) ->
    let count' = ref count and duplicates' = ref duplicates and unique' = ref unique in
    for j = 1 to String.length arg - 1 do
      match arg.[j] with
      | 'c' -> count' := true
      | 'd' -> duplicates' := true
      | 'u' -> unique' := true
      | _ -> ()
    done;
    parse !count' !duplicates' !unique' skip_fields skip_chars file rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse count duplicates unique skip_fields skip_chars file rest
    else parse count duplicates unique skip_fields skip_chars (Some arg) rest
in
parse false false false None None None args|}
    ; no_expand_combined = false
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
| "--" :: rest ->
  let remaining = List.filter (fun a -> String.length a > 0) rest in
  (match remaining with
   | [ path ] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Basename { path; suffix = None }))
   | [ path; suffix ] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Basename { path; suffix = Some suffix }))
   | _ -> None)
| _ -> None|}
    ; no_expand_combined = false
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
| "--" :: rest ->
  (match List.find_opt (fun a -> String.length a > 0) rest with
   | Some path -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Dirname { path }))
   | None -> None)
| _ -> None|}
    ; no_expand_combined = false
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
(* POSIX end-of-options: strip leading -- *)
let args = match args with "--" :: rest -> rest | _ -> args in
match args with
| [] -> None
| expression -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Test { expression }))
    |}
    ; no_expand_combined = false
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
    ; no_expand_combined = false
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
  | "--short" :: rest -> parse true rest
  | "--" :: rest -> parse short rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse short rest
    else parse short rest
in
parse false args|}
    ; no_expand_combined = false
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
    ; no_expand_combined = false
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
  | "-h" :: rest | "--human-readable" :: rest -> parse true summary max_depth rest
  | "-s" :: rest | "--summarize" :: rest -> parse human_readable true max_depth rest
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
    (match Shell_ir_typed_types.eq_form_flag_value arg [ "--max-depth" ] with
     | Some n ->
       (match int_of_string_opt n with
        | Some d -> parse human_readable summary (Some d) rest
        | None -> None)
     | None ->
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
    ; no_expand_combined = false
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
  | "-h" :: rest | "--human-readable" :: rest -> parse true fs_type rest
  | "-t" :: t :: rest | "--type" :: t :: rest -> parse human_readable (Some t) rest
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
    (match Shell_ir_typed_types.eq_form_flag_value arg [ "--type" ] with
     | Some t -> parse human_readable (Some t) rest
     | None ->
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
    ; no_expand_combined = false
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
  (* POSIX end-of-options: next non-empty arg is the path *)
  | "--" :: rest ->
    (match List.find_opt (fun a -> String.length a > 0) rest with
     | Some p ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.File { path = p; mime; brief }))
     | None -> None)
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
    ; no_expand_combined = false
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
(* POSIX end-of-options: strip leading -- *)
let args = match args with "--" :: rest -> rest | _ -> args in
match args with
| [] -> None
| format :: rest ->
  Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Printf { format; args = rest }))
|}
    ; no_expand_combined = false
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
  | "-a" :: rest | "--all" :: rest -> parse true kn rel mach rest
  | "-s" :: rest | "--kernel-name" :: rest -> parse all true rel mach rest
  | "-r" :: rest | "--release" :: rest -> parse all kn true mach rest
  | "-m" :: rest | "--machine" :: rest -> parse all kn rel true rest
  | "--" :: rest -> parse all kn rel mach rest
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
    ; no_expand_combined = false
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
  | "-e" :: rest | "-A" :: rest | "--all" :: rest -> parse true full user rest
  | "-f" :: rest | "--full" :: rest -> parse all true user rest
  | "-u" :: u :: rest | "--user" :: u :: rest when not (String.length u > 0 && u.[0] = '-') -> parse all full (Some u) rest
  | "--" :: rest -> parse all full user rest
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
    ; no_expand_combined = false
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
    ; no_expand_combined = false
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
(* wget flags that consume the next argument as a value *)
let wget_value_flags =
  [ "--header"; "--execute"; "-e"
  ; "--post-data"; "--post-file"
  ; "--timeout"; "--connect-timeout"; "--dns-timeout"; "--read-timeout"
  ; "--tries"; "--wait"; "--waitretry"
  ; "--domains"; "--exclude-domains"; "--reject"; "--accept"
  ; "--reject-regex"; "--accept-regex"
  ; "--user"; "--password"
  ; "--level"; "--directory-prefix"; "--cut-dirs"
  ; "--bind-address"; "--limit-rate"
  ; "--user-agent"; "--referer"
  ; "--certificate"; "--private-key"; "--ca-certificate"
  ; "--quota"; "--max-redirect"; "--max-filename-length"
  ; "-i"; "--input-file"   (* input file *)
  ; "-B"; "--base"         (* base URL *)
  ; "-P"   (* directory prefix *)
  ; "-A"   (* accept pattern *)
  ; "-R"   (* reject pattern *)
  ; "-D"   (* domains *)
  ]
in
let rec parse output continue_ ncc url dd = function
  | [] ->
    (match url with
     | Some u ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Wget { url = u; output; continue_; no_check_certificate = ncc }))
     | None -> None)
  | "-O" :: o :: rest when not dd -> parse (Some o) continue_ ncc url dd rest
  | "--output-document" :: o :: rest when not dd -> parse (Some o) continue_ ncc url dd rest
  | "-c" :: rest when not dd -> parse output true ncc url dd rest
  | "--continue" :: rest when not dd -> parse output true ncc url dd rest
  | "--no-check-certificate" :: rest when not dd -> parse output continue_ true url dd rest
  (* POSIX end-of-options: skip --, remaining args are positional *)
  | "--" :: rest -> parse output continue_ ncc url true rest
  (* value-consuming flags: skip flag + its value (space-separated) *)
  | flag :: _ :: rest when not dd && List.mem flag wget_value_flags ->
    parse output continue_ ncc url dd rest
  (* Eq-form value flags: --flag=VALUE *)
  | arg :: rest
    when not dd
         && Shell_ir_typed_types.is_eq_form_flag arg
              ("--output-document" :: wget_value_flags) ->
    (match Shell_ir_typed_types.eq_form_flag_value arg [ "--output-document" ] with
     | Some o -> parse (Some o) continue_ ncc url dd rest
     | None -> parse output continue_ ncc url dd rest)
  | arg :: rest ->
    if not dd && String.length arg > 0 && arg.[0] = '-'
    then parse output continue_ ncc url dd rest
    else (
      match url with
      | None -> parse output continue_ ncc (Some arg) dd rest
      | Some _ -> None)
in
parse None false false None false args|}
    ; no_expand_combined = false
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
let rec parse port id_file host user command dd = function
  | [] ->
    (match host with
     | Some h ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Ssh { host = h; user; command; port; identity_file = id_file }))
     | None -> None)
  | "-p" :: p_str :: rest when not dd ->
    (match int_of_string_opt p_str with
     | Some p -> parse (Some p) id_file host user command dd rest
     | None -> parse port id_file host user command dd rest)
  (* Combined form: -p22 *)
  | arg :: rest
    when not dd && String.length arg > 2
         && arg.[0] = '-' && arg.[1] = 'p'
         && String.for_all (fun c -> c >= '0' && c <= '9')
              (String.sub arg 2 (String.length arg - 2)) ->
    let p = int_of_string (String.sub arg 2 (String.length arg - 2)) in
    parse (Some p) id_file host user command dd rest
  | "-i" :: f :: rest when not dd -> parse port (Some f) host user command dd rest
  | "-o" :: _ :: rest when not dd -> parse port id_file host user command dd rest
  | "-L" :: _ :: rest when not dd -> parse port id_file host user command dd rest
  | "-R" :: _ :: rest when not dd -> parse port id_file host user command dd rest
  | "-D" :: _ :: rest when not dd -> parse port id_file host user command dd rest
  | "-J" :: _ :: rest when not dd -> parse port id_file host user command dd rest
  | "-F" :: _ :: rest when not dd -> parse port id_file host user command dd rest
  | "-l" :: _ :: rest when not dd -> parse port id_file host user command dd rest
  | "-c" :: _ :: rest when not dd -> parse port id_file host user command dd rest
  | "-m" :: _ :: rest when not dd -> parse port id_file host user command dd rest
  | "-W" :: _ :: rest when not dd -> parse port id_file host user command dd rest
  | "-E" :: _ :: rest when not dd -> parse port id_file host user command dd rest
  | "-b" :: _ :: rest when not dd -> parse port id_file host user command dd rest
  | "-Q" :: _ :: rest when not dd -> parse port id_file host user command dd rest
  | "-O" :: _ :: rest when not dd -> parse port id_file host user command dd rest
  | "-S" :: _ :: rest when not dd -> parse port id_file host user command dd rest
  (* POSIX end-of-options: remaining are host + command *)
  | "--" :: rest -> parse port id_file host user command true rest
  | arg :: rest ->
    if not dd && String.length arg > 0 && arg.[0] = '-'
    then parse port id_file host user command dd rest
    else (
      match host with
      | None ->
        (* First positional: [user@]host *)
        let u, h =
          match String.split_on_char '@' arg with
          | [ u; h ] -> (Some u, h)
          | _ -> (None, arg)
        in
        parse port id_file (Some h) u command dd rest
      | Some _ ->
        (* Remaining positional tokens are the remote command *)
        let cmd = String.concat " " (arg :: rest) in
        Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Ssh
          { host = (match host with Some h -> h | None -> ""); user; command = Some cmd; port; identity_file = id_file })))
in
parse None None None None None false args|}
    ; no_expand_combined = false
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
  (* Combined form: -P22 *)
  | arg :: rest
    when String.length arg > 2
         && arg.[0] = '-' && arg.[1] = 'P'
         && String.for_all (fun c -> c >= '0' && c <= '9')
              (String.sub arg 2 (String.length arg - 2)) ->
    let p = int_of_string (String.sub arg 2 (String.length arg - 2)) in
    parse recursive (Some p) src dest rest
  | "-p" :: rest -> parse recursive port src dest rest
  | "-C" :: rest -> parse recursive port src dest rest
  | "-v" :: rest -> parse recursive port src dest rest
  | "-q" :: rest -> parse recursive port src dest rest
  | "-i" :: _ :: rest -> parse recursive port src dest rest
  | "-l" :: _ :: rest -> parse recursive port src dest rest
  | "-o" :: _ :: rest -> parse recursive port src dest rest
  | "-F" :: _ :: rest -> parse recursive port src dest rest
  | "-S" :: _ :: rest -> parse recursive port src dest rest
  | "-J" :: _ :: rest -> parse recursive port src dest rest
  (* Combined short flags: -rCv, -Cvr, etc. *)
  | arg :: rest
    when String.length arg > 2
         && arg.[0] = '-'
         && arg.[1] <> '-'
         && String.for_all (fun c -> c = 'r' || c = 'p' || c = 'C' || c = 'v' || c = 'q')
              (String.sub arg 1 (String.length arg - 1)) ->
    let r' = ref recursive in
    for j = 1 to String.length arg - 1 do
      match arg.[j] with
      | 'r' -> r' := true
      | _ -> ()
    done;
    parse !r' port src dest rest
  (* POSIX end-of-options: remaining are source, dest *)
  | "--" :: rest ->
    let remaining = List.filter (fun a -> String.length a > 0) rest in
    (match remaining with
     | [ s; d ] ->
       (match src, dest with
        | None, None ->
          Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Scp { source = s; dest = d; recursive; port }))
        | _ -> None)
     | _ -> None)
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
    ; no_expand_combined = false
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
  | "--file" :: f :: rest -> parse action compression (Some f) paths rest
  | "--gzip" :: rest -> parse action `Gzip archive paths rest
  | "--bzip2" :: rest -> parse action `Bzip2 archive paths rest
  | "--xz" :: rest -> parse action `Xz archive paths rest
  | "--exclude" :: _ :: rest -> parse action compression archive paths rest
  | "--strip-components" :: _ :: rest -> parse action compression archive paths rest
  (* POSIX end-of-options: all remaining args are paths *)
  | "--" :: rest ->
    let paths' = List.rev_append (List.filter (fun a -> String.length a > 0) rest) paths in
    (match action, archive with
     | Some a, Some f ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Tar { action = a; archive = f; paths = List.rev paths'; compression }))
     | _ -> None)
  (* --file=ARCHIVE equal-sign form *)
  | arg :: rest
    when Shell_ir_typed_types.is_eq_form_flag arg ["--file"] ->
    let f = Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--file"]) in
    parse action compression (Some f) paths rest
  (* --exclude=PATTERN equal-sign form *)
  | arg :: rest
    when Shell_ir_typed_types.is_eq_form_flag arg ["--exclude"] ->
    parse action compression archive paths rest
  (* --strip-components=N equal-sign form *)
  | arg :: rest
    when Shell_ir_typed_types.is_eq_form_flag arg ["--strip-components"] ->
    parse action compression archive paths rest
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
    ; no_expand_combined = false
    }
  ; { name = "Make"
    ; anon_pattern = "Make _"
    ; bind_pattern = "Make { target; jobs; directory; makefile; dry_run; keep_going; silent; always_make }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args =
        (match directory with None -> [] | Some d -> [ "-C"; d ])
        @ (match makefile with None -> [] | Some f -> [ "-f"; f ])
        @ (if dry_run then [ "-n" ] else [])
        @ (if keep_going then [ "-k" ] else [])
        @ (if silent then [ "-s" ] else [])
        @ (if always_make then [ "-B" ] else [])
        @ (match jobs with None -> [] | Some j -> [ "-j"; string_of_int j ])
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
let is_eq_form_flag arg flag =
  let len = String.length arg in
  let flen = String.length flag in
  len > flen + 1 && String.sub arg 0 (flen + 1) = flag ^ "="
in
let eq_form_flag_value arg flag =
  let flen = String.length flag in
  if is_eq_form_flag arg flag
  then Some (String.sub arg (flen + 1) (String.length arg - flen - 1))
  else None
in
let rec parse jobs target directory makefile dry_run keep_going silent always_make dd = function
  | [] ->
    Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Make
      { target; jobs; directory; makefile; dry_run; keep_going; silent; always_make }))
  (* -j N / --jobs N *)
  | "-j" :: n :: rest when not dd ->
    (match int_of_string_opt n with
     | Some j -> parse (Some j) target directory makefile dry_run keep_going silent always_make dd rest
     | None -> None)
  | "--jobs" :: n :: rest when not dd ->
    (match int_of_string_opt n with
     | Some j -> parse (Some j) target directory makefile dry_run keep_going silent always_make dd rest
     | None -> None)
  (* --jobs=N *)
  | arg :: rest when not dd && is_eq_form_flag arg "--jobs" ->
    (match int_of_string_opt (Option.get (eq_form_flag_value arg "--jobs")) with
     | Some j -> parse (Some j) target directory makefile dry_run keep_going silent always_make dd rest
     | None -> None)
  (* Combined form: -j4 → jobs = Some 4 *)
  | arg :: rest
    when not dd
         && String.length arg > 2
         && String.length arg <= 5
         && arg.[0] = '-'
         && arg.[1] = 'j'
         && String.for_all (fun c -> c >= '0' && c <= '9')
              (String.sub arg 2 (String.length arg - 2)) ->
    let j = int_of_string (String.sub arg 2 (String.length arg - 2)) in
    parse (Some j) target directory makefile dry_run keep_going silent always_make dd rest
  (* -C DIR / --directory DIR / --directory=DIR *)
  | "-C" :: d :: rest when not dd ->
    parse jobs target (Some d) makefile dry_run keep_going silent always_make dd rest
  | "--directory" :: d :: rest when not dd ->
    parse jobs target (Some d) makefile dry_run keep_going silent always_make dd rest
  | arg :: rest when not dd && is_eq_form_flag arg "--directory" ->
    let d = Option.get (eq_form_flag_value arg "--directory") in
    parse jobs target (Some d) makefile dry_run keep_going silent always_make dd rest
  (* -f FILE / --file FILE / --file=FILE / --makefile FILE / --makefile=FILE *)
  | "-f" :: f :: rest when not dd ->
    parse jobs target directory (Some f) dry_run keep_going silent always_make dd rest
  | "--file" :: f :: rest when not dd ->
    parse jobs target directory (Some f) dry_run keep_going silent always_make dd rest
  | arg :: rest when not dd && is_eq_form_flag arg "--file" ->
    let f = Option.get (eq_form_flag_value arg "--file") in
    parse jobs target directory (Some f) dry_run keep_going silent always_make dd rest
  | "--makefile" :: f :: rest when not dd ->
    parse jobs target directory (Some f) dry_run keep_going silent always_make dd rest
  | arg :: rest when not dd && is_eq_form_flag arg "--makefile" ->
    let f = Option.get (eq_form_flag_value arg "--makefile") in
    parse jobs target directory (Some f) dry_run keep_going silent always_make dd rest
  (* -n / --dry-run *)
  | "-n" :: rest when not dd ->
    parse jobs target directory makefile true keep_going silent always_make dd rest
  | "--dry-run" :: rest when not dd ->
    parse jobs target directory makefile true keep_going silent always_make dd rest
  (* -k / --keep-going *)
  | "-k" :: rest when not dd ->
    parse jobs target directory makefile dry_run true silent always_make dd rest
  | "--keep-going" :: rest when not dd ->
    parse jobs target directory makefile dry_run true silent always_make dd rest
  (* -s / --silent / --quiet *)
  | "-s" :: rest when not dd ->
    parse jobs target directory makefile dry_run keep_going true always_make dd rest
  | "--silent" :: rest when not dd ->
    parse jobs target directory makefile dry_run keep_going true always_make dd rest
  | "--quiet" :: rest when not dd ->
    parse jobs target directory makefile dry_run keep_going true always_make dd rest
  (* -B / --always-make *)
  | "-B" :: rest when not dd ->
    parse jobs target directory makefile dry_run keep_going silent true dd rest
  | "--always-make" :: rest when not dd ->
    parse jobs target directory makefile dry_run keep_going silent true dd rest
  (* POSIX end-of-options: skip --, remaining args are positional *)
  | "--" :: rest ->
    parse jobs target directory makefile dry_run keep_going silent always_make true rest
  | arg :: rest ->
    if not dd && String.length arg > 0 && arg.[0] = '-'
    then parse jobs target directory makefile dry_run keep_going silent always_make dd rest
    else (
      match target with
      | None -> parse jobs (Some arg) directory makefile dry_run keep_going silent always_make dd rest
      | Some _ -> None)
in
parse None None None None false false false false false args|}
    ; no_expand_combined = false
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
  | "-L" :: _ :: rest -> parse unified brief files rest
  | "--label" :: _ :: rest -> parse unified brief files rest
  | "-U" :: _ :: rest -> parse unified brief files rest
  | "--unified=" :: rest -> parse unified brief files rest
  | "-I" :: _ :: rest -> parse unified brief files rest
  | "--ignore-matching-lines" :: _ :: rest -> parse unified brief files rest
  | "-W" :: _ :: rest -> parse unified brief files rest
  | "--width" :: _ :: rest -> parse unified brief files rest
  | "--" :: rest ->
    (* POSIX end-of-options: remaining are file1, file2 *)
    let remaining = List.filter (fun a -> String.length a > 0) rest in
    (match remaining with
     | [ f1; f2 ] ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Diff { file1 = f1; file2 = f2; unified; brief }))
     | _ -> None)
  (* Combined short flags: -uq, -qu, etc. *)
  | arg :: rest
    when String.length arg > 2
         && arg.[0] = '-'
         && arg.[1] <> '-'
         && String.for_all (fun c -> c = 'u' || c = 'q')
              (String.sub arg 1 (String.length arg - 1)) ->
    let u' = ref unified and q' = ref brief in
    for j = 1 to String.length arg - 1 do
      match arg.[j] with
      | 'u' -> u' := true
      | 'q' -> q' := true
      | _ -> ()
    done;
    parse !u' !q' files rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse unified brief files rest
    else parse unified brief (files @ [ arg ]) rest
in
parse false false [] args|}
    ; no_expand_combined = false
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
let rec parse in_place ext_re suppress expr file dd = function
  | [] ->
    (match expr, file with
     | Some e, Some f ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Sed { expression = e; file = f; in_place; extended_regex = ext_re; suppress_output = suppress }))
     | _ -> None)
  | "-i" :: rest when not dd ->
    (* macOS sed -i '' takes an empty suffix; GNU sed -i has no suffix.
       Only skip the next token if it's an explicit empty string (macOS style).
       Non-empty non-flag tokens are the expression, not a suffix. *)
    (match rest with
     | "" :: rest' -> parse true ext_re suppress expr file dd rest'   (* -i '' — macOS empty suffix *)
     | _ -> parse true ext_re suppress expr file dd rest)              (* -i at end or GNU style *)
  | "--in-place" :: rest when not dd ->
    parse true ext_re suppress expr file dd rest
  | "-e" :: e :: rest | "--expression" :: e :: rest when not dd -> parse in_place ext_re suppress (Some e) file dd rest  (* explicit expression *)
  | "-f" :: f :: rest | "--file" :: f :: rest when not dd -> parse in_place ext_re suppress (Some f) file dd rest  (* script file → expression *)
  | "-E" :: rest | "--regexp-extended" :: rest when not dd -> parse in_place true suppress expr file dd rest
  | "-n" :: rest | "--quiet" :: rest | "--silent" :: rest when not dd -> parse in_place ext_re true expr file dd rest
  (* POSIX end-of-options: remaining are expression, file *)
  | "--" :: rest -> parse in_place ext_re suppress expr file true rest
  (* --expression=EXPR and --file=FILE eq-forms *)
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg ["--expression"] ->
    let e = Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--expression"]) in
    parse in_place ext_re suppress (Some e) file dd rest
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg ["--file"] ->
    let f = Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--file"]) in
    parse in_place ext_re suppress (Some f) file dd rest
  | arg :: rest ->
    if not dd && String.length arg > 0 && arg.[0] = '-'
    then parse in_place ext_re suppress expr file dd rest
    else (
      match expr with
      | None -> parse in_place ext_re suppress (Some arg) file dd rest
      | Some _ ->
        match file with
        | None -> parse in_place ext_re suppress expr (Some arg) dd rest
        | Some _ -> None)
in
parse false false false None None false args|}
    ; no_expand_combined = false
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
  | "--" :: rest ->
    (* POSIX end-of-options: remaining are source, dest *)
    let remaining = List.filter (fun a -> String.length a > 0) rest in
    (match remaining with
     | [ s; d ] ->
       (match src, dst with
        | None, None ->
          Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Rsync { source = s; dest = d; archive; delete; dry_run; compress; flags = List.rev flags }))
        | _ -> None)
     | _ -> None)
  (* Combined short flags: -az, -anz, -nza, etc. (typed flags only) *)
  | arg :: rest
    when String.length arg > 2
         && arg.[0] = '-'
         && arg.[1] <> '-'
         && String.for_all (fun c -> c = 'a' || c = 'n' || c = 'z')
              (String.sub arg 1 (String.length arg - 1)) ->
    let archive' = ref archive and delete' = ref delete
    and dry_run' = ref dry_run and compress' = ref compress in
    for j = 1 to String.length arg - 1 do
      match arg.[j] with
      | 'a' -> archive' := true
      | 'n' -> dry_run' := true
      | 'z' -> compress' := true
      | _ -> ()
    done;
    parse flags !archive' !delete' !dry_run' !compress' src dst rest
  | arg :: rest ->
    (match Shell_ir_typed_types.eq_form_flag_value arg rsync_value_flags with
     | Some value ->
       let flag = String.sub arg 0 (String.length arg - String.length value - 1) in
       parse (value :: flag :: flags) archive delete dry_run compress src dst rest
     | None ->
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
    ; no_expand_combined = false
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
let node_value_flags = [ "--require"; "--loader"; "--max-old-space-size"; "--inspect-port"; "--env-file"; "--input-type"; "--conditions"; "--experimental-specifier-resolution"; "--experimental-policy"; "--watch-paths"; "--watch-path"; "--title"; "--experimental-default-type" ] in
let rec parse inline script extra dd = function
  | [] ->
    (match inline, script with
     | Some code, _ ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Node { script = ""; args = List.rev extra; inline = Some code }))
     | None, Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Node { script = s; args = List.rev extra; inline = None }))
     | None, None -> None)
  | "-e" :: code :: rest when not dd -> parse (Some code) script extra dd rest
  | "--" :: rest -> parse inline script extra true rest
  (* Value-consuming flags: skip flag + value to prevent value becoming script *)
  | arg :: _val :: rest
    when not dd && String.length arg > 0 && arg.[0] = '-'
         && List.mem arg node_value_flags ->
    parse inline script extra dd rest
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg node_value_flags ->
    let ev = Shell_ir_typed_types.eq_form_flag_value arg node_value_flags in
    parse inline script (match ev with Some evv -> evv :: extra | None -> extra) dd rest
  | arg :: rest ->
    (match inline, script with
     | Some _, _ -> parse inline script (arg :: extra) dd rest
     | None, Some _ -> parse inline script (arg :: extra) dd rest
     | None, None ->
       if not dd && String.length arg > 0 && arg.[0] = '-'
       then parse inline script extra dd rest
       else parse inline (Some arg) extra dd rest)
in
parse None None [] false args|}
    ; no_expand_combined = false
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
let python_value_flags = [ "-m"; "-W"; "-X"; "--check-hash-based-pycs" ] in
let rec parse inline script extra dd = function
  | [] ->
    (match inline, script with
     | Some code, _ ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Python { script = ""; args = List.rev extra; inline = Some code }))
     | None, Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Python { script = s; args = List.rev extra; inline = None }))
     | None, None -> None)
  | "-c" :: code :: rest when not dd -> parse (Some code) script extra dd rest
  | "--" :: rest -> parse inline script extra true rest
  (* Value-consuming flags: skip flag + value *)
  | arg :: _val :: rest
    when not dd && List.mem arg python_value_flags ->
    parse inline script extra dd rest
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg python_value_flags ->
    let ev = Shell_ir_typed_types.eq_form_flag_value arg python_value_flags in
    parse inline script (match ev with Some evv -> evv :: extra | None -> extra) dd rest
  | arg :: rest ->
    (match inline, script with
     | Some _, _ -> parse inline script (arg :: extra) dd rest
     | None, Some _ -> parse inline script (arg :: extra) dd rest
     | None, None ->
       if not dd && String.length arg > 0 && arg.[0] = '-'
       then parse inline script extra dd rest
       else parse inline (Some arg) extra dd rest)
in
parse None None [] false args|}
    ; no_expand_combined = false
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
let python3_value_flags = [ "-m"; "-W"; "-X"; "--check-hash-based-pycs" ] in
let rec parse inline script extra dd = function
  | [] ->
    (match inline, script with
     | Some code, _ ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Python3 { script = ""; args = List.rev extra; inline = Some code }))
     | None, Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Python3 { script = s; args = List.rev extra; inline = None }))
     | None, None -> None)
  | "-c" :: code :: rest when not dd -> parse (Some code) script extra dd rest
  | "--" :: rest -> parse inline script extra true rest
  (* Value-consuming flags: skip flag + value *)
  | arg :: _val :: rest
    when not dd && List.mem arg python3_value_flags ->
    parse inline script extra dd rest
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg python3_value_flags ->
    let ev = Shell_ir_typed_types.eq_form_flag_value arg python3_value_flags in
    parse inline script (match ev with Some evv -> evv :: extra | None -> extra) dd rest
  | arg :: rest ->
    (match inline, script with
     | Some _, _ -> parse inline script (arg :: extra) dd rest
     | None, Some _ -> parse inline script (arg :: extra) dd rest
     | None, None ->
       if not dd && String.length arg > 0 && arg.[0] = '-'
       then parse inline script extra dd rest
       else parse inline (Some arg) extra dd rest)
in
parse None None [] false args|}
    ; no_expand_combined = false
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
let pip_value_flags = [ "--index-url"; "--extra-index-url"; "--timeout"; "-r"; "--constraint"; "--prefix"; "--target"; "--log"; "--proxy"; "--root"; "--format"; "--python-version"; "--implementation"; "--abi"; "--platform"; "--trusted-host"; "--client-cert"; "--key"; "--global-option"; "--hash" ] in
let rec parse subcmd pkgs dd = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Pip { subcommand = s; packages = List.rev pkgs }))
     | None -> None)
  | "--" :: rest -> parse subcmd pkgs true rest
  (* Value-consuming flags: skip flag + value *)
  | arg :: _val :: rest
    when not dd && String.length arg > 0 && arg.[0] = '-'
         && List.mem arg pip_value_flags ->
    parse subcmd pkgs dd rest
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg pip_value_flags ->
    let ev = Shell_ir_typed_types.eq_form_flag_value arg pip_value_flags in
    parse subcmd (match ev with Some evv -> evv :: pkgs | None -> pkgs) dd rest
  | arg :: rest ->
    (match subcmd with
     | None when not dd -> parse (Some arg) pkgs dd rest
     | _ -> parse subcmd (arg :: pkgs) dd rest)
in
parse None [] false args|}
    ; no_expand_combined = false
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
  | "--" :: rest ->
    (* POSIX end-of-options: remaining non-empty args are file *)
    let remaining = List.filter (fun a -> String.length a > 0) rest in
    (match remaining with
     | [] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Patch { file; patchfile; strip; reverse }))
     | [ f ] -> Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Patch { file = Some f; patchfile; strip; reverse }))
     | _ -> None)
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
    ; no_expand_combined = false
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
(* Npm flags that consume the next token as their argument *)
let npm_value_flags =
  [ "--registry"
  ; "--prefix"
  ; "--cache"
  ; "--userconfig"
  ; "--tag"
  ; "--scope"
  ; "--auth-type"
  ; "--otp"
  ; "--loglevel"
  ; "--workspace"; "-w"
  ; "--omit"
  ; "--install-strategy"
  ; "--proxy"; "--https-proxy"
  ; "--no-proxy"
  ]
in
let rec parse subcmd sd glb frc dd = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Npm { subcommand = s; save_dev = sd; global = glb; force = frc; rest = [] }))
     | None -> None)
  | "--save-dev" :: rest when not dd -> parse subcmd true glb frc dd rest
  | "-D" :: rest when not dd -> parse subcmd true glb frc dd rest
  | "--global" :: rest when not dd -> parse subcmd sd true frc dd rest
  | "-g" :: rest when not dd -> parse subcmd sd true frc dd rest
  | "--force" :: rest when not dd -> parse subcmd sd glb true dd rest
  (* Value-consuming flags: skip the flag and its argument *)
  | arg :: _val :: rest
    when not dd && String.length arg > 0 && arg.[0] = '-'
         && List.mem arg npm_value_flags ->
    parse subcmd sd glb frc dd rest
  (* --flag=VALUE equal-sign form *)
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg npm_value_flags ->
    let ev = Shell_ir_typed_types.eq_form_flag_value arg npm_value_flags in
    parse subcmd sd glb frc dd (match ev with Some evv -> evv :: rest | None -> rest)
  (* POSIX end-of-options: all remaining args are positional *)
  | "--" :: rest -> parse subcmd sd glb frc true rest
  | arg :: rest ->
    (match subcmd with
     | None when not dd -> parse (Some arg) sd glb frc dd rest
     | _ ->       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Npm {
         subcommand = (match subcmd with Some s -> s | None -> arg);
         save_dev = sd; global = glb; force = frc;
         rest = (match subcmd with Some _ -> arg :: rest | None -> List.rev rest)
       })))
in
parse None false false false false args|}
    ; no_expand_combined = false
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
(* Cargo flags that consume the next token as their argument *)
let cargo_value_flags =
  [ "--target"; "--target-dir"
  ; "--manifest-path"
  ; "--color"
  ; "--jobs"; "-j"
  ; "--profile"
  ; "--bin"; "--example"; "--test"; "--bench"
  ; "--package"; "-p"
  ; "--message-format"
  ; "--out-dir"
  ; "--config"
  ; "--registry"; "--index"; "--token"
  ; "--exclude"
  ; "-Z"
  ]
in
let rec parse subcmd rel verb feat dd = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Cargo { subcommand = s; release = rel; verbose = verb; features = feat; rest = [] }))
     | None -> None)
  | "--release" :: rest when not dd -> parse subcmd true verb feat dd rest
  | "--verbose" :: rest when not dd -> parse subcmd rel true feat dd rest
  | "-v" :: rest when not dd -> parse subcmd rel true feat dd rest
  | "--features" :: f :: rest when not dd -> parse subcmd rel verb (Some f) dd rest
  (* Value-consuming flags: skip the flag and its argument *)
  | arg :: _val :: rest
    when not dd && String.length arg > 0 && arg.[0] = '-'
         && List.mem arg cargo_value_flags ->
    parse subcmd rel verb feat dd rest
  (* --flag=VALUE equal-sign form for value-consuming flags *)
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg ("--features" :: cargo_value_flags) ->
    (match Shell_ir_typed_types.eq_form_flag_value arg [ "--features" ] with
     | Some f -> parse subcmd rel verb (Some f) dd rest
     | None ->
       let ev = Shell_ir_typed_types.eq_form_flag_value arg cargo_value_flags in
       parse subcmd rel verb feat dd (match ev with Some evv -> evv :: rest | None -> rest))
  (* POSIX end-of-options: all remaining args are positional *)
  | "--" :: rest -> parse subcmd rel verb feat true rest
  | arg :: rest ->
    (match subcmd with
     | None when not dd -> parse (Some arg) rel verb feat dd rest
     | _ ->       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Cargo {
         subcommand = (match subcmd with Some s -> s | None -> arg);
         release = rel; verbose = verb; features = feat;
         rest = (match subcmd with Some _ -> arg :: rest | None -> List.rev rest)
       })))
in
parse None false false None false args|}
    ; no_expand_combined = false
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
(* Go flags that consume the next token as their argument *)
let go_value_flags =
  [ "-o"
  ; "-C"
  ; "-ldflags"; "-asmflags"; "-gcflags"
  ; "-tags"
  ; "-mod"
  ; "-count"
  ; "-benchtime"
  ; "-timeout"
  ; "-run"; "-bench"
  ; "-coverprofile"; "-covermode"; "-coverpkg"
  ; "-cpuprofile"; "-memprofile"; "-blockprofile"; "-mutexprofile"
  ; "-trace"
  ; "-outputdir"
  ; "-parallel"
  ; "-vet"
  ; "-modfile"
  ; "-overlay"
  ; "-pkgdir"
  ; "-toolexec"
  ]
in
let rec parse subcmd v race dd = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Go { subcommand = s; verbose = v; race; rest = [] }))
     | None -> None)
  | "-v" :: rest when not dd -> parse subcmd true race dd rest
  | "-race" :: rest when not dd -> parse subcmd v true dd rest
  | "-trimpath" :: rest when not dd -> parse subcmd v race dd rest
  (* Value-consuming flags: skip the flag and its argument *)
  | arg :: _val :: rest
    when not dd && String.length arg > 0 && arg.[0] = '-'
         && List.mem arg go_value_flags ->
    parse subcmd v race dd rest
  (* Eq-form value flags: --flag=VALUE *)
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg go_value_flags ->
    let ev = Shell_ir_typed_types.eq_form_flag_value arg go_value_flags in
    parse subcmd v race dd (match ev with Some evv -> evv :: rest | None -> rest)
  (* POSIX end-of-options: all remaining args are positional *)
  | "--" :: rest -> parse subcmd v race true rest
  | arg :: rest ->
    (match subcmd with
     | None when not dd -> parse (Some arg) v race dd rest
     | _ ->       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Go {
         subcommand = (match subcmd with Some s -> s | None -> arg);
         verbose = v; race;
         rest = (match subcmd with Some _ -> arg :: rest | None -> List.rev rest)
       })))
in
parse None false false false args|}
    ; no_expand_combined = false
    }
  ; { name = "Gh"
    ; anon_pattern = "Gh _"
    ; bind_pattern =
        "Gh { subcommand; action; draft; squash; delete_branch; body; title; \
         search; state; rest }"
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
      let args = match search with Some q -> args @ [ "--search"; q ] | None -> args in
      let args = match state with Some s -> args @ [ "--state"; s ] | None -> args in
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
let rec parse subcmd act draft squash del_branch body title search state rest = function
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
               ; search
               ; state
               ; rest = List.rev rest
               }))
     | None -> None)
  | arg :: args ->
    let is_flag = String.length arg > 0 && arg.[0] = '-' in
    (match subcmd, act with
     (* First non-flag token is the subcommand; the second is the action.
        Flags — whether they appear BEFORE the subcommand (gh/Cobra accepts
        global flags like [--repo o/r] ahead of the subcommand) or after it —
        fall through to the flag handling below, which consumes value-taking
        flags. Routing leading flags through the same handling keeps the real
        subcommand from being shadowed by a flag or its value (issue #23390). *)
     | None, _ when not is_flag ->
       parse (Some arg) act draft squash del_branch body title search state rest args
     | Some _, None when not is_flag ->
       parse subcmd (Some arg) draft squash del_branch body title search state rest args
     | _ ->
       (match arg with
        | "--draft" -> parse subcmd act true squash del_branch body title search state rest args
        | "--squash" -> parse subcmd act draft true del_branch body title search state rest args
        | "--delete-branch" -> parse subcmd act draft squash true body title search state rest args
        | "--body" ->
          (match args with
           | v :: rest' -> parse subcmd act draft squash del_branch (Some v) title search state rest rest'
           | [] -> parse subcmd act draft squash del_branch body title search state rest args)
        | "--title" ->
          (match args with
           | v :: rest' -> parse subcmd act draft squash del_branch body (Some v) search state rest rest'
           | [] -> parse subcmd act draft squash del_branch body title search state rest args)
        | "--search" ->
          (match args with
           | v :: rest' -> parse subcmd act draft squash del_branch body title (Some v) state rest rest'
           | [] -> parse subcmd act draft squash del_branch body title search state rest args)
        | "--state" ->
          (match args with
           | v :: rest' -> parse subcmd act draft squash del_branch body title search (Some v) rest rest'
           | [] -> parse subcmd act draft squash del_branch body title search state rest args)
        | arg when Shell_ir_typed_types.is_eq_form_flag arg ["--body"] ->
          let v = Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--body"]) in
          parse subcmd act draft squash del_branch (Some v) title search state rest args
        | arg when Shell_ir_typed_types.is_eq_form_flag arg ["--title"] ->
          let v = Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--title"]) in
          parse subcmd act draft squash del_branch body (Some v) search state rest args
        | arg when Shell_ir_typed_types.is_eq_form_flag arg ["--search"] ->
          let v = Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--search"]) in
          parse subcmd act draft squash del_branch body title (Some v) state rest args
        | arg when Shell_ir_typed_types.is_eq_form_flag arg ["--state"] ->
          let v = Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--state"]) in
          parse subcmd act draft squash del_branch body title search (Some v) rest args
        | "--repo" | "--assignee" | "--label" | "--milestone" | "--project"
        | "--reviewer" | "--base" | "--head" | "--editor" | "--hostname"
        | "--jq" | "--template" | "--limit"
        | "-R" | "-a" | "-l" | "-p" | "-r" | "-B" | "-H" ->
          (match args with
           | _ :: rest' -> parse subcmd act draft squash del_branch body title search state rest rest'
           | [] -> parse subcmd act draft squash del_branch body title search state rest args)
        | "--" ->
          (* POSIX end-of-options: remaining args go to rest *)
          parse subcmd act draft squash del_branch body title search state (List.rev args @ rest) []
        | _ when String.length arg > 1 && arg.[0] = '-' && arg.[1] = '-' ->
          (match String.index_opt arg '=' with
           | Some _ -> parse subcmd act draft squash del_branch body title search state rest args
           | None ->
             (match args with
              | v :: rest' when String.length v > 0 && v.[0] <> '-' ->
                parse subcmd act draft squash del_branch body title search state rest rest'
              | _ -> parse subcmd act draft squash del_branch body title search state rest args))
        | _ -> parse subcmd act draft squash del_branch body title search state (arg :: rest) args))
in
parse None None false false false None None None None [] args|}
    ; no_expand_combined = false
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
  | "--" :: rest ->
    (* POSIX end-of-options: remaining are mode, path *)
    let remaining = List.filter (fun a -> String.length a > 0) rest in
    (match remaining with
     | [ m; p ] ->
       (match mode, path with
        | None, None ->
          Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Chmod { mode = m; path = p; recursive }))
        | _ -> None)
     | _ -> None)
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
    ; no_expand_combined = false
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
  | "--" :: rest ->
    (* POSIX end-of-options: remaining are owner, path *)
    let remaining = List.filter (fun a -> String.length a > 0) rest in
    (match remaining with
     | [ o; p ] ->
       (match owner, path with
        | None, None ->
          Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Chown { owner = o; path = p; recursive }))
        | _ -> None)
     | _ -> None)
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
    ; no_expand_combined = false
    }
  ; { name = "Docker"
    ; anon_pattern = "Docker _"
    ; bind_pattern = "Docker { subcommand; rm; privileged; detach; name; network; volumes; publish; env_vars; workdir; platform; rest }"
    ; risk = "`Audited"
    ; sandbox = "`Docker"
    ; to_simple_body =
        {|
      let args =
        let base = [ subcommand ] in
        let base = if rm then base @ [ "--rm" ] else base in
        let base = if privileged then base @ [ "--privileged" ] else base in
        let base = if detach then base @ [ "-d" ] else base in
        let base = (match name with Some n -> base @ [ "--name"; n ] | None -> base) in
        let base = (match network with Some n -> base @ [ "--network"; n ] | None -> base) in
        let base = List.fold_left (fun acc v -> acc @ [ "-v"; v ]) base volumes in
        let base = List.fold_left (fun acc p -> acc @ [ "-p"; p ]) base publish in
        let base = List.fold_left (fun acc e -> acc @ [ "-e"; e ]) base env_vars in
        let base = (match workdir with Some w -> base @ [ "-w"; w ] | None -> base) in
        let base = (match platform with Some p -> base @ [ "--platform"; p ] | None -> base) in
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
(* Docker flags that consume the next token as their argument *)
let docker_value_flags =
  [ "--name"; "--hostname"; "-h"
  ; "--network"; "--net"
  ; "-v"; "--volume"
  ; "-p"; "--publish"
  ; "--env"; "-e"
  ; "--workdir"; "-w"
  ; "--entrypoint"
  ; "--platform"
  ; "--user"; "-u"
  ; "--label"; "-l"
  ; "--log-driver"; "--log-opt"
  ; "--mount"; "--tmpfs"
  ; "--device"
  ; "--add-host"
  ; "--dns"; "--dns-search"; "--dns-option"
  ; "--ip"; "--ip6"
  ; "--link"
  ; "--volumes-from"
  ; "--network-alias"
  ; "--restart"
  ; "--stop-signal"; "--stop-timeout"
  ; "--health-cmd"; "--health-interval"; "--health-timeout"
  ; "--health-retries"; "--health-start-period"
  ; "--memory"; "-m"
  ; "--cpus"; "--cpu-shares"; "--cpu-period"; "--cpu-quota"; "--cpuset-cpus"
  ; "--gpus"
  ; "--pid"
  ; "--pids-limit"
  ; "--memory-swap"; "--memory-reservation"
  ; "--kernel-memory"; "--oom-score-adj"
  ; "--ulimit"
  ; "--security-opt"; "--cap-add"; "--cap-drop"
  ; "--group-add"
  ; "--blkio-weight"; "--blkio-weight-device"
  ; "--cgroup-parent"
  ; "--device-cgroup-rule"
  ; "--sysctl"
  ; "--shm-size"
  ; "--storage-opt"
  ; "-c"; "--cpu-shares"
  ; "--annotation"
  ; "--init-binary"
  ]
in
let rec parse subcmd rm priv det nm net vols pubs envs wd plat dd = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Docker {
         subcommand = s; rm; privileged = priv; detach = det;
         name = nm; network = net; volumes = List.rev vols; publish = List.rev pubs;
         env_vars = List.rev envs; workdir = wd; platform = plat; rest = [] }))
     | None -> None)
  | "--rm" :: rest when not dd -> parse subcmd true priv det nm net vols pubs envs wd plat dd rest
  | "--privileged" :: rest when not dd -> parse subcmd rm true det nm net vols pubs envs wd plat dd rest
  | "-d" :: rest when not dd -> parse subcmd rm priv true nm net vols pubs envs wd plat dd rest
  | "--detach" :: rest when not dd -> parse subcmd rm priv true nm net vols pubs envs wd plat dd rest
  (* Typed value-consuming flags: capture into typed fields *)
  | "--name" :: v :: rest when not dd -> parse subcmd rm priv det (Some v) net vols pubs envs wd plat dd rest
  | "--network" :: v :: rest when not dd -> parse subcmd rm priv det nm (Some v) vols pubs envs wd plat dd rest
  | "--net" :: v :: rest when not dd -> parse subcmd rm priv det nm (Some v) vols pubs envs wd plat dd rest
  | "-v" :: v :: rest when not dd -> parse subcmd rm priv det nm net (v :: vols) pubs envs wd plat dd rest
  | "--volume" :: v :: rest when not dd -> parse subcmd rm priv det nm net (v :: vols) pubs envs wd plat dd rest
  | "-p" :: v :: rest when not dd -> parse subcmd rm priv det nm net vols (v :: pubs) envs wd plat dd rest
  | "--publish" :: v :: rest when not dd -> parse subcmd rm priv det nm net vols (v :: pubs) envs wd plat dd rest
  | "-e" :: v :: rest when not dd -> parse subcmd rm priv det nm net vols pubs (v :: envs) wd plat dd rest
  | "--env" :: v :: rest when not dd -> parse subcmd rm priv det nm net vols pubs (v :: envs) wd plat dd rest
  | "-w" :: v :: rest when not dd -> parse subcmd rm priv det nm net vols pubs envs (Some v) plat dd rest
  | "--workdir" :: v :: rest when not dd -> parse subcmd rm priv det nm net vols pubs envs (Some v) plat dd rest
  | "--platform" :: v :: rest when not dd -> parse subcmd rm priv det nm net vols pubs envs wd (Some v) dd rest
  (* Other value-consuming flags: skip the flag and its argument *)
  | arg :: _val :: rest
    when not dd && String.length arg > 0 && arg.[0] = '-'
         && List.mem arg docker_value_flags ->
    parse subcmd rm priv det nm net vols pubs envs wd plat dd rest
  (* --flag=VALUE equal-sign form for typed flags *)
  | arg :: rest when not dd && Shell_ir_typed_types.is_eq_form_flag arg ["--name"] ->
    let v = Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--name"]) in
    parse subcmd rm priv det (Some v) net vols pubs envs wd plat dd rest
  | arg :: rest when not dd && Shell_ir_typed_types.is_eq_form_flag arg ["--network"] ->
    let v = Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--network"]) in
    parse subcmd rm priv det nm (Some v) vols pubs envs wd plat dd rest
  | arg :: rest when not dd && Shell_ir_typed_types.is_eq_form_flag arg ["--workdir"] ->
    let v = Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--workdir"]) in
    parse subcmd rm priv det nm net vols pubs envs (Some v) plat dd rest
  | arg :: rest when not dd && Shell_ir_typed_types.is_eq_form_flag arg ["--platform"] ->
    let v = Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--platform"]) in
    parse subcmd rm priv det nm net vols pubs envs wd (Some v) dd rest
  (* --flag=VALUE equal-sign form for other value-consuming flags *)
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg docker_value_flags ->
    let ev = Shell_ir_typed_types.eq_form_flag_value arg docker_value_flags in
    parse subcmd rm priv det nm net vols pubs envs wd plat dd (match ev with Some evv -> evv :: rest | None -> rest)
  (* POSIX end-of-options: all remaining args are positional *)
  | "--" :: rest -> parse subcmd rm priv det nm net vols pubs envs wd plat true rest
  | arg :: rest when String.length arg > 0 && arg.[0] = '-' && Option.is_some subcmd && not dd ->
    (* Unknown flag (e.g. -t, --tty): skip, continue parsing to avoid breaking round-trip *)
    parse subcmd rm priv det nm net vols pubs envs wd plat dd rest
  | arg :: rest ->
    (match subcmd with
     | None when not dd -> parse (Some arg) rm priv det nm net vols pubs envs wd plat dd rest
     | _ ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Docker {
         subcommand = (match subcmd with Some s -> s | None -> arg);
         rm; privileged = priv; detach = det;
         name = nm; network = net; volumes = List.rev vols; publish = List.rev pubs;
         env_vars = List.rev envs; workdir = wd; platform = plat;
         rest = (match subcmd with Some _ -> arg :: rest | None -> List.rev rest)
       })))
in
parse None false false false None None [] [] [] None None false args|}
    ; no_expand_combined = false
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
let opam_value_flags = [ "--repo"; "--root"; "--switch"; "--dir"; "--solver"; "--best-effort-prefix"; "--color"; "--confirm-level" ] in
  let rec parse subcmd y dd = function
    | [] ->
      (match subcmd with
       | Some s ->
         Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Opam { subcommand = s; yes = y; rest = [] }))
       | None -> None)
    | "-y" :: rest when not dd -> parse subcmd true dd rest
    | "--yes" :: rest when not dd -> parse subcmd true dd rest
    | "--" :: rest -> parse subcmd y true rest
    (* Value-consuming flags: skip flag + value *)
    | arg :: _val :: rest
      when not dd && String.length arg > 0 && arg.[0] = '-'
           && List.mem arg opam_value_flags ->
      parse subcmd y dd rest
    (* --flag=VALUE equal-sign form *)
    | arg :: rest
      when not dd && Shell_ir_typed_types.is_eq_form_flag arg opam_value_flags ->
      let ev = Shell_ir_typed_types.eq_form_flag_value arg opam_value_flags in
      parse subcmd y dd (match ev with Some evv -> evv :: rest | None -> rest)
    | arg :: rest ->
      (match subcmd with
       | None when not dd -> parse (Some arg) y dd rest
       | _ ->         Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Opam {
           subcommand = (match subcmd with Some s -> s | None -> arg);
           yes = y;
           rest = (match subcmd with Some _ -> arg :: rest | None -> List.rev rest)
         })))
  in
  parse None false false args|}
    ; no_expand_combined = false
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
let npx_value_flags = [ "--package"; "--cache"; "--userconfig"; "--call"; "-p" ] in
  let rec parse subcmd y dd = function
    | [] ->
      (match subcmd with
       | Some s ->
         Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Npx { subcommand = s; yes = y; rest = [] }))
       | None -> None)
    | "-y" :: rest when not dd -> parse subcmd true dd rest
    | "--yes" :: rest when not dd -> parse subcmd true dd rest
    | "--" :: rest -> parse subcmd y true rest
    (* Value-consuming flags: skip flag + value *)
    | arg :: _val :: rest
      when not dd && String.length arg > 0 && arg.[0] = '-'
           && List.mem arg npx_value_flags ->
      parse subcmd y dd rest
    (* --flag=VALUE equal-sign form *)
    | arg :: rest
      when not dd && Shell_ir_typed_types.is_eq_form_flag arg npx_value_flags ->
      let ev = Shell_ir_typed_types.eq_form_flag_value arg npx_value_flags in
      parse subcmd y dd (match ev with Some evv -> evv :: rest | None -> rest)
    | arg :: rest ->
      (match subcmd with
       | None when not dd -> parse (Some arg) y dd rest
       | _ ->         Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Npx {
           subcommand = (match subcmd with Some s -> s | None -> arg);
           yes = y;
           rest = (match subcmd with Some _ -> arg :: rest | None -> List.rev rest)
         })))
  in
  parse None false false args|}
    ; no_expand_combined = false
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
let yarn_value_flags = [ "--cwd"; "--modules-folder"; "--cache-folder"; "--registry"; "--mutex"; "--har"; "--preferred-cache-folder"; "--network-timeout"; "--network-concurrency" ] in
let rec parse subcmd dev glb prod fl dd = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Yarn { subcommand = s; dev; global = glb; production = prod; frozen_lockfile = fl; rest = [] }))
     | None -> None)
  | "--dev" :: rest when not dd -> parse subcmd true glb prod fl dd rest
  | "-D" :: rest when not dd -> parse subcmd true glb prod fl dd rest
  | "--global" :: rest when not dd -> parse subcmd dev true prod fl dd rest
  | "-g" :: rest when not dd -> parse subcmd dev true prod fl dd rest
  | "--production" :: rest when not dd -> parse subcmd dev glb true fl dd rest
  | "--prod" :: rest when not dd -> parse subcmd dev glb true fl dd rest
  | "--frozen-lockfile" :: rest when not dd -> parse subcmd dev glb prod true dd rest
  (* POSIX end-of-options: all remaining args are positional *)
  | "--" :: rest -> parse subcmd dev glb prod fl true rest
  (* Value-consuming flags: skip flag + value *)
  | arg :: _val :: rest
    when not dd && String.length arg > 0 && arg.[0] = '-'
         && List.mem arg yarn_value_flags ->
    parse subcmd dev glb prod fl dd rest
  (* --flag=VALUE equal-sign form *)
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg yarn_value_flags ->
    let ev = Shell_ir_typed_types.eq_form_flag_value arg yarn_value_flags in
    parse subcmd dev glb prod fl dd (match ev with Some evv -> evv :: rest | None -> rest)
  | arg :: rest ->
    (match subcmd with
     | None when not dd -> parse (Some arg) dev glb prod fl dd rest
     | _ ->       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Yarn {
         subcommand = (match subcmd with Some s -> s | None -> arg);
         dev; global = glb; production = prod; frozen_lockfile = fl;
         rest = (match subcmd with Some _ -> arg :: rest | None -> List.rev rest)
       })))
in
parse None false false false false false args|}
    ; no_expand_combined = false
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
let rec parse subcmd sd glb frc prod dd = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Pnpm { subcommand = s; save_dev = sd; global = glb; force = frc; production = prod; rest = [] }))
     | None -> None)
  | "--save-dev" :: rest when not dd -> parse subcmd true glb frc prod dd rest
  | "-D" :: rest when not dd -> parse subcmd true glb frc prod dd rest
  | "--global" :: rest when not dd -> parse subcmd sd true frc prod dd rest
  | "-g" :: rest when not dd -> parse subcmd sd true frc prod dd rest
  | "--force" :: rest when not dd -> parse subcmd sd glb true prod dd rest
  | "--production" :: rest when not dd -> parse subcmd sd glb frc true dd rest
  | "--prod" :: rest when not dd -> parse subcmd sd glb frc true dd rest
  (* Value-consuming flags: skip flag + value *)
  | arg :: _val :: rest
    when not dd && String.length arg > 0 && arg.[0] = '-'
         && List.mem arg [ "--dir"; "--filter"; "--store-dir"; "--registry"; "--config"; "--global-dir"; "--reporter"; "--loglevel"; "--prefix"; "--color" ] ->
    parse subcmd sd glb frc prod dd rest
  (* --flag=VALUE equal-sign form *)
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg [ "--dir"; "--filter"; "--store-dir"; "--registry"; "--config"; "--global-dir"; "--reporter"; "--loglevel"; "--prefix"; "--color" ] ->
    let ev = Shell_ir_typed_types.eq_form_flag_value arg [ "--dir"; "--filter"; "--store-dir"; "--registry"; "--config"; "--global-dir"; "--reporter"; "--loglevel"; "--prefix"; "--color" ] in
    parse subcmd sd glb frc prod dd (match ev with Some evv -> evv :: rest | None -> rest)
  (* POSIX end-of-options: all remaining args are positional *)
  | "--" :: rest -> parse subcmd sd glb frc prod true rest
  | arg :: rest ->
    (match subcmd with
     | None when not dd -> parse (Some arg) sd glb frc prod dd rest
     | _ ->       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Pnpm {
         subcommand = (match subcmd with Some s -> s | None -> arg);
         save_dev = sd; global = glb; force = frc; production = prod;
         rest = (match subcmd with Some _ -> arg :: rest | None -> List.rev rest)
       })))
in
parse None false false false false false args|}
    ; no_expand_combined = false
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
let rec parse subcmd nc sys dd = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Uv { subcommand = s; no_cache = nc; system = sys; rest = [] }))
     | None -> None)
  | "--no-cache" :: rest when not dd -> parse subcmd true sys dd rest
  | "-n" :: rest when not dd -> parse subcmd true sys dd rest
  | "--system" :: rest when not dd -> parse subcmd nc true dd rest
  (* Value-consuming flags: skip flag + value *)
  | arg :: _val :: rest
    when not dd && String.length arg > 0 && arg.[0] = '-'
         && List.mem arg [ "--index-url"; "--extra-index-url"; "--python"; "--cache-dir"; "--find-links"; "--resolution"; "--prerelease"; "--index-strategy"; "--keyring-provider" ] ->
    parse subcmd nc sys dd rest
  (* --flag=VALUE equal-sign form *)
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg [ "--index-url"; "--extra-index-url"; "--python"; "--cache-dir"; "--find-links"; "--resolution"; "--prerelease"; "--index-strategy"; "--keyring-provider" ] ->
    let ev = Shell_ir_typed_types.eq_form_flag_value arg [ "--index-url"; "--extra-index-url"; "--python"; "--cache-dir"; "--find-links"; "--resolution"; "--prerelease"; "--index-strategy"; "--keyring-provider" ] in
    parse subcmd nc sys dd (match ev with Some evv -> evv :: rest | None -> rest)
  (* POSIX end-of-options: all remaining args are positional *)
  | "--" :: rest -> parse subcmd nc sys true rest
  | arg :: rest ->
    (match subcmd with
     | None when not dd -> parse (Some arg) nc sys dd rest
     | _ ->       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Uv {
         subcommand = (match subcmd with Some s -> s | None -> arg);
         no_cache = nc; system = sys;
         rest = (match subcmd with Some _ -> arg :: rest | None -> List.rev rest)
       })))
in
parse None false false false args|}
    ; no_expand_combined = false
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
let rec parse subcmd y f dd = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Glab { subcommand = s; yes = y; force = f; rest = [] }))
     | None -> None)
  | "--yes" :: rest when not dd -> parse subcmd true f dd rest
  | "-y" :: rest when not dd -> parse subcmd true f dd rest
  | "--force" :: rest when not dd -> parse subcmd y true dd rest
  | "-f" :: rest when not dd -> parse subcmd y true dd rest
  (* Value-consuming flags: skip flag + value *)
  | arg :: _val :: rest
    when not dd && String.length arg > 0 && arg.[0] = '-'
         && List.mem arg [ "--repo"; "--hostname"; "--group"; "--output"; "--per-page"; "--jq"; "--template" ] ->
    parse subcmd y f dd rest
  (* --flag=VALUE equal-sign form *)
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg [ "--repo"; "--hostname"; "--group"; "--output"; "--per-page"; "--jq"; "--template" ] ->
    let ev = Shell_ir_typed_types.eq_form_flag_value arg [ "--repo"; "--hostname"; "--group"; "--output"; "--per-page"; "--jq"; "--template" ] in
    parse subcmd y f dd (match ev with Some evv -> evv :: rest | None -> rest)
  | "--" :: rest -> parse subcmd y f true rest
  | arg :: rest ->
    (match subcmd with
     | None when not dd -> parse (Some arg) y f dd rest
     | _ ->       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Glab {
         subcommand = (match subcmd with Some s -> s | None -> arg);
         yes = y; force = f;
         rest = (match subcmd with Some _ -> arg :: rest | None -> List.rev rest)
       })))
in
parse None false false false args|}
    ; no_expand_combined = false
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
let rec parse subcmd v x dd = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Pytest { subcommand = s; verbose = v; exitfirst = x; rest = [] }))
     | None -> None)
  | "-v" :: rest | "--verbose" :: rest when not dd -> parse subcmd true x dd rest
  | "-x" :: rest | "--exitfirst" :: rest when not dd -> parse subcmd v true dd rest
  (* Value-consuming flags: skip flag + value *)
  | arg :: _val :: rest
    when not dd && String.length arg > 0 && arg.[0] = '-'
         && List.mem arg [ "-k"; "-m"; "--tb"; "-p"; "--deselect"; "--junitxml"; "--result-log"; "--confcutdir"; "--rootdir"; "--override-ini" ] ->
    parse subcmd v x dd rest
  (* --flag=VALUE equal-sign form (double-dash only) *)
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg [ "--tb"; "--deselect"; "--junitxml"; "--result-log"; "--confcutdir"; "--rootdir"; "--override-ini" ] ->
    let ev = Shell_ir_typed_types.eq_form_flag_value arg [ "--tb"; "--deselect"; "--junitxml"; "--result-log"; "--confcutdir"; "--rootdir"; "--override-ini" ] in
    parse subcmd v x dd (match ev with Some evv -> evv :: rest | None -> rest)
  | "--" :: rest -> parse subcmd v x true rest
  | arg :: rest ->
    (match subcmd with
     | None when not dd -> parse (Some arg) v x dd rest
     | _ ->       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Pytest {
         subcommand = (match subcmd with Some s -> s | None -> arg);
         verbose = v; exitfirst = x;
         rest = (match subcmd with Some _ -> arg :: rest | None -> List.rev rest)
       })))
in
parse None false false false args|}
    ; no_expand_combined = false
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
  | "--" :: rest -> parse_pos title message rest
  | arg :: rest ->
    if String.length arg > 0 && arg.[0] = '-'
    then parse title message rest
    else (match title with
          | None -> parse (Some arg) message rest
          | Some _ -> (match message with
                       | None -> parse title (Some arg) rest
                       | Some _ -> None))
and parse_pos title message = function
  | [] ->
    (match title, message with
     | Some t, Some m ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Terminal_notifier { title = t; message = m }))
     | _ -> None)
  | arg :: rest ->
    (match title with
     | None -> parse_pos (Some arg) message rest
     | Some _ -> (match message with
                  | None -> parse_pos title (Some arg) rest
                  | Some _ -> None))
in
parse None None args|}
    ; no_expand_combined = false
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
let ruff_value_flags = [ "--config"; "--select"; "--ignore"; "--line-length"; "--target-version"; "--exclude"; "--extend-select"; "--per-file-ignores"; "--format"; "--fixable"; "--unfixable"; "--extend-ignore"; "--output-format" ] in
let rec parse subcmd f s dd = function
  | [] ->
    (match subcmd with
     | Some sc ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Ruff { subcommand = sc; fix = f; show_source = s; rest = [] }))
     | None -> None)
  | "--fix" :: rest when not dd -> parse subcmd true s dd rest
  | "--show-source" :: rest when not dd -> parse subcmd f true dd rest
  | "--preview" :: rest when not dd -> parse subcmd f s dd rest
  | "--" :: rest -> parse subcmd f s true rest
  (* Value-consuming flags: skip flag + value *)
  | arg :: _val :: rest
    when not dd && String.length arg > 0 && arg.[0] = '-'
         && List.mem arg ruff_value_flags ->
    parse subcmd f s dd rest
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg ruff_value_flags ->
    let ev = Shell_ir_typed_types.eq_form_flag_value arg ruff_value_flags in
    parse subcmd f s dd (match ev with Some evv -> evv :: rest | None -> rest)
  | arg :: rest ->
    (match subcmd with
     | None when not dd -> parse (Some arg) f s dd rest
     | _ ->       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Ruff {
         subcommand = (match subcmd with Some sc -> sc | None -> arg);
         fix = f; show_source = s;
         rest = (match subcmd with Some _ -> arg :: rest | None -> List.rev rest)
       })))
in
parse None false false false args|}
    ; no_expand_combined = false
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
let rec parse subcmd st dd = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Pyright { subcommand = s; strict = st; rest = [] }))
     | None -> None)
  | "--strict" :: rest when not dd -> parse subcmd true dd rest
  (* Value-consuming flags: skip flag + value *)
  | arg :: _val :: rest
    when not dd && String.length arg > 0 && arg.[0] = '-'
         && List.mem arg [ "--pythonversion"; "--pythonplatform"; "--lib"; "--project"; "--venv-path" ] ->
    parse subcmd st dd rest
  (* --flag=VALUE equal-sign form *)
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg [ "--pythonversion"; "--pythonplatform"; "--lib"; "--project"; "--venv-path" ] ->
    let ev = Shell_ir_typed_types.eq_form_flag_value arg [ "--pythonversion"; "--pythonplatform"; "--lib"; "--project"; "--venv-path" ] in
    parse subcmd st dd (match ev with Some evv -> evv :: rest | None -> rest)
  | "--" :: rest -> parse subcmd st true rest
  | arg :: rest ->
    (match subcmd with
     | None when not dd -> parse (Some arg) st dd rest
     | _ ->       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Pyright {
         subcommand = (match subcmd with Some s -> s | None -> arg);
         strict = st;
         rest = (match subcmd with Some _ -> arg :: rest | None -> List.rev rest)
       })))
in
parse None false false args|}
    ; no_expand_combined = false
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
let tsc_value_flags = [ "--target"; "--module"; "--lib"; "--outDir"; "--rootDir"; "--jsx"; "--moduleResolution"; "--types"; "--typeRoots"; "--baseUrl"; "--paths"; "--outFile"; "--sourceMap"; "--declaration"; "--declarationDir"; "--emitDeclarationOnly"; "--importHelpers"; "--downlevelIteration"; "--strict"; "--project"; "--extends"; "--init"; "--locale"; "--mapRoot"; "--sourceRoot"; "--configFilePath" ] in
let rec parse subcmd nw w dd = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Tsc { subcommand = s; no_emit = nw; watch = w; rest = [] }))
     | None -> None)
  | "--noEmit" :: rest when not dd -> parse subcmd true w dd rest
  | "--watch" :: rest when not dd -> parse subcmd nw true dd rest
  | "--" :: rest -> parse subcmd nw w true rest
  (* Value-consuming flags: skip flag + value *)
  | arg :: _val :: rest
    when not dd && String.length arg > 0 && arg.[0] = '-'
         && List.mem arg tsc_value_flags ->
    parse subcmd nw w dd rest
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg tsc_value_flags ->
    let ev = Shell_ir_typed_types.eq_form_flag_value arg tsc_value_flags in
    parse subcmd nw w dd (match ev with Some evv -> evv :: rest | None -> rest)
  | arg :: rest ->
    (match subcmd with
     | None when not dd -> parse (Some arg) nw w dd rest
     | _ ->       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Tsc {
         subcommand = (match subcmd with Some s -> s | None -> arg);
         no_emit = nw; watch = w;
         rest = (match subcmd with Some _ -> arg :: rest | None -> List.rev rest)
       })))
in
parse None false false false args|}
    ; no_expand_combined = false
    }
  ; subcommand_args_ctor ~name:"Ocamlfind" ~risk:"`Audited" ~sandbox:"`Host" ()
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
let rec parse subcmd opt tst dd = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Rustc { subcommand = s; optimize = opt; test = tst; rest = [] }))
     | None -> None)
  | "-O" :: rest when not dd -> parse subcmd true tst dd rest
  | "--test" :: rest when not dd -> parse subcmd opt true dd rest
  | arg :: _val :: rest
    when not dd
         && List.mem arg [ "--edition"; "--target"; "--out-dir"; "--emit"; "--crate-name"; "--crate-type"; "-L"; "-l"; "--sysroot"; "--print" ] ->
    parse subcmd opt tst dd rest
  | arg :: rest
    when not dd
         && Shell_ir_typed_types.is_eq_form_flag arg
              [ "--edition"; "--target"; "--out-dir"; "--emit"; "--crate-name"; "--crate-type"; "-L"; "-l"; "--sysroot"; "--print" ] ->
    let ev = Shell_ir_typed_types.eq_form_flag_value arg [ "--edition"; "--target"; "--out-dir"; "--emit"; "--crate-name"; "--crate-type"; "-L"; "-l"; "--sysroot"; "--print" ] in
    parse subcmd opt tst dd (match ev with Some evv -> evv :: rest | None -> rest)
  | "--" :: rest -> parse subcmd opt tst true rest
  | arg :: rest ->
    (match subcmd with
     | None when not dd -> parse (Some arg) opt tst dd rest
     | _ ->       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Rustc {
         subcommand = (match subcmd with Some s -> s | None -> arg);
         optimize = opt; test = tst;
         rest = (match subcmd with Some _ -> arg :: rest | None -> List.rev rest)
       })))
in
parse None false false false args|}
    ; no_expand_combined = false
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
let rec parse subcmd w lf dd = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Gofmt { subcommand = s; write = w; list_files = lf; rest = [] }))
     | None -> None)
  | "-w" :: rest when not dd -> parse subcmd true lf dd rest
  | "-l" :: rest when not dd -> parse subcmd w true dd rest
  | arg :: _val :: rest
    when not dd && List.mem arg [ "-tabs"; "-tabwidth"; "-comments" ] ->
    parse subcmd w lf dd (_val :: rest)
  (* Eq-form value flags: -flag=VALUE *)
  | arg :: rest
    when not dd
         && Shell_ir_typed_types.is_eq_form_flag arg [ "-tabs"; "-tabwidth"; "-comments" ] ->
    let ev = Shell_ir_typed_types.eq_form_flag_value arg [ "-tabs"; "-tabwidth"; "-comments" ] in
    parse subcmd w lf dd (match ev with Some evv -> evv :: rest | None -> rest)
  | "--" :: rest -> parse subcmd w lf true rest
  | arg :: rest ->
    (match subcmd with
     | None when not dd -> parse (Some arg) w lf dd rest
     | _ ->       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Gofmt {
         subcommand = (match subcmd with Some s -> s | None -> arg);
         write = w; list_files = lf;
         rest = (match subcmd with Some _ -> arg :: rest | None -> List.rev rest)
       })))
in
parse None false false false args|}
    ; no_expand_combined = false
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
let gradle_value_flags = [ "--build-file"; "--settings-file"; "--gradle-user-home"; "--project-cache-dir"; "--project-dir"; "-D"; "--system-prop"; "--init-script"; "--include-build" ] in
let rec parse subcmd nd p dd = function
  | [] ->
    (match subcmd with
     | Some s ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Gradle { subcommand = s; no_daemon = nd; parallel = p; rest = [] }))
     | None -> None)
  | "--no-daemon" :: rest when not dd -> parse subcmd true p dd rest
  | "--parallel" :: rest when not dd -> parse subcmd nd true dd rest
  | "--rerun-tasks" :: rest when not dd -> parse subcmd nd p dd rest
  | "--" :: rest -> parse subcmd nd p true rest
  (* Value-consuming flags: skip the flag and its argument *)
  | arg :: _val :: rest
    when not dd && String.length arg > 0 && arg.[0] = '-'
         && List.mem arg gradle_value_flags ->
    parse subcmd nd p dd rest
  (* --flag=VALUE equal-sign form for value-consuming flags *)
  | arg :: rest
    when not dd && Shell_ir_typed_types.is_eq_form_flag arg gradle_value_flags ->
    let ev = Shell_ir_typed_types.eq_form_flag_value arg gradle_value_flags in
    parse subcmd nd p dd (match ev with Some evv -> evv :: rest | None -> rest)
  | arg :: rest ->
    (match subcmd with
     | None when not dd -> parse (Some arg) nd p dd rest
     | _ ->       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Gradle {
         subcommand = (match subcmd with Some s -> s | None -> arg);
         no_daemon = nd; parallel = p;
         rest = (match subcmd with Some _ -> arg :: rest | None -> List.rev rest)
       })))
in
parse None false false false args|}
    ; no_expand_combined = false
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
  let rec parse subcmd j dd = function
    | [] ->
      (match subcmd with
       | Some s ->
         Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Ninja { subcommand = s; jobs = j; rest = [] }))
       | None -> None)
    | "--" :: rest -> parse subcmd j true rest
    | "--jobs" :: n :: rest when not dd ->
      (match int_of_string_opt n with
       | Some j' -> parse subcmd (Some j') dd rest
       | None ->         Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Ninja {
           subcommand = (match subcmd with Some s -> s | None -> n); jobs = j;
           rest = (match subcmd with Some _ -> List.rev_append rest [ n ] | None -> List.rev rest)
         })))
    | arg :: rest when not dd && Shell_ir_typed_types.is_eq_form_flag arg ["--jobs"] ->
      let n = Option.get (Shell_ir_typed_types.eq_form_flag_value arg ["--jobs"]) in
      (match int_of_string_opt n with
       | Some j' -> parse subcmd (Some j') dd rest
       | None ->         Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Ninja {
           subcommand = (match subcmd with Some s -> s | None -> arg); jobs = j;
           rest = (match subcmd with Some _ -> arg :: rest | None -> List.rev rest)
         })))
    | arg :: v :: rest
      when not dd && List.mem arg [ "-C"; "-f"; "-k"; "-l"; "-d" ] ->
      (match subcmd with
       | None -> parse (Some v) j dd rest
       | Some _ -> parse subcmd j dd (v :: rest))
    | arg :: rest
      when not dd
           && Shell_ir_typed_types.is_eq_form_flag arg
                [ "-C"; "-f"; "-k"; "-l"; "-d" ] ->
      let ev = Shell_ir_typed_types.eq_form_flag_value arg [ "-C"; "-f"; "-k"; "-l"; "-d" ] in
      parse subcmd j dd (match ev with Some evv -> evv :: rest | None -> rest)
    | arg :: rest ->
      if not dd && String.length arg > 2 && String.sub arg 0 2 = "-j"
      then
        (try parse subcmd (Some (int_of_string (String.sub arg 2 (String.length arg - 2)))) dd rest
         with Failure _ ->
           match subcmd with
           | None when not dd -> parse (Some arg) j dd rest
           | _ ->             Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Ninja {
               subcommand = (match subcmd with Some s -> s | None -> arg); jobs = j;
               rest = (match subcmd with Some _ -> arg :: rest | None -> List.rev rest)
             })))
      else
        match subcmd with
        | None when not dd -> parse (Some arg) j dd rest
        | _ ->          Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Ninja {
            subcommand = (match subcmd with Some s -> s | None -> arg); jobs = j;
            rest = (match subcmd with Some _ -> arg :: rest | None -> List.rev rest)
          }))
  in
  parse None None false args|}
    ; no_expand_combined = false
    }
  ; subcommand_args_ctor ~name:"Java" ~risk:"`Audited" ~sandbox:"`Host" ()
  ; subcommand_args_ctor ~name:"Javac" ~risk:"`Audited" ~sandbox:"`Host" ()
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
  (* Mvn flags that consume the next token as their argument *)
  (* Mvn flags that consume the next token as their argument.
     NOTE: -nt/--no-transfer-progress is boolean (disables progress display),
     -X is boolean (enables debug output) — neither consumes a value. *)
  let mvn_value_flags =
    [ "-D"; "--define"
    ; "-f"; "--file"
    ; "-s"; "--settings"
    ; "-gs"; "--global-settings"
    ; "-P"; "--activate-profiles"
    ; "--log-file"
    ; "--color"
    ; "-l"
    ; "-pl"; "--projects"
    ; "-rf"; "--resume-from"
    ; "-t"; "--threads"
    ; "-T"
    ]
  in
  let rec parse subcmd off bat q dd = function
    | [] ->
      (match subcmd with
       | Some s ->
         Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Mvn {
           subcommand = s; offline = off; batch_mode = bat; quiet = q; args = [] }))
       | None -> None)
    | "-o" :: rest when not dd -> parse subcmd true bat q dd rest
    | "--offline" :: rest when not dd -> parse subcmd true bat q dd rest
    | "-B" :: rest when not dd -> parse subcmd off true q dd rest
    | "--batch-mode" :: rest when not dd -> parse subcmd off true q dd rest
    | "-q" :: rest when not dd -> parse subcmd off bat true dd rest
    | "--quiet" :: rest when not dd -> parse subcmd off bat true dd rest
    (* Value-consuming flags: skip the flag and its argument *)
    | arg :: _val :: rest
      when not dd && String.length arg > 0 && arg.[0] = '-'
           && List.mem arg mvn_value_flags ->
      parse subcmd off bat q dd rest
    (* --flag=VALUE equal-sign form *)
    | arg :: rest
      when not dd && Shell_ir_typed_types.is_eq_form_flag arg mvn_value_flags ->
      let ev = Shell_ir_typed_types.eq_form_flag_value arg mvn_value_flags in
      parse subcmd off bat q dd (match ev with Some evv -> evv :: rest | None -> rest)
    | "--" :: rest -> parse subcmd off bat q true rest
    | arg :: rest ->
      (match subcmd with
       | None when not dd -> parse (Some arg) off bat q dd rest
       | _ ->         Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Mvn {
           subcommand = (match subcmd with Some s -> s | None -> arg);
           offline = off; batch_mode = bat; quiet = q;
           args = (match subcmd with Some _ -> arg :: rest | None -> List.rev rest) })))
  in
  parse None false false false false args|}
    ; no_expand_combined = false
    }
  ; subcommand_args_ctor ~name:"Cmake" ~risk:"`Audited" ~sandbox:"`Host" ()
  ; subcommand_args_ctor ~name:"Dune_local_sh" ~risk:"`Audited" ~sandbox:"`Host" ()
  ; subcommand_args_ctor ~name:"Osascript" ~risk:"`Audited" ~sandbox:"`Host" ()
  ; subcommand_args_ctor ~name:"Play" ~risk:"`Audited" ~sandbox:"`Host" ()
  ; subcommand_args_ctor ~name:"Rec" ~risk:"`Audited" ~sandbox:"`Host" ()
  ; subcommand_args_ctor ~name:"Ffplay" ~risk:"`Audited" ~sandbox:"`Host" ()
  ; subcommand_args_ctor ~name:"Mpg123" ~risk:"`Audited" ~sandbox:"`Host" ()
  ; subcommand_args_ctor ~name:"Open" ~risk:"`Audited" ~sandbox:"`Host" ()
  ; subcommand_args_ctor ~name:"Su" ~risk:"`Privileged" ~sandbox:"`Host"
      ~value_flags:[ "-s"; "--shell"; "-g"; "--group"; "-G"; "--supp-group"; "-c"; "--command"; "-w"; "--whitelist-environment" ] ()
  ; subcommand_args_ctor ~name:"Dd" ~risk:"`Privileged" ~sandbox:"`Host" ()
  ; subcommand_args_ctor ~name:"Mkfs" ~risk:"`Privileged" ~sandbox:"`Host"
      ~value_flags:[ "-t"; "--type"; "-L"; "--label"; "-U"; "-b"; "-i"; "-I"; "-N"; "-m"; "-O" ] ()
  ; { name = "Cp"
    ; anon_pattern =
        "Cp { source; dest; recursive; force; preserve }"
    ; bind_pattern =
        "Cp { source; dest; recursive; force; preserve }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let flag_args =
        (if recursive then [ "-r" ] else [])
        @ (if force then [ "-f" ] else [])
        @ (if preserve then [ "-p" ] else [])
      in
      let all_args = flag_args @ [ source; dest ] in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Cp
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) all_args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Cp"
    ; parse_body =
        Some
          {|
let rec parse flags positional dd = function
  | [] ->
    (match positional with
     | [ src; dst ] ->
       let recursive = List.mem "-r" flags || List.mem "-R" flags in
       let force = List.mem "-f" flags in
       let preserve = List.mem "-p" flags in
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Cp { source = src; dest = dst; recursive; force; preserve }))
     | _ -> None)
  | "--" :: rest -> parse flags positional true rest
  | arg :: rest when not dd && (arg = "-r" || arg = "-R" || arg = "-f" || arg = "-p") ->
    parse (arg :: flags) positional dd rest
  | arg :: rest when not dd && arg = "--no-preserve=all" ->
    parse flags positional dd rest
  | arg :: rest when not dd && String.length arg > 2 && arg.[0] = '-' && arg.[1] <> '-' ->
    parse flags positional dd rest
  | arg :: rest ->
    parse flags (positional @ [ arg ]) dd rest
in
parse [] [] false args|}
    ; no_expand_combined = false
    }
  ; { name = "Mv"
    ; anon_pattern = "Mv { source; dest; force; no_clobber }"
    ; bind_pattern = "Mv { source; dest; force; no_clobber }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let flag_args =
        (if force then [ "-f" ] else [])
        @ (if no_clobber then [ "-n" ] else [])
      in
      let all_args = flag_args @ [ source; dest ] in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Mv
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) all_args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Mv"
    ; parse_body =
        Some
          {|
let rec parse flags positional dd = function
  | [] ->
    (match positional with
     | [ src; dst ] ->
       let force = List.mem "-f" flags in
       let no_clobber = List.mem "-n" flags in
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Mv { source = src; dest = dst; force; no_clobber }))
     | _ -> None)
  | "--" :: rest -> parse flags positional true rest
  | arg :: rest when not dd && (arg = "-f" || arg = "-n" || arg = "-i") ->
    parse (arg :: flags) positional dd rest
  | arg :: rest when not dd && String.length arg > 2 && arg.[0] = '-' && arg.[1] <> '-' ->
    parse flags positional dd rest
  | arg :: rest ->
    parse flags (positional @ [ arg ]) dd rest
in
parse [] [] false args|}
    ; no_expand_combined = false
    }
  ; { name = "Ln"
    ; anon_pattern = "Ln { target; link_name; symbolic; force }"
    ; bind_pattern = "Ln { target; link_name; symbolic; force }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let flag_args =
        (if symbolic then [ "-s" ] else [])
        @ (if force then [ "-f" ] else [])
      in
      let all_args = flag_args @ [ target; link_name ] in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Ln
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) all_args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Ln"
    ; parse_body =
        Some
          {|
let rec parse flags positional dd = function
  | [] ->
    (match positional with
     | [ tgt; link ] ->
       let symbolic = List.mem "-s" flags in
       let force = List.mem "-f" flags in
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Ln { target = tgt; link_name = link; symbolic; force }))
     | _ -> None)
  | "--" :: rest -> parse flags positional true rest
  | arg :: rest when not dd && (arg = "-s" || arg = "-f" || arg = "-n") ->
    parse (arg :: flags) positional dd rest
  | arg :: rest when not dd && arg = "--symbolic" ->
    parse ("-s" :: flags) positional dd rest
  | arg :: rest when not dd && arg = "--force" ->
    parse ("-f" :: flags) positional dd rest
  | arg :: rest when not dd && String.length arg > 2 && arg.[0] = '-' && arg.[1] <> '-' ->
    parse flags positional dd rest
  | arg :: rest ->
    parse flags (positional @ [ arg ]) dd rest
in
parse [] [] false args|}
    ; no_expand_combined = false
    }
  ; { name = "Touch"
    ; anon_pattern = "Touch { files; no_create; time }"
    ; bind_pattern = "Touch { files; no_create; time }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let flag_args =
        (if no_create then [ "-c" ] else [])
        @ (match time with
           | Some `Access -> [ "-a" ]
           | Some `Modify -> [ "-m" ]
           | None -> [])
      in
      let all_args = flag_args @ files in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Touch
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) all_args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Touch"
    ; parse_body =
        Some
          {|
let rec parse flags positional dd = function
  | [] ->
    let no_create = List.mem "-c" flags in
    let time =
      if List.mem "-a" flags then Some `Access
      else if List.mem "-m" flags then Some `Modify
      else None
    in
    (match positional with
     | _ :: _ ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Touch { files = positional; no_create; time }))
     | [] -> None)
  | "--" :: rest -> parse flags positional true rest
  | arg :: rest when not dd && (arg = "-c" || arg = "-a" || arg = "-m" || arg = "-r" || arg = "-t") ->
    parse (arg :: flags) positional dd rest
  | arg :: _val :: rest when not dd && (arg = "-r" || arg = "-t") ->
    parse (arg :: flags) positional dd rest
  | arg :: rest when not dd && String.length arg > 2 && arg.[0] = '-' && arg.[1] <> '-' ->
    parse flags positional dd rest
  | arg :: rest ->
    parse flags (positional @ [ arg ]) dd rest
in
parse [] [] false args|}
    ; no_expand_combined = true
    }
  ; { name = "Tee"
    ; anon_pattern = "Tee { files; append }"
    ; bind_pattern = "Tee { files; append }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let flag_args = if append then [ "-a" ] else [] in
      let all_args = flag_args @ files in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Tee
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) all_args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Tee"
    ; parse_body =
        Some
          {|
let rec parse append positional dd = function
  | [] ->
    (match positional with
     | _ :: _ ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Tee { files = positional; append }))
     | [] -> None)
  | "--" :: rest -> parse append positional true rest
  | arg :: rest when not dd && arg = "-a" ->
    parse true positional dd rest
  | arg :: rest when not dd && String.length arg > 2 && arg.[0] = '-' && arg.[1] <> '-' ->
    parse append positional dd rest
  | arg :: rest ->
    parse append (positional @ [ arg ]) dd rest
in
parse false [] false args|}
    ; no_expand_combined = true
    }
  ; { name = "Awk"
    ; anon_pattern = "Awk { program; files }"
    ; bind_pattern = "Awk { program; files }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let all_args = program :: files in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Awk
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) all_args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Awk"
    ; parse_body =
        Some
          {|
let rec parse flags program files dd = function
  | [] ->
    (match program with
     | Some prog ->
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Awk { program = prog; files = List.rev files }))
     | None -> None)
  | "--" :: rest -> parse flags program files true rest
  | arg :: _val :: rest when not dd && (arg = "-F" || arg = "-v" || arg = "-f" || arg = "-e") ->
    parse (arg :: _val :: flags) program files dd rest
  | arg :: rest when not dd && arg = "--re-interval" ->
    parse (arg :: flags) program files dd rest
  | arg :: rest when not dd && String.length arg > 1 && arg.[0] = '-' && arg.[1] <> '-' ->
    parse (arg :: flags) program files dd rest
  | arg :: rest ->
    (match program with
     | None -> parse flags (Some arg) files dd rest
     | Some _ -> parse flags program (arg :: files) dd rest)
in
parse [] None [] false args|}
    ; no_expand_combined = true
    }
  ; { name = "Xargs"
    ; anon_pattern = "Xargs { command; args; null_terminated; max_args }"
    ; bind_pattern = "Xargs { command; args; null_terminated; max_args }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let flag_args =
        (if null_terminated then [ "-0" ] else [])
        @ (match max_args with Some n -> [ "-n"; string_of_int n ] | None -> [])
      in
      let all_args = flag_args @ [ command ] @ args in
      { Shell_ir.bin = Exec_program.of_known Exec_program.Xargs
      ; args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) all_args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    ; bin_variant = Some "Xargs"
    ; parse_body =
        Some
          {|
let rec parse flags positional dd = function
  | [] ->
    (match positional with
     | cmd :: rest ->
       let null_terminated = List.mem "-0" flags in
       let max_args =
         let rec find_n = function
           | "-n" :: n :: _ -> (try Some (int_of_string n) with _ -> None)
           | _ :: tl -> find_n tl
           | [] -> None
         in
         find_n flags
       in
       Some (Shell_ir_typed_types.W (Shell_ir_typed_types.Xargs { command = cmd; args = rest; null_terminated; max_args }))
     | [] -> None)
  | "--" :: rest -> parse flags positional true rest
  | arg :: rest when not dd && arg = "-0" ->
    parse (arg :: flags) positional dd rest
  | arg :: _n :: rest when not dd && arg = "-n" ->
    parse (arg :: _n :: flags) positional dd rest
  | arg :: rest ->
    parse flags (positional @ [ arg ]) dd rest
in
parse [] [] false args|}
    ; no_expand_combined = true
    }
  ; { name = "Generic"
    ; anon_pattern = "Generic _"
    ; bind_pattern = "Generic simple"
    ; risk = "`Privileged"
    ; sandbox = "`Host"
    ; to_simple_body = " simple"
    ; bin_variant = None
    ; parse_body = None
    ; no_expand_combined = false
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

(* RFC-0208 P1: exhaustive Generic discriminator. Generated (not
   hand-written with a catch-all) so warning 4 stays satisfied and a new
   constructor forces an explicit [false] arm here rather than silently
   counting as a typed hit. *)
let emit_is_generic buf spec =
  Buffer.add_string
    buf
    "let gen_is_generic : Shell_ir_typed_types.wrapped -> bool = function\n";
  List.iter
    (fun c ->
       Buffer.add_string
         buf
         (Printf.sprintf
            "  | Shell_ir_typed_types.W (Shell_ir_typed_types.%s) -> %b\n"
            c.anon_pattern
            (c.name = "Generic")))
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
    Long flags (--foo), flag+value (-n5), bare "-", and everything after [--] are unchanged.
    Length capped at 4 to avoid expanding flag+value forms like ["-ePATTERN"]. *)
let expand_combined_short_flags (args : string list) : string list =
  let rec go = function
    | [] -> []
    | "--" :: rest -> "--" :: rest  (* POSIX end-of-options: pass remainder untouched *)
    | arg :: rest ->
      let expanded =
        if String.length arg >= 3
           && String.length arg <= 4
           && Char.code arg.[0] = Char.code '-'
           && Char.code arg.[1] <> Char.code '-'
           && String.for_all (fun c -> (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))
                (String.sub arg 1 (String.length arg - 1))
        then
          List.init (String.length arg - 1) (fun i ->
            Printf.sprintf "-%c" arg.[i + 1])
        else [ arg ]
      in
      expanded @ go rest
  in
  go args
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
           Some (subcmd, c.name, c.no_expand_combined)
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
    ; "Psql"; "Mysql"; "Mariadb"; "Cockroach"
    ; "Sudo"; "Su"; "Chmod"; "Chown"; "Rm"; "Dd"; "Mkfs"
    ; "Shutdown"; "Reboot"; "Halt"; "Poweroff"
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
    (fun (subcmd_name, ctor_name, no_expand) ->
       let parse_fn = Printf.sprintf "gen_parse_%s" ctor_name in
       let arg_expr =
         if no_expand then "rest" else "(expand_combined_short_flags rest)"
       in
       Buffer.add_string
         buf
         (Printf.sprintf
            "           | %S :: rest -> %s %s\n" subcmd_name parse_fn arg_expr))
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
    ; "Touch"; "Tee"; "Awk"; "Xargs"
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
  emit_is_generic buf shell_ir_typed_spec;
  emit_sandbox buf shell_ir_typed_spec;
  emit_to_simple buf shell_ir_typed_spec;
  emit_parse_functions buf shell_ir_typed_spec;
  emit_flag_expander buf;
  emit_of_simple buf shell_ir_typed_spec;
  emit_constructor_names buf shell_ir_typed_spec;
  print_string (Buffer.contents buf)
;;
