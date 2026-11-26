
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,           // 手动下一张
    input                       key2,           // 自动播放 开/关
    input                       key3,           // 图像算法切换
    inout                       gesture_sda,    // J2 pin 1 via RN29, FPGA P4
    inout                       gesture_scl,    // J2 pin 2 via RN29, FPGA N4
    input                       uart_rxd,       // CH340 RXD, FPGA pin F12
    output                      uart_txd,       // CH340 TXD, FPGA pin D12

    output [5:0]                seg_sel,
    output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter FRAME_PIXELS  = 24'd307200;   // 640*480
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire        display_valid;

// ====== 显示特效模块(my_display_fx) 相关连线 ======
wire zoom_toggle_video,zoom_next_sd;
wire [1:0] zoom_level_sd;
reg [1:0] zoom_video_s1,zoom_video_s2,zoom_video;
wire        fx_hs;
wire        fx_vs;
wire        fx_de;
wire [23:0] fx_rgb;
wire [1:0]  effect_mode_video;
wire [7:0]  scene_luma_video;
wire        effect_next_pulse;
wire        brightness_next_pulse;
wire        audio_tick;
wire        overlay_toggle_pulse;
wire        focus_toggle_pulse;
wire alpha_next_pulse;
wire        key3_press_pulse;
wire        key3_debounced;
wire        key1_adjust_press;
wire        key2_adjust_press;
reg         key3_video_s1;
reg         key3_video_s2;
reg         key3_video_d;
reg         key3_armed;
reg         key3_combo_used;
reg  [25:0] key3_hold_count;
wire        transition_toggle_sd;
wire        image_change_start_video;
reg         transition_video_s1;
reg         transition_video_s2;
reg         transition_video_d;

wire [3:0]  state_code;
wire [6:0]  seg_hex_state;
wire [6:0]  seg_hex_count;
wire [6:0]  seg_hex_index;
wire [6:0]  seg_hex_effect;
wire [6:0]  seg_hex_auto;
wire [6:0]  seg_hex_valid;

// CDC: state_code is produced in the 100 MHz SD-card domain but displayed in
// the 50 MHz board-clock domain.  Two sampling stages prevent the seven-
// segment decoder from seeing metastable status bits.
reg  [3:0]  state_code_clk_s1;
reg  [3:0]  state_code_clk_s2;
reg  [2:0]  image_count_clk_s1;
reg  [2:0]  image_count_clk_s2;
reg  [1:0]  image_index_clk_s1;
reg  [1:0]  image_index_clk_s2;
reg         auto_play_clk_s1;
reg         auto_play_clk_s2;
reg         display_valid_clk_s1;
reg         display_valid_clk_s2;
reg  [1:0]  effect_mode_clk_s1;
reg  [1:0]  effect_mode_clk_s2;

// CDC: display_valid is asserted by the SD-card controller and consumed by
// the pixel pipeline.  Synchronize it before it gates RGB data.
reg         display_valid_video_s1;
reg         display_valid_video_s2;
reg         display_valid_video;
reg  [1:0]  disp_buf_video_s1;
reg  [1:0]  disp_buf_video_s2;
reg  [1:0]  disp_buf_idx_video;
reg  [1:0]  image_index_video_s1;
reg  [1:0]  image_index_video_s2;
reg  [1:0]  image_index_video;
reg         vs_0_d;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data;

wire        sd_card_write_en;
wire sd_card_write_pause;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx_sd;
wire [2:0]  image_count_sd;
wire [1:0]  image_index_sd;
wire subtitle_wr_en_sd;
wire [10:0] subtitle_wr_addr_sd;
wire [7:0] subtitle_wr_data_sd;
wire [6:0] subtitle_count_sd;
wire subtitle_boot_done_sd;
wire uart_subtitle_wr_en;
wire uart_subtitle_wr_bank;
wire [10:0] uart_subtitle_wr_addr;
wire [7:0] uart_subtitle_wr_data;
wire [6:0] uart_subtitle_count;
wire uart_subtitle_bank;
wire uart_subtitle_commit;
wire uart_subtitle_ack;
wire        auto_play_en_sd;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;
wire vs_0_edge = vs_0 & ~vs_0_d;

// HDMI 1.4b 音频发射相关
wire        audio_pll_lock;
wire        audio_mclk;
wire        audio_i2s_bclk;
wire        audio_i2s_lrck;
wire        audio_i2s_dout;
wire        audio_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;

wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// Global asynchronous reset request.  Each clock domain below performs an
// asynchronous assertion and a two-cycle synchronous release.  This avoids
// recovery/removal violations when startup_done changes in the 50 MHz domain.
wire rst_async;
wire rst_clk;
wire rst_sd;
wire rst_mem;
wire rst_video;
wire rst_audio;
wire rst_hdmi5;
reg [1:0] rst_clk_sync;
reg [1:0] rst_sd_sync;
reg [1:0] rst_mem_sync;
reg [1:0] rst_video_sync;
reg [1:0] rst_audio_sync;
reg [1:0] rst_hdmi5_sync;
reg [17:0] startup_count;
reg        startup_done;
assign rst_async = ~rst_n | ~audio_pll_lock | ~startup_done;
assign rst_clk    = rst_clk_sync[1];
assign rst_sd     = rst_sd_sync[1];
assign rst_mem    = rst_mem_sync[1];
assign rst_video  = rst_video_sync[1];
assign rst_audio  = rst_audio_sync[1];
assign rst_hdmi5  = rst_hdmi5_sync[1];

// Give every PLL and the embedded SDRAM clock tree about 5 ms to settle.
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        startup_count <= 18'd0;
        startup_done  <= 1'b0;
    end else if (!audio_pll_lock) begin
        startup_count <= 18'd0;
        startup_done  <= 1'b0;
    end else if (!startup_done) begin
        if (&startup_count)
            startup_done <= 1'b1;
        else
            startup_count <= startup_count + 18'd1;
    end
end

always @(posedge clk or posedge rst_async)
    if (rst_async) rst_clk_sync <= 2'b11;
    else           rst_clk_sync <= {rst_clk_sync[0], 1'b0};

always @(posedge sd_card_clk or posedge rst_async)
    if (rst_async) rst_sd_sync <= 2'b11;
    else           rst_sd_sync <= {rst_sd_sync[0], 1'b0};

always @(posedge ext_mem_clk or posedge rst_async)
    if (rst_async) rst_mem_sync <= 2'b11;
    else           rst_mem_sync <= {rst_mem_sync[0], 1'b0};

always @(posedge video_clk or posedge rst_async)
    if (rst_async) rst_video_sync <= 2'b11;
    else           rst_video_sync <= {rst_video_sync[0], 1'b0};

always @(posedge audio_mclk or posedge rst_async)
    if (rst_async) rst_audio_sync <= 2'b11;
    else           rst_audio_sync <= {rst_audio_sync[0], 1'b0};

always @(posedge hdmi_5x_clk or posedge rst_async)
    if (rst_async) rst_hdmi5_sync <= 2'b11;
    else           rst_hdmi5_sync <= {rst_hdmi5_sync[0], 1'b0};

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft),
    .reset      (1'b0)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk),
    .reset      (1'b0)
);

// 复用你 I2S->HDMI 工程里的 PLL，只取 12.288MHz 音频主时钟
PLL_HDMI_AUDIO u_audio_pll(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (audio_pll_lock),
    .clk0_out   (),
    .clk1_out   (),
    .clk2_out   (audio_mclk)
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_mem) begin
    if (rst_mem)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

always @(posedge clk or posedge rst_clk) begin
    if (rst_clk) begin
        state_code_clk_s1 <= 4'd0;
        state_code_clk_s2 <= 4'd0;
        image_count_clk_s1 <= 3'd0;
        image_count_clk_s2 <= 3'd0;
        image_index_clk_s1 <= 2'd0;
        image_index_clk_s2 <= 2'd0;
        auto_play_clk_s1 <= 1'b0;
        auto_play_clk_s2 <= 1'b0;
        display_valid_clk_s1 <= 1'b0;
        display_valid_clk_s2 <= 1'b0;
        effect_mode_clk_s1 <= 2'd0;
        effect_mode_clk_s2 <= 2'd0;
    end else begin
        state_code_clk_s1 <= state_code;
        state_code_clk_s2 <= state_code_clk_s1;
        image_count_clk_s1 <= image_count_sd;
        image_count_clk_s2 <= image_count_clk_s1;
        image_index_clk_s1 <= image_index_sd;
        image_index_clk_s2 <= image_index_clk_s1;
        auto_play_clk_s1 <= auto_play_en_sd;
        auto_play_clk_s2 <= auto_play_clk_s1;
        display_valid_clk_s1 <= display_valid;
        display_valid_clk_s2 <= display_valid_clk_s1;
        effect_mode_clk_s1 <= effect_mode_video;
        effect_mode_clk_s2 <= effect_mode_clk_s1;
    end
end

always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        display_valid_video_s1 <= 1'b0;
        display_valid_video_s2 <= 1'b0;
        display_valid_video    <= 1'b0;
        disp_buf_video_s1      <= 2'd0;
        disp_buf_video_s2      <= 2'd0;
        disp_buf_idx_video     <= 2'd0;
        image_index_video_s1   <= 2'd0;
        image_index_video_s2   <= 2'd0;
        image_index_video      <= 2'd0;
        vs_0_d                 <= 1'b0;
        transition_video_s1     <= 1'b0;
        transition_video_s2     <= 1'b0;
        transition_video_d      <= 1'b0;
    end else begin
        display_valid_video_s1 <= display_valid;
        display_valid_video_s2 <= display_valid_video_s1;
        disp_buf_video_s1      <= disp_buf_idx_sd;
        disp_buf_video_s2      <= disp_buf_video_s1;
        image_index_video_s1   <= image_index_sd;
        image_index_video_s2   <= image_index_video_s1;
        vs_0_d                 <= vs_0;
        transition_video_s1     <= transition_toggle_sd;
        transition_video_s2     <= transition_video_s1;
        transition_video_d      <= transition_video_s2;
        if (vs_0_edge) begin
            display_valid_video <= display_valid_video_s2;
            disp_buf_idx_video  <= disp_buf_video_s2;
            image_index_video   <= image_index_video_s2;
        end
    end
end

assign image_change_start_video = transition_video_s2 ^ transition_video_d;

// APDS-9960 gestures in the 25-MHz video domain: LEFT next, RIGHT autoplay; UP/DOWN actions disabled.
wire gesture_online,gesture_event,gesture_tick_ms,gesture_next_active,gesture_auto_active;
wire gesture_zoom_video,gesture_zoom_sd,gesture_effect_toggle,gesture_effect_video;
reg gesture_zoom_toggle;
wire [2:0] gesture_direction;
wire [23:0] gesture_diagnostic;
wire key_zoom_next_sd;
mg_apds9960 #(.CLK_HZ(25000000),.I2C_HZ(50000),.AA_COMPAT(1)) u_gesture_sensor(.clk(video_clk),.rst(rst_video),
 .scl(gesture_scl),.sda(gesture_sda),.online(gesture_online),.diagnostic(gesture_diagnostic),
 .event_valid(gesture_event),.direction(gesture_direction),.tick_ms(gesture_tick_ms));
mg_gesture_actions #(.VERTICAL_ENABLE(0)) u_gesture_actions(.clk(video_clk),.rst(rst_video),.tick_ms(gesture_tick_ms),
 .event_valid(gesture_event),.direction(gesture_direction),.next_active(gesture_next_active),
 .auto_active(gesture_auto_active),.zoom_pulse(gesture_zoom_video),.effect_toggle(gesture_effect_toggle));
mg_zoom_cdc u_gesture_effect_cdc(.clk(video_clk),.rst(rst_video),
 .event_toggle(gesture_effect_toggle),.event_pulse(gesture_effect_video));
// The next/auto levels are held 40 ms; existing two-flop key debouncers
// synchronize them in the SD domain. Zoom uses a separate toggle synchronizer.
always @(posedge video_clk or posedge rst_video)
 if(rst_video)gesture_zoom_toggle<=0;
 else if(gesture_zoom_video)gesture_zoom_toggle<=~gesture_zoom_toggle;
mg_zoom_cdc u_gesture_zoom_cdc(.clk(sd_card_clk),.rst(rst_sd),
 .event_toggle(gesture_zoom_toggle),.event_pulse(gesture_zoom_sd));
assign zoom_next_sd=key_zoom_next_sd | gesture_zoom_sd;

// ===================== FAT32 根目录多图索引与双缓冲 =====================
wire key_next_masked, key_auto_masked;
key_combo_mask u_key_combo_mask (
    .clk(sd_card_clk), .rst(rst_sd),
    .key1(key1), .key2(key2), .key3(key3),
    .key_next(key_next_masked), .key_auto(key_auto_masked)
);
sd_card_bmp #(
    .LOAD_SUBTITLE(0), // Directory scan only; fixed subtitle has no SD font dependency.
    .BILINEAR(1), .SCALING_MODE(1), .KEY_ZOOM(1),    .CLK_FREQ_HZ       (100_000_000),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd4)
) sd_card_bmp_m0(
    .display_buf_ack(disp_buf_idx_video),
    .zoom_next(zoom_next_sd),.zoom_level_o(zoom_level_sd),
    .clk               (sd_card_clk),
    .rst               (rst_sd),
    .audio_clk(video_clk), .audio_rst(rst_video), .audio_tick(audio_tick),
    .audio_pcm(audio_left_data), .audio_valid(audio_valid),
    // Keep a combination suppressed until every participating key is up.
    .key_next          (key_next_masked & ~gesture_next_active),
    .key_auto          (key_auto_masked & ~gesture_auto_active),
    .state_code        (state_code),
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .display_valid     (display_valid),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx_sd),
    .image_count       (image_count_sd),
    .image_index       (image_index_sd),
    .auto_play_en_o    (auto_play_en_sd),
    .transition_toggle (transition_toggle_sd),
    .subtitle_wr_en    (subtitle_wr_en_sd),
    .subtitle_wr_addr  (subtitle_wr_addr_sd),
    .subtitle_wr_data  (subtitle_wr_data_sd),
    .subtitle_count    (subtitle_count_sd),
    .subtitle_boot_done(subtitle_boot_done_sd),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_pause       (sd_card_write_pause),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso)
);

// Fixed subtitle build: CH340 receive input has no command decoder.
// Keep the transmitter electrically idle and retain the board pin interface.
assign uart_txd=1'b1;
assign uart_subtitle_wr_en=1'b0;
assign uart_subtitle_wr_bank=1'b0;
assign uart_subtitle_wr_addr=11'd0;
assign uart_subtitle_wr_data=8'd0;
assign uart_subtitle_count=7'd0;
assign uart_subtitle_bank=1'b0;
assign uart_subtitle_commit=1'b0;

seg_decoder u_seg_state(
    .bin_data          (state_code_clk_s2),
    .seg_data          (seg_hex_state)
);
seg_decoder u_seg_count(
    .bin_data          ({1'b0,image_count_clk_s2}),
    .seg_data          (seg_hex_count)
);
seg_decoder u_seg_index(
    .bin_data          (display_valid_clk_s2 ? {2'b00,image_index_clk_s2} + 4'd1 : 4'd0),
    .seg_data          (seg_hex_index)
);
seg_decoder u_seg_effect(
    .bin_data          ({2'b00,effect_mode_clk_s2}),
    .seg_data          (seg_hex_effect)
);
seg_decoder u_seg_auto(
    .bin_data          ({3'b000,auto_play_clk_s2}),
    .seg_data          (seg_hex_auto)
);
seg_decoder u_seg_valid(
    .bin_data          ({3'b000,display_valid_clk_s2}),
    .seg_data          (seg_hex_valid)
);

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        ({1'b1,seg_hex_valid}),
    .seg_data_1        ({1'b1,seg_hex_auto}),
    .seg_data_2        ({1'b1,seg_hex_effect}),
    .seg_data_3        ({1'b1,seg_hex_index}),
    .seg_data_4        ({1'b1,seg_hex_count}),
    .seg_data_5        ({1'b1,seg_hex_state})
);

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_video),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_video),
    .read_en           (video_read_en),
    .read_data         (video_read_data[31:8]),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw)
);

// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容
assign vout_data = display_valid_video ? vout_data_raw : 24'd0;

key_press_debounce #(
    .CLK_FREQ_HZ (25_000_000),
    .DEBOUNCE_MS (20)
) u_key_effect (
    .clk         (video_clk),
    .rst         (rst_video),
    .button_in   (key3),
    .press_pulse (key3_press_pulse),
    .button_stable_o(key3_debounced)
);

key_press_debounce #(
    .CLK_FREQ_HZ (25_000_000),
    .DEBOUNCE_MS (20)
) u_key_brightness (
    .clk         (video_clk),
    .rst         (rst_video),
    .button_in   (key1),
    .press_pulse (key1_adjust_press)
);

key_press_debounce #(
    .CLK_FREQ_HZ (25_000_000),
    .DEBOUNCE_MS (20)
) u_key_wave_gain (
    .clk         (video_clk),
    .rst         (rst_video),
    .button_in   (key2),
    .press_pulse (key2_adjust_press)
);

// Hold KEY3 first, then tap KEY2: cycle zoom without toggling autoplay.
mg_demo_keys #(.ENABLE_ALPHA(1)) u_demo_keys(
 .clk(video_clk),.rst(rst_video),.key3_debounced(key3_debounced),
 .key3_press_pulse(key3_press_pulse),.key1_adjust_press(key1_adjust_press),.key2_adjust_press(key2_adjust_press),
 .effect_next_pulse(effect_next_pulse),.brightness_next_pulse(brightness_next_pulse),
 .overlay_toggle_pulse(overlay_toggle_pulse),.focus_toggle_pulse(focus_toggle_pulse),.zoom_toggle(zoom_toggle_video),.alpha_next_pulse(alpha_next_pulse));
mg_zoom_cdc u_zoom_cdc(.clk(sd_card_clk),.rst(rst_sd),.event_toggle(zoom_toggle_video),.event_pulse(key_zoom_next_sd));
always @(posedge video_clk or posedge rst_video) begin
 if(rst_video) begin zoom_video_s1<=2;zoom_video_s2<=2;zoom_video<=2;end
 else begin
  zoom_video_s1<=zoom_level_sd;zoom_video_s2<=zoom_video_s1;
  if(vs_0_edge)zoom_video<=zoom_video_s2;
 end
end

// ===================== 原创实时图像处理流水线 =====================
// 透传 / 自适应增强 / 青色轮廓融合 / 暖色海报化，切图与切模式均淡入。
// 链路: video_delay 的 vout_data -> my_display_fx -> video_rgb_to_axis
my_display_fx #(.GESTURE_STATUS(1),.GESTURE_DIAGNOSTICS(0),.UNIFIED_PANEL(1),.RESOLUTION_OSD(1),.H_ACTIVE(640),.V_ACTIVE(480),.ALPHA_OVERLAY(1),.ZOOM_OSD(1)) u_my_display_fx(
    .gesture_online(gesture_online),.gesture_diagnostic(gesture_diagnostic),
    .zoom_level(zoom_video),
    .video_clk (video_clk),
    .sd_clk    (sd_card_clk),
    .subtitle_wr_en(subtitle_wr_en_sd),
    .subtitle_wr_addr(subtitle_wr_addr_sd),
    .subtitle_wr_data(subtitle_wr_data_sd),
    .subtitle_count(subtitle_count_sd),
    .uart_subtitle_wr_en(uart_subtitle_wr_en),
    .uart_subtitle_wr_bank(uart_subtitle_wr_bank),
    .uart_subtitle_wr_addr(uart_subtitle_wr_addr),
    .uart_subtitle_wr_data(uart_subtitle_wr_data),
    .uart_subtitle_count(uart_subtitle_count),
    .uart_subtitle_bank(uart_subtitle_bank),
    .uart_subtitle_commit(uart_subtitle_commit),
    .uart_subtitle_ack(uart_subtitle_ack),
    .rst       (rst_video),
    .hs        (hs),
    .vs        (vs),
    .de        (de),
    .disp_buf_idx (disp_buf_idx_video),
    .image_index  (image_index_video),
    .effect_next  (effect_next_pulse | gesture_effect_video),
    .image_change_start(image_change_start_video),
    .brightness_next(brightness_next_pulse),
    .wave_gain_next(alpha_next_pulse),
    .overlay_toggle(overlay_toggle_pulse),
    .focus_toggle(focus_toggle_pulse),
    .audio_valid(audio_valid),
    .audio_sample(audio_left_data),
    .rgb_in    (vout_data),
    .hs_o      (fx_hs),
    .vs_o      (fx_vs),
    .de_o      (fx_de),
    .rgb_o     (fx_rgb),
    .effect_mode(effect_mode_video),
    .scene_luma(scene_luma_video)
);

frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (24'd0),
    .read_addr_3       (24'd0),
    .read_addr_index   (disp_buf_idx_video),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (24'd0),
    .write_addr_3      (24'd0),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
    .write_pause       (sd_card_write_pause),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// ===================== 音频：I2S 采样节拍，TF 卡提供实际 PCM =====================
hdmi_audio_tone_i2s_64fs #(
    .PHASE_INC (32'd39370534),
    .AMP       (24'sd0)
) u_hdmi_audio_tone_i2s_64fs (
    .I_mclk      (audio_mclk),
    .I_rst       (rst_audio),
    .O_i2s_BCLK  (audio_i2s_bclk),
    .O_i2s_LRCK  (audio_i2s_lrck),
    .O_i2s_DOUT  (audio_i2s_dout)
);

assign audio_right_data=audio_left_data;
// The existing receiver supplies the tested 48 kHz sample cadence only.
// HDMI and FFT both receive TF-card PCM above.
I2S_receiver u_I2S_receiver(
    .I_clk              (video_clk),
    .I_rst              (rst_video),
    .I_i2s_BCLK         (audio_i2s_bclk),
    .I_i2s_LRCK         (audio_i2s_lrck),
    .I_i2s_DOUT         (audio_i2s_dout),
    .O_audio_valid      (audio_tick),
    .O_audio_left_data  (),
    .O_audio_right_data ()
);

audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (rst_video),
    .I_audio_valid (audio_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_video),
    .I_vs          (fx_vs),    // 改: 来自 my_display_fx
    .I_de          (fx_de),    // 改: 来自 my_display_fx
    .I_rgb         (fx_rgb),   // 改: 来自 my_display_fx
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_video),
    .O_pulse (edid_trig)
);

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_video),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left_data),
    .I_audio_right_data (audio_right_data),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_hdmi5),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule

// PC -> CH340 -> FPGA. A5 5A, glyph count (0..64), count*32 glyph bytes,
// then 8-bit sum of count and data. The PC renders Unicode glyphs from
// FONT.BIN; the FPGA only receives pixels, so live updates never touch TF.
module key_combo_mask (
    input wire clk, rst, key1, key2, key3,
    output wire key_next, key_auto
);
    reg [2:0] keys_s1, keys_s2;
    reg blocked;
    assign key_next = key1 | ~key3 | blocked;
    assign key_auto = key2 | ~key3 | blocked;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            keys_s1<=3'b111; keys_s2<=3'b111; blocked<=1'b0;
        end else begin
            keys_s1<={key3,key2,key1}; keys_s2<=keys_s1;
            if (!keys_s2[2]) blocked<=1'b1;
            else if (keys_s2==3'b111) blocked<=1'b0;
        end
    end
endmodule

module mg_demo_keys #(parameter ENABLE_ALPHA=0,HOLD_ALPHA=75000000,HOLD_FOCUS=25000000,HOLD_LONG=50000000)(
 input clk,rst,key3_debounced,key3_press_pulse,key1_adjust_press,key2_adjust_press,
 output reg effect_next_pulse,brightness_next_pulse,overlay_toggle_pulse,focus_toggle_pulse,zoom_toggle,alpha_next_pulse);
reg key3_video_s1,key3_video_s2,key3_video_d,key3_armed,key3_combo_used;
reg [26:0] key3_hold_count;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        key3_video_s1        <= 1'b1;
        key3_video_s2        <= 1'b1;
        key3_video_d         <= 1'b1;
        key3_armed           <= 1'b0;
        key3_combo_used      <= 1'b0;
        effect_next_pulse    <= 1'b0;
        brightness_next_pulse<= 1'b0;
        overlay_toggle_pulse <= 1'b0;
        focus_toggle_pulse   <= 1'b0;
        key3_hold_count      <= 26'd0;
        zoom_toggle<=0;alpha_next_pulse<=0;
    end else begin
        key3_video_s1 <= key3_debounced;
        key3_video_s2 <= key3_video_s1;
        key3_video_d  <= key3_video_s2;
        effect_next_pulse     <= 1'b0;
        brightness_next_pulse <= 1'b0;
        overlay_toggle_pulse  <= 1'b0;
        focus_toggle_pulse    <= 1'b0;alpha_next_pulse<=0;

        if (key3_press_pulse) begin
            key3_armed      <= 1'b1;
            key3_combo_used <= 1'b0;
            key3_hold_count <= 26'd0;
        end
        if (!key3_video_s2 && key1_adjust_press && key3_armed) begin
            brightness_next_pulse <= 1'b1;
            key3_combo_used       <= 1'b1;
        end
        if (!key3_video_s2 && key2_adjust_press && key3_armed) begin
            zoom_toggle<=~zoom_toggle;
            key3_combo_used     <= 1'b1;
        end
        // Decide which long-press action to take on release so a 2 s hold
        // cannot accidentally toggle both the focus and the optional OSD.
        if (!key3_video_s2 && key3_armed) begin
            if (key3_combo_used) begin
                key3_hold_count <= 26'd0;
            end else if (key3_hold_count < (ENABLE_ALPHA?HOLD_ALPHA:HOLD_LONG)) begin
                key3_hold_count <= key3_hold_count + 26'd1;
            end
        end else begin
            key3_hold_count <= 26'd0;
        end
        if (key3_video_s2 && !key3_video_d && key3_armed) begin
            if (!key3_combo_used) begin
                if (ENABLE_ALPHA && key3_hold_count >= HOLD_ALPHA)
                    alpha_next_pulse<=1'b1;
                else if (key3_hold_count >= HOLD_LONG)
                    overlay_toggle_pulse <= 1'b1;
                else if (key3_hold_count >= HOLD_FOCUS)
                    focus_toggle_pulse <= 1'b1;
                else
                    effect_next_pulse <= 1'b1;
            end
            key3_armed      <= 1'b0;
            key3_combo_used <= 1'b0;
        end
    end
end

endmodule

module mg_zoom_cdc(input clk,rst,event_toggle,output event_pulse);
reg s1,s2,previous;
always @(posedge clk or posedge rst)
 if(rst)begin s1<=0;s2<=0;previous<=0;end
 else begin s1<=event_toggle;s2<=s1;previous<=s2;end
assign event_pulse=s2^previous;
endmodule
