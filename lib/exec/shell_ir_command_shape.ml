type stage =
  { bin : string
  ; args : string list
  }

let normalize_command_name command_name =
  let command_name = Filename.basename command_name |> String.lowercase_ascii in
  if String.ends_with ~suffix:".exe" command_name
  then String.sub command_name 0 (String.length command_name - String.length ".exe")
  else command_name

let literal_args args =
  let rec loop acc = function
    | [] -> Some (List.rev acc)
    | Shell_ir.Lit (arg, _) :: rest -> loop (arg :: acc) rest
    | Shell_ir.Concat _ :: _ | Shell_ir.Var (_, _) :: _ -> None
  in
  loop [] args

let stage_of_simple simple =
  match literal_args simple.Shell_ir.args with
  | None -> None
  | Some args -> Some { bin = Exec_program.to_string simple.bin; args }

let parsed_stages ir =
  let rec loop acc = function
    | Shell_ir.Simple simple -> (
      match stage_of_simple simple with
      | Some stage -> Some (stage :: acc)
      | None -> None)
    | Shell_ir.Pipeline stages ->
      List.fold_left
        (fun acc stage -> Option.bind acc (fun acc -> loop acc stage))
        (Some acc)
        stages
  in
  match loop [] ir with
  | Some stages -> List.rev stages
  | None -> []

let is_shell_identifier name =
  let len = String.length name in
  let is_head = function
    | 'A' .. 'Z' | 'a' .. 'z' | '_' -> true
    | _ -> false
  in
  let is_tail = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true
    | _ -> false
  in
  len > 0
  && is_head name.[0]
  && Seq.for_all is_tail (String.to_seq (String.sub name 1 (len - 1)))

let is_env_assignment token =
  match String.index_opt token '=' with
  | None -> false
  | Some 0 -> false
  | Some i -> is_shell_identifier (String.sub token 0 i)

let rec effective_stage stage =
  match normalize_command_name stage.bin, stage.args with
  | "env", args ->
    let rec scan = function
      | [] -> None
      | ("-i" | "--ignore-environment") :: rest -> scan rest
      | arg :: rest when is_env_assignment arg -> scan rest
      | arg :: _rest when String.starts_with ~prefix:"-" arg -> None
      | bin :: args -> Some { bin; args }
    in
    scan args
  | "opam", "exec" :: rest ->
    (match rest with
     | "--" :: bin :: args -> Some { bin; args }
     | bin :: args when not (String.starts_with ~prefix:"-" bin) ->
       Some { bin; args }
     | _ -> None)
  (* DET-OK: parsed_stages already rejected non-literal argv fragments; this
     default preserves explicit command shape for later policy checks. *)
  | _ -> Some stage

let effective_stages ir =
  parsed_stages ir |> List.filter_map effective_stage

let command_name_of_simple simple = Exec_program.to_string simple.Shell_ir.bin

let rec first_command_name = function
  | Shell_ir.Simple simple -> Some (command_name_of_simple simple)
  | Shell_ir.Pipeline (first :: _) -> first_command_name first
  | Shell_ir.Pipeline [] -> None

let rec last_command_name = function
  | Shell_ir.Simple simple -> Some (command_name_of_simple simple)
  | Shell_ir.Pipeline stages ->
    (match List.rev stages with
     | last :: _ -> last_command_name last
     | [] -> None)

let top_level_stage_count = function
  | Shell_ir.Simple _ -> 1
  | Shell_ir.Pipeline stages -> List.length stages
