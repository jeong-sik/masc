(** Shell_ir_typed — GADT-based typed command IR implementation.

    Coexists with the untyped [Shell_ir.t].  Each constructor records the
    command's input type, output type, risk level, and sandbox requirement
    in the GADT parameters so that policy dispatch can be indexed by the
    compiler.

    Type definitions live in [Shell_ir_typed_types] to break the
    circular dependency with [Shell_ir_typed_walkers_gen] (which
    deconstructs these types in its generated match arms). *)

(* Helpers — mirror the pattern used in [Capability_check.all_lits_opt].  *)

include Shell_ir_typed_types

let lit_of_arg = function
  | Shell_ir.Lit s -> Some s
  | Shell_ir.Var _ | Shell_ir.Concat _ -> None
;;

let rec all_lits_opt (args : Shell_ir.arg list) : string list option =
  let rec go acc = function
    | [] -> Some (List.rev acc)
    | a :: rest ->
      (match lit_of_arg a with
       | Some s -> go (s :: acc) rest
       | None -> None)
  in
  go [] args
;;

(* ---------------------------------------------------------------------- *)
(* Individual parsers.
   Each returns [Some (W cmd)] on success or [None] when the argv shape
   does not match the constructor's grammar (caller falls back to
   [Generic]). *)

let parse_ls (args : string list) : wrapped option =
  let rec parse flags path = function
    | [] -> Some (W (Ls { path; flags = List.rev flags }))
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
  parse [] None args
;;

let parse_cat (args : string list) : wrapped option =
  match args with
  | [ path ] -> Some (W (Cat { path }))
  | _ -> None
;;

let parse_rg (args : string list) : wrapped option =
  let rec parse case_sensitive pattern path = function
    | [] ->
      (match pattern with
       | Some p -> Some (W (Rg { pattern = p; path; case_sensitive }))
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
  parse true None None args
;;

let parse_git_status (args : string list) : wrapped option =
  let rec parse short = function
    | [] -> Some (W (Git_status { short }))
    | "-s" :: rest | "--short" :: rest -> parse true rest
    | "--porcelain" :: rest -> parse true rest
    | _ :: _ -> None
  in
  parse false args
;;

let parse_git_clone (args : string list) : wrapped option =
  let rec parse depth branch repo = function
    | [] ->
      (match repo with
       | Some r -> Some (W (Git_clone { repo = r; branch; depth }))
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
  parse 1 None None args
;;

let parse_curl (args : string list) : wrapped option =
  let rec parse method_ headers body url = function
    | [] ->
      (match url with
       | Some u ->
         Some
           (W
              (Curl
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
  parse `GET [] None None args
;;

let parse_rm (args : string list) : wrapped option =
  let rec parse recursive force paths = function
    | [] ->
      (match paths with
       | [] -> None
       | _ -> Some (W (Rm { paths = List.rev paths; recursive; force })))
    | "-r" :: rest | "-R" :: rest | "--recursive" :: rest -> parse true force paths rest
    | "-f" :: rest | "--force" :: rest -> parse recursive true paths rest
    | arg :: rest ->
      if String.length arg > 0 && arg.[0] = '-'
      then None
      else parse recursive force (arg :: paths) rest
  in
  parse false false [] args
;;

let parse_sudo (args : string list) : wrapped option =
  match args with
  | [] -> None
  | args -> Some (W (Sudo { target_argv = args }))
;;

(* ---------------------------------------------------------------------- *)
(* of_simple
 *
 * Fail-closed: anything we cannot lift into a specific constructor
 * falls through to [W (Generic s)], which the [risk] extractor pins
 * to [`Privileged] and which [Capability_check_typed.of_command]
 * routes back to the untyped [Capability_check.of_simple] so that
 * env, redirect (Read_path / Write_path) and head capabilities are
 * preserved.  Never returning [None] removes a silent "no typed
 * command" outcome that callers could mishandle.
 *
 * Conditions that force the Generic fallback:
 *   - any non-literal arg (Var / Concat) — typed grammar only
 *     covers literal argv;
 *   - a non-empty [env] or [redirects] list — typed constructors
 *     do not carry env/redirect state, so retaining the original
 *     simple is the only way to keep the [Approval_policy] hooks
 *     (e.g. [find_write_escape]) wired correctly;
 *   - any binary kind we do not yet have a dedicated parser for
 *     (Docker, Ssh, Other_audited, unknown Safe / Privileged
 *     binaries) or sub-command we did not match (e.g. [git push]). *)

let typed_carries_no_extras (s : Shell_ir.simple) : bool =
  s.Shell_ir.env = [] && s.Shell_ir.redirects = []
;;

let of_simple (s : Shell_ir.simple) : wrapped =
  let generic () = W (Generic s) in
  if not (typed_carries_no_extras s)
  then generic ()
  else (
    match all_lits_opt s.Shell_ir.args with
    | None -> generic ()
    | Some lit_argv ->
      let parsed : wrapped option =
        match Bin.known s.Shell_ir.bin with
        | Some Bin.Ls -> parse_ls lit_argv
        | Some Bin.Cat -> parse_cat lit_argv
        | Some Bin.Rg -> parse_rg lit_argv
        | Some Bin.Git ->
          (match lit_argv with
           | "status" :: rest -> parse_git_status rest
           | "clone" :: rest -> parse_git_clone rest
           | _ -> None)
        | Some Bin.Curl -> parse_curl lit_argv
        | Some Bin.Rm -> parse_rm lit_argv
        | Some Bin.Sudo -> parse_sudo lit_argv
        | Some
            ( Bin.Pwd
            | Bin.Echo
            | Bin.Head
            | Bin.Tail
            | Bin.Grep
            | Bin.Find
            | Bin.Which
            | Bin.Test
            | Bin.Basename
            | Bin.Dirname
            | Bin.Stat
            | Bin.Du
            | Bin.Df
            | Bin.Sort
            | Bin.Uniq
            | Bin.Wc
            | Bin.Cut
            | Bin.Tr
            | Bin.Date
            | Bin.Env
            | Bin.Printenv
            | Bin.Hostname
            | Bin.Whoami
            | Bin.Uname
            | Bin.Ps
            | Bin.Tty
            | Bin.Docker
            | Bin.Wget
            | Bin.Ssh
            | Bin.Scp
            | Bin.Tar
            | Bin.Rsync
            | Bin.Make
            | Bin.Cmake
            | Bin.Npm
            | Bin.Yarn
            | Bin.Pnpm
            | Bin.Pip
            | Bin.Opam
            | Bin.Cargo
            | Bin.Gh
            | Bin.Glab
            | Bin.Terminal_notifier
            | Bin.Osascript
            | Bin.Play
            | Bin.Rec
            | Bin.Ffplay
            | Bin.Mpg123
            | Bin.Open
            | Bin.Claude
            | Bin.Gemini
            | Bin.Codex
            | Bin.Su
            | Bin.Chmod
            | Bin.Chown
            | Bin.Dd
            | Bin.Mkfs ) -> None
        | None -> None
      in
      (match parsed with
       | Some w -> w
       | None -> generic ()))
;;

(* ---------------------------------------------------------------------- *)
(* to_simple — delegated to generated walker (RFC-0054 PR-5) *)

let to_simple : type i o r s. (i, o, r, s) command -> Shell_ir.simple =
  Shell_ir_typed_walkers_gen.gen_to_simple
;;

(* ---------------------------------------------------------------------- *)
(* GADT extractors — delegated to generated walkers (RFC-0054 PR-5) *)

let risk = Shell_ir_typed_walkers_gen.gen_risk
let sandbox = Shell_ir_typed_walkers_gen.gen_sandbox

(* ---------------------------------------------------------------------- *)
(* Pretty-printer *)

let pp fmt = function
  | W (Ls { path; flags }) ->
    Format.fprintf
      fmt
      "Ls(path=%a, flags=%d)"
      (Format.pp_print_option Format.pp_print_string)
      path
      (List.length flags)
  | W (Cat { path }) -> Format.fprintf fmt "Cat(path=%s)" path
  | W (Rg { pattern; path; case_sensitive }) ->
    Format.fprintf
      fmt
      "Rg(pattern=%s, path=%a, case_sensitive=%b)"
      pattern
      (Format.pp_print_option Format.pp_print_string)
      path
      case_sensitive
  | W (Git_status { short }) -> Format.fprintf fmt "Git_status(short=%b)" short
  | W (Git_clone { repo; branch; depth }) ->
    Format.fprintf
      fmt
      "Git_clone(repo=%s, branch=%a, depth=%d)"
      repo
      (Format.pp_print_option Format.pp_print_string)
      branch
      depth
  | W (Curl { url; method_; headers; body }) ->
    Format.fprintf
      fmt
      "Curl(url=%s, method=%s, headers=%a, body=%a)"
      url
      (match method_ with
       | `GET -> "GET"
       | `POST -> "POST"
       | `PUT -> "PUT"
       | `DELETE -> "DELETE")
      (Format.pp_print_option (fun fmt hs ->
         List.iter (fun (k, v) -> Format.fprintf fmt "%s:%s " k v) hs))
      headers
      (Format.pp_print_option Format.pp_print_string)
      body
  | W (Rm { paths; recursive; force }) ->
    Format.fprintf
      fmt
      "Rm(paths=%a, recursive=%b, force=%b)"
      (Format.pp_print_list Format.pp_print_string)
      paths
      recursive
      force
  | W (Sudo { target_argv }) ->
    Format.fprintf
      fmt
      "Sudo(target_argv=%a)"
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt " ")
         Format.pp_print_string)
      target_argv
  | W (Generic s) -> Format.fprintf fmt "Generic(%a)" Shell_ir.pp (Shell_ir.Simple s)
;;
