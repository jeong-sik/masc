(** Shell_ir_risk — phantom-typed risk envelope for Shell IR.

    RFC-0160 S3: every Shell_ir.t that reaches dispatch carries a
    risk_class computed once at the classification boundary. Producers
    create [Shell_ir.t] unchanged; consumers wrap via [undecided],
    classify, then dispatch via [Exec_dispatch.dispatch_decided].

    Phantom types ([undecided] / [decided]) enforce at compile time
    that no IR reaches [dispatch_decided] without classification.
    Zero runtime overhead: the phantom parameter is erased. *)

type undecided
type decided

type risk_class =
  | R0_Read
  | R1_Reversible_mutation
  | R2_Irreversible
  | Destructive_protected

let string_of_risk_class = function
  | R0_Read -> "R0"
  | R1_Reversible_mutation -> "R1"
  | R2_Irreversible -> "R2"
  | Destructive_protected -> "Destructive_protected"
;;

let pp_risk_class fmt rc = Format.pp_print_string fmt (string_of_risk_class rc)

type _ t = T of Shell_ir.t

let undecided (ir : Shell_ir.t) : undecided t = T ir

let unwrap : type phase. phase t -> Shell_ir.t = fun (T ir) -> ir

type 'phase decided_ir = { ir : Shell_ir.t; risk : risk_class }

let risk_class (envelope : decided decided_ir) = envelope.risk
let is_r0 e = e.risk = R0_Read
let is_r1 e = e.risk = R1_Reversible_mutation
let is_r2 e = e.risk = R2_Irreversible
let is_destructive e = e.risk = Destructive_protected

(* --- Write sub-classification --------------------------------------- *)

let classify_write_detail (words : string list) : risk_class option =
  match words with
  | "git" :: sub :: _ ->
    (match sub with
     | "push" | "merge" | "rebase" | "commit" -> Some R1_Reversible_mutation
     | "reset" -> Some R2_Irreversible
     | "checkout" | "branch" | "tag" | "stash" | "clone" | "init" ->
       Some R1_Reversible_mutation
     | _ -> None)
  | ("npm" | "pnpm" | "yarn") :: _ -> Some R1_Reversible_mutation
  | "dune" :: _ -> Some R1_Reversible_mutation
  | "make" :: _ -> Some R1_Reversible_mutation
  | ("mv" | "cp" | "mkdir" | "touch" | "chmod" | "chown" | "chgrp"
    | "truncate" | "mktemp" | "tee") :: _ ->
    Some R1_Reversible_mutation
  | ("rm" | "rmdir" | "ln" | "unlink" | "install" | "dd" | "shred") :: _ ->
    Some R2_Irreversible
  | _ -> None

(* --- Repo-hosting CLI classification on IR words -------------------- *)

let repo_hosting_cli_irreversible_ops =
  [
    ("pr", [ "merge"; "ready" ]);
    ("repo", [ "delete"; "archive"; "transfer"; "rename" ]);
    ("release", [ "delete" ]);
    ("secret", [ "delete"; "remove" ]);
    ("ssh-key", [ "delete" ]);
    ("workflow", [ "disable" ]);
    ("auth", [ "logout"; "token" ]);
    ("gist", [ "delete" ]);
    ("ruleset", [ "delete" ]);
  ]
;;

let repo_hosting_cli_reversible_mutations =
  [
    ("pr",
     [ "create"; "close"; "reopen"; "edit"; "comment"; "review"; "lock";
       "unlock" ]);
    ("issue",
     [ "create"; "close"; "reopen"; "edit"; "comment"; "lock"; "unlock";
       "develop"; "pin"; "unpin" ]);
    ("label", [ "create"; "edit"; "delete"; "clone" ]);
    ("release", [ "create"; "edit"; "upload"; "download" ]);
    ("run", [ "cancel"; "rerun"; "watch" ]);
    ("cache", [ "delete" ]);
    ("gist", [ "create"; "edit"; "clone"; "rename" ]);
    ("repo",
     [ "create"; "clone"; "fork"; "edit"; "sync"; "set-default" ]);
    ("project",
     [ "create"; "edit"; "close"; "copy"; "link"; "unlink"; "field-create";
       "field-delete"; "item-add"; "item-archive"; "item-delete"; "item-edit" ]);
    ("workflow", [ "enable"; "run" ]);
    ("ruleset", [ "create"; "edit" ]);
  ]
;;

let in_table table command sub =
  List.exists
    (fun (c, subs) -> c = command && List.mem sub subs)
    table

let has_mutating_method parts =
  List.exists
    (fun tok ->
       let lower = String.lowercase_ascii tok in
       String.starts_with ~prefix:"-f" lower
       || String.starts_with ~prefix:"-f=" lower
       || String.starts_with ~prefix:"--field" lower
       || String.starts_with ~prefix:"--raw-field" lower)
    parts

let extract_method_from_parts parts =
  let rec find = function
    | [] -> None
    | "-X" :: m :: _ | "--method" :: m :: _ -> Some (String.uppercase_ascii m)
    | tok :: _rest
      when String.length tok > 3
           && String.starts_with ~prefix:"-X=" tok ->
      Some
        (String.uppercase_ascii (String.sub tok 3 (String.length tok - 3)))
    | tok :: _rest
      when String.length tok > 9
           && String.starts_with ~prefix:"--method=" tok ->
      Some
        (String.uppercase_ascii (String.sub tok 9 (String.length tok - 9)))
    (* The repo-hosting CLI accepts `-X<METHOD>` as a single token. Stress test
       2026-05-26: `gh api -XDELETE /repos/o/r` fell through to GET -> R0
       even though Execute, Shell IR, and worker-dev dispatch paths depend on
       this for the live gate. *)
    | tok :: _rest
      when String.length tok > 2
           && String.starts_with ~prefix:"-X" tok
           && tok.[2] <> '=' ->
      Some
        (String.uppercase_ascii (String.sub tok 2 (String.length tok - 2)))
    | _ :: rest -> find rest
  in
  find parts

(* GraphQL mutation fragments that mark a query body as R2 irreversible.
   Conservative deny-list. Keep this in Shell IR risk so Execute has one
   parser-owned source for command risk instead of a product-level GH family. *)
let repo_hosting_graphql_r2_fragments =
  [ "deletepullrequest"; "deleteissue"; "deletebranch"; "deleteref";
    "deleteproject"; "deletebranchprotectionrule";
    "removeouterfromorganization"; "transferrepository";
    "archiverepository";
    (* Forward-looking verb prefixes for mutations GitHub may introduce.
       Over-block here is acceptable — under-block (silent miss) is not. *)
    "purgerepository" ]

let strip_graphql_comments s =
  let buf = Buffer.create (String.length s) in
  let in_comment = ref false in
  String.iter
    (fun c ->
       if !in_comment then
         (if c = '\n' then begin in_comment := false; Buffer.add_char buf c end)
       else if c = '#' then in_comment := true
       else Buffer.add_char buf c)
    s;
  Buffer.contents buf

let body_contains_r2_mutation words =
  let body =
    String.concat " " words
    |> String.lowercase_ascii
    |> strip_graphql_comments
  in
  let m = String.length body in
  List.exists
    (fun frag ->
       let n = String.length frag in
       if n = 0 || n > m then false
       else
         let rec scan i =
           if i + n > m then false
           else if String.sub body i n = frag then true
           else scan (i + 1)
         in
         scan 0)
    repo_hosting_graphql_r2_fragments

let classify_repo_hosting_cli (words : string list) : risk_class =
  match words with
  | [] | [ _ ] -> R0_Read
  | _ :: command_raw :: rest ->
    let command = String.lowercase_ascii command_raw in
    (* Boolean-default sub extraction: any [-foo] is treated as a
       boolean flag (does NOT consume the next token). Previously
       `-q delete some-wf` had -q swallow "delete" and let the
       block-list miss. Stress test 2026-05-26: flag-bool-prefix-bypass.
       Trade-off: a real value-taking flag positioned before the subcmd
       may surface its value as sub. We accept over-block; silent
       bypass is unacceptable. *)
    let sub =
      let is_flag tok = String.length tok > 0 && tok.[0] = '-' in
      let rec first_non_flag = function
        | [] -> ""
        | tok :: tl ->
          if is_flag tok then first_non_flag tl
          else String.lowercase_ascii tok
      in
      first_non_flag rest
    in
    (* Path-unification: scan ALL positional tokens (not just sub) for
       any dangerous keyword belonging to this top-level command. A
       value token like `.` from `repo --jq . delete o/r` would be
       picked as sub but the real dangerous keyword is `delete` later
       in the list. *)
    let dangerous_subs_for_cmd =
      List.fold_left
        (fun acc (c, subs) -> if c = command then acc @ subs else acc)
        [] repo_hosting_cli_irreversible_ops
    in
    let positional_dangerous_hit =
      let is_flag tok = String.length tok > 0 && tok.[0] = '-' in
      List.exists
        (fun t ->
           not (is_flag t)
           && List.mem (String.lowercase_ascii t) dangerous_subs_for_cmd)
        rest
    in
    if in_table repo_hosting_cli_irreversible_ops command sub
       || positional_dangerous_hit
    then R2_Irreversible
    else if command = "api" then
      let method_ =
        match extract_method_from_parts words with
        | Some m -> m
        | None -> "GET"
      in
      if method_ = "DELETE" then R2_Irreversible
      else if sub = "graphql" then begin
        (* graphql endpoint always POSTs. Look inside the query body
           for known destructive mutation fragments; default to R1
           when none match (mutation is still a write). Stress test
           2026-05-26: deletePullRequest/purgeRepository previously
           returned R1 — silent miss. *)
        if body_contains_r2_mutation words then R2_Irreversible
        else R1_Reversible_mutation
      end
      else if List.mem method_ [ "POST"; "PUT"; "PATCH" ] then R1_Reversible_mutation
      else if has_mutating_method words then R1_Reversible_mutation
      else R0_Read
    else if in_table repo_hosting_cli_reversible_mutations command sub then R1_Reversible_mutation
    else R0_Read

(* --- Stage-word extraction (local copy; dependency direction prevents
    reference to Exec_policy_mutation_classifier in the top-level lib). --- *)

let literal_words_of_simple (simple : Shell_ir.simple) : string list option =
  let rec collect acc = function
    | [] -> Some (List.rev acc)
    | Shell_ir.Lit (a, _) :: rest -> collect (a :: acc) rest
    | Shell_ir.Concat _ :: _ | Shell_ir.Var _ :: _ -> None
  in
  match collect [] simple.args with
  | None -> None
  | Some args -> Some (Exec_program.to_string simple.bin :: args)
;;

let flat_stage_words (ir : Shell_ir.t) : string list =
  let rec collect acc = function
    | Shell_ir.Simple s ->
      (match literal_words_of_simple s with
       | Some ws -> ws :: acc
       | None -> acc)
    | Shell_ir.Pipeline stages ->
      List.fold_left collect acc stages
  in
  List.rev (collect [] ir) |> List.concat
;;

(* --- Write-level classification (pure, on word list) ---------------- *)

let is_write_operation (words : string list) =
  match words with
  | "git" :: sub :: _ ->
    List.mem
      sub
      [ "push"; "commit"; "merge"; "rebase"; "reset"; "checkout"; "branch";
        "tag"; "stash"; "clone"; "init" ]
  | "dune" :: sub :: _ -> List.mem sub [ "clean"; "promote" ]
  | "make" :: sub :: _ -> List.mem sub [ "clean"; "deploy"; "install"; "publish" ]
  | ("npm" | "pnpm" | "yarn") :: sub :: _ ->
    List.mem
      sub
      [ "add"; "install"; "link"; "prune"; "publish"; "remove"; "unlink";
        "update"; "up" ]
  | cmd_name :: _ ->
    List.mem
      cmd_name
      [ "mv"
      ; "cp"
      ; "mkdir"
      ; "touch"
      ; "chmod"
      ; "rm"
      ; "rmdir"
      ; "ln"
      ; "unlink"
      ; "install"
      ; "dd"
      ; "chown"
      ; "chgrp"
      ; "truncate"
      ; "mktemp"
      ; "tee"
      ; "shred"
      ]
  | [] -> false
;;

let is_short_option arg = String.length arg > 1 && arg.[0] = '-' && arg.[1] <> '-'
let has_short_flag flag arg = is_short_option arg && String.contains arg flag

let is_protected_branch_target arg =
  let target = String.lowercase_ascii arg in
  List.mem
    target
    [ "main"; "master"; "origin/main"; "origin/master";
      "refs/heads/main"; "refs/heads/master" ]
  || List.exists
       (fun suffix -> String.ends_with ~suffix target)
       [ ":main"; ":master"; ":origin/main"; ":origin/master";
         ":refs/heads/main"; ":refs/heads/master" ]
;;

let is_destructive_bash_operation (words : string list) =
  match words with
  | "git" :: "push" :: rest ->
    let has_force =
      List.exists
        (fun arg ->
           arg = "--force" || arg = "-f"
           || String.starts_with ~prefix:"--force-with-lease" arg)
        rest
    in
    has_force && List.exists is_protected_branch_target rest
  | "rm" :: rest ->
    let option_args =
      List.filter (fun arg -> String.length arg > 0 && arg.[0] = '-') rest
    in
    let has_recursive =
      List.exists
        (fun arg ->
           arg = "--recursive" || has_short_flag 'r' arg || has_short_flag 'R' arg)
        option_args
    in
    let has_force =
      List.exists (fun arg -> arg = "--force" || has_short_flag 'f' arg) option_args
    in
    has_recursive && has_force
  | _ -> false
;;

(* --- Word-list decision (pre-typed-GADT path) -----------------------

   Retained for the [Generic] escape hatch (env/redirect/$VAR/unknown
   bin), for [Pipeline]s, and as the differential baseline that
   [risk_of_typed] must never under-classify. *)

let classify_words (words : string list) : risk_class =
  if is_destructive_bash_operation words then Destructive_protected
  else if is_write_operation words then
    (match classify_write_detail words with
     | Some r -> r
     | None -> R2_Irreversible)
  else
    (match words with
     | "gh" :: _ -> classify_repo_hosting_cli words
     | _ -> R0_Read)
;;

(* --- Typed-GADT decision substrate (RFC-0160 §S1 completion) ----------

   [risk_of_typed] is the risk opinion implied by the typed command
   shape alone — the first decision path that reads the [Shell_ir_typed]
   GADT instead of re-flattening to a word list. [classify] combines it
   with the word-list floor ([classify_words]) by taking the stricter of
   the two, so the overall decision is monotone-safe by construction.

   The match is exhaustive (no [_ ->] catch-all): adding a constructor
   to [Shell_ir_typed_types.command] forces a compile error here, so a
   new typed command cannot reach dispatch without a risk decision.
   CLAUDE.md §"FSM Sparse Match" — every constructor named, no wildcard.

   Policy (2026-05-29, option B — monotone-safe, escalate dangerous
   gaps only): the type closes word-list holes it makes visible —
   [Sudo] (privilege escalation; the word-list head token was "sudo" so
   its "rm"/"git push" arms never fired -> silent R0), [Su] and [Mkfs]
   (R0 -> R2). Commands the word-list already classifies keep their risk
   (curl/sed/git pull stay R0; git push/commit stay R1; rm -rf protected
   stays Destructive). [Gh] and [Generic] return R0 here because the
   type cannot see their risk-bearing tokens (gh -X METHOD / graphql
   body live in [rest]); the word-list floor in [classify] supplies it.
   Dropping that floor is gated on the typed model subsuming it. *)

let npm_write_subcommands =
  [ "add"; "install"; "link"; "prune"; "publish"; "remove"; "unlink";
    "update"; "up" ]
;;

let risk_of_typed (w : Shell_ir_typed.wrapped) : risk_class =
  let open Shell_ir_typed in
  match w with
  (* --- read / inspection: R0_Read ----------------------------------- *)
  | W (Ls _) -> R0_Read
  | W (Cat _) -> R0_Read
  | W (Rg _) -> R0_Read
  | W (Find _) -> R0_Read
  | W (Head _) -> R0_Read
  | W (Tail _) -> R0_Read
  | W (Grep _) -> R0_Read
  | W (Wc _) -> R0_Read
  | W (Pwd _) -> R0_Read
  | W (Echo _) -> R0_Read
  | W (Which _) -> R0_Read
  | W (Sort _) -> R0_Read
  | W (Cut _) -> R0_Read
  | W (Tr _) -> R0_Read
  | W (Date _) -> R0_Read
  | W (Env _) -> R0_Read
  | W (Printenv _) -> R0_Read
  | W (Uniq _) -> R0_Read
  | W (Basename _) -> R0_Read
  | W (Dirname _) -> R0_Read
  | W (Test _) -> R0_Read
  | W (Stat _) -> R0_Read
  | W (Hostname _) -> R0_Read
  | W (Whoami _) -> R0_Read
  | W (Du _) -> R0_Read
  | W (Df _) -> R0_Read
  | W (File _) -> R0_Read
  | W (Printf _) -> R0_Read
  | W (Uname _) -> R0_Read
  | W (Ps _) -> R0_Read
  | W (Tty _) -> R0_Read
  | W (Diff _) -> R0_Read
  (* git read subcommands: R0 (parity with word-list) *)
  | W (Git_status _) -> R0_Read
  | W (Git_diff _) -> R0_Read
  | W (Git_log _) -> R0_Read
  (* git pull: word-list does not list "pull" as write -> R0 (kept under
     option B; escalation deferred to a correctness follow-up) *)
  | W (Git_pull _) -> R0_Read
  | W (Git_stash _) -> R0_Read
  | W (Git_rebase _) -> R0_Read
  | W (Git_merge _) -> R0_Read
  | W (Git_branch _) -> R0_Read
  | W (Git_checkout _) -> R0_Read
  | W (Git_fetch _) -> R0_Read
  | W (Git_show _) -> R0_Read
  | W (Git_reset _) -> R0_Read
  | W (Git_blame _) -> R0_Read
  | W (Git_add _) -> R0_Read
  (* network commands the word-list leaves at R0 (option B: unchanged) *)
  | W (Curl _) -> R0_Read
  | W (Wget _) -> R0_Read
  | W (Ssh _) -> R0_Read
  | W (Scp _) -> R0_Read
  | W (Tar _) -> R0_Read
  | W (Sed _) -> R0_Read
  | W (Rsync _) -> R0_Read
  (* interpreters / build tools the word-list leaves at R0 *)
  | W (Node _) -> R0_Read
  | W (Python _) -> R0_Read
  | W (Python3 _) -> R0_Read
  | W (Pip _) -> R0_Read
  | W (Patch _) -> R0_Read
  | W (Cargo _) -> R0_Read
  | W (Go _) -> R0_Read
  | W (Opam _) -> R0_Read
  | W (Npx _) -> R0_Read
  | W (Uv _) -> R0_Read
  | W (Glab _) -> R0_Read
  | W (Pytest _) -> R0_Read
  | W (Terminal_notifier _) -> R0_Read
  | W (Ruff _) -> R0_Read
  | W (Pyright _) -> R0_Read
  | W (Tsc _) -> R0_Read
  | W (Ocamlfind _) -> R0_Read
  | W (Rustc _) -> R0_Read
  | W (Gofmt _) -> R0_Read
  | W (Gradle _) -> R0_Read
  | W (Ninja _) -> R0_Read
  | W (Java _) -> R0_Read
  | W (Javac _) -> R0_Read
  | W (Mvn _) -> R0_Read
  | W (Cmake _) -> R0_Read
  | W (Dune_local_sh _) -> R0_Read
  | W (Osascript _) -> R0_Read
  | W (Play _) -> R0_Read
  | W (Rec _) -> R0_Read
  | W (Ffplay _) -> R0_Read
  | W (Mpg123 _) -> R0_Read
  | W (Open _) -> R0_Read
  (* --- reversible mutation: R1 (parity with word-list write list) --- *)
  | W (Mkdir _) -> R1_Reversible_mutation
  | W (Chmod _) -> R1_Reversible_mutation
  | W (Chown _) -> R1_Reversible_mutation
  | W (Make _) -> R1_Reversible_mutation
  | W (Git_clone _) -> R1_Reversible_mutation
  | W (Git_commit _) -> R1_Reversible_mutation
  (* node package managers: write subcommands -> R1, else R0 *)
  | W (Npm { subcommand; _ }) ->
    if List.mem subcommand npm_write_subcommands then R1_Reversible_mutation
    else R0_Read
  | W (Yarn { subcommand; _ }) ->
    if List.mem subcommand npm_write_subcommands then R1_Reversible_mutation
    else R0_Read
  | W (Pnpm { subcommand; _ }) ->
    if List.mem subcommand npm_write_subcommands then R1_Reversible_mutation
    else R0_Read
  (* git push: force / force-with-lease to a protected branch is
     Destructive_protected (word-list parity via [is_protected_branch_target]
     on the typed [branch] field); any other push is R1 *)
  | W (Git_push { force; force_with_lease; branch; _ }) ->
    let forced = force || force_with_lease in
    let protected_target =
      match branch with
      | Some b -> is_protected_branch_target b
      | None -> false
    in
    if forced && protected_target then Destructive_protected
    else R1_Reversible_mutation
  (* --- irreversible: R2 --------------------------------------------- *)
  (* Su / Dd / Mkfs: word-list head-token match missed Su/Mkfs (-> R0);
     the type makes them visible. Dd was already R2 in the word-list. *)
  | W (Su _) -> R2_Irreversible
  | W (Dd _) -> R2_Irreversible
  | W (Mkfs _) -> R2_Irreversible
  (* rm: recursive + force -> Destructive_protected, else R2 (word-list
     parity with [is_destructive_bash_operation] / [classify_write_detail]) *)
  | W (Rm { recursive; force; _ }) ->
    if recursive && force then Destructive_protected else R2_Irreversible
  (* --- privilege escalation: Destructive_protected ------------------ *)
  (* sudo wraps an arbitrary argv; the word-list head was "sudo" so its
     "rm"/"git push" arms never fired (silent R0). Privilege escalation
     always requires approval. *)
  | W (Sudo _) -> Destructive_protected
  (* gh: the typed [Gh] constructor buries the HTTP method (-X DELETE)
     and graphql body in [rest], so the type alone cannot decide gh
     risk. [classify]'s word-list floor supplies it; revisit here once
     the typed model captures the method + graphql body. *)
  | W (Gh _) -> R0_Read
  | W (Docker _) -> R0_Read
  (* File operations — cp/mv/ln/touch are reversible or low-risk mutations *)
  | W (Cp _) -> R1_Reversible_mutation
  | W (Mv _) -> R1_Reversible_mutation
  | W (Ln _) -> R1_Reversible_mutation
  | W (Touch _) -> R1_Reversible_mutation
  | W (Tee _) -> R1_Reversible_mutation
  | W (Awk _) -> R0_Read
  | W (Xargs _) -> R2_Irreversible
  (* escape hatch (env/redirect/$VAR/unknown bin): no typed shape to
     read; [classify]'s word-list floor classifies it. *)
  | W (Generic _) -> R0_Read
;;

(* --- Main classifier ------------------------------------------------ *)

let risk_rank = function
  | R0_Read -> 0
  | R1_Reversible_mutation -> 1
  | R2_Irreversible -> 2
  | Destructive_protected -> 3
;;

let max_risk a b = if risk_rank a >= risk_rank b then a else b

(* Per-[Simple] decision: the stricter of the typed-shape opinion and
   the word-list floor for that single command. Both opinions are scoped
   to one command's own words, so a pipeline can compose them stage by
   stage instead of flattening every stage into one head-anchored list.
   When [literal_words_of_simple] returns [None] (env/redirect/$VAR present)
   the word-list floor cannot be computed and falls back to [R0_Read];
   the typed opinion still supplies escalation for those cases. *)
let decision_of_simple (s : Shell_ir.simple) : risk_class =
  let typed = risk_of_typed (Shell_ir_typed.of_simple s) in
  let floor =
    match literal_words_of_simple s with
    | Some words -> classify_words words
    | None -> R0_Read
  in
  max_risk typed floor
;;

(* RFC-0208 P0: compose the per-stage decision across a pipeline with
   [max_risk], rather than the previous blanket [Pipeline -> R0_Read]
   for the typed path. Before this, a privilege-escalation or destructive
   command in any non-head pipeline stage (e.g.
   [echo x | sudo tee /etc/passwd], [cat f | git push --force origin main],
   [sudo cat f | grep y]) was invisible to both the typed path (which
   read no stage) and the word-list floor (which matches only the head
   token of the flattened word list). The fold reuses the existing
   per-constructor [risk_of_typed] and [classify_words] per stage — in
   particular the [W (Sudo)] arm now fires for sudo anywhere in a
   pipeline — so it adds no new string classifier. *)
let rec composed_decision (ir : Shell_ir.t) : risk_class =
  match ir with
  | Shell_ir.Simple s -> decision_of_simple s
  | Shell_ir.Pipeline stages ->
    List.fold_left
      (fun acc stage -> max_risk acc (composed_decision stage))
      R0_Read
      stages
;;

(* The decision is the stricter of the per-stage composed verdict and the
   flattened word-list floor, so it is monotone-safe by construction:
   never lower than the legacy flat verdict and never lower than the
   typed verdict. [composed_decision] dominates the flat floor for every
   input the floor is head-anchored over, but the flat floor is retained
   as a conservative lower bound (it can still catch a cross-stage
   concatenation the per-stage scope does not). Retiring the floor is
   gated on the differential-safety harness (RFC-0208 P2/P6). *)
let classify (T ir : undecided t) : decided decided_ir =
  let flat_floor = classify_words (flat_stage_words ir) in
  { ir; risk = max_risk flat_floor (composed_decision ir) }
;;
