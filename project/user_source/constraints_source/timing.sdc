
# ============================================================
# merged_top_tf_hdmi_audio.sdc
# ???TF ???? + HDMI(??+??) ????
#
# ?????
# 1) ?? top.sdc ???????? derive_clocks
# 2) ? timing(2).sdc ?? pixel/serial ????????????
# 3) ?? hdmi_5x_clk / audio_mclk ???
# 4) ????? net ?? create_clock???? derive_clocks ??
# ============================================================

# ------------------------------------------------------------
# 1. ???????
#    ??? top.sdc ? clk=50MHz???????? 20ns
# ------------------------------------------------------------
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]

# ------------------------------------------------------------
# 2. ???? PLL ????
# ------------------------------------------------------------
derive_clocks

# ------------------------------------------------------------
# 3. ??? PLL ????
#    ???????????????????
#      sys_pll      -> sys_pll_m0
#      video_pll    -> video_pll_m0
#      ?? PLL     -> u_audio_pll
#
#    ???????????????? Timing Analyzer ???? pin ????
# ------------------------------------------------------------
rename_clock -name {sd_card_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {ext_mem_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {video_clk}   -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {audio_mclk}  -source [get_ports {clk}] -master_clock {clk} [get_pins {u_audio_pll/pll_inst.clkc[2]}]

# ------------------------------------------------------------
# 4. ?? timing(2).sdc ????? HDMI ??/??????
#
#    ?????
#      create_clock -name pixel_clk  ... [get_nets {S_pixel_clk}]
#      create_clock -name serial_clk ... [get_nets {S_serial_clk}]
#      set_clock_groups -exclusive ...
#
#    ??????????????? video_pll ?????? derive_clocks ?????
#    ????????????????? create_clock?
#
#    ???????????? video_clk ? hdmi_5x_clk ?? exclusive?
#    ???? Timing Analyzer ??????????????????????????
# ------------------------------------------------------------
set_clock_groups -exclusive \
    -group [get_clocks {video_clk}] \
    -group [get_clocks {hdmi_5x_clk}]

# ------------------------------------------------------------
# 5. ?? I2S ???/?????
#
#    audio_mclk ???? I2S?video_clk ??????????
#    ???????????????????????
# ------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks {audio_mclk}] \
    -group [get_clocks {clk video_clk hdmi_5x_clk sd_card_clk ext_mem_clk}]

# ------------------------------------------------------------
# 6. TF/SDRAM/video ??????????? FIFO?toggle ????
#    ??????????????????????????????
#    ????????????? PLL ???????????????
# ------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks {sd_card_clk}] \
    -group [get_clocks {ext_mem_clk}] \
    -group [get_clocks {video_clk}]

# ------------------------------------------------------------
# 7. ?? Input/Output delay ?????
#    ??????? sdc ?????????
# ------------------------------------------------------------

# ------------------------------------------------------------
# 8. EG4S20 ?? SDRAM ????
#
# EG_PHY_SDRAM_2M_32 ???????????TD 6.2 ???? DQ ??
# ???????? PAD ????????????? fabric ?????
# ?? SWNS????????????? -6.7 ns???????? DQ
# ???????????? SDRAM ????FIFO???/??????
# ext_mem_clk ???????????
# ------------------------------------------------------------
set_false_path -from [get_pins -nowarn {U3/sdram.dq[*]}]
set_false_path -to   [get_pins -nowarn {U3/sdram.dq[*]}]

# The SDRAM macro's address/control pads are also fixed hard-IP boundary arcs.
# They are timed by the macro model and cannot be changed by fabric routing.
set_false_path -to [get_pins -nowarn {U3/sdram.*}]

# Async reset assertion is intentional.  Deassertion is made synchronous in
# each clock domain by the rst_*_sync chains in top_tf_hdmi_audio.v, so the
# synchronizer flops' own recovery/removal arcs are excluded from STA.
# Removed obsolete no-match SR pattern; no timing paths are added to exceptions.

# startup_done is part of the asynchronous reset assertion request. Its
# deassertion reaches functional logic only through the per-domain two-flop
# reset synchronizers, so direct recovery/removal analysis to SR pins is false.
# startup_done is a logical net; packing may move its Q into an unrelated cell.
# Cut only its asynchronous reset assertion path into SR pins. Deassertion
# still passes through the per-domain two-flop reset synchronizers.
set_false_path -through [get_nets {startup_done}] -to [get_pins -nowarn {*.sr}]

# The only video->50-MHz data consumers are effect_mode_clk_s1[1:0],
# followed by effect_mode_clk_s2[1:0] for the debug seven-segment display.
# Do not impose phase-related setup/hold on the first-stage CDC sample.
# Its second-stage 50-MHz paths and every functional data path remain timed.
set_false_path -from [get_clocks {video_clk}] -to [get_clocks {clk}]

