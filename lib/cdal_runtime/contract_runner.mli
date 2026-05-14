(** Contract-driven agent runner -- PoC-1 entry point.

    Wraps {!Agent.run} with contract enforcement and proof capture.
    The agent code remains completely unaware of contracts and proofs.

    When not called, agent runs proceed with zero overhead.

    @stability Evolving
    @since 0.93.1 *)

type run_result =
  { response : (Types.api_response, Error.sdk_error) result
  ; proof : Cdal_proof.t
  }

(** Run an agent with contract enforcement and proof capture.

    Flow:
    1. Validate contract and compute effective execution mode
    2. Create proof capture hooks and compose with agent's hooks
    3. Run agent via {!Agent.run}
    4. Finalize proof bundle and write artifacts

    Returns [Error] in response if risk class forbids execution
    (Critical), with [proof.result_status = Cancelled]. *)
val run
  :  sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> ?store:Proof_store.config
  -> contract:Risk_contract.t
  -> Agent.t
  -> string
  -> run_result
