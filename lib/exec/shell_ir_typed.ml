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
      "Git_clone(repo=%s, branch=%a, depth=%a)"
      repo
      (Format.pp_print_option Format.pp_print_string)
      branch
      (Format.pp_print_option Format.pp_print_int)
      depth
  | W (Curl { url; method_; headers; body; output_file; follow_redirects; insecure }) ->
    Format.fprintf
      fmt
      "Curl(url=%s, method=%s, headers=%a, body=%a, output=%a, follow=%b, insecure=%b)"
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
      (Format.pp_print_option Format.pp_print_string)
      output_file
      follow_redirects
      insecure
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
  | W (Find { path; name; type_; maxdepth }) ->
    Format.fprintf
      fmt
      "Find(path=%s, name=%a, type_=%a, maxdepth=%a)"
      path
      (Format.pp_print_option Format.pp_print_string)
      name
      (Format.pp_print_option (fun fmt t ->
         Format.pp_print_string fmt (match t with `File -> "f" | `Dir -> "d")))
      type_
      (Format.pp_print_option Format.pp_print_int)
      maxdepth
  | W (Head { path; lines }) ->
    Format.fprintf fmt "Head(path=%s, lines=%d)" path lines
  | W (Tail { path; lines }) ->
    Format.fprintf fmt "Tail(path=%s, lines=%d)" path lines
  | W (Grep { pattern; path; recursive; case_sensitive; files_with_matches }) ->
    Format.fprintf
      fmt
      "Grep(pattern=%s, path=%a, recursive=%b, case_sensitive=%b, files_with_matches=%b)"
      pattern
      (Format.pp_print_option Format.pp_print_string)
      path
      recursive
      case_sensitive
      files_with_matches
  | W (Mkdir { path; parents }) ->
    Format.fprintf fmt "Mkdir(path=%s, parents=%b)" path parents
  | W (Wc { path; mode }) ->
    Format.fprintf
      fmt
      "Wc(path=%s, mode=%a)"
      path
      (Format.pp_print_option (fun fmt m ->
         Format.pp_print_string fmt
           (match m with `Lines -> "lines" | `Words -> "words" | `Chars -> "chars")))
      mode
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
  | W (Uniq { count; duplicates; unique; skip_fields; skip_chars; file }) ->
    Format.fprintf
      fmt
      "Uniq(count=%b, duplicates=%b, unique=%b, skip_f=%a, skip_s=%a, file=%a)"
      count
      duplicates
      unique
      (Format.pp_print_option Format.pp_print_int)
      skip_fields
      (Format.pp_print_option Format.pp_print_int)
      skip_chars
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
  | W (Wget { url; output; continue_; no_check_certificate }) ->
    Format.fprintf
      fmt
      "Wget(url=%s, output=%a, continue=%b, no_check_cert=%b)"
      url
      (Format.pp_print_option Format.pp_print_string)
      output
      continue_
      no_check_certificate
  | W (Ssh { host; user; command; port; identity_file }) ->
    Format.fprintf
      fmt
      "Ssh(host=%s, user=%a, command=%a, port=%a, id=%a)"
      host
      (Format.pp_print_option Format.pp_print_string)
      user
      (Format.pp_print_option Format.pp_print_string)
      command
      (Format.pp_print_option Format.pp_print_int)
      port
      (Format.pp_print_option Format.pp_print_string)
      identity_file
  | W (Scp { source; dest; recursive; port }) ->
    Format.fprintf fmt "Scp(source=%s, dest=%s, recursive=%b, port=%a)" source dest recursive
      (Format.pp_print_option Format.pp_print_int) port
  | W (Tar { action; archive; paths; compression }) ->
    Format.fprintf
      fmt
      "Tar(action=%s, archive=%s, paths=%a, compression=%s)"
      (match action with `Create -> "create" | `Extract -> "extract" | `List -> "list")
      archive
      (Format.pp_print_list Format.pp_print_string)
      paths
      (match compression with
       | `None -> "none"
       | `Gzip -> "gzip"
       | `Bzip2 -> "bzip2"
       | `Xz -> "xz"
       | `Zstd -> "zstd")
  | W (Make { target; jobs }) ->
    Format.fprintf
      fmt
      "Make(target=%a, jobs=%a)"
      (Format.pp_print_option Format.pp_print_string)
      target
      (Format.pp_print_option Format.pp_print_int)
      jobs
  | W (Diff { file1; file2; unified; brief }) ->
    Format.fprintf fmt "Diff(file1=%s, file2=%s, unified=%b, brief=%b)" file1 file2 unified brief
  | W (Sed { expression; file; in_place; extended_regex; suppress_output }) ->
    Format.fprintf fmt "Sed(expression=%s, file=%s, in_place=%b, ext_re=%b, suppress=%b)" expression file in_place extended_regex suppress_output
  | W (Rsync { source; dest; archive; delete; dry_run; compress; flags }) ->
    Format.fprintf fmt "Rsync(source=%s, dest=%s, archive=%b, delete=%b, dry_run=%b, compress=%b, flags=%a)" source dest
      archive delete dry_run compress
      (Format.pp_print_list Format.pp_print_string) flags
  | W (Node { script; args; inline }) ->
    Format.fprintf fmt "Node(script=%s, args=%a, inline=%a)" script
      (Format.pp_print_list Format.pp_print_string) args
      (Format.pp_print_option Format.pp_print_string) inline
  | W (Python { script; args; inline }) ->
    Format.fprintf fmt "Python(script=%s, args=%a, inline=%a)" script
      (Format.pp_print_list Format.pp_print_string) args
      (Format.pp_print_option Format.pp_print_string) inline
  | W (Python3 { script; args; inline }) ->
    Format.fprintf fmt "Python3(script=%s, args=%a, inline=%a)" script
      (Format.pp_print_list Format.pp_print_string) args
      (Format.pp_print_option Format.pp_print_string) inline
  | W (Pip { subcommand; packages }) ->
    Format.fprintf fmt "Pip(subcommand=%s, packages=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) packages
  | W (Patch { file; patchfile; strip; reverse }) ->
    Format.fprintf fmt "Patch(file=%a, patchfile=%a, strip=%d, reverse=%b)"
      (Format.pp_print_option Format.pp_print_string) file
      (Format.pp_print_option Format.pp_print_string) patchfile strip reverse
  | W (Npm { subcommand; save_dev; global; force; rest }) ->
    Format.fprintf fmt "Npm(sub=%s, D=%b, g=%b, force=%b, rest=%a)" subcommand save_dev global force
      (Format.pp_print_list Format.pp_print_string) rest
  | W (Cargo { subcommand; release; verbose; features; rest }) ->
    Format.fprintf fmt "Cargo(sub=%s, rel=%b, verb=%b, feat=%a, rest=%a)" subcommand release verbose
      (Format.pp_print_option Format.pp_print_string) features
      (Format.pp_print_list Format.pp_print_string) rest
  | W (Go { subcommand; verbose; race; rest }) ->
    Format.fprintf fmt "Go(sub=%s, v=%b, race=%b, rest=%a)" subcommand verbose race
      (Format.pp_print_list Format.pp_print_string) rest
  | W (Gh { subcommand; action; draft; squash; delete_branch; body; title; rest }) ->
    Format.fprintf
      fmt
      "Gh(sub=%s, action=%a, draft=%b, squash=%b, del_br=%b, body=%a, title=%a, rest=%a)"
      subcommand
      (Format.pp_print_option Format.pp_print_string)
      action
      draft
      squash
      delete_branch
      (Format.pp_print_option Format.pp_print_string)
      body
      (Format.pp_print_option Format.pp_print_string)
      title
      (Format.pp_print_list Format.pp_print_string)
      rest
  | W (Chmod { mode; path; recursive }) ->
    Format.fprintf fmt "Chmod(mode=%s, path=%s, recursive=%b)" mode path recursive
  | W (Chown { owner; path; recursive }) ->
    Format.fprintf fmt "Chown(owner=%s, path=%s, recursive=%b)" owner path recursive
  | W (Docker { subcommand; rm; privileged; detach; rest }) ->
    Format.fprintf fmt "Docker(sub=%s, rm=%b, priv=%b, det=%b, rest=%a)" subcommand rm privileged detach
      (Format.pp_print_list Format.pp_print_string) rest
  | W (Opam { subcommand; yes; rest }) ->
    Format.fprintf fmt "Opam(sub=%s, yes=%b, rest=%a)" subcommand yes
      (Format.pp_print_list Format.pp_print_string) rest
  | W (Npx { subcommand; yes; rest }) ->
    Format.fprintf fmt "Npx(sub=%s, yes=%b, rest=%a)" subcommand yes
      (Format.pp_print_list Format.pp_print_string) rest
  | W (Yarn { subcommand; dev; global; production; frozen_lockfile; rest }) ->
    Format.fprintf fmt "Yarn(sub=%s, D=%b, g=%b, prod=%b, fl=%b, rest=%a)" subcommand dev global production frozen_lockfile
      (Format.pp_print_list Format.pp_print_string) rest
  | W (Pnpm { subcommand; save_dev; global; force; production; rest }) ->
    Format.fprintf fmt "Pnpm(sub=%s, D=%b, g=%b, force=%b, prod=%b, rest=%a)" subcommand save_dev global force production
      (Format.pp_print_list Format.pp_print_string) rest
  | W (Uv { subcommand; no_cache; system; rest }) ->
    Format.fprintf fmt "Uv(sub=%s, nc=%b, sys=%b, rest=%a)" subcommand no_cache system
      (Format.pp_print_list Format.pp_print_string) rest
  | W (Glab { subcommand; yes; force; rest }) ->
    Format.fprintf fmt "Glab(sub=%s, y=%b, f=%b, rest=%a)" subcommand yes force
      (Format.pp_print_list Format.pp_print_string) rest
  | W (Pytest { subcommand; verbose; exitfirst; rest }) ->
    Format.fprintf fmt "Pytest(sub=%s, v=%b, x=%b, rest=%a)" subcommand verbose exitfirst
      (Format.pp_print_list Format.pp_print_string) rest
  | W (Terminal_notifier { title; message }) ->
    Format.fprintf fmt "Terminal_notifier(title=%s, message=%s)" title message
  | W (Ruff { subcommand; fix; show_source; rest }) ->
    Format.fprintf fmt "Ruff(sub=%s, fix=%b, show_src=%b, rest=%a)" subcommand fix show_source
      (Format.pp_print_list Format.pp_print_string) rest
  | W (Pyright { subcommand; strict; rest }) ->
    Format.fprintf fmt "Pyright(sub=%s, strict=%b, rest=%a)" subcommand strict
      (Format.pp_print_list Format.pp_print_string) rest
  | W (Tsc { subcommand; no_emit; watch; rest }) ->
    Format.fprintf fmt "Tsc(sub=%s, noEmit=%b, watch=%b, rest=%a)" subcommand no_emit watch
      (Format.pp_print_list Format.pp_print_string) rest
  | W (Ocamlfind { subcommand; args }) ->
    Format.fprintf fmt "Ocamlfind(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Rustc { subcommand; optimize; test; rest }) ->
    Format.fprintf fmt "Rustc(sub=%s, opt=%b, test=%b, rest=%a)" subcommand optimize test
      (Format.pp_print_list Format.pp_print_string) rest
  | W (Gofmt { subcommand; write; list_files; rest }) ->
    Format.fprintf fmt "Gofmt(sub=%s, w=%b, l=%b, rest=%a)" subcommand write list_files
      (Format.pp_print_list Format.pp_print_string) rest
  | W (Gradle { subcommand; no_daemon; parallel; rest }) ->
    Format.fprintf fmt "Gradle(sub=%s, no_daemon=%b, parallel=%b, rest=%a)" subcommand no_daemon parallel
      (Format.pp_print_list Format.pp_print_string) rest
  | W (Ninja { subcommand; jobs; rest }) ->
    Format.fprintf fmt "Ninja(sub=%s, jobs=%a, rest=%a)" subcommand
      (fun fmt j -> match j with None -> Format.fprintf fmt "none" | Some n -> Format.fprintf fmt "%d" n) jobs
      (Format.pp_print_list Format.pp_print_string) rest
  | W (Java { subcommand; args }) ->
    Format.fprintf fmt "Java(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Javac { subcommand; args }) ->
    Format.fprintf fmt "Javac(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Mvn { subcommand; offline; batch_mode; quiet; args }) ->
    Format.fprintf fmt "Mvn(sub=%s, offline=%b, batch=%b, quiet=%b, args=%a)" subcommand offline batch_mode quiet
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
  | W (Su { subcommand; args }) ->
    Format.fprintf fmt "Su(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Dd { subcommand; args }) ->
    Format.fprintf fmt "Dd(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Mkfs { subcommand; args }) ->
    Format.fprintf fmt "Mkfs(subcommand=%s, args=%a)" subcommand
      (Format.pp_print_list Format.pp_print_string) args
  | W (Generic s) -> Format.fprintf fmt "Generic(%a)" Shell_ir.pp (Shell_ir.Simple s)
;;
