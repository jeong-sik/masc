(** Shell_ir_typed — GADT-based typed command IR implementation.

    Coexists with the untyped [Shell_ir.t].  Each constructor records the
    command's input type, output type, risk level, and sandbox requirement
    in the GADT parameters so that policy dispatch can be indexed by the
    compiler.

    Type definitions live in [Shell_ir_typed_types] to break the
    circular dependency with [Shell_ir_typed_walkers_gen] (which
    deconstructs these types in its generated match arms). *)

include Shell_ir_typed_types

(* ---------------------------------------------------------------------- *)
(* of_simple — delegated to generated walker (RFC-0054 PR-4) *)

let of_simple : Shell_ir.simple -> wrapped = Shell_ir_typed_walkers_gen.gen_of_simple

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
  | W (Find { path; name; type_ }) ->
    Format.fprintf
      fmt
      "Find(path=%s, name=%a, type_=%a)"
      path
      (Format.pp_print_option Format.pp_print_string)
      name
      (Format.pp_print_option (fun fmt t ->
         Format.pp_print_string fmt (match t with `File -> "f" | `Dir -> "d")))
      type_
  | W (Head { path; lines }) ->
    Format.fprintf fmt "Head(path=%s, lines=%d)" path lines
  | W (Tail { path; lines }) ->
    Format.fprintf fmt "Tail(path=%s, lines=%d)" path lines
  | W (Grep { pattern; path; recursive; case_sensitive }) ->
    Format.fprintf
      fmt
      "Grep(pattern=%s, path=%a, recursive=%b, case_sensitive=%b)"
      pattern
      (Format.pp_print_option Format.pp_print_string)
      path
      recursive
      case_sensitive
  | W (Mkdir { path; parents }) ->
    Format.fprintf fmt "Mkdir(path=%s, parents=%b)" path parents
  | W (Wc { path; mode }) ->
    Format.fprintf
      fmt
      "Wc(path=%s, mode=%s)"
      path
      (match mode with `Lines -> "lines" | `Words -> "words" | `Chars -> "chars")
  | W (Git_diff { stat; cached; paths }) ->
    Format.fprintf
      fmt
      "Git_diff(stat=%b, cached=%b, paths=%a)"
      stat
      cached
      (Format.pp_print_list Format.pp_print_string)
      paths
  | W (Git_log { oneline; max_count }) ->
    Format.fprintf
      fmt
      "Git_log(oneline=%b, max_count=%a)"
      oneline
      (Format.pp_print_option Format.pp_print_int)
      max_count
  | W (Git_commit { message; amend }) ->
    Format.fprintf fmt "Git_commit(message=%s, amend=%b)" message amend
  | W (Git_push { force; force_with_lease; set_upstream; remote; branch }) ->
    Format.fprintf
      fmt
      "Git_push(force=%b, force_with_lease=%b, set_upstream=%b, remote=%a, branch=%a)"
      force
      force_with_lease
      set_upstream
      (Format.pp_print_option Format.pp_print_string)
      remote
      (Format.pp_print_option Format.pp_print_string)
      branch
  | W (Git_pull { rebase; remote; branch }) ->
    Format.fprintf
      fmt
      "Git_pull(rebase=%b, remote=%a, branch=%a)"
      rebase
      (Format.pp_print_option Format.pp_print_string)
      remote
      (Format.pp_print_option Format.pp_print_string)
      branch
  | W (Pwd ()) -> Format.fprintf fmt "Pwd"
  | W (Echo { args }) ->
    Format.fprintf
      fmt
      "Echo(args=%a)"
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt " ")
         Format.pp_print_string)
      args
  | W (Which { names }) ->
    Format.fprintf
      fmt
      "Which(names=%a)"
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt " ")
         Format.pp_print_string)
      names
  | W (Sort { reverse; numeric; unique; key; file }) ->
    Format.fprintf
      fmt
      "Sort(reverse=%b, numeric=%b, unique=%b, key=%a, file=%a)"
      reverse
      numeric
      unique
      (Format.pp_print_option Format.pp_print_int)
      key
      (Format.pp_print_option Format.pp_print_string)
      file
  | W (Cut { delimiter; fields; file }) ->
    Format.fprintf
      fmt
      "Cut(delimiter=%a, fields=%s, file=%a)"
      (Format.pp_print_option Format.pp_print_string)
      delimiter
      fields
      (Format.pp_print_option Format.pp_print_string)
      file
  | W (Tr { set1; set2; delete; squeeze }) ->
    Format.fprintf
      fmt
      "Tr(set1=%s, set2=%a, delete=%b, squeeze=%b)"
      set1
      (Format.pp_print_option Format.pp_print_string)
      set2
      delete
      squeeze
  | W (Date { format; utc }) ->
    Format.fprintf
      fmt
      "Date(format=%a, utc=%b)"
      (Format.pp_print_option Format.pp_print_string)
      format
      utc
  | W (Env ()) -> Format.fprintf fmt "Env"
  | W (Printenv { name }) ->
    Format.fprintf
      fmt
      "Printenv(name=%a)"
      (Format.pp_print_option Format.pp_print_string)
      name
  | W (Uniq { count; duplicates; unique; file }) ->
    Format.fprintf
      fmt
      "Uniq(count=%b, duplicates=%b, unique=%b, file=%a)"
      count
      duplicates
      unique
      (Format.pp_print_option Format.pp_print_string)
      file
  | W (Basename { path; suffix }) ->
    Format.fprintf
      fmt
      "Basename(path=%s, suffix=%a)"
      path
      (Format.pp_print_option Format.pp_print_string)
      suffix
  | W (Dirname { path }) -> Format.fprintf fmt "Dirname(path=%s)" path
  | W (Test { expression }) ->
    Format.fprintf
      fmt
      "Test(expression=%a)"
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt " ")
         Format.pp_print_string)
      expression
  | W (Stat { format; path }) ->
    Format.fprintf
      fmt
      "Stat(format=%a, path=%s)"
      (Format.pp_print_option Format.pp_print_string)
      format
      path
  | W (Hostname { short }) ->
    Format.fprintf fmt "Hostname(short=%b)" short
  | W (Whoami ()) -> Format.fprintf fmt "Whoami"
  | W (Du { path; human_readable; summary; max_depth }) ->
    Format.fprintf
      fmt
      "Du(path=%a, h=%b, s=%b, max_depth=%a)"
      (Format.pp_print_option Format.pp_print_string)
      path
      human_readable
      summary
      (Format.pp_print_option Format.pp_print_int)
      max_depth
  | W (Df { path; human_readable; filesystem_type }) ->
    Format.fprintf
      fmt
      "Df(path=%a, h=%b, fs_type=%a)"
      (Format.pp_print_option Format.pp_print_string)
      path
      human_readable
      (Format.pp_print_option Format.pp_print_string)
      filesystem_type
  | W (File { path; mime; brief }) ->
    Format.fprintf fmt "File(path=%s, mime=%b, brief=%b)" path mime brief
  | W (Printf { format; args }) ->
    Format.fprintf
      fmt
      "Printf(format=%s, args=%a)"
      format
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt " ")
         Format.pp_print_string)
      args
  | W (Uname { all; kernel_name; release; machine }) ->
    Format.fprintf
      fmt
      "Uname(a=%b, s=%b, r=%b, m=%b)"
      all
      kernel_name
      release
      machine
  | W (Ps { all; full; user }) ->
    Format.fprintf
      fmt
      "Ps(all=%b, full=%b, user=%a)"
      all
      full
      (Format.pp_print_option Format.pp_print_string)
      user
  | W (Tty ()) -> Format.fprintf fmt "Tty"
  | W (Wget { url; output }) ->
    Format.fprintf
      fmt
      "Wget(url=%s, output=%a)"
      url
      (Format.pp_print_option Format.pp_print_string)
      output
  | W (Ssh { host; user; command }) ->
    Format.fprintf
      fmt
      "Ssh(host=%s, user=%a, command=%a)"
      host
      (Format.pp_print_option Format.pp_print_string)
      user
      (Format.pp_print_option Format.pp_print_string)
      command
  | W (Scp { source; dest; recursive }) ->
    Format.fprintf fmt "Scp(source=%s, dest=%s, recursive=%b)" source dest recursive
  | W (Tar { action; archive; paths; gzip }) ->
    Format.fprintf
      fmt
      "Tar(action=%s, archive=%s, paths=%a, gzip=%b)"
      (match action with `Create -> "create" | `Extract -> "extract" | `List -> "list")
      archive
      (Format.pp_print_list Format.pp_print_string)
      paths
      gzip
  | W (Make { target; jobs }) ->
    Format.fprintf
      fmt
      "Make(target=%a, jobs=%a)"
      (Format.pp_print_option Format.pp_print_string)
      target
      (Format.pp_print_option Format.pp_print_int)
      jobs
  | W (Diff { file1; file2; unified }) ->
    Format.fprintf fmt "Diff(file1=%s, file2=%s, unified=%b)" file1 file2 unified
  | W (Sed { expression; file; in_place }) ->
    Format.fprintf fmt "Sed(expression=%s, file=%s, in_place=%b)" expression file in_place
  | W (Rsync { source; dest; flags }) ->
    Format.fprintf fmt "Rsync(source=%s, dest=%s, flags=%a)" source dest
      (Format.pp_print_list Format.pp_print_string) flags
  | W (Node { script; args }) ->
    Format.fprintf fmt "Node(script=%s, args=%a)" script
      (Format.pp_print_list Format.pp_print_string) args
  | W (Python { script; args }) ->
    Format.fprintf fmt "Python(script=%s, args=%a)" script
      (Format.pp_print_list Format.pp_print_string) args
  | W (Python3 { script; args }) ->
    Format.fprintf fmt "Python3(script=%s, args=%a)" script
      (Format.pp_print_list Format.pp_print_string) args
  | W (Pip { subcommand; packages }) ->
    Format.fprintf fmt "Pip(subcommand=%s, packages=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) packages
  | W (Patch { file; patchfile; strip; reverse }) ->
    Format.fprintf fmt "Patch(file=%a, patchfile=%a, strip=%d, reverse=%b)"
      (Format.pp_print_option Format.pp_print_string) file
      (Format.pp_print_option Format.pp_print_string) patchfile strip reverse
  | W (Npm { subcommand; args }) ->
    Format.fprintf fmt "Npm(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Cargo { subcommand; args }) ->
    Format.fprintf fmt "Cargo(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Go { subcommand; args }) ->
    Format.fprintf fmt "Go(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Gh { subcommand; args }) ->
    Format.fprintf fmt "Gh(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Chmod { mode; path }) ->
    Format.fprintf fmt "Chmod(mode=%s, path=%s)" mode path
  | W (Chown { owner; path }) ->
    Format.fprintf fmt "Chown(owner=%s, path=%s)" owner path
  | W (Docker { subcommand; args }) ->
    Format.fprintf fmt "Docker(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Opam { subcommand; args }) ->
    Format.fprintf fmt "Opam(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Npx { subcommand; args }) ->
    Format.fprintf fmt "Npx(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Yarn { subcommand; args }) ->
    Format.fprintf fmt "Yarn(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Pnpm { subcommand; args }) ->
    Format.fprintf fmt "Pnpm(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Uv { subcommand; args }) ->
    Format.fprintf fmt "Uv(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Glab { subcommand; args }) ->
    Format.fprintf fmt "Glab(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Pytest { subcommand; args }) ->
    Format.fprintf fmt "Pytest(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Terminal_notifier { title; message }) ->
    Format.fprintf fmt "Terminal_notifier(title=%s, message=%s)" title message
  | W (Ruff { subcommand; args }) ->
    Format.fprintf fmt "Ruff(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Pyright { subcommand; args }) ->
    Format.fprintf fmt "Pyright(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Tsc { subcommand; args }) ->
    Format.fprintf fmt "Tsc(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Ocamlfind { subcommand; args }) ->
    Format.fprintf fmt "Ocamlfind(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Rustc { subcommand; args }) ->
    Format.fprintf fmt "Rustc(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Gofmt { subcommand; args }) ->
    Format.fprintf fmt "Gofmt(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Gradle { subcommand; args }) ->
    Format.fprintf fmt "Gradle(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Ninja { subcommand; args }) ->
    Format.fprintf fmt "Ninja(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Java { subcommand; args }) ->
    Format.fprintf fmt "Java(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Javac { subcommand; args }) ->
    Format.fprintf fmt "Javac(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Mvn { subcommand; args }) ->
    Format.fprintf fmt "Mvn(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Cmake { subcommand; args }) ->
    Format.fprintf fmt "Cmake(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Dune_local_sh { subcommand; args }) ->
    Format.fprintf fmt "Dune_local_sh(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Osascript { subcommand; args }) ->
    Format.fprintf fmt "Osascript(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Play { subcommand; args }) ->
    Format.fprintf fmt "Play(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Rec { subcommand; args }) ->
    Format.fprintf fmt "Rec(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Ffplay { subcommand; args }) ->
    Format.fprintf fmt "Ffplay(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Mpg123 { subcommand; args }) ->
    Format.fprintf fmt "Mpg123(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Open { subcommand; args }) ->
    Format.fprintf fmt "Open(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Generic s) -> Format.fprintf fmt "Generic(%a)" Shell_ir.pp (Shell_ir.Simple s)
;;
