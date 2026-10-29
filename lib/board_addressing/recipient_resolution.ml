(** Recipient resolution — see the interface. *)

module Candidate = struct
  type t = string

  let of_string name = if Board_addressing.is_routable_target name then Some name else None
  let to_string name = name
end

type 'recipient resolution =
  { recipients : 'recipient list
  ; unresolved : string list
  }

(* One walk in the order the candidates were written.  [asked] holds the
   spellings [declared] has answered, so a name written five times is one
   lookup.  Both lists are built reversed and turned once at the end.  An
   [Error] ends the walk where it stands: the lists built so far are dropped
   with the frame, so a failed lookup leaves no partial resolution to use. *)
let resolve ~equal ~declared candidates =
  let asked = Hashtbl.create 16 in
  let rec walk recipients unresolved = function
    | [] -> Ok { recipients = List.rev recipients; unresolved = List.rev unresolved }
    | candidate :: rest ->
      let spelling = Candidate.to_string candidate in
      if Hashtbl.mem asked spelling
      then walk recipients unresolved rest
      else (
        Hashtbl.replace asked spelling ();
        match declared candidate with
        | Error failure -> Error failure
        | Ok None -> walk recipients (spelling :: unresolved) rest
        | Ok (Some recipient) ->
          if List.exists (equal recipient) recipients
          then walk recipients unresolved rest
          else walk (recipient :: recipients) unresolved rest)
  in
  walk [] [] candidates
;;
