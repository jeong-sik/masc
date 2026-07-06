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

(* RFC-0208 P1: [true] for the [Generic] escape hatch, [false] for every
   typed constructor. Generated (exhaustive, no catch-all) so a new
   constructor forces an explicit arm. *)
let is_generic = Shell_ir_typed_walkers_gen.gen_is_generic

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
  | W (Git_clone { repo; branch; depth; dest_dir }) ->
    Format.fprintf
      fmt
      "Git_clone(repo=%s, branch=%a, depth=%a, dest_dir=%a)"
      repo
      (Format.pp_print_option Format.pp_print_string)
      branch
      (Format.pp_print_option Format.pp_print_int)
      depth
      (Format.pp_print_option Format.pp_print_string)
      dest_dir
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
  | W (Git_stash { action; message }) ->
    let action_s =
      match action with
      | `Push -> "push" | `Pop -> "pop" | `Drop -> "drop" | `List -> "list" | `Show -> "show"
    in
    Format.fprintf
      fmt
      "Git_stash(action=%s, message=%a)"
      action_s
      (Format.pp_print_option Format.pp_print_string)
      message
  | W (Git_rebase { interactive; onto; branch; continue_; abort }) ->
    Format.fprintf
      fmt
      "Git_rebase(interactive=%b, onto=%a, branch=%a, continue=%b, abort=%b)"
      interactive
      (Format.pp_print_option Format.pp_print_string)
      onto
      (Format.pp_print_option Format.pp_print_string)
      branch
      continue_
      abort
  | W (Git_merge { no_ff; squash; branch; abort; continue_ }) ->
    Format.fprintf
      fmt
      "Git_merge(no_ff=%b, squash=%b, branch=%s, abort=%b, continue=%b)"
      no_ff
      squash
      branch
      abort
      continue_
  | W (Git_branch { delete; list_all; rename }) ->
    Format.fprintf
      fmt
      "Git_branch(delete=%a, list_all=%b, rename=%a)"
      (Format.pp_print_option Format.pp_print_string)
      delete
      list_all
      (Format.pp_print_option Format.pp_print_string)
      rename
  | W (Git_checkout { new_branch; branch }) ->
    Format.fprintf
      fmt
      "Git_checkout(new_branch=%b, branch=%s)"
      new_branch
      branch
  | W (Git_fetch { remote; branch; prune; all }) ->
    Format.fprintf
      fmt
      "Git_fetch(remote=%a, branch=%a, prune=%b, all=%b)"
      (Format.pp_print_option Format.pp_print_string)
      remote
      (Format.pp_print_option Format.pp_print_string)
      branch
      prune
      all
  | W (Git_show { commit; stat }) ->
    Format.fprintf
      fmt
      "Git_show(commit=%s, stat=%b)"
      commit
      stat
  | W (Git_reset { mode; target }) ->
    let mode_str = match mode with `Soft -> "soft" | `Mixed -> "mixed" | `Hard -> "hard" in
    Format.fprintf
      fmt
      "Git_reset(mode=%s, target=%a)"
      mode_str
      (Format.pp_print_option Format.pp_print_string)
      target
  | W (Git_blame { file; range }) ->
    Format.fprintf
      fmt
      "Git_blame(file=%s, range=%a)"
      file
      (Format.pp_print_option Format.pp_print_string)
      range
  | W (Git_add { paths; force; update }) ->
    Format.fprintf
      fmt
      "Git_add(paths=%a, force=%b, update=%b)"
      (Format.pp_print_list Format.pp_print_string)
      paths
      force
      update
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
  | W (Make { target; jobs; directory; makefile; dry_run; keep_going; silent; always_make }) ->
    Format.fprintf
      fmt
      "Make(target=%a, jobs=%a, directory=%a, makefile=%a, dry_run=%b, keep_going=%b, silent=%b, always_make=%b)"
      (Format.pp_print_option Format.pp_print_string)
      target
      (Format.pp_print_option Format.pp_print_int)
      jobs
      (Format.pp_print_option Format.pp_print_string)
      directory
      (Format.pp_print_option Format.pp_print_string)
      makefile
      dry_run
      keep_going
      silent
      always_make
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
  | W (Gh { subcommand; action; draft; squash; delete_branch; body; title; search; state; rest }) ->
    Format.fprintf
      fmt
      "Gh(sub=%s, action=%a, draft=%b, squash=%b, del_br=%b, body=%a, title=%a, search=%a, state=%a, rest=%a)"
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
      (Format.pp_print_option Format.pp_print_string)
      search
      (Format.pp_print_option Format.pp_print_string)
      state
      (Format.pp_print_list Format.pp_print_string)
      rest
  | W (Chmod { mode; path; recursive }) ->
    Format.fprintf fmt "Chmod(mode=%s, path=%s, recursive=%b)" mode path recursive
  | W (Chown { owner; path; recursive }) ->
    Format.fprintf fmt "Chown(owner=%s, path=%s, recursive=%b)" owner path recursive
  | W (Docker { subcommand; rm; privileged; detach; name; network; volumes; publish; env_vars; workdir; platform; rest }) ->
    Format.fprintf fmt "Docker(sub=%s, rm=%b, priv=%b, det=%b, name=%a, net=%a, vols=%a, pubs=%a, envs=%a, wd=%a, plat=%a, rest=%a)"
      subcommand rm privileged detach
      (Format.pp_print_option Format.pp_print_string) name
      (Format.pp_print_option Format.pp_print_string) network
      (Format.pp_print_list Format.pp_print_string) volumes
      (Format.pp_print_list Format.pp_print_string) publish
      (Format.pp_print_list Format.pp_print_string) env_vars
      (Format.pp_print_option Format.pp_print_string) workdir
      (Format.pp_print_option Format.pp_print_string) platform
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
  | W (Cp { source; dest; recursive; force; preserve }) ->
    Format.fprintf fmt "Cp(source=%s, dest=%s, recursive=%b, force=%b, preserve=%b)"
      source dest recursive force preserve
  | W (Mv { source; dest; force; no_clobber }) ->
    Format.fprintf fmt "Mv(source=%s, dest=%s, force=%b, no_clobber=%b)"
      source dest force no_clobber
  | W (Ln { target; link_name; symbolic; force }) ->
    Format.fprintf fmt "Ln(target=%s, link_name=%s, symbolic=%b, force=%b)"
      target link_name symbolic force
  | W (Touch { files; no_create; time }) ->
    let time_str = match time with Some `Access -> "Access" | Some `Modify -> "Modify" | None -> "None" in
    Format.fprintf fmt "Touch(files=%a, no_create=%b, time=%s)"
      (Format.pp_print_list Format.pp_print_string) files no_create time_str
  | W (Tee { files; append }) ->
    Format.fprintf fmt "Tee(files=%a, append=%b)"
      (Format.pp_print_list Format.pp_print_string) files append
  | W (Awk { program; files }) ->
    Format.fprintf fmt "Awk(program=%s, files=%a)" program
      (Format.pp_print_list Format.pp_print_string) files
  | W (Xargs { command; args; null_terminated; max_args }) ->
    Format.fprintf fmt "Xargs(command=%s, args=%a, null_terminated=%b, max_args=%a)" command
      (Format.pp_print_list Format.pp_print_string) args
      null_terminated
      (Format.pp_print_option Format.pp_print_int) max_args
  | W (Generic s) -> Format.fprintf fmt "Generic(%a)" Shell_ir.pp (Shell_ir.Simple s)
;;

(* ---------------------------------------------------------------------- *)
(* Filesystem read-path extraction — exhaustive match, no catch-all.

   Returns local filesystem paths that the command will attempt to read.
   Empty for write commands, remote commands, and commands without path
   args.  The compiler enforces exhaustiveness so new constructors force
   an explicit decision here. *)

let path_args : wrapped -> string list = function
  | W (Ls { path = Some p; _ }) -> [ p ]
  | W (Ls { path = None; _ }) -> []
  | W (Cat { path }) -> [ path ]
  | W (Rg { path = Some p; _ }) -> [ p ]
  | W (Rg { path = None; _ }) -> []
  | W (Find { path; _ }) -> [ path ]
  | W (Head { path; _ }) -> [ path ]
  | W (Tail { path; _ }) -> [ path ]
  | W (Grep { path = Some p; _ }) -> [ p ]
  | W (Grep { path = None; _ }) -> []
  | W (Wc { path; _ }) -> [ path ]
  | W (Stat { path; _ }) -> [ path ]
  | W (Du { path = Some p; _ }) -> [ p ]
  | W (Du { path = None; _ }) -> []
  | W (Df { path = Some p; _ }) -> [ p ]
  | W (Df { path = None; _ }) -> []
  | W (File { path; _ }) -> [ path ]
  | W (Diff { file1; file2; _ }) -> [ file1; file2 ]
  | W (Awk { files; _ }) -> files
  | W (Sort { file = Some f; _ }) -> [ f ]
  | W (Sort { file = None; _ }) -> []
  | W (Cut { file = Some f; _ }) -> [ f ]
  | W (Cut { file = None; _ }) -> []
  | W (Uniq { file = Some f; _ }) -> [ f ]
  | W (Uniq { file = None; _ }) -> []
  (* Write / mixed — return paths but consumer filters by risk *)
  | W (Rm { paths; _ }) -> paths
  | W (Mkdir { path; _ }) -> [ path ]
  | W (Cp { source; dest; _ }) -> [ source; dest ]
  | W (Mv { source; dest; _ }) -> [ source; dest ]
  | W (Ln { target; link_name; _ }) -> [ target; link_name ]
  | W (Touch { files; _ }) -> files
  | W (Tee { files; _ }) -> files
  | W (Chmod { path; _ }) -> [ path ]
  | W (Chown { path; _ }) -> [ path ]
  | W (Tar { archive; paths; _ }) -> archive :: paths
  | W (Sed { file; _ }) -> [ file ]
  | W (Rsync { source; dest; _ }) -> [ source; dest ]
  | W (Git_blame { file; _ }) -> [ file ]
  | W (Git_diff { paths; _ }) -> paths
  | W (Git_add { paths; _ }) -> paths
  | W (Node { script; _ }) -> [ script ]
  | W (Python { script; _ }) -> [ script ]
  | W (Python3 { script; _ }) -> [ script ]
  | W (Patch { file = Some f; _ }) -> [ f ]
  | W (Patch { file = None; _ }) -> []
  | W (Make { directory = Some d; _ }) -> [ d ]
  | W (Make { directory = None; _ }) -> []
  | W (Git_clone { dest_dir = Some d; _ }) -> [ d ]
  (* Remote / URL — not local filesystem paths *)
  | W (Git_clone { dest_dir = None; _ }) -> []
  | W (Curl _) -> []
  | W (Wget _) -> []
  | W (Ssh _) -> []
  | W (Scp _) -> []
  (* No filesystem path arguments *)
  | W (Git_status _) -> []
  | W (Git_log _) -> []
  | W (Git_commit _) -> []
  | W (Git_push _) -> []
  | W (Git_pull _) -> []
  | W (Git_stash _) -> []
  | W (Git_rebase _) -> []
  | W (Git_merge _) -> []
  | W (Git_branch _) -> []
  | W (Git_checkout _) -> []
  | W (Git_fetch _) -> []
  | W (Git_show _) -> []
  | W (Git_reset _) -> []
  | W (Basename _) -> []
  | W (Dirname _) -> []
  | W (Pwd _) -> []
  | W (Echo _) -> []
  | W (Which _) -> []
  | W (Tr _) -> []
  | W (Date _) -> []
  | W (Env _) -> []
  | W (Printenv _) -> []
  | W (Test _) -> []
  | W (Hostname _) -> []
  | W (Whoami _) -> []
  | W (Printf _) -> []
  | W (Uname _) -> []
  | W (Ps _) -> []
  | W (Tty _) -> []
  | W (Sudo _) -> []
  | W (Docker _) -> []
  | W (Pip _) -> []
  | W (Npm _) -> []
  | W (Npx _) -> []
  | W (Yarn _) -> []
  | W (Pnpm _) -> []
  | W (Uv _) -> []
  | W (Gh _) -> []
  | W (Glab _) -> []
  | W (Pytest _) -> []
  | W (Terminal_notifier _) -> []
  | W (Ruff _) -> []
  | W (Pyright _) -> []
  | W (Tsc _) -> []
  | W (Cargo _) -> []
  | W (Go _) -> []
  | W (Ocamlfind _) -> []
  | W (Rustc _) -> []
  | W (Gofmt _) -> []
  | W (Gradle _) -> []
  | W (Ninja _) -> []
  | W (Java _) -> []
  | W (Javac _) -> []
  | W (Mvn _) -> []
  | W (Cmake _) -> []
  | W (Dune_local_sh _) -> []
  | W (Osascript _) -> []
  | W (Play _) -> []
  | W (Rec _) -> []
  | W (Ffplay _) -> []
  | W (Mpg123 _) -> []
  | W (Open _) -> []
  | W (Su _) -> []
  | W (Dd _) -> []
  | W (Mkfs _) -> []
  | W (Opam _) -> []
  | W (Xargs _) -> []
  | W (Generic _) -> []
;;
