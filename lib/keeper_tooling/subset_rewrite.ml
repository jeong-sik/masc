module Gate = Masc_exec_command_gate.Shell_command_gate

type field = Connector

type call =
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

(* RFC execute-boundary-is-the-sandbox. Every sentence below was written while
   the subset was what ran, so "this tool does not do that" was a fact about
   the tool. It is not one any more: [script] is a shell, and an argv-shaped
   shell normalises into it, so a caller who wrote [$(...)] or [$PWD] or a
   loop wrote something that works.

   Advising against it is not merely stale, it is the failure this module was
   written to end -- 2026-08-31, lane-smith was told "this tool runs no shell"
   for a working [$PWD] and rewrote it into an absolute path. What is left is
   [&], where another call is the better move, and a nested pipeline, where a
   field still is; for the rest the honest answer is that there is nothing to
   say. *)
let a_shell_is_the_answer construct because =
  Unrepresentable { construct; because }
;;

(* Exhaustive on purpose.  A construct cannot join the excluded list without
   someone choosing whether the caller should have done something else. *)
let of_construct : Masc_exec.Parsed.reason_too_complex -> t = function
  (* Still true, and not about the subset: the shell that runs the line exits
     when the line ends, so [&] leaves a child with no handle to wait on or
     stop. Spawn is the tool that returns one. *)
  | `Background ->
    Call_this_instead
      { call = Spawn
      ; because =
          "the shell running this line exits when the line does, so [&] \
           leaves a child with no handle to wait on, read from, or stop"
      }
  | ( `Heredoc
    | `Here_string
    | `Cmd_subst
    | `Param_expansion
    | `Arith_expansion
    | `Glob_brace
    | `Subshell
    | `Proc_subst
    | `Control_flow
    | `Function_def
    | `Redirect ) as construct ->
    a_shell_is_the_answer
      construct
      "a shell runs this line, so it does what you wrote. The typed argv form \
       cannot say it, and argv is the form that gets path scope -- use it \
       when the line does not need a shell"
  | `Unknown_construct _ as construct ->
    a_shell_is_the_answer
      construct
      "the parser could not name this construct. The shell still runs the \
       line; only the classification is missing"
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
  | Connector -> "connector"
;;

(* The category the census counts. RFC execute-subset-dispositions §3.7 keys
   its corpus table on these, so they stay put when what the caller types is
   renamed. *)
let call_name = function
  | Spawn -> "spawn"
;;

(* What the caller types. Two of these are patterns over calls the caller
   already has, so they read as descriptions and the hyphens say so. [Spawn]
   became one concrete tool, so it is named exactly -- "call spawn instead"
   sent the reader looking for a tool nobody has. This library cannot see the
   tool schemas, so a test at a layer that sees both holds the two together. *)
let call_instruction = function
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
