type t = {
  domain_mgr : Eio.Domain_manager.ty Eio.Domain_manager.t;
}

let create ~domain_mgr =
  { domain_mgr }

let run_cpu_intensive t f =
  (* Eio.Domain_manager를 통해 별도 OS 코어(Domain)로 연산 위임 *)
  Eio.Domain_manager.run t.domain_mgr f

let compute_local_embedding t ~text =
  run_cpu_intensive t (fun () ->
    (* 1. OrtCreateTensor FFI를 호출하여 C 텐서 획득 (가정) *)
    let tensor = "mock_onnx_tensor_ptr" in
    
    (* 2. Gc.finalise 대신 Fun.protect를 사용해 Native C Heap 리소스의 명시적 해제 보장 (OOM 방어) *)
    Fun.protect
      ~finally:(fun () ->
         (* 3. OrtReleaseTensor(tensor) FFI 즉시 호출하여 리소스 누수 방지 *)
         let _ = tensor in
         ())
      (fun () ->
         (* 4. 1,536차원 모크 임베딩 벡터 반환 *)
         let _ = text in
         Array.make 1536 0.05
      )
  )
