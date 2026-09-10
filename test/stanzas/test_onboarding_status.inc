(test
 (name test_onboarding_status)
 (modules test_onboarding_status)
 (deps ../config/runtime.toml ../config/keepers-default/imp.toml)
 (libraries masc.operator masc.string_util alcotest yojson unix))
