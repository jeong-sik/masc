(test
 (name test_onboarding_status)
 (modules test_onboarding_status)
 (deps ../scripts/fixtures/release-evidence/runtime.toml ../config/keepers-default/imp.toml)
 (libraries masc_test_deps masc.operator masc.browser_lane masc.string_util alcotest yojson unix digestif))
