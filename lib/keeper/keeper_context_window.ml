(** Keeper_context_window — see the interface for the contract. *)

type source =
  | Declared
  | Shrunk_after_overflow of { declared_tokens : int }

type t =
  { window_tokens : int
  ; source : source
  }

let declared ~window_tokens = { window_tokens; source = Declared }

type for_runtime =
  | Window of t
  | Declared_window_exceeds_max_context of { window_tokens : int; max_context : int }

(* A window larger than the model's context is two different situations, and
   only one of them is the operator's. An operator who declared the window
   named a contradiction, and it is named back rather than quietly changed. A
   compiled default was named by nobody: refusing it would mean a fresh
   install whose model carries less than the default could not run a turn at
   all, which is what 0.35.19's install smoke found on a 32,768-token runtime.
   So the default starts at what the model carries: [max_context] is the
   runtime's declared input window, already clamped to the provider's own cap
   ([Runtime.max_context_of_runtime_id]), and a provider that still reports an
   overflow shrinks the window through [with_tokens] as before. *)
let for_runtime ~window_tokens ~operator_declared ~max_context =
  if window_tokens <= max_context
  then Window (declared ~window_tokens)
  else if operator_declared
  then Declared_window_exceeds_max_context { window_tokens; max_context }
  else Window (declared ~window_tokens:max_context)
;;

let declared_tokens t =
  match t.source with
  | Declared -> t.window_tokens
  | Shrunk_after_overflow { declared_tokens } -> declared_tokens
;;

let with_tokens t ~window_tokens =
  let declared_tokens = declared_tokens t in
  if window_tokens = declared_tokens
  then { window_tokens; source = Declared }
  else { window_tokens; source = Shrunk_after_overflow { declared_tokens } }
;;

let source_to_string = function
  | Declared -> "declared"
  | Shrunk_after_overflow _ -> "shrunk_after_overflow"
;;

let to_json t =
  `Assoc
    [ "window_tokens", `Int t.window_tokens
    ; "declared_tokens", `Int (declared_tokens t)
    ; "source", `String (source_to_string t.source)
    ]
;;

type density =
  { input_tokens : int
  ; measured_bytes : int
  }

type capacity =
  | Measured of
      { window_tokens : int
      ; density : density
      ; capacity_bytes : int
      }
  | Unmeasured of { window_tokens : int }

(* Integer arithmetic on purpose: a window of tens of thousands of tokens
   against a request of a few megabytes stays far inside a 63-bit int, and
   two readers of the same observation must agree on the byte. *)
let capacity t = function
  | None -> Unmeasured { window_tokens = t.window_tokens }
  | Some density ->
    Measured
      { window_tokens = t.window_tokens
      ; density
      ; capacity_bytes = t.window_tokens * density.measured_bytes / density.input_tokens
      }
;;

let tokens_of_bytes density bytes = bytes * density.input_tokens / density.measured_bytes

let capacity_to_json = function
  | Measured { window_tokens; density; capacity_bytes } ->
    `Assoc
      [ "window_tokens", `Int window_tokens
      ; "capacity_bytes", `Int capacity_bytes
      ; "density_input_tokens", `Int density.input_tokens
      ; "density_measured_bytes", `Int density.measured_bytes
      ]
  | Unmeasured { window_tokens } ->
    `Assoc [ "window_tokens", `Int window_tokens; "capacity_bytes", `Null ]
;;

module Density = struct
  module Table = Map.Make (String)

  type state =
    { mutable observed : density Table.t
    ; mutex : Eio.Mutex.t
    }

  let global = { observed = Table.empty; mutex = Eio.Mutex.create () }

  let observe ~runtime_id ~measured_bytes ~input_tokens =
    if measured_bytes > 0 && input_tokens > 0
    then
      Eio.Mutex.use_rw ~protect:true global.mutex (fun () ->
        global.observed <-
          Table.add runtime_id { input_tokens; measured_bytes } global.observed)
  ;;

  let lookup ~runtime_id =
    Eio.Mutex.use_ro global.mutex (fun () -> Table.find_opt runtime_id global.observed)
  ;;

  module For_testing = struct
    let reset () =
      Eio.Mutex.use_rw ~protect:true global.mutex (fun () ->
        global.observed <- Table.empty)
    ;;
  end
end
