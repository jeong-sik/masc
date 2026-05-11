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
    (* [Bin.known] constructor that triggers this parser in
       [gen_of_simple], e.g. "Ls". [None] for [Generic] (fallback). *)
  ; parse_body : string option
    (* OCaml expression of type [string list -> Shell_ir_typed_types.wrapped option].
       The parameter is named [args].  For Git sub-commands [args] is
       the remainder after the sub-command has already been stripped.
       [None] for [Generic]. *)
  }

(* Order mirrors lib/exec/shell_ir_typed.{ml,mli} declaration order
   (Ls, Cat, Rg, Git_status, Git_clone, Curl, Rm, Sudo, Generic). *)
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
      { Shell_ir.bin = Bin.of_known Bin.Ls
      ; args = List.map (fun s -> Shell_ir.Lit s) args
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
      { Shell_ir.bin = Bin.of_known Bin.Cat
      ; args = [ Shell_ir.Lit path ]
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
      { Shell_ir.bin = Bin.of_known Bin.Rg
      ; args = List.map (fun s -> Shell_ir.Lit s) args
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
      { Shell_ir.bin = Bin.of_known Bin.Git
      ; args = List.map (fun s -> Shell_ir.Lit s) ("status" :: args)
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
        (if depth <> 1 then [ "--depth"; string_of_int depth ] else [])
        @ (match branch with None -> [] | Some b -> [ "-b"; b ])
        @ [ repo ]
      in
      { Shell_ir.bin = Bin.of_known Bin.Git
      ; args = List.map (fun s -> Shell_ir.Lit s) ("clone" :: args)
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
     | Some d -> parse d branch repo rest
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
parse 1 None None args|}
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
      { Shell_ir.bin = Bin.of_known Bin.Curl
      ; args = List.map (fun s -> Shell_ir.Lit s) args
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
      { Shell_ir.bin = Bin.of_known Bin.Rm
      ; args = List.map (fun s -> Shell_ir.Lit s) (flag_args @ paths)
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
      { Shell_ir.bin = Bin.of_known Bin.Sudo
      ; args = List.map (fun s -> Shell_ir.Lit s) target_argv
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
  Buffer.add_string
    buf
    "let gen_of_simple (s : Shell_ir.simple) : Shell_ir_typed_types.wrapped =\n\
    \  let generic () = Shell_ir_typed_types.W (Shell_ir_typed_types.Generic s) in\n\
    \  let lit_of_arg = function\n\
    \    | Shell_ir.Lit s -> Some s\n\
    \    | Shell_ir.Var _ | Shell_ir.Concat _ -> None\n\
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
    \        match Bin.known s.Shell_ir.bin with\n\
    \        | Some Bin.Ls -> gen_parse_Ls lit_argv\n\
    \        | Some Bin.Cat -> gen_parse_Cat lit_argv\n\
    \        | Some Bin.Rg -> gen_parse_Rg lit_argv\n\
    \        | Some Bin.Git ->\n\
    \          (match lit_argv with\n\
    \           | \"status\" :: rest -> gen_parse_Git_status rest\n\
    \           | \"clone\" :: rest -> gen_parse_Git_clone rest\n\
    \           | _ -> None)\n\
    \        | Some Bin.Curl -> gen_parse_Curl lit_argv\n\
    \        | Some Bin.Rm -> gen_parse_Rm lit_argv\n\
    \        | Some Bin.Sudo -> gen_parse_Sudo lit_argv\n\
    \        | Some\n\
    \            ( Bin.Pwd\n\
    \            | Bin.Echo\n\
    \            | Bin.Head\n\
    \            | Bin.Tail\n\
    \            | Bin.Grep\n\
    \            | Bin.Find\n\
    \            | Bin.Which\n\
    \            | Bin.Test\n\
    \            | Bin.Basename\n\
    \            | Bin.Dirname\n\
    \            | Bin.Stat\n\
    \            | Bin.Du\n\
    \            | Bin.Df\n\
    \            | Bin.Sort\n\
    \            | Bin.Uniq\n\
    \            | Bin.Wc\n\
    \            | Bin.Cut\n\
    \            | Bin.Tr\n\
    \            | Bin.Date\n\
    \            | Bin.Env\n\
    \            | Bin.Printenv\n\
    \            | Bin.Hostname\n\
    \            | Bin.Whoami\n\
    \            | Bin.Uname\n\
    \            | Bin.Ps\n\
    \            | Bin.Tty\n\
    \            | Bin.Docker\n\
    \            | Bin.Wget\n\
    \            | Bin.Ssh\n\
    \            | Bin.Scp\n\
    \            | Bin.Tar\n\
    \            | Bin.Rsync\n\
    \            | Bin.Make\n\
    \            | Bin.Cmake\n\
    \            | Bin.Npm\n\
    \            | Bin.Yarn\n\
    \            | Bin.Pnpm\n\
    \            | Bin.Pip\n\
    \            | Bin.Opam\n\
    \            | Bin.Cargo\n\
    \            | Bin.Gh\n\
    \            | Bin.Glab\n\
    \            | Bin.Terminal_notifier\n\
    \            | Bin.Osascript\n\
    \            | Bin.Play\n\
    \            | Bin.Rec\n\
    \            | Bin.Ffplay\n\
    \            | Bin.Mpg123\n\
    \            | Bin.Open\n\
    \            | Bin.Claude\n\
    \            | Bin.Gemini\n\
    \            | Bin.Codex\n\
    \            | Bin.Su\n\
    \            | Bin.Chmod\n\
    \            | Bin.Chown\n\
    \            | Bin.Dd\n\
    \            | Bin.Mkfs ) -> None\n\
    \        | None -> None\n\
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
