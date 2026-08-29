module Gate = Masc_exec_command_gate.Shell_command_gate

type field =
  | Stdin
  | Connector

type call =
  | Write_then_execute
  | Execute_twice
  | Spawn

type t =
  | Move_to_field of {
      field : field;
      because : string;
    }
  | Call_this_instead of {
      call : call;
      because : string;
    }
  | Spell_it_as of {
      spelling : string;
      because : string;
    }
      (** The same call, written the way this tool spells it. Separate from
          {!Call_this_instead} because nothing about which call to make
          changes, and from {!Move_to_field} because the construct is not
          something a field carries. *)
  | Unrepresentable of {
      construct : Masc_exec.Parsed.reason_too_complex;
      because : string;
    }

let stdin_is_a_field because = Move_to_field { field = Stdin; because }
let a_program_belongs_in_a_file because = Call_this_instead { call = Write_then_execute; because }

(* Exhaustive on purpose.  A construct cannot join the excluded list without
   someone choosing what the caller should have done instead. *)
let of_construct : Masc_exec.Parsed.reason_too_complex -> t = function
  | `Heredoc ->
    stdin_is_a_field "a heredoc is the child's stdin, and stdin is a typed field"
  | `Here_string ->
    stdin_is_a_field "a here-string is the child's stdin, and stdin is a typed field"
  | `Cmd_subst ->
    Call_this_instead
      { call = Execute_twice
      ; because =
          "a substitution is one command feeding another, which is two calls \
           and not one"
      }
  | `Background ->
    Call_this_instead
      { call = Spawn
      ; because =
          "[&] backgrounds nothing here -- the child inherits this call's \
           output pipe, so the call waits for it anyway, and a timeout leaves \
           it running with no handle to stop it"
      }
  | `Control_flow -> a_program_belongs_in_a_file "a loop or a branch is a program, not a command line"
  | `Function_def -> a_program_belongs_in_a_file "a function definition is a program, not a command line"
  | `Subshell -> a_program_belongs_in_a_file "a subshell is a program, not a command line"
  | `Proc_subst ->
    a_program_belongs_in_a_file
      "process substitution needs the inner output on disk before the outer \
       command can name it"
  | `Arith_expansion ->
    Call_this_instead
      { call = Execute_twice
      ; because = "compute the value first and pass the result as an argument"
      }
  | `Glob_brace ->
    (* Not stdin and not a file: the expansion is argv, and the caller already
       has the expanded form.  Kept here rather than as a Move_to_field because
       the field it would name is the argv it is already using. *)
    Call_this_instead
      { call = Execute_twice
      ; because =
          "a shell expands this before the command runs. List the arguments, \
           or produce them with a first call"
      }
  | `Param_expansion ->
    Call_this_instead
      { call = Execute_twice
      ; because =
          "a shell would expand this before the command runs, and this tool \
           runs no shell. Read the value with a first call and pass it as an \
           argument -- and for [$?], this call already reports whether the \
           command succeeded"
      }
  | `Redirect ->
    (* [>], [>>], [<] and [n>&m] are in the subset, so what reaches here is one
       of the forms that are not: [&>], [>|], [<>], [>&-]. The move is the
       same call spelled differently, which is why this is not a field or
       another tool. *)
    Spell_it_as
      { spelling = "> file 2>&1"
      ; because =
          "this tool takes [>], [>>], [<] and [n>&m]. It has no operator that \
           joins two streams, overrides noclobber, or closes a descriptor"
      }
  | `Unknown_construct _ as construct ->
    Unrepresentable
      { construct
      ; because =
          "the parser could not name this construct, so there is no call to \
           suggest instead"
      }
;;

let of_reason : Gate.too_complex_reason -> t = function
  | Gate.Unsupported_construct construct -> of_construct construct
  | Gate.Unsupported_nested_pipeline ->
    Move_to_field
      { field = Connector
      ; because =
          "a pipeline is a flat list of stages. Name each stage once rather \
           than nesting one pipeline inside another"
      }
;;

let field_name = function
  | Stdin -> "stdin"
  | Connector -> "connector"
;;

(* The category the census counts. RFC execute-subset-dispositions §3.7 keys
   its corpus table on these, so they stay put when what the caller types is
   renamed. *)
let call_name = function
  | Write_then_execute -> "write-then-execute"
  | Execute_twice -> "execute-twice"
  | Spawn -> "spawn"
;;

(* What the caller types. Two of these are patterns over calls the caller
   already has, so they read as descriptions and the hyphens say so. [Spawn]
   became one concrete tool, so it is named exactly -- "call spawn instead"
   sent the reader looking for a tool nobody has. This library cannot see the
   tool schemas, so a test at a layer that sees both holds the two together. *)
let call_instruction = function
  | Write_then_execute -> "write-then-execute"
  | Execute_twice -> "execute-twice"
  | Spawn -> "keeper_spawn"
;;

let tag = function
  | Move_to_field { field; _ } -> "move_to_field:" ^ field_name field
  | Call_this_instead { call; _ } -> "call_this_instead:" ^ call_name call
  | Spell_it_as _ -> "spell_it_as"
  | Unrepresentable _ -> "unrepresentable"
;;

let to_string = function
  | Move_to_field { field; because } ->
    Printf.sprintf "use the %s field: %s" (field_name field) because
  | Call_this_instead { call; because } ->
    Printf.sprintf "call %s instead: %s" (call_instruction call) because
  | Spell_it_as { spelling; because } ->
    Printf.sprintf "write it as [%s]: %s" spelling because
  | Unrepresentable { construct = _; because } -> because
;;
