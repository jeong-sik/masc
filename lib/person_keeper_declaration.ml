(* The declaration of a person's Keeper (RFC a-persons-keeper-runs-on-the-
   engine, S2 / stack A3-2). The .mli says what each value is for; this file
   only spells them and renders them. *)

let activation_mode = "on_demand"
let sandbox_profile = "docker"
let sandbox_image = "base"
let network_mode = "inherit"

let instructions =
  {|너는 이 사람의 Keeper 다. 주인이 보낸 메시지에 답한다.
주인은 너를 자기 계정의 Runtime 으로 돌린다. 너는 그 Runtime 의 대화 하나에서만 답한다.
MASC 도구도, 파일·명령·웹 도구도 없다. 주인이 묻지 않은 일을 스스로 시작하지 않는다.
답할 수 없으면 답할 수 없다고 말한다. 없는 근거를 지어내지 않는다.|}
;;

let content () =
  Otoml.Printer.to_string
    (Otoml.TomlTable
       [ ( "keeper"
         , Otoml.TomlTable
             [ "activation_mode", Otoml.TomlString activation_mode
             ; "sandbox_profile", Otoml.TomlString sandbox_profile
             ; "sandbox_image", Otoml.TomlString sandbox_image
             ; "network_mode", Otoml.TomlString network_mode
             ; "instructions", Otoml.TomlString instructions
             (* The subtable goes last: a TOML key printed after a subtable
                header belongs to that subtable, so [instructions] above would
                otherwise be read as [keeper.tools.instructions]. *)
             ; "tools", Otoml.TomlTable [ "masc_enabled", Otoml.TomlBoolean false ]
             ] ) ])
;;
