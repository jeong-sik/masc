(* HIGH-RISK-UNREVIEWED: see the interface. *)

(* Each of the three takes the call of the account it works on, and that
   call does not wait. Side by side, one would skip an account another
   holds, so they run one after the other.

   The two that remove keys go first. They remove files and call no vendor.
   A deletion of a conversation can wait for its vendor client: were the
   deletions first, a key would stay on disk for as long as they wait. The
   order takes nothing from the deletions: one of an account whose removal
   began does not reach the vendor whichever goes first (issue #53044). *)
let resume ~env ~zone ~base_path =
  Server_key_account_purge.resume ~zone ~base_path;
  Server_key_account_replacement.remove_left_keys ~zone ~base_path;
  Server_keeper_conversation_purge.resume ~env ~zone ~base_path
;;

let start ~sw ~env ~zone ~base_path = Eio.Fiber.fork ~sw (fun () -> resume ~env ~zone ~base_path)
