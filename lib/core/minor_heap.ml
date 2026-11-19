(* Why the server tunes at all. A minor collection is a stop-the-world
   barrier across every domain, so a domain collecting eight times as often
   stops the whole process eight times as often. Measured on this machine
   with fourteen allocating domains: p99 of a quiet domain's work was 169 us
   with four of them and 11 ms with fourteen.

   Measured 2026-09-05: a domain spawned after a 4M-word set reports the
   runtime's initial size, so a single set in [main_eio.ml] reached one
   domain out of fifteen and the live server ran its pool on the default.
   Each domain therefore applies its heap on its own first step. [Gc.get] is
   a read of the domain's own state, not a barrier. *)
type t =
  | Runtime_default
  | Tuned

let tuned_words = 4 * 1024 * 1024

let apply = function
  | Runtime_default -> ()
  | Tuned ->
    (match Sys.getenv_opt "OCAMLRUNPARAM" with
     | Some _ -> ()
     | None ->
       let control = Gc.get () in
       if control.Gc.minor_heap_size < tuned_words
       then Gc.set { control with Gc.minor_heap_size = tuned_words })
;;

let domain_mgr policy (mgr : _ Eio.Domain_manager.t) =
  match mgr with
  | Eio.Resource.T (inner, ops) ->
    let module Inner = (val Eio.Resource.get ops Eio.Domain_manager.Pi.Mgr) in
    let module Applying = struct
      type t = Inner.t

      let run t fn =
        Inner.run t (fun ~cancelled ->
          apply policy;
          fn ~cancelled)
      ;;

      let run_raw t fn =
        Inner.run_raw t (fun () ->
          apply policy;
          fn ())
      ;;
    end
    in
    (Eio.Resource.T (inner, Eio.Domain_manager.Pi.mgr (module Applying))
      : Eio.Domain_manager.ty Eio.Resource.t)
;;
