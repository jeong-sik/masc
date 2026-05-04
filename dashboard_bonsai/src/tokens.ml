(* @generated DO NOT EDIT — run `pnpm tokens:build` (source: dashboard/design-system/tokens/source.ts) *)

type semantic =
  [
  | `Bg_0
  | `Bg_1
  | `Bg_2
  | `Bg_3
  | `Bg_4
  | `Line_1
  | `Line_2
  | `Line_3
  | `Fg_1
  | `Fg_2
  | `Fg_3
  | `Fg_4
  | `Brass_1
  | `Brass_2
  | `Brass_3
  | `Brass_glow
  | `Ok
  | `Warn
  | `Err
  | `Info
  | `Idle
  | `Stalled
  | `Ok_glow
  | `Warn_glow
  | `Err_glow
  | `Info_glow
  | `Stalled_glow
  | `K_1
  | `K_2
  | `K_3
  | `K_4
  | `K_5
  | `K_6
  | `K_7
  | `K_8
  | `K_9
  | `K_10
  | `K_11
  | `K_12
  | `K_1_glow
  | `K_2_glow
  | `K_3_glow
  | `K_4_glow
  | `K_5_glow
  | `K_6_glow
  | `K_7_glow
  | `K_8_glow
  | `K_9_glow
  | `K_10_glow
  | `K_11_glow
  | `K_12_glow
  | `P_anthropic
  | `P_kimi
  | `P_openai
  | `P_xai
  | `P_gemini
  | `P_deepseek
  | `P_qwen
  | `P_mistral
  | `P_nemotron
  | `P_ollama
  | `P_llamacpp
  | `P_glm
  | `P_gemini_cli
  | `P_codex_cli
  | `Font_sans
  | `Font_mono
  | `Fs_9
  | `Fs_10
  | `Fs_11
  | `Fs_12
  | `Fs_13
  | `Fs_14
  | `Fs_16
  | `Fs_20
  | `Fs_28
  | `Fs_36
  | `Fs_56
  | `Lh_tight
  | `Lh_body
  | `Lh_loose
  | `Fw_reg
  | `Fw_med
  | `Fw_semi
  | `Fw_bold
  | `Track_tight
  | `Track_normal
  | `Track_wide
  | `Track_caps
  | `Sp_1
  | `Sp_2
  | `Sp_3
  | `Sp_4
  | `Sp_5
  | `Sp_6
  | `Sp_7
  | `Sp_8
  | `Sp_0h
  | `Sp_1h
  | `R_0
  | `R_1
  | `R_2
  | `R_3
  | `T_fast
  | `T_med
  | `T_slow
  | `T_xslow
  | `Ease
  | `Ease_out
  | `Ease_in
  | `Ease_inout
  | `Ease_spring
  | `Space_1
  | `Space_2
  | `Space_3
  | `Space_4
  | `Space_5
  | `Space_6
  | `Space_7
  | `Space_8
  | `Radius_xs
  | `Radius_sm
  | `Radius_md
  | `Radius_lg
  | `Radius_pill
  | `Radius_circle
  | `Font_display
  | `Font_body
  | `Font_ui
  | `Scrollbar_thumb
  | `Scrollbar_thumb_hover
  | `Density
  | `Grid_unit
  | `Grid_half
  | `Grid_dbl
  | `H_topbar
  | `H_ticker
  | `H_kpi
  | `H_lifeline
  | `H_composer
  | `H_deck
  | `W_sidebar
  | `W_rail
  | `Z_base
  | `Z_sticky
  | `Z_dropdown
  | `Z_overlay
  | `Z_drawer
  | `Z_modal
  | `Z_toast
  | `Font_size_3xs
  | `Font_size_2xs
  | `Font_size_xs
  | `Font_size_sm
  | `Font_size_base
  | `Font_size_md
  | `Font_size_lg
  | `Spacing_element
  | `Spacing_group
  | `Spacing_card
  | `Radius_xl
  | `Slate_400
  | `Slate_500
  | `Slate_600
  | `Slate_800
  | `Blue_400
  | `Sky_400
  | `Purple_500
  | `Yellow_100
  | `Red_100
  | `Cyan_100
  | `Emerald
  | `Emerald_fg
  | `Indigo
  | `Yellow_bright
  | `Amber_bright
  | `Rose
  | `Rose_fg
  | `Rose_light
  | `Cyan
  | `Purple
  | `Frost_100
  | `White_pure
  | `Text_near_white
  | `Text_slate_light
  | `Text_strong
  | `Text_body
  | `Text_muted
  | `Text_dim
  | `State_idle
  | `State_offline
  | `Agent_working
  | `Agent_busy
  | `Chat_user_avatar
  | `Chat_user_chip
  | `Chat_assistant_avatar
  | `Chat_assistant_chip
  | `Chat_error_avatar
  | `Chat_error_chip
  | `Chat_code_callout
  | `Vote_up
  | `Vote_down
  | `Vote_hover
  | `Text_slate
  | `Warn_bright
  | `Bad_light
  | `Ok_soft
  | `Ok_fg
  | `Ok_border
  | `Ok_ring
  | `Warn_soft
  | `Warn_fg
  | `Warn_border
  | `Warn_ring
  | `Err_soft
  | `Err_fg
  | `Err_border
  | `Err_ring
  | `Info_soft
  | `Info_fg
  | `Info_border
  | `Info_ring
  | `Idle_soft
  | `Idle_fg
  | `Idle_border
  | `Stalled_soft
  | `Stalled_fg
  | `Stalled_border
  | `Stalled_ring
  | `Brass_soft
  | `Brass_fg
  | `Brass_border
  | `Brass_ring
  | `K_1_soft
  | `K_1_border
  | `K_1_ring
  | `K_2_soft
  | `K_2_border
  | `K_2_ring
  | `K_3_soft
  | `K_3_border
  | `K_3_ring
  | `K_4_soft
  | `K_4_border
  | `K_4_ring
  | `K_5_soft
  | `K_5_border
  | `K_5_ring
  | `K_6_soft
  | `K_6_border
  | `K_6_ring
  | `K_7_soft
  | `K_7_border
  | `K_7_ring
  | `K_8_soft
  | `K_8_border
  | `K_8_ring
  | `K_9_soft
  | `K_9_border
  | `K_9_ring
  | `K_10_soft
  | `K_10_border
  | `K_10_ring
  | `K_11_soft
  | `K_11_border
  | `K_11_ring
  | `K_12_soft
  | `K_12_border
  | `K_12_ring
  | `P_anthropic_soft
  | `P_anthropic_border
  | `P_kimi_soft
  | `P_kimi_border
  | `P_openai_soft
  | `P_openai_border
  | `P_xai_soft
  | `P_xai_border
  | `P_gemini_soft
  | `P_gemini_border
  | `P_deepseek_soft
  | `P_deepseek_border
  | `P_qwen_soft
  | `P_qwen_border
  | `P_mistral_soft
  | `P_mistral_border
  | `P_nemotron_soft
  | `P_nemotron_border
  | `P_ollama_soft
  | `P_ollama_border
  | `P_llamacpp_soft
  | `P_llamacpp_border
  | `P_glm_soft
  | `P_glm_border
  | `P_gemini_cli_soft
  | `P_gemini_cli_border
  | `P_codex_cli_soft
  | `P_codex_cli_border
  | `Color_bg_page
  | `Color_bg_surface
  | `Color_bg_panel_alt
  | `Color_bg_elevated
  | `Color_bg_hover
  | `Color_fg_primary
  | `Color_fg_secondary
  | `Color_fg_muted
  | `Color_fg_disabled
  | `Color_border_default
  | `Color_border_strong
  | `Color_border_divider
  | `Color_accent_fg
  | `Color_accent_fg_dim
  | `Color_accent_glow
  | `Color_status_ok
  | `Color_status_warn
  | `Color_status_err
  | `Color_status_info
  | `Color_status_idle
  | `Color_status_stalled
  | `Color_keeper_1
  | `Color_keeper_2
  | `Color_keeper_3
  | `Color_keeper_4
  | `Color_keeper_5
  | `Color_keeper_6
  | `Color_keeper_7
  | `Color_keeper_8
  | `Color_keeper_9
  | `Color_keeper_10
  | `Color_keeper_11
  | `Color_keeper_12
  | `Color_focus_ring
  | `Color_status_added
  | `Color_status_modified
  | `Color_status_deleted
  | `Type_micro
  | `Type_caption
  | `Type_label
  | `Type_meta
  | `Type_body
  | `Type_code
  | `Type_title
  | `Type_kpi_m
  | `Type_kpi_l
  | `Type_hero
  | `Type_display
  | `Sp_inline
  | `Sp_gutter
  | `Sp_stack
  | `Sp_section
  | `Sp_region
  | `Row_h_micro
  | `Row_h_tight
  | `Row_h
  | `Row_h_loose
  | `Row_h_tall
  | `Ctrl_h_xs
  | `Ctrl_h_sm
  | `Ctrl_h
  | `Ctrl_h_lg
  | `_density_scope
  | `Elev_0_bg
  | `Elev_0_border
  | `Elev_0_shadow
  | `Elev_1_bg
  | `Elev_1_border
  | `Elev_1_shadow
  | `Elev_2_bg
  | `Elev_2_border
  | `Elev_2_shadow
  | `Elev_3_bg
  | `Elev_3_border
  | `Elev_3_shadow
  | `Elev_4_bg
  | `Elev_4_border
  | `Elev_4_shadow
  | `Elev_5_bg
  | `Elev_5_border
  | `Elev_5_shadow
  | `Elev_6_bg
  | `Elev_6_border
  | `Elev_6_shadow
  | `Shadow_1
  | `Shadow_2
  | `Shadow_3
  | `Shadow_inset
  | `Shadow_card
  | `Shadow_panel
  | `Shadow_glow
  | `Shadow_raised
  | `Shadow_ring
  | `Shadow_cmd_palette
  | `Shadow_drawer_left
  | `Focus_ring
  | `Focus_ring_err
  | `Hover_overlay
  | `Hover_overlay_strong
  | `Active_overlay
  | `Pressed_scale
  | `Hover_lift
  | `Focus_ring_width
  | `Focus_ring_offset
  | `Button_primary_bg
  | `Button_primary_fg
  | `Button_primary_border
  | `Button_primary_bg_hover
  | `Button_primary_bg_pressed
  | `Button_ghost_bg
  | `Button_ghost_fg
  | `Button_ghost_border
  | `Button_ghost_bg_hover
  | `Button_ghost_bg_pressed
  | `Button_danger_bg
  | `Button_danger_fg
  | `Button_danger_border
  | `Button_danger_bg_hover
  | `Button_danger_bg_pressed
  | `Button_ok_bg
  | `Button_ok_fg
  | `Button_ok_border
  | `Button_ok_bg_hover
  | `Button_ok_bg_pressed
  | `Button_warn_bg
  | `Button_warn_fg
  | `Button_warn_border
  | `Button_warn_bg_hover
  | `Button_warn_bg_pressed
  | `Button_subtle_bg
  | `Button_subtle_fg
  | `Button_subtle_border
  | `Button_subtle_bg_hover
  | `Button_subtle_bg_pressed
  | `Input_bg
  | `Input_fg
  | `Input_border
  | `Input_bg_hover
  | `Input_bg_focus
  | `Input_placeholder
  | `Input_border_focus
  | `Dialog_panel_bg
  | `Dialog_panel_border
  | `Dialog_overlay_bg
  | `Toast_bg
  | `State_hover_bg
  | `State_hover_fg
  | `State_hover_border
  | `State_selected_bg
  | `State_selected_fg
  | `State_selected_border
  | `State_pressed_bg
  | `State_active_bg
  | `State_active_fg
  | `State_active_border
  | `State_disabled_fg
  | `State_disabled_bg
  | `Divider
  | `Divider_emphasis
  | `Divider_zone
  | `Scrim_subtle
  | `Scrim
  | `Scrim_strong
  | `Scrim_brass
  | `Bg_tab_sticky_hover
  | `Tab_bg
  | `Tab_bg_active
  | `Tab_bg_hover
  | `Tab_fg
  | `Tab_fg_active
  | `Tab_border
  | `Tab_indicator
  | `Tab_close_hover
  | `Sidebar_bg
  | `Sidebar_fg
  | `Sidebar_item_hover_bg
  | `Sidebar_item_active_bg
  | `Sidebar_icon_fg
  | `Sidebar_icon_active_fg
  | `Sidebar_section_header_fg
  | `Sidebar_border
  | `Panel_header_bg
  | `Panel_header_fg
  | `Panel_resize_handle
  | `Panel_resize_handle_hover
  | `Terminal_bg
  | `Terminal_fg
  | `Terminal_prompt
  | `Terminal_cursor
  | `Terminal_selection_bg
  | `Menu_bg
  | `Menu_border
  | `Menu_shadow
  | `Menu_separator
  | `Menuitem_fg
  | `Menuitem_hover_bg
  | `Menuitem_active_bg
  | `Menuitem_disabled_fg
  | `Menu_shortcut_fg
  | `Tooltip_bg
  | `Tooltip_fg
  | `Tooltip_border
  | `Tooltip_shadow
  | `Toast_bg_info
  | `Toast_bg_success
  | `Toast_bg_warning
  | `Toast_bg_error
  | `Toast_fg
  | `Toast_border
  | `Toast_shadow
  | `Terminal_ansi_black
  | `Terminal_ansi_red
  | `Terminal_ansi_green
  | `Terminal_ansi_yellow
  | `Terminal_ansi_blue
  | `Terminal_ansi_magenta
  | `Terminal_ansi_cyan
  | `Terminal_ansi_white
  | `Terminal_ansi_bright_black
  | `Terminal_ansi_bright_red
  | `Terminal_ansi_bright_green
  | `Terminal_ansi_bright_yellow
  | `Terminal_ansi_bright_blue
  | `Terminal_ansi_bright_magenta
  | `Terminal_ansi_bright_cyan
  | `Terminal_ansi_bright_white
  | `Motion_enter
  | `Motion_exit
  | `Motion_swap
  | `Motion_reveal
  | `Motion_settle
  | `Motion_pop
  | `Enter_duration
  | `Exit_duration
  | `Enter_easing
  | `Exit_easing
  | `_motion_scope
  | `Cmt_question
  | `Cmt_flag
  | `Cmt_note
  | `Cmt_approve
  | `Cmt_suggest
  | `Diff_add
  | `Diff_del
  | `Diff_add_bar
  | `Diff_del_bar
  | `Heat_1
  | `Heat_2
  | `Heat_3
  | `Color_text_body
  | `Color_text_muted
  | `Color_text_dim
  | `Color_accent_brass
  | `Color_accent_soft
  | `Color_keeper_1_glow
  | `Color_keeper_2_glow
  | `Color_keeper_3_glow
  | `Color_keeper_4_glow
  | `Color_keeper_5_glow
  | `Color_keeper_6_glow
  | `Color_keeper_7_glow
  | `Color_keeper_8_glow
  | `Color_keeper_9_glow
  | `Color_keeper_10_glow
  | `Color_keeper_11_glow
  | `Color_keeper_12_glow
  ]

let name_of = function
  | `Bg_0 -> "bg-0"
  | `Bg_1 -> "bg-1"
  | `Bg_2 -> "bg-2"
  | `Bg_3 -> "bg-3"
  | `Bg_4 -> "bg-4"
  | `Line_1 -> "line-1"
  | `Line_2 -> "line-2"
  | `Line_3 -> "line-3"
  | `Fg_1 -> "fg-1"
  | `Fg_2 -> "fg-2"
  | `Fg_3 -> "fg-3"
  | `Fg_4 -> "fg-4"
  | `Brass_1 -> "brass-1"
  | `Brass_2 -> "brass-2"
  | `Brass_3 -> "brass-3"
  | `Brass_glow -> "brass-glow"
  | `Ok -> "ok"
  | `Warn -> "warn"
  | `Err -> "err"
  | `Info -> "info"
  | `Idle -> "idle"
  | `Stalled -> "stalled"
  | `Ok_glow -> "ok-glow"
  | `Warn_glow -> "warn-glow"
  | `Err_glow -> "err-glow"
  | `Info_glow -> "info-glow"
  | `Stalled_glow -> "stalled-glow"
  | `K_1 -> "k-1"
  | `K_2 -> "k-2"
  | `K_3 -> "k-3"
  | `K_4 -> "k-4"
  | `K_5 -> "k-5"
  | `K_6 -> "k-6"
  | `K_7 -> "k-7"
  | `K_8 -> "k-8"
  | `K_9 -> "k-9"
  | `K_10 -> "k-10"
  | `K_11 -> "k-11"
  | `K_12 -> "k-12"
  | `K_1_glow -> "k-1-glow"
  | `K_2_glow -> "k-2-glow"
  | `K_3_glow -> "k-3-glow"
  | `K_4_glow -> "k-4-glow"
  | `K_5_glow -> "k-5-glow"
  | `K_6_glow -> "k-6-glow"
  | `K_7_glow -> "k-7-glow"
  | `K_8_glow -> "k-8-glow"
  | `K_9_glow -> "k-9-glow"
  | `K_10_glow -> "k-10-glow"
  | `K_11_glow -> "k-11-glow"
  | `K_12_glow -> "k-12-glow"
  | `P_anthropic -> "p-anthropic"
  | `P_kimi -> "p-kimi"
  | `P_openai -> "p-openai"
  | `P_xai -> "p-xai"
  | `P_gemini -> "p-gemini"
  | `P_deepseek -> "p-deepseek"
  | `P_qwen -> "p-qwen"
  | `P_mistral -> "p-mistral"
  | `P_nemotron -> "p-nemotron"
  | `P_ollama -> "p-ollama"
  | `P_llamacpp -> "p-llamacpp"
  | `P_glm -> "p-glm"
  | `P_gemini_cli -> "p-gemini-cli"
  | `P_codex_cli -> "p-codex-cli"
  | `Font_sans -> "font-sans"
  | `Font_mono -> "font-mono"
  | `Fs_9 -> "fs-9"
  | `Fs_10 -> "fs-10"
  | `Fs_11 -> "fs-11"
  | `Fs_12 -> "fs-12"
  | `Fs_13 -> "fs-13"
  | `Fs_14 -> "fs-14"
  | `Fs_16 -> "fs-16"
  | `Fs_20 -> "fs-20"
  | `Fs_28 -> "fs-28"
  | `Fs_36 -> "fs-36"
  | `Fs_56 -> "fs-56"
  | `Lh_tight -> "lh-tight"
  | `Lh_body -> "lh-body"
  | `Lh_loose -> "lh-loose"
  | `Fw_reg -> "fw-reg"
  | `Fw_med -> "fw-med"
  | `Fw_semi -> "fw-semi"
  | `Fw_bold -> "fw-bold"
  | `Track_tight -> "track-tight"
  | `Track_normal -> "track-normal"
  | `Track_wide -> "track-wide"
  | `Track_caps -> "track-caps"
  | `Sp_1 -> "sp-1"
  | `Sp_2 -> "sp-2"
  | `Sp_3 -> "sp-3"
  | `Sp_4 -> "sp-4"
  | `Sp_5 -> "sp-5"
  | `Sp_6 -> "sp-6"
  | `Sp_7 -> "sp-7"
  | `Sp_8 -> "sp-8"
  | `Sp_0h -> "sp-0h"
  | `Sp_1h -> "sp-1h"
  | `R_0 -> "r-0"
  | `R_1 -> "r-1"
  | `R_2 -> "r-2"
  | `R_3 -> "r-3"
  | `T_fast -> "t-fast"
  | `T_med -> "t-med"
  | `T_slow -> "t-slow"
  | `T_xslow -> "t-xslow"
  | `Ease -> "ease"
  | `Ease_out -> "ease-out"
  | `Ease_in -> "ease-in"
  | `Ease_inout -> "ease-inout"
  | `Ease_spring -> "ease-spring"
  | `Space_1 -> "space-1"
  | `Space_2 -> "space-2"
  | `Space_3 -> "space-3"
  | `Space_4 -> "space-4"
  | `Space_5 -> "space-5"
  | `Space_6 -> "space-6"
  | `Space_7 -> "space-7"
  | `Space_8 -> "space-8"
  | `Radius_xs -> "radius-xs"
  | `Radius_sm -> "radius-sm"
  | `Radius_md -> "radius-md"
  | `Radius_lg -> "radius-lg"
  | `Radius_pill -> "radius-pill"
  | `Radius_circle -> "radius-circle"
  | `Font_display -> "font-display"
  | `Font_body -> "font-body"
  | `Font_ui -> "font-ui"
  | `Scrollbar_thumb -> "scrollbar-thumb"
  | `Scrollbar_thumb_hover -> "scrollbar-thumb-hover"
  | `Density -> "density"
  | `Grid_unit -> "grid-unit"
  | `Grid_half -> "grid-half"
  | `Grid_dbl -> "grid-dbl"
  | `H_topbar -> "h-topbar"
  | `H_ticker -> "h-ticker"
  | `H_kpi -> "h-kpi"
  | `H_lifeline -> "h-lifeline"
  | `H_composer -> "h-composer"
  | `H_deck -> "h-deck"
  | `W_sidebar -> "w-sidebar"
  | `W_rail -> "w-rail"
  | `Z_base -> "z-base"
  | `Z_sticky -> "z-sticky"
  | `Z_dropdown -> "z-dropdown"
  | `Z_overlay -> "z-overlay"
  | `Z_drawer -> "z-drawer"
  | `Z_modal -> "z-modal"
  | `Z_toast -> "z-toast"
  | `Font_size_3xs -> "font-size-3xs"
  | `Font_size_2xs -> "font-size-2xs"
  | `Font_size_xs -> "font-size-xs"
  | `Font_size_sm -> "font-size-sm"
  | `Font_size_base -> "font-size-base"
  | `Font_size_md -> "font-size-md"
  | `Font_size_lg -> "font-size-lg"
  | `Spacing_element -> "spacing-element"
  | `Spacing_group -> "spacing-group"
  | `Spacing_card -> "spacing-card"
  | `Radius_xl -> "radius-xl"
  | `Slate_400 -> "slate-400"
  | `Slate_500 -> "slate-500"
  | `Slate_600 -> "slate-600"
  | `Slate_800 -> "slate-800"
  | `Blue_400 -> "blue-400"
  | `Sky_400 -> "sky-400"
  | `Purple_500 -> "purple-500"
  | `Yellow_100 -> "yellow-100"
  | `Red_100 -> "red-100"
  | `Cyan_100 -> "cyan-100"
  | `Emerald -> "emerald"
  | `Emerald_fg -> "emerald-fg"
  | `Indigo -> "indigo"
  | `Yellow_bright -> "yellow-bright"
  | `Amber_bright -> "amber-bright"
  | `Rose -> "rose"
  | `Rose_fg -> "rose-fg"
  | `Rose_light -> "rose-light"
  | `Cyan -> "cyan"
  | `Purple -> "purple"
  | `Frost_100 -> "frost-100"
  | `White_pure -> "white-pure"
  | `Text_near_white -> "text-near-white"
  | `Text_slate_light -> "text-slate-light"
  | `Text_strong -> "text-strong"
  | `Text_body -> "text-body"
  | `Text_muted -> "text-muted"
  | `Text_dim -> "text-dim"
  | `State_idle -> "state-idle"
  | `State_offline -> "state-offline"
  | `Agent_working -> "agent-working"
  | `Agent_busy -> "agent-busy"
  | `Chat_user_avatar -> "chat-user-avatar"
  | `Chat_user_chip -> "chat-user-chip"
  | `Chat_assistant_avatar -> "chat-assistant-avatar"
  | `Chat_assistant_chip -> "chat-assistant-chip"
  | `Chat_error_avatar -> "chat-error-avatar"
  | `Chat_error_chip -> "chat-error-chip"
  | `Chat_code_callout -> "chat-code-callout"
  | `Vote_up -> "vote-up"
  | `Vote_down -> "vote-down"
  | `Vote_hover -> "vote-hover"
  | `Text_slate -> "text-slate"
  | `Warn_bright -> "warn-bright"
  | `Bad_light -> "bad-light"
  | `Ok_soft -> "ok-soft"
  | `Ok_fg -> "ok-fg"
  | `Ok_border -> "ok-border"
  | `Ok_ring -> "ok-ring"
  | `Warn_soft -> "warn-soft"
  | `Warn_fg -> "warn-fg"
  | `Warn_border -> "warn-border"
  | `Warn_ring -> "warn-ring"
  | `Err_soft -> "err-soft"
  | `Err_fg -> "err-fg"
  | `Err_border -> "err-border"
  | `Err_ring -> "err-ring"
  | `Info_soft -> "info-soft"
  | `Info_fg -> "info-fg"
  | `Info_border -> "info-border"
  | `Info_ring -> "info-ring"
  | `Idle_soft -> "idle-soft"
  | `Idle_fg -> "idle-fg"
  | `Idle_border -> "idle-border"
  | `Stalled_soft -> "stalled-soft"
  | `Stalled_fg -> "stalled-fg"
  | `Stalled_border -> "stalled-border"
  | `Stalled_ring -> "stalled-ring"
  | `Brass_soft -> "brass-soft"
  | `Brass_fg -> "brass-fg"
  | `Brass_border -> "brass-border"
  | `Brass_ring -> "brass-ring"
  | `K_1_soft -> "k-1-soft"
  | `K_1_border -> "k-1-border"
  | `K_1_ring -> "k-1-ring"
  | `K_2_soft -> "k-2-soft"
  | `K_2_border -> "k-2-border"
  | `K_2_ring -> "k-2-ring"
  | `K_3_soft -> "k-3-soft"
  | `K_3_border -> "k-3-border"
  | `K_3_ring -> "k-3-ring"
  | `K_4_soft -> "k-4-soft"
  | `K_4_border -> "k-4-border"
  | `K_4_ring -> "k-4-ring"
  | `K_5_soft -> "k-5-soft"
  | `K_5_border -> "k-5-border"
  | `K_5_ring -> "k-5-ring"
  | `K_6_soft -> "k-6-soft"
  | `K_6_border -> "k-6-border"
  | `K_6_ring -> "k-6-ring"
  | `K_7_soft -> "k-7-soft"
  | `K_7_border -> "k-7-border"
  | `K_7_ring -> "k-7-ring"
  | `K_8_soft -> "k-8-soft"
  | `K_8_border -> "k-8-border"
  | `K_8_ring -> "k-8-ring"
  | `K_9_soft -> "k-9-soft"
  | `K_9_border -> "k-9-border"
  | `K_9_ring -> "k-9-ring"
  | `K_10_soft -> "k-10-soft"
  | `K_10_border -> "k-10-border"
  | `K_10_ring -> "k-10-ring"
  | `K_11_soft -> "k-11-soft"
  | `K_11_border -> "k-11-border"
  | `K_11_ring -> "k-11-ring"
  | `K_12_soft -> "k-12-soft"
  | `K_12_border -> "k-12-border"
  | `K_12_ring -> "k-12-ring"
  | `P_anthropic_soft -> "p-anthropic-soft"
  | `P_anthropic_border -> "p-anthropic-border"
  | `P_kimi_soft -> "p-kimi-soft"
  | `P_kimi_border -> "p-kimi-border"
  | `P_openai_soft -> "p-openai-soft"
  | `P_openai_border -> "p-openai-border"
  | `P_xai_soft -> "p-xai-soft"
  | `P_xai_border -> "p-xai-border"
  | `P_gemini_soft -> "p-gemini-soft"
  | `P_gemini_border -> "p-gemini-border"
  | `P_deepseek_soft -> "p-deepseek-soft"
  | `P_deepseek_border -> "p-deepseek-border"
  | `P_qwen_soft -> "p-qwen-soft"
  | `P_qwen_border -> "p-qwen-border"
  | `P_mistral_soft -> "p-mistral-soft"
  | `P_mistral_border -> "p-mistral-border"
  | `P_nemotron_soft -> "p-nemotron-soft"
  | `P_nemotron_border -> "p-nemotron-border"
  | `P_ollama_soft -> "p-ollama-soft"
  | `P_ollama_border -> "p-ollama-border"
  | `P_llamacpp_soft -> "p-llamacpp-soft"
  | `P_llamacpp_border -> "p-llamacpp-border"
  | `P_glm_soft -> "p-glm-soft"
  | `P_glm_border -> "p-glm-border"
  | `P_gemini_cli_soft -> "p-gemini-cli-soft"
  | `P_gemini_cli_border -> "p-gemini-cli-border"
  | `P_codex_cli_soft -> "p-codex-cli-soft"
  | `P_codex_cli_border -> "p-codex-cli-border"
  | `Color_bg_page -> "color-bg-page"
  | `Color_bg_surface -> "color-bg-surface"
  | `Color_bg_panel_alt -> "color-bg-panel-alt"
  | `Color_bg_elevated -> "color-bg-elevated"
  | `Color_bg_hover -> "color-bg-hover"
  | `Color_fg_primary -> "color-fg-primary"
  | `Color_fg_secondary -> "color-fg-secondary"
  | `Color_fg_muted -> "color-fg-muted"
  | `Color_fg_disabled -> "color-fg-disabled"
  | `Color_border_default -> "color-border-default"
  | `Color_border_strong -> "color-border-strong"
  | `Color_border_divider -> "color-border-divider"
  | `Color_accent_fg -> "color-accent-fg"
  | `Color_accent_fg_dim -> "color-accent-fg-dim"
  | `Color_accent_glow -> "color-accent-glow"
  | `Color_status_ok -> "color-status-ok"
  | `Color_status_warn -> "color-status-warn"
  | `Color_status_err -> "color-status-err"
  | `Color_status_info -> "color-status-info"
  | `Color_status_idle -> "color-status-idle"
  | `Color_status_stalled -> "color-status-stalled"
  | `Color_keeper_1 -> "color-keeper-1"
  | `Color_keeper_2 -> "color-keeper-2"
  | `Color_keeper_3 -> "color-keeper-3"
  | `Color_keeper_4 -> "color-keeper-4"
  | `Color_keeper_5 -> "color-keeper-5"
  | `Color_keeper_6 -> "color-keeper-6"
  | `Color_keeper_7 -> "color-keeper-7"
  | `Color_keeper_8 -> "color-keeper-8"
  | `Color_keeper_9 -> "color-keeper-9"
  | `Color_keeper_10 -> "color-keeper-10"
  | `Color_keeper_11 -> "color-keeper-11"
  | `Color_keeper_12 -> "color-keeper-12"
  | `Color_focus_ring -> "color-focus-ring"
  | `Color_status_added -> "color-status-added"
  | `Color_status_modified -> "color-status-modified"
  | `Color_status_deleted -> "color-status-deleted"
  | `Type_micro -> "type-micro"
  | `Type_caption -> "type-caption"
  | `Type_label -> "type-label"
  | `Type_meta -> "type-meta"
  | `Type_body -> "type-body"
  | `Type_code -> "type-code"
  | `Type_title -> "type-title"
  | `Type_kpi_m -> "type-kpi-m"
  | `Type_kpi_l -> "type-kpi-l"
  | `Type_hero -> "type-hero"
  | `Type_display -> "type-display"
  | `Sp_inline -> "sp-inline"
  | `Sp_gutter -> "sp-gutter"
  | `Sp_stack -> "sp-stack"
  | `Sp_section -> "sp-section"
  | `Sp_region -> "sp-region"
  | `Row_h_micro -> "row-h-micro"
  | `Row_h_tight -> "row-h-tight"
  | `Row_h -> "row-h"
  | `Row_h_loose -> "row-h-loose"
  | `Row_h_tall -> "row-h-tall"
  | `Ctrl_h_xs -> "ctrl-h-xs"
  | `Ctrl_h_sm -> "ctrl-h-sm"
  | `Ctrl_h -> "ctrl-h"
  | `Ctrl_h_lg -> "ctrl-h-lg"
  | `_density_scope -> "_density-scope"
  | `Elev_0_bg -> "elev-0-bg"
  | `Elev_0_border -> "elev-0-border"
  | `Elev_0_shadow -> "elev-0-shadow"
  | `Elev_1_bg -> "elev-1-bg"
  | `Elev_1_border -> "elev-1-border"
  | `Elev_1_shadow -> "elev-1-shadow"
  | `Elev_2_bg -> "elev-2-bg"
  | `Elev_2_border -> "elev-2-border"
  | `Elev_2_shadow -> "elev-2-shadow"
  | `Elev_3_bg -> "elev-3-bg"
  | `Elev_3_border -> "elev-3-border"
  | `Elev_3_shadow -> "elev-3-shadow"
  | `Elev_4_bg -> "elev-4-bg"
  | `Elev_4_border -> "elev-4-border"
  | `Elev_4_shadow -> "elev-4-shadow"
  | `Elev_5_bg -> "elev-5-bg"
  | `Elev_5_border -> "elev-5-border"
  | `Elev_5_shadow -> "elev-5-shadow"
  | `Elev_6_bg -> "elev-6-bg"
  | `Elev_6_border -> "elev-6-border"
  | `Elev_6_shadow -> "elev-6-shadow"
  | `Shadow_1 -> "shadow-1"
  | `Shadow_2 -> "shadow-2"
  | `Shadow_3 -> "shadow-3"
  | `Shadow_inset -> "shadow-inset"
  | `Shadow_card -> "shadow-card"
  | `Shadow_panel -> "shadow-panel"
  | `Shadow_glow -> "shadow-glow"
  | `Shadow_raised -> "shadow-raised"
  | `Shadow_ring -> "shadow-ring"
  | `Shadow_cmd_palette -> "shadow-cmd-palette"
  | `Shadow_drawer_left -> "shadow-drawer-left"
  | `Focus_ring -> "focus-ring"
  | `Focus_ring_err -> "focus-ring-err"
  | `Hover_overlay -> "hover-overlay"
  | `Hover_overlay_strong -> "hover-overlay-strong"
  | `Active_overlay -> "active-overlay"
  | `Pressed_scale -> "pressed-scale"
  | `Hover_lift -> "hover-lift"
  | `Focus_ring_width -> "focus-ring-width"
  | `Focus_ring_offset -> "focus-ring-offset"
  | `Button_primary_bg -> "button-primary-bg"
  | `Button_primary_fg -> "button-primary-fg"
  | `Button_primary_border -> "button-primary-border"
  | `Button_primary_bg_hover -> "button-primary-bg-hover"
  | `Button_primary_bg_pressed -> "button-primary-bg-pressed"
  | `Button_ghost_bg -> "button-ghost-bg"
  | `Button_ghost_fg -> "button-ghost-fg"
  | `Button_ghost_border -> "button-ghost-border"
  | `Button_ghost_bg_hover -> "button-ghost-bg-hover"
  | `Button_ghost_bg_pressed -> "button-ghost-bg-pressed"
  | `Button_danger_bg -> "button-danger-bg"
  | `Button_danger_fg -> "button-danger-fg"
  | `Button_danger_border -> "button-danger-border"
  | `Button_danger_bg_hover -> "button-danger-bg-hover"
  | `Button_danger_bg_pressed -> "button-danger-bg-pressed"
  | `Button_ok_bg -> "button-ok-bg"
  | `Button_ok_fg -> "button-ok-fg"
  | `Button_ok_border -> "button-ok-border"
  | `Button_ok_bg_hover -> "button-ok-bg-hover"
  | `Button_ok_bg_pressed -> "button-ok-bg-pressed"
  | `Button_warn_bg -> "button-warn-bg"
  | `Button_warn_fg -> "button-warn-fg"
  | `Button_warn_border -> "button-warn-border"
  | `Button_warn_bg_hover -> "button-warn-bg-hover"
  | `Button_warn_bg_pressed -> "button-warn-bg-pressed"
  | `Button_subtle_bg -> "button-subtle-bg"
  | `Button_subtle_fg -> "button-subtle-fg"
  | `Button_subtle_border -> "button-subtle-border"
  | `Button_subtle_bg_hover -> "button-subtle-bg-hover"
  | `Button_subtle_bg_pressed -> "button-subtle-bg-pressed"
  | `Input_bg -> "input-bg"
  | `Input_fg -> "input-fg"
  | `Input_border -> "input-border"
  | `Input_bg_hover -> "input-bg-hover"
  | `Input_bg_focus -> "input-bg-focus"
  | `Input_placeholder -> "input-placeholder"
  | `Input_border_focus -> "input-border-focus"
  | `Dialog_panel_bg -> "dialog-panel-bg"
  | `Dialog_panel_border -> "dialog-panel-border"
  | `Dialog_overlay_bg -> "dialog-overlay-bg"
  | `Toast_bg -> "toast-bg"
  | `State_hover_bg -> "state-hover-bg"
  | `State_hover_fg -> "state-hover-fg"
  | `State_hover_border -> "state-hover-border"
  | `State_selected_bg -> "state-selected-bg"
  | `State_selected_fg -> "state-selected-fg"
  | `State_selected_border -> "state-selected-border"
  | `State_pressed_bg -> "state-pressed-bg"
  | `State_active_bg -> "state-active-bg"
  | `State_active_fg -> "state-active-fg"
  | `State_active_border -> "state-active-border"
  | `State_disabled_fg -> "state-disabled-fg"
  | `State_disabled_bg -> "state-disabled-bg"
  | `Divider -> "divider"
  | `Divider_emphasis -> "divider-emphasis"
  | `Divider_zone -> "divider-zone"
  | `Scrim_subtle -> "scrim-subtle"
  | `Scrim -> "scrim"
  | `Scrim_strong -> "scrim-strong"
  | `Scrim_brass -> "scrim-brass"
  | `Bg_tab_sticky_hover -> "bg-tab-sticky-hover"
  | `Tab_bg -> "tab-bg"
  | `Tab_bg_active -> "tab-bg-active"
  | `Tab_bg_hover -> "tab-bg-hover"
  | `Tab_fg -> "tab-fg"
  | `Tab_fg_active -> "tab-fg-active"
  | `Tab_border -> "tab-border"
  | `Tab_indicator -> "tab-indicator"
  | `Tab_close_hover -> "tab-close-hover"
  | `Sidebar_bg -> "sidebar-bg"
  | `Sidebar_fg -> "sidebar-fg"
  | `Sidebar_item_hover_bg -> "sidebar-item-hover-bg"
  | `Sidebar_item_active_bg -> "sidebar-item-active-bg"
  | `Sidebar_icon_fg -> "sidebar-icon-fg"
  | `Sidebar_icon_active_fg -> "sidebar-icon-active-fg"
  | `Sidebar_section_header_fg -> "sidebar-section-header-fg"
  | `Sidebar_border -> "sidebar-border"
  | `Panel_header_bg -> "panel-header-bg"
  | `Panel_header_fg -> "panel-header-fg"
  | `Panel_resize_handle -> "panel-resize-handle"
  | `Panel_resize_handle_hover -> "panel-resize-handle-hover"
  | `Terminal_bg -> "terminal-bg"
  | `Terminal_fg -> "terminal-fg"
  | `Terminal_prompt -> "terminal-prompt"
  | `Terminal_cursor -> "terminal-cursor"
  | `Terminal_selection_bg -> "terminal-selection-bg"
  | `Menu_bg -> "menu-bg"
  | `Menu_border -> "menu-border"
  | `Menu_shadow -> "menu-shadow"
  | `Menu_separator -> "menu-separator"
  | `Menuitem_fg -> "menuitem-fg"
  | `Menuitem_hover_bg -> "menuitem-hover-bg"
  | `Menuitem_active_bg -> "menuitem-active-bg"
  | `Menuitem_disabled_fg -> "menuitem-disabled-fg"
  | `Menu_shortcut_fg -> "menu-shortcut-fg"
  | `Tooltip_bg -> "tooltip-bg"
  | `Tooltip_fg -> "tooltip-fg"
  | `Tooltip_border -> "tooltip-border"
  | `Tooltip_shadow -> "tooltip-shadow"
  | `Toast_bg_info -> "toast-bg-info"
  | `Toast_bg_success -> "toast-bg-success"
  | `Toast_bg_warning -> "toast-bg-warning"
  | `Toast_bg_error -> "toast-bg-error"
  | `Toast_fg -> "toast-fg"
  | `Toast_border -> "toast-border"
  | `Toast_shadow -> "toast-shadow"
  | `Terminal_ansi_black -> "terminal-ansi-black"
  | `Terminal_ansi_red -> "terminal-ansi-red"
  | `Terminal_ansi_green -> "terminal-ansi-green"
  | `Terminal_ansi_yellow -> "terminal-ansi-yellow"
  | `Terminal_ansi_blue -> "terminal-ansi-blue"
  | `Terminal_ansi_magenta -> "terminal-ansi-magenta"
  | `Terminal_ansi_cyan -> "terminal-ansi-cyan"
  | `Terminal_ansi_white -> "terminal-ansi-white"
  | `Terminal_ansi_bright_black -> "terminal-ansi-bright-black"
  | `Terminal_ansi_bright_red -> "terminal-ansi-bright-red"
  | `Terminal_ansi_bright_green -> "terminal-ansi-bright-green"
  | `Terminal_ansi_bright_yellow -> "terminal-ansi-bright-yellow"
  | `Terminal_ansi_bright_blue -> "terminal-ansi-bright-blue"
  | `Terminal_ansi_bright_magenta -> "terminal-ansi-bright-magenta"
  | `Terminal_ansi_bright_cyan -> "terminal-ansi-bright-cyan"
  | `Terminal_ansi_bright_white -> "terminal-ansi-bright-white"
  | `Motion_enter -> "motion-enter"
  | `Motion_exit -> "motion-exit"
  | `Motion_swap -> "motion-swap"
  | `Motion_reveal -> "motion-reveal"
  | `Motion_settle -> "motion-settle"
  | `Motion_pop -> "motion-pop"
  | `Enter_duration -> "enter-duration"
  | `Exit_duration -> "exit-duration"
  | `Enter_easing -> "enter-easing"
  | `Exit_easing -> "exit-easing"
  | `_motion_scope -> "_motion-scope"
  | `Cmt_question -> "cmt-question"
  | `Cmt_flag -> "cmt-flag"
  | `Cmt_note -> "cmt-note"
  | `Cmt_approve -> "cmt-approve"
  | `Cmt_suggest -> "cmt-suggest"
  | `Diff_add -> "diff-add"
  | `Diff_del -> "diff-del"
  | `Diff_add_bar -> "diff-add-bar"
  | `Diff_del_bar -> "diff-del-bar"
  | `Heat_1 -> "heat-1"
  | `Heat_2 -> "heat-2"
  | `Heat_3 -> "heat-3"
  | `Color_text_body -> "color-text-body"
  | `Color_text_muted -> "color-text-muted"
  | `Color_text_dim -> "color-text-dim"
  | `Color_accent_brass -> "color-accent-brass"
  | `Color_accent_soft -> "color-accent-soft"
  | `Color_keeper_1_glow -> "color-keeper-1-glow"
  | `Color_keeper_2_glow -> "color-keeper-2-glow"
  | `Color_keeper_3_glow -> "color-keeper-3-glow"
  | `Color_keeper_4_glow -> "color-keeper-4-glow"
  | `Color_keeper_5_glow -> "color-keeper-5-glow"
  | `Color_keeper_6_glow -> "color-keeper-6-glow"
  | `Color_keeper_7_glow -> "color-keeper-7-glow"
  | `Color_keeper_8_glow -> "color-keeper-8-glow"
  | `Color_keeper_9_glow -> "color-keeper-9-glow"
  | `Color_keeper_10_glow -> "color-keeper-10-glow"
  | `Color_keeper_11_glow -> "color-keeper-11-glow"
  | `Color_keeper_12_glow -> "color-keeper-12-glow"

let var_of t = "var(--" ^ name_of t ^ ")"
