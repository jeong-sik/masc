(* A2 walker — Shell_ir.t -> Capability.t list.

   Exhaustive match on Shell_ir variants.  New arm in Shell_ir forces a
   compile error here, so policy decisions are never silently dropped. *)

let lit_of_arg = function
  | Shell_ir.Lit s -> Some s
  | Shell_ir.Var _ | Shell_ir.Concat _ -> None

let all_lits_opt (args : Shell_ir.arg list) : string list option =
  let rec go acc = function
    | [] -> Some (List.rev acc)
    | a :: rest ->
      (match lit_of_arg a with
       | Some s -> go (s :: acc) rest
       | None -> None)
  in
  go [] args

let head_cap (bin : Bin.t) (args : Shell_ir.arg list) : Capability.t =
  (* Typed dispatch on [Bin.kind].  No [String.equal] on the binary name —
     the only way to add a new fast-path is to extend [Bin.kind] and add
     an arm here, which the compiler will demand. *)
  match Bin.kind bin with
  | `Git ->
    (match all_lits_opt args with
     | Some lit_argv ->
       (match Git_op.of_argv ("git" :: lit_argv) with
        | Ok git_op -> Capability.Git git_op
        | Error (`Unknown_subcmd _) -> Capability.Exec_bin (bin, args))
     | None -> Capability.Exec_bin (bin, args))
  | `Docker | `Curl | `Ssh
  | `Other_audited | `Safe_bin | `Privileged_bin ->
    Capability.Exec_bin (bin, args)

let redirect_cap = function
  | Redirect_scope.File { target; mode = Redirect_scope.Read; _ } ->
    [ Capability.Read_path target ]
  | Redirect_scope.File { target; mode = (Redirect_scope.Write | Redirect_scope.Append) as m; _ } ->
    [ Capability.Write_path (target, m) ]
  | Redirect_scope.Fd_to_fd _ -> []

let of_simple (s : Shell_ir.simple) : Capability.t list =
  let env_caps =
    List.map (fun (k, v) -> Capability.Env_set (k, v)) s.env
  in
  let head = head_cap s.bin s.args in
  let redir_caps = List.concat_map redirect_cap s.redirects in
  env_caps @ (head :: redir_caps)

let rec of_ir : Shell_ir.t -> Capability.t list = function
  | Shell_ir.Simple s -> of_simple s
  | Shell_ir.Pipeline stages ->
    let per_stage = List.concat_map of_ir stages in
    [ Capability.Pipeline_fold per_stage ]
