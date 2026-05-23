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
  | ("mv" | "cp" | "mkdir" | "touch" | "chmod") :: _ -> Some R1_Reversible_mutation
  | _ -> None

(* --- gh classification on IR words ---------------------------------- *)

let gh_irreversible_ops =
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

let gh_reversible_mutations =
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
    | tok :: rest
      when String.length tok > 3
           && String.starts_with ~prefix:"-X=" tok ->
      Some
        (String.uppercase_ascii (String.sub tok 3 (String.length tok - 3)))
    | tok :: rest
      when String.length tok > 9
           && String.starts_with ~prefix:"--method=" tok ->
      Some
        (String.uppercase_ascii (String.sub tok 9 (String.length tok - 9)))
    | _ :: rest -> find rest
  in
  find parts

let classify_gh (words : string list) : risk_class =
  match words with
  | [] | [ _ ] -> R0_Read
  | _ :: command_raw :: rest ->
    let command = String.lowercase_ascii command_raw in
    let sub =
      let is_flag tok = String.length tok > 0 && tok.[0] = '-' in
      let rec first_non_flag = function
        | [] -> ""
        | tok :: tl ->
          if is_flag tok then
            if String.contains tok '=' then first_non_flag tl
            else
              (match tl with _ :: rest -> first_non_flag rest | [] -> "")
          else String.lowercase_ascii tok
      in
      first_non_flag rest
    in
    if in_table gh_irreversible_ops command sub then R2_Irreversible
    else if command = "api" then
      if sub = "graphql" then R1_Reversible_mutation
      else
        let method_ =
          match extract_method_from_parts words with
          | Some m -> m
          | None -> "GET"
        in
        if method_ = "DELETE" then R2_Irreversible
        else if List.mem method_ [ "POST"; "PUT"; "PATCH" ] then R1_Reversible_mutation
        else if has_mutating_method words then R1_Reversible_mutation
        else R0_Read
    else if in_table gh_reversible_mutations command sub then R1_Reversible_mutation
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
  | Some args -> Some (Bin.to_string simple.bin :: args)
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
  | cmd_name :: _ -> List.mem cmd_name [ "mv"; "cp"; "mkdir"; "touch"; "chmod" ]
  | [] -> false
;;

let is_destructive_bash_operation (words : string list) =
  let is_short_option arg = String.length arg > 1 && arg.[0] = '-' && arg.[1] <> '-' in
  let has_short_flag flag arg = is_short_option arg && String.contains arg flag in
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
  in
  match words with
  | "git" :: "push" :: rest ->
    List.exists
      (fun arg ->
         arg = "--force" || arg = "-f"
         || String.starts_with ~prefix:"--force-with-lease" arg)
      rest
    || List.exists is_protected_branch_target rest
  | "git" :: "reset" :: rest -> List.mem "--hard" rest
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

(* --- Main classifier ------------------------------------------------ *)

let classify (T ir : undecided t) : decided decided_ir =
  let words = flat_stage_words ir in
  let risk =
    if is_destructive_bash_operation words then
      Destructive_protected
    else if is_write_operation words then
      (match classify_write_detail words with
       | Some r -> r
       | None -> R2_Irreversible)
    else
      (match words with
       | "gh" :: _ -> classify_gh words
       | _ -> R0_Read)
  in
  { ir; risk }

(* Test/transitional escape hatch. Production code should use [classify]. *)
let trust_decided (T ir : undecided t) : decided decided_ir =
  { ir; risk = R0_Read }
