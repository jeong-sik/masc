(* RFC-0054 PR-3 + PR-4 — codegen-based walker generator for
   [lib/exec/shell_ir_typed.ml].

   Approach: emits OCaml source text to stdout. A [dune (rule ...)] in
   [lib/exec/dune] runs this binary at build time and writes the output
   as [shell_ir_typed_walkers_gen.ml]. The standard parser handles the
   generated file — no ppxlib involvement, so the AST-vs-source
   divergence that broke RFC-0054 PR-1 / PR-1b is impossible here.

   PR-3 added [gen_risk] / [gen_sandbox] for parallel verification.
   PR-4 adds [gen_to_simple] (typed → untyped). The hand-written
   [Shell_ir_typed.to_simple] stays in place; the golden test
   [test_shell_ir_walkers_gen.ml] asserts byte-for-byte equivalence
   across all 9 constructors. PR-5 retires the hand-written walkers. *)

(* ─── Spec: per-constructor metadata ─────────────────────────────── *)

type ctor =
  { name : string  (* OCaml constructor name *)
  ; anon_pattern : string  (* match pattern under [W (...)], anonymous fields *)
  ; risk : string  (* polymorphic-variant value *)
  ; sandbox : string  (* polymorphic-variant value *)
  ; to_simple_body : string
        (* OCaml expression returning Shell_ir.simple, given the
           field-binding pattern provides the constructor's payload.
           [arg_of_string] is inlined as [Shell_ir.Lit]; module names
           are unqualified inside masc_exec. *)
  ; bind_pattern : string
        (* match pattern that binds the constructor's payload, e.g.
           "Ls { path; flags }". Used for [gen_to_simple]. *)
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
      { Shell_ir.bin = Result.get_ok (Bin.of_string "ls")
      ; args = List.map (fun s -> Shell_ir.Lit s) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    }
  ; { name = "Cat"
    ; anon_pattern = "Cat _"
    ; bind_pattern = "Cat { path }"
    ; risk = "`Safe"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      { Shell_ir.bin = Result.get_ok (Bin.of_string "cat")
      ; args = [ Shell_ir.Lit path ]
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
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
      { Shell_ir.bin = Result.get_ok (Bin.of_string "rg")
      ; args = List.map (fun s -> Shell_ir.Lit s) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    }
  ; { name = "Git_status"
    ; anon_pattern = "Git_status _"
    ; bind_pattern = "Git_status { short }"
    ; risk = "`Audited"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      let args = if short then [ "-s" ] else [] in
      { Shell_ir.bin = Result.get_ok (Bin.of_string "git")
      ; args = List.map (fun s -> Shell_ir.Lit s) ("status" :: args)
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
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
      { Shell_ir.bin = Result.get_ok (Bin.of_string "git")
      ; args = List.map (fun s -> Shell_ir.Lit s) ("clone" :: args)
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
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
      { Shell_ir.bin = Result.get_ok (Bin.of_string "curl")
      ; args = List.map (fun s -> Shell_ir.Lit s) args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
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
      { Shell_ir.bin = Result.get_ok (Bin.of_string "rm")
      ; args = List.map (fun s -> Shell_ir.Lit s) (flag_args @ paths)
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    }
  ; { name = "Sudo"
    ; anon_pattern = "Sudo _"
    ; bind_pattern = "Sudo { target_argv }"
    ; risk = "`Privileged"
    ; sandbox = "`Host"
    ; to_simple_body =
        {|
      { Shell_ir.bin = Result.get_ok (Bin.of_string "sudo")
      ; args = List.map (fun s -> Shell_ir.Lit s) target_argv
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }|}
    }
  ; { name = "Generic"
    ; anon_pattern = "Generic _"
    ; bind_pattern = "Generic simple"
    ; risk = "`Privileged"
    ; sandbox = "`Host"
    ; to_simple_body = " simple"
    }
  ]

(* ─── Generator: emit OCaml source ───────────────────────────────── *)

let emit_header buf =
  Buffer.add_string buf
    "(* RFC-0054 PR-3 + PR-4 — auto-generated by bin/gen_shell_ir_walkers.\n\
    \   DO NOT EDIT.  Regenerated from the spec on every build.\n\
    \   The spec lives in bin/gen_shell_ir_walkers.ml; the dune rule\n\
    \   in lib/exec/dune re-emits this file when the generator changes.\n\n\
    \   This file currently provides parallel-verification walkers\n\
    \   (gen_risk, gen_sandbox, gen_to_simple) that the test suite\n\
    \   compares against the hand-written equivalents in\n\
    \   [Shell_ir_typed]. PR-5 will retire the hand-written walkers in\n\
    \   favour of these. *)\n\n"

let emit_risk buf spec =
  Buffer.add_string buf
    "let gen_risk : Shell_ir_typed.wrapped -> Shell_ir_typed.risk = function\n";
  List.iter
    (fun c ->
      Buffer.add_string buf
        (Printf.sprintf
           "  | Shell_ir_typed.W (Shell_ir_typed.%s) -> %s\n"
           c.anon_pattern
           c.risk))
    spec;
  Buffer.add_string buf "\n"

let emit_sandbox buf spec =
  Buffer.add_string buf
    "let gen_sandbox : Shell_ir_typed.wrapped -> Shell_ir_typed.sandbox = \
     function\n";
  List.iter
    (fun c ->
      Buffer.add_string buf
        (Printf.sprintf
           "  | Shell_ir_typed.W (Shell_ir_typed.%s) -> %s\n"
           c.anon_pattern
           c.sandbox))
    spec;
  Buffer.add_string buf "\n"

let emit_to_simple buf spec =
  Buffer.add_string buf
    "let gen_to_simple\n\
    \  : type i o r s. (i, o, r, s) Shell_ir_typed.command -> Shell_ir.simple\n\
    \  = function\n";
  List.iter
    (fun c ->
      Buffer.add_string buf
        (Printf.sprintf
           "  | Shell_ir_typed.%s ->%s\n"
           c.bind_pattern
           c.to_simple_body))
    spec;
  Buffer.add_string buf "\n"

let emit_constructor_names buf spec =
  Buffer.add_string buf "let gen_constructor_names : string list =\n  [ ";
  let names = List.map (fun c -> Printf.sprintf "%S" c.name) spec in
  Buffer.add_string buf (String.concat "\n  ; " names);
  Buffer.add_string buf "\n  ]\n"

let () =
  let buf = Buffer.create 4096 in
  emit_header buf;
  emit_risk buf shell_ir_typed_spec;
  emit_sandbox buf shell_ir_typed_spec;
  emit_to_simple buf shell_ir_typed_spec;
  emit_constructor_names buf shell_ir_typed_spec;
  print_string (Buffer.contents buf)
