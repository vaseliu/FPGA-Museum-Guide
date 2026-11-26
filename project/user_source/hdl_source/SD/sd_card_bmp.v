
module sd_card_bmp #(
    parameter integer LOAD_SUBTITLE = 1,
    parameter integer BILINEAR = 0,
    parameter integer SCALING_MODE = 0,
    parameter integer KEY_ZOOM = 0,
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4
)(
    input zoom_next,
    input [1:0] display_buf_ack,
    output reg [1:0] zoom_level_o,
    input                       clk,
    input                       rst,
    input                       audio_clk, audio_rst, audio_tick,
    output [23:0]               audio_pcm,
    output                      audio_valid,
    input                       key_next,
    input                       key_auto,
    output [3:0]                state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,

    input                       write_finish_toggle,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,
    output [2:0]                image_count,
    output [1:0]                image_index,
    output                      auto_play_en_o,
    output reg                  transition_toggle,
    output                      subtitle_wr_en,
    output [10:0]               subtitle_wr_addr,
    output [7:0]                subtitle_wr_data,
    output [6:0]                subtitle_count,
    output                      subtitle_boot_done,

    output                      write_req,
    input                       write_req_ack,
    input                       write_pause,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO
);

reg [1:0] zoom_desired,zoom_loading;
reg zoom_reload;
reg display_ack_s1,display_ack_s2;
wire display_safe=!KEY_ZOOM || !display_valid || (display_ack_s2==disp_buf_idx[0]);
always @(posedge clk or posedge rst)
 if(rst)begin display_ack_s1<=0;display_ack_s2<=0;end
 else begin display_ack_s1<=display_buf_ack[0];display_ack_s2<=display_ack_s1;end
wire zoom_event=KEY_ZOOM && zoom_next && display_valid;
wire key_next_press;
wire key_auto_press;

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             sd_init_done;
wire             bmp_ready_raw;
reg              bmp_ready;
// Break the scaler state-decode path before the slideshow controller.
// load_busy prevents a second request while readiness propagates.
always @(posedge clk or posedge rst)
    if (rst) bmp_ready <= 1'b0;
    else bmp_ready <= bmp_ready_raw;
wire             scan_done;
wire [2:0]       directory_bmp_count;
wire [31:0]      directory_bmp_lba0, directory_bmp_lba1;
wire [31:0]      directory_bmp_lba2, directory_bmp_lba3;
wire             bmp_operation_error;
wire             subtitle_done;
reg initial_exhausted;
reg fallback_started;
reg fallback_scan_start;
wire fallback_scan_done, fallback_found_valid;
wire [31:0] fallback_found_sector;
assign scan_done = subtitle_done && (fallback_started ? fallback_scan_done :
                                     (directory_bmp_count!=0));
assign subtitle_boot_done = subtitle_done;
wire             subtitle_read;
wire [31:0]      subtitle_read_addr;
reg              subtitle_start;
reg              subtitle_started;
wire             subtitle_owner = subtitle_started && !subtitle_done;
wire card_read;
wire [31:0] card_read_addr;
wire [1:0] card_owner;
wire card_active;
wire music_found,music_read,music_urgent,music_file_error,music_underrun;
wire [31:0] music_cluster,music_size,volume_fat,volume_data,music_addr;
wire [7:0] volume_spc;
mg_sd_music_arbiter u_card_arbiter(
 .clk(clk),.rst(rst),.initialized(sd_init_done),
 .sub_req(subtitle_owner && subtitle_read),.sub_addr(subtitle_read_addr),
 .bmp_req(!subtitle_owner && sd_sec_read),.bmp_addr(sd_sec_read_addr),
 .music_req(music_read),.music_addr(music_addr),.music_urgent(music_urgent),
 .raw_end(sd_sec_read_end),.card_req(card_read),.card_addr(card_read_addr),
 .owner(card_owner),.active(card_active));
mg_tf_music #(.CLK_HZ(CLK_FREQ_HZ)) u_music(
 .clk(clk),.rst(rst),.enable(subtitle_done && display_valid && music_found),
 .first_cluster(music_cluster),.file_size(music_size),
 .fat_base(volume_fat),.data_base(volume_data),.sectors_per_cluster(volume_spc),
 .sd_req(music_read),.sd_addr(music_addr),.sd_data(sd_sec_read_data),
 .sd_valid(sd_sec_read_data_valid && card_active && card_owner==2),
 .sd_end(sd_sec_read_end && card_active && card_owner==2),
 .urgent(music_urgent),.file_error(music_file_error),
 .audio_clk(audio_clk),.audio_rst(audio_rst),.sample_tick(audio_tick),
 .pcm_valid(audio_valid),.pcm_sample(audio_pcm),.underrun(music_underrun));

reg              load_start_pulse;
reg [31:0]       load_sector;
reg              first_image_committed;
reg              auto_play_en;
reg [31:0]       auto_cnt;
reg [2:0]        img_found_count;
reg [1:0]        img_idx;              // 当前真正显示中的图片编号
reg [1:0]        load_idx;             // 当前正在写入的图片编号
reg [1:0]        initial_candidate;

reg [3:0]        image_bad;
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
reg [31:0]       img_sector0;
reg [31:0]       img_sector1;
reg [31:0]       img_sector2;
reg [31:0]       img_sector3;
reg              next_req_pending;
reg              load_busy;

// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
reg              source_done_seen;
reg              source_started_seen;
reg              write_done_seen;

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;

wire auto_tick;
wire [1:0] next_from_current;

assign write_en   = bmp_data_wr_en;
assign write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};
assign auto_tick  = (auto_cnt == (CLK_FREQ_HZ - 1));
assign next_from_current = next_index_playable(img_idx, img_found_count,
                                               image_bad);
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
assign image_count        = img_found_count;
assign image_index        = img_idx;
assign auto_play_en_o     = auto_play_en;

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (20)
) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_press), .button_stable_o()
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (20)
) u_key_auto (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_auto),
    .press_pulse(key_auto_press), .button_stable_o()
);

function [1:0] next_index_limited;
    input [1:0] cur;
    input [2:0] count;
    begin
        case (count)
            3'd0: next_index_limited = 2'd0;
            3'd1: next_index_limited = 2'd0;
            3'd2: next_index_limited = (cur == 2'd1) ? 2'd0 : (cur + 2'd1);
            3'd3: next_index_limited = (cur == 2'd2) ? 2'd0 : (cur + 2'd1);
            default: next_index_limited = (cur == 2'd3) ? 2'd0 : (cur + 2'd1);
        endcase
    end
endfunction

function [1:0] next_index_playable;
    input [1:0] cur; input [2:0] count; input [3:0] bad;
    begin
        // Parallel constant-index priorities, equivalent to four chained hops.
        next_index_playable=cur;
        case(count)
        3'd0,3'd1: case(cur)
            2'd0: begin
                if (!bad[0]) next_index_playable=2'd0;
            end
            2'd1: begin
                if (!bad[0]) next_index_playable=2'd0;
            end
            2'd2: begin
                if (!bad[0]) next_index_playable=2'd0;
            end
            2'd3: begin
                if (!bad[0]) next_index_playable=2'd0;
            end
        endcase
        3'd2: case(cur)
            2'd0: begin
                if (!bad[1]) next_index_playable=2'd1;
                else if (!bad[0]) next_index_playable=2'd0;
            end
            2'd1: begin
                if (!bad[0]) next_index_playable=2'd0;
                else if (!bad[1]) next_index_playable=2'd1;
            end
            2'd2: begin
                if (!bad[3]) next_index_playable=2'd3;
                else if (!bad[0]) next_index_playable=2'd0;
                else if (!bad[1]) next_index_playable=2'd1;
            end
            2'd3: begin
                if (!bad[0]) next_index_playable=2'd0;
                else if (!bad[1]) next_index_playable=2'd1;
            end
        endcase
        3'd3: case(cur)
            2'd0: begin
                if (!bad[1]) next_index_playable=2'd1;
                else if (!bad[2]) next_index_playable=2'd2;
                else if (!bad[0]) next_index_playable=2'd0;
            end
            2'd1: begin
                if (!bad[2]) next_index_playable=2'd2;
                else if (!bad[0]) next_index_playable=2'd0;
                else if (!bad[1]) next_index_playable=2'd1;
            end
            2'd2: begin
                if (!bad[0]) next_index_playable=2'd0;
                else if (!bad[1]) next_index_playable=2'd1;
                else if (!bad[2]) next_index_playable=2'd2;
            end
            2'd3: begin
                if (!bad[0]) next_index_playable=2'd0;
                else if (!bad[1]) next_index_playable=2'd1;
                else if (!bad[2]) next_index_playable=2'd2;
            end
        endcase
        default: case(cur)
            2'd0: begin
                if (!bad[1]) next_index_playable=2'd1;
                else if (!bad[2]) next_index_playable=2'd2;
                else if (!bad[3]) next_index_playable=2'd3;
                else if (!bad[0]) next_index_playable=2'd0;
            end
            2'd1: begin
                if (!bad[2]) next_index_playable=2'd2;
                else if (!bad[3]) next_index_playable=2'd3;
                else if (!bad[0]) next_index_playable=2'd0;
                else if (!bad[1]) next_index_playable=2'd1;
            end
            2'd2: begin
                if (!bad[3]) next_index_playable=2'd3;
                else if (!bad[0]) next_index_playable=2'd0;
                else if (!bad[1]) next_index_playable=2'd1;
                else if (!bad[2]) next_index_playable=2'd2;
            end
            2'd3: begin
                if (!bad[0]) next_index_playable=2'd0;
                else if (!bad[1]) next_index_playable=2'd1;
                else if (!bad[2]) next_index_playable=2'd2;
                else if (!bad[3]) next_index_playable=2'd3;
            end
        endcase
        endcase
    end
endfunction

function [31:0] sector_lut;
    input [1:0] idx;
    begin
        case (idx)
            2'd0: sector_lut = img_sector0;
            2'd1: sector_lut = img_sector1;
            2'd2: sector_lut = img_sector2;
            2'd3: sector_lut = img_sector3;
            default: sector_lut = img_sector0;
        endcase
    end
endfunction

function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input       valid_now;
    begin
        if (!valid_now)
            next_buf_lut = 2'd0;                 // 首图固定写 buffer0
        else if (cur_disp_buf == 2'd0)
            next_buf_lut = 2'd1;
        else
            next_buf_lut = 2'd0;
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        zoom_desired<=2;zoom_loading<=2;zoom_level_o<=2;zoom_reload<=0;
        load_start_pulse      <= 1'b0;
        load_sector           <= 32'd0;
        subtitle_start        <= 1'b0;
        subtitle_started      <= 1'b0;
        fallback_started <= 1'b0;
        fallback_scan_start <= 1'b0;
        first_image_committed <= 1'b0;
        // Power-on default: begin the slideshow as soon as the TF scan and
        // first-frame commit finish. KEY2 can still pause/resume playback.
        auto_play_en          <= 1'b1;
        auto_cnt              <= 32'd0;
        img_found_count       <= 3'd0;
        img_idx               <= 2'd0;
        load_idx              <= 2'd0;
        initial_candidate     <= 2'd0;
        initial_exhausted     <= 1'b0;
        image_bad             <= 4'b0000;
        pending_buf_idx       <= 2'd0;
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        img_sector0           <= 32'd0;
        img_sector1           <= 32'd0;
        img_sector2           <= 32'd0;
        img_sector3           <= 32'd0;
        next_req_pending      <= 1'b0;
        load_busy             <= 1'b0;
        source_done_seen <= 1'b0;
        source_started_seen <= 1'b0;
        write_done_seen <= 1'b0;
        display_valid         <= 1'b0;
        transition_toggle      <= 1'b0;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        // Readiness is registered; an arbiter grant may make it stale.
        // Retain a scaled-load request until the decoder has left IDLE.
        if (!SCALING_MODE || !load_busy || state_code != 4'd0)
            load_start_pulse <= 1'b0;
        subtitle_start   <= 1'b0;
        fallback_scan_start <= 1'b0;

        if (!sd_init_done) begin
            zoom_desired<=2;zoom_loading<=2;zoom_level_o<=2;zoom_reload<=0;
            subtitle_started      <= 1'b0;
            fallback_started <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en          <= 1'b1;
            auto_cnt              <= 32'd0;
            img_found_count       <= 3'd0;
            img_idx               <= 2'd0;
            load_idx              <= 2'd0;
            initial_candidate     <= 2'd0;
            initial_exhausted     <= 1'b0;
            image_bad             <= 4'b0000;
            pending_buf_idx       <= 2'd0;
            write_buf_idx         <= 2'd0;
            disp_buf_idx          <= 2'd0;
            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
            next_req_pending      <= 1'b0;
            load_busy             <= 1'b0;
            source_done_seen <= 1'b0;
            source_started_seen <= 1'b0;
            write_done_seen <= 1'b0;
            display_valid         <= 1'b0;
            transition_toggle      <= 1'b0;
        end else begin
            // Index FAT32 root directory before reading images or font data.
            if (!subtitle_started && bmp_ready) begin
                subtitle_start   <= 1'b1;
                subtitle_started <= 1'b1;
            end
            if (subtitle_done && !first_image_committed && !fallback_started) begin
                img_found_count <= directory_bmp_count;
                img_sector0 <= directory_bmp_lba0;
                img_sector1 <= directory_bmp_lba1;
                img_sector2 <= directory_bmp_lba2;
                img_sector3 <= directory_bmp_lba3;
            end
            // Preserve the old working card layout path if FAT indexing yields
            // no usable first image. Start only after subtitle ownership ends.
            if (subtitle_done && !fallback_started && !first_image_committed &&
                !load_busy && bmp_ready &&
                (directory_bmp_count==0 || initial_exhausted)) begin
                fallback_started<=1'b1;
                fallback_scan_start<=1'b1;
                img_found_count<=3'd0;
                initial_candidate<=2'd0;
                initial_exhausted<=1'b0;
                image_bad<=4'd0;
            end
            if (fallback_started && fallback_found_valid) begin
                case (img_found_count)
                    3'd0: img_sector0<=fallback_found_sector;
                    3'd1: img_sector1<=fallback_found_sector;
                    3'd2: img_sector2<=fallback_found_sector;
                    3'd3: img_sector3<=fallback_found_sector;
                    default: ;
                endcase
                if (img_found_count<3'd4)
                    img_found_count<=img_found_count+3'd1;
            end

            // 记住 bmp_read 已经把源图送完 FIFO，但还不能切显示，得等整帧写完
            // Bus ownership also deasserts ready. Only a non-IDLE decoder
            // proves that a pending scaled request was actually accepted.
            if (load_busy && (SCALING_MODE ? state_code != 4'd0 : !bmp_ready))
                source_started_seen <= 1'b1;
            if (load_busy && source_started_seen && bmp_ready)
                source_done_seen <= 1'b1;
            if (load_busy && write_finish_pulse) write_done_seen <= 1'b1;

            // A malformed card/file must never leave the slideshow locked in
            // load_busy.  The current displayed buffer remains untouched.
            if (load_busy && bmp_operation_error) begin
                load_busy        <= 1'b0;
                source_done_seen <= 1'b0;
                source_started_seen <= 1'b0;
                write_done_seen <= 1'b0;
                next_req_pending <= 1'b0;
                auto_cnt         <= 32'd0;
                if(!zoom_reload) image_bad[load_idx] <= 1'b1;
                else if(zoom_desired==zoom_loading) zoom_desired<=zoom_level_o;
                if (!first_image_committed) begin
                    if ({1'b0,initial_candidate}+3'd1 < img_found_count)
                        initial_candidate <= initial_candidate+2'd1;
                    else initial_exhausted <= 1'b1;
                end
            end

            // Remember both completions: SDRAM may finish before the trailing SD bytes.
            if (load_busy && !bmp_operation_error &&
                (source_done_seen || (source_started_seen && bmp_ready)) &&
                (write_done_seen || write_finish_pulse)) begin
                load_busy             <= 1'b0;
                source_done_seen <= 1'b0;
                source_started_seen <= 1'b0;
                write_done_seen <= 1'b0;
                disp_buf_idx          <= pending_buf_idx;
                img_idx               <= load_idx;
                zoom_level_o<=zoom_loading;
                display_valid         <= 1'b1;
                first_image_committed <= 1'b1;
            end

            begin
                // 忙的时候也只记 1 次“下一张”请求，不会累积成连跳两张
                if (key_next_press && scan_done && (img_found_count > 3'd0))
                    next_req_pending <= 1'b1;
                if (next_req_pending && next_from_current==img_idx)
                    next_req_pending <= 1'b0;

                // 自动播放开/关
                if (key_auto_press && scan_done && (img_found_count > 3'd1)) begin
                    auto_play_en <= ~auto_play_en;
                    auto_cnt     <= 32'd0;
                end

                // 自动播放 1s 计数：只有当前没有写图任务时才计时
                if (scan_done && auto_play_en && display_valid && !load_busy && first_image_committed && (img_found_count > 3'd1)) begin
                    if (key_auto_press || auto_tick)
                        auto_cnt <= 32'd0;
                    else
                        auto_cnt <= auto_cnt + 32'd1;
                end else begin
                    auto_cnt <= 32'd0;
                end

                // 首图自动加载到 buffer0
                if (scan_done && !first_image_committed && !initial_exhausted && bmp_ready && !load_busy && (img_found_count != 3'd0)) begin
                    load_idx         <= initial_candidate;
                    load_sector      <= sector_lut(initial_candidate);
                    pending_buf_idx  <= 2'd0;
                    write_buf_idx    <= 2'd0;
                    zoom_loading<=zoom_desired;zoom_reload<=0;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    source_started_seen <= 1'b0;
                    write_done_seen <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 手动下一张优先：写到“非当前显示”的另一块 buffer
                else if (scan_done && bmp_ready && display_valid && display_safe && !load_busy && next_req_pending && (next_from_current != img_idx)) begin
                    load_idx         <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    zoom_loading<=zoom_desired;zoom_reload<=0;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    source_started_seen <= 1'b0;
                    write_done_seen <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                    transition_toggle <= ~transition_toggle;
                end
                // Refresh this same image into the inactive buffer for a new zoom.
                else if (KEY_ZOOM && bmp_ready && display_valid && display_safe && !load_busy && zoom_desired!=zoom_level_o) begin
                    load_idx<=img_idx;load_sector<=sector_lut(img_idx);
                    pending_buf_idx<=next_buf_lut(disp_buf_idx,display_valid);
                    write_buf_idx<=next_buf_lut(disp_buf_idx,display_valid);
                    zoom_loading<=zoom_desired;zoom_reload<=1;
                    load_start_pulse<=1;load_busy<=1;
                    source_done_seen<=0;source_started_seen<=0;write_done_seen<=0;
                    auto_cnt<=0;
                end
                // 自动播放下一张：同样写到“非当前显示”的另一块 buffer
                else if (scan_done && bmp_ready && display_valid && display_safe && !load_busy && auto_play_en && !key_auto_press && auto_tick && !zoom_event && (next_from_current != img_idx)) begin
                    load_idx         <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    zoom_loading<=zoom_desired;zoom_reload<=0;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    source_started_seen <= 1'b0;
                    write_done_seen <= 1'b0;
                    auto_cnt         <= 32'd0;
                    transition_toggle <= ~transition_toggle;
                end
            end
            // Zoom holds the current exhibit for filming. Music stays enabled.
            // Desired level may change during a load; the next load uses the latest value.
            if(zoom_event) begin
                zoom_desired<=(zoom_desired==2) ? 0 : zoom_desired+1'b1;
                auto_play_en<=0;auto_cnt<=0;
            end

        end
    end
end

bmp_read #(
    .BILINEAR(BILINEAR),.ENABLE_SCALER(SCALING_MODE), .ENABLE_ZOOM(KEY_ZOOM),    .CLK_FREQ_HZ (CLK_FREQ_HZ)
) bmp_read_m0(
    .zoom_level(zoom_loading),
    .write_pause(write_pause), .sd_busy(card_active),
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready_raw),

    .scan_start             (fallback_scan_start),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (fallback_scan_done),
    .scan_found_valid       (fallback_found_valid),
    .scan_found_sector      (fallback_found_sector),
    .scan_found_total       (),

    .load_start             (load_start_pulse),
    .load_sector            (load_sector),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid && card_active && card_owner==1),
    .sd_sec_read_end        (sd_sec_read_end && card_active && card_owner==1),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data),
    .operation_error        (bmp_operation_error)
);

sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (card_read),
    .sd_sec_read_addr       (card_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

subtitle_loader_fat #(.LOAD_FONT(LOAD_SUBTITLE),.MIN_BMP_BYTES(SCALING_MODE ? 54 : 921654)) u_subtitle_loader (
    .clk(clk), .rst(rst), .start(subtitle_start),
    .sd_sec_read(subtitle_read), .sd_sec_read_addr(subtitle_read_addr),
    .sd_sec_read_data(sd_sec_read_data),
    .sd_sec_read_data_valid(sd_sec_read_data_valid && card_active && card_owner==0),
    .sd_sec_read_end(sd_sec_read_end && card_active && card_owner==0),
    .font_wr_en(subtitle_wr_en), .font_wr_addr(subtitle_wr_addr),
    .font_wr_data(subtitle_wr_data), .char_count(subtitle_count),
    .bmp_count(directory_bmp_count),
    .bmp_lba0(directory_bmp_lba0), .bmp_lba1(directory_bmp_lba1),
    .bmp_lba2(directory_bmp_lba2), .bmp_lba3(directory_bmp_lba3),
    .music_found(music_found), .music_first_cluster(music_cluster), .music_file_size(music_size),
    .volume_fat_base(volume_fat), .volume_data_base(volume_data), .volume_spc(volume_spc),
    .done(subtitle_done)
);

endmodule

// Reads a UTF-8 TXT and a one-time Unicode 16x16 font pack from raw FAT32
// data sectors. The TXT starts with UTF-8 BOM and "SUBTITLE\n"; only its
// following line is user-editable. FONT.BIN starts with "FON1" and has
// 32-byte glyphs indexed by Unicode code point after its first sector.
module subtitle_loader_fat #(parameter LOAD_FONT=1,parameter [31:0] MIN_BMP_BYTES=921654) (
 input wire clk, rst, start,
 output reg sd_sec_read,
 output reg [31:0] sd_sec_read_addr,
 input wire [7:0] sd_sec_read_data,
 input wire sd_sec_read_data_valid, sd_sec_read_end,
 output reg font_wr_en,
 output reg [10:0] font_wr_addr,
 output reg [7:0] font_wr_data,
 output reg [6:0] char_count,
 output reg [2:0] bmp_count,
 output reg [31:0] bmp_lba0, bmp_lba1, bmp_lba2, bmp_lba3,
 output reg music_found,
 output reg [31:0] music_first_cluster, music_file_size,
 output wire [31:0] volume_fat_base,volume_data_base,
 output wire [7:0] volume_spc,
 output reg done
);
 reg [7:0] card_data_q;
 reg card_valid_q, card_end_q;
 // Register sector data and its strobes together before directory/UTF-8 decode.
 always @(posedge clk or posedge rst) begin
   if (rst) begin
     card_data_q<=8'd0; card_valid_q<=1'b0; card_end_q<=1'b0;
   end else begin
     card_data_q<=sd_sec_read_data;
     card_valid_q<=sd_sec_read_data_valid;
     card_end_q<=sd_sec_read_end;
   end
 end
 localparam IDLE=4'd0, MBR=4'd1, MBR_DONE=4'd2,
            BPB=4'd3, BPB_DONE=4'd4, ROOT_PREP=4'd5,
            ROOT=4'd6, ROOT_DONE=4'd7, TEXT_PREP=4'd8,
            TEXT=4'd9, FONT_PREP=4'd10, FONT=4'd11,
            FINISH=4'd12, ROOT_FAT_PREP=4'd13,
            ROOT_FAT=4'd14, ROOT_FAT_DONE=4'd15,
            ROOT_SCALE=5'd16, ROOT_ADDR=5'd17, TEXT_DONE=5'd18;
 reg [4:0] state;
 reg [9:0] byte_index;
 reg [31:0] partition_lba, mbr_part_lba, fat_size, root_cluster;
 reg [31:0] data_lba, root_lba, font_lba, text_lba;
 reg [31:0] next_root_cluster;
 reg [31:0] root_cluster_minus2, root_cluster_offset, fat_lba;
 reg [6:0] root_cluster_count;
 reg [15:0] bytes_per_sector, reserved;
 reg [7:0] sectors_per_cluster, fat_count, root_offset;
 reg root_end, found_font, found_text;
 reg [87:0] root_name;
 reg [15:0] entry_high, entry_low;
 reg [31:0] entry_cluster_minus2, entry_cluster_offset;
 reg [7:0] entry_attribute;
 reg [23:0] entry_size_low;
 reg bmp_entry_candidate;
 reg entry_cluster_valid;
 reg [7:0] marker_index;
 reg text_body, text_invalid, text_end;
 reg [1:0] utf_remaining;
 reg [15:0] utf_code;
 reg [15:0] codepoints [0:63];
 reg codepoint_wr_en;
 reg [5:0] codepoint_wr_addr;
 reg [15:0] codepoint_wr_data;
 reg [6:0] parsed_count, glyph_index;
 reg [9:0] glyph_base;
 reg [26:0] watchdog;
 reg watchdog_expired;
 assign volume_fat_base=fat_lba;
 assign volume_data_base=data_lba;
 assign volume_spc=sectors_per_cluster;
 wire [31:0] entry_cluster = {entry_high,entry_low};
 wire [4:0] cluster_shift =
     sectors_per_cluster==8'd1 ? 5'd0 :
     sectors_per_cluster==8'd2 ? 5'd1 :
     sectors_per_cluster==8'd4 ? 5'd2 :
     sectors_per_cluster==8'd8 ? 5'd3 :
     sectors_per_cluster==8'd16 ? 5'd4 :
     sectors_per_cluster==8'd32 ? 5'd5 :
     sectors_per_cluster==8'd64 ? 5'd6 : 5'd7;
 wire [31:0] entry_lba = data_lba + entry_cluster_offset;
 wire [31:0] first_data_lba = partition_lba + {16'd0,reserved} +
                              ((fat_count==8'd2) ? (fat_size<<1) : fat_size);
 wire [9:0] fat_entry_offset = {1'b0,root_cluster[6:0],2'b00};

 // Decouple UTF-8 validation/mux logic from the distributed RAM write port.
 always @(posedge clk) begin
   if (!rst && codepoint_wr_en)
     codepoints[codepoint_wr_addr]<=codepoint_wr_data;
 end

 always @(posedge clk or posedge rst) begin
   if (rst || state==IDLE || state==FINISH ||
       card_valid_q || card_end_q) begin
     watchdog<=27'd0;
     watchdog_expired<=1'b0;
   end else if (watchdog<27'd100_000_000) begin
     watchdog<=watchdog+27'd1;
     watchdog_expired<=(watchdog==27'd99_999_999);
   end else
     watchdog_expired<=1'b0;
 end

 always @(posedge clk or posedge rst) begin
   if (rst) begin
     music_found<=0; music_first_cluster<=0; music_file_size<=0;
     state<=IDLE; sd_sec_read<=1'b0; sd_sec_read_addr<=32'd0;
     byte_index<=10'd0; partition_lba<=32'd0; mbr_part_lba<=32'd0;
     fat_size<=32'd0; root_cluster<=32'd0; data_lba<=32'd0;
     root_lba<=32'd0; font_lba<=32'd0; text_lba<=32'd0;
     next_root_cluster<=32'd0; root_cluster_count<=7'd0;
     root_cluster_minus2<=32'd0; root_cluster_offset<=32'd0; fat_lba<=32'd0;
     bytes_per_sector<=16'd0; reserved<=16'd0;
     sectors_per_cluster<=8'd0; fat_count<=8'd0; root_offset<=8'd0;
     root_end<=1'b0; found_font<=1'b0; found_text<=1'b0;
     root_name<=88'd0; entry_high<=16'd0; entry_low<=16'd0;
     entry_cluster_minus2<=32'd0; entry_cluster_offset<=32'd0;entry_cluster_valid<=0;
     entry_attribute<=8'd0; marker_index<=8'd0;
     entry_size_low<=24'd0;
     bmp_entry_candidate<=1'b0;
     bmp_count<=3'd0; bmp_lba0<=32'd0; bmp_lba1<=32'd0;
     bmp_lba2<=32'd0; bmp_lba3<=32'd0;
     text_body<=1'b0; text_invalid<=1'b0; text_end<=1'b0;
     utf_remaining<=2'd0; utf_code<=16'd0;
     codepoint_wr_en<=1'b0; codepoint_wr_addr<=6'd0; codepoint_wr_data<=16'd0;
     parsed_count<=7'd0; glyph_index<=7'd0; glyph_base<=10'd0;
     font_wr_en<=1'b0; font_wr_addr<=11'd0; font_wr_data<=8'd0;
     char_count<=7'd0; done<=1'b0;
   end else begin
     font_wr_en<=1'b0;
     codepoint_wr_en<=1'b0;
     if (watchdog_expired) begin
       sd_sec_read<=1'b0; state<=FINISH;
     end else case(state)
       IDLE: if (start) begin
         music_found<=0; music_first_cluster<=0; music_file_size<=0;
         done<=1'b0; char_count<=7'd0;
         found_font<=1'b0; found_text<=1'b0;
         bmp_count<=3'd0;
         root_cluster_count<=7'd0;
         byte_index<=10'd0; sd_sec_read_addr<=32'd0; state<=MBR;
       end
       MBR: begin
         sd_sec_read<=1'b1;
         if (card_valid_q) begin
           byte_index<=byte_index+10'd1;
           case(byte_index)
             10'd11: bytes_per_sector[7:0]<=card_data_q;
             10'd12: bytes_per_sector[15:8]<=card_data_q;
             10'd454: mbr_part_lba[7:0]<=card_data_q;
             10'd455: mbr_part_lba[15:8]<=card_data_q;
             10'd456: mbr_part_lba[23:16]<=card_data_q;
             10'd457: mbr_part_lba[31:24]<=card_data_q;
             default: ;
           endcase
         end
         if (card_end_q) begin sd_sec_read<=1'b0; state<=MBR_DONE; end
       end
       MBR_DONE: begin
         partition_lba <= (bytes_per_sector==16'd512) ? 32'd0 : mbr_part_lba;
         sd_sec_read_addr <= (bytes_per_sector==16'd512) ? 32'd0 : mbr_part_lba;
         byte_index<=10'd0; bytes_per_sector<=16'd0; state<=BPB;
       end
       BPB: begin
         sd_sec_read<=1'b1;
         if (card_valid_q) begin
           byte_index<=byte_index+10'd1;
           case(byte_index)
             10'd11: bytes_per_sector[7:0]<=card_data_q;
             10'd12: bytes_per_sector[15:8]<=card_data_q;
             10'd13: sectors_per_cluster<=card_data_q;
             10'd14: reserved[7:0]<=card_data_q;
             10'd15: reserved[15:8]<=card_data_q;
             10'd16: fat_count<=card_data_q;
             10'd36: fat_size[7:0]<=card_data_q;
             10'd37: fat_size[15:8]<=card_data_q;
             10'd38: fat_size[23:16]<=card_data_q;
             10'd39: fat_size[31:24]<=card_data_q;
             10'd44: root_cluster[7:0]<=card_data_q;
             10'd45: root_cluster[15:8]<=card_data_q;
             10'd46: root_cluster[23:16]<=card_data_q;
             10'd47: root_cluster[31:24]<=card_data_q;
             default: ;
           endcase
         end
         if (card_end_q) begin sd_sec_read<=1'b0; state<=BPB_DONE; end
       end
       BPB_DONE: begin
         if (bytes_per_sector!=16'd512 || root_cluster[31:1]==31'd0 ||
             sectors_per_cluster==8'd0 || sectors_per_cluster>8'd128 ||
             ((sectors_per_cluster & (sectors_per_cluster-8'd1))!=8'd0) ||
             reserved==16'd0 || fat_size==32'd0 ||
             fat_count==8'd0 || fat_count>8'd2)
           state<=FINISH;
         else begin
           data_lba<=first_data_lba;
           fat_lba<=partition_lba+{16'd0,reserved};
           state<=ROOT_PREP;
         end
       end
       ROOT_PREP: begin
         // Split subtraction, variable shift, and addition across clocks.
         // Keep the SD request low until the complete address is registered.
         sd_sec_read<=1'b0;
         root_cluster_minus2<=root_cluster-32'd2;
         state<=ROOT_SCALE;
       end
       ROOT_SCALE: begin
         root_cluster_offset<=root_cluster_minus2<<cluster_shift;
         state<=ROOT_ADDR;
       end
       ROOT_ADDR: begin
         root_lba<=data_lba+root_cluster_offset;
         sd_sec_read_addr<=data_lba+root_cluster_offset;
         byte_index<=10'd0; root_offset<=8'd0;
         root_end<=1'b0; state<=ROOT;
       end
       ROOT: begin
         sd_sec_read<=1'b1;
         if (card_valid_q) begin
           byte_index<=byte_index+10'd1;
           if (byte_index[4:0]<5'd11)
             root_name<={root_name[79:0],card_data_q};
           case(byte_index[4:0])
             5'd0: if (card_data_q==8'd0) root_end<=1'b1;
             5'd11: entry_attribute<=card_data_q;
             5'd20: entry_high[7:0]<=card_data_q;
             5'd21: entry_high[15:8]<=card_data_q;
             5'd26: entry_low[7:0]<=card_data_q;
             5'd27: entry_low[15:8]<=card_data_q;
             5'd28: begin
               entry_cluster_valid <= entry_cluster>=32'd2;
               entry_cluster_minus2<=entry_cluster-32'd2;
               entry_size_low[7:0]<=card_data_q;
             end
             5'd29: begin
               entry_cluster_offset<=entry_cluster_minus2<<cluster_shift;
               entry_size_low[15:8]<=card_data_q;
             end
             // Compute the BMP name/attribute test a byte early.
             // The final size byte can only increase a FAT directory file size.
             5'd30: begin
               entry_size_low[23:16]<=card_data_q;
               bmp_entry_candidate <= root_name[23:0]=="BMP" &&
                   root_name[87:80]!=8'he5 && !entry_attribute[4] &&
                   !entry_attribute[3] && bmp_count<3'd4;
             end
             5'd31: if (!root_end && entry_attribute!=8'h0f &&
                        !entry_attribute[4] && !entry_attribute[3] &&
                        entry_cluster_valid) begin
               if (root_name=="MUSIC   WAV") begin
                 music_found<=1'b1; music_first_cluster<=entry_cluster;
                 music_file_size<={card_data_q,entry_size_low};
               end
               if (root_name=="SUBTITLETXT") begin
                 found_text<=1'b1; text_lba<=entry_lba;
               end
               if (root_name=="FONT    BIN") begin
                 found_font<=1'b1; font_lba<=entry_lba;
               end
               if (bmp_entry_candidate &&
                   {card_data_q,entry_size_low}>=MIN_BMP_BYTES &&
                   bmp_count<3'd4) begin
                 case (bmp_count)
                   3'd0: bmp_lba0<=entry_lba;
                   3'd1: bmp_lba1<=entry_lba;
                   3'd2: bmp_lba2<=entry_lba;
                   3'd3: bmp_lba3<=entry_lba;
                   default: ;
                 endcase
                 bmp_count<=bmp_count+3'd1;
               end
             end
             default: ;
           endcase
         end
         if (card_end_q) begin sd_sec_read<=1'b0; state<=ROOT_DONE; end
       end
       ROOT_DONE: begin
         if (root_end) begin
           if (LOAD_FONT && found_font && found_text) state<=TEXT_PREP;
           else state<=FINISH;
         end
         else if (root_offset+8'd1>=sectors_per_cluster)
           state<=ROOT_FAT_PREP;
         else begin
           root_offset<=root_offset+8'd1;
           sd_sec_read_addr<=root_lba+{24'd0,root_offset}+32'd1;
           byte_index<=10'd0; state<=ROOT;
         end
       end
       ROOT_FAT_PREP: begin
         // FAT32 has 128 four-byte cluster entries per 512-byte sector.
         sd_sec_read_addr<=fat_lba+(root_cluster>>7);
         byte_index<=10'd0;
         next_root_cluster<=32'd0;
         state<=ROOT_FAT;
       end
       ROOT_FAT: begin
         sd_sec_read<=1'b1;
         if (card_valid_q) begin
           byte_index<=byte_index+10'd1;
           if (byte_index==fat_entry_offset)
             next_root_cluster[7:0]<=card_data_q;
           else if (byte_index==fat_entry_offset+10'd1)
             next_root_cluster[15:8]<=card_data_q;
           else if (byte_index==fat_entry_offset+10'd2)
             next_root_cluster[23:16]<=card_data_q;
           else if (byte_index==fat_entry_offset+10'd3)
             next_root_cluster[31:24]<=card_data_q;
         end
         if (card_end_q) begin
           sd_sec_read<=1'b0;
           state<=ROOT_FAT_DONE;
         end
       end
       ROOT_FAT_DONE: begin
         if (next_root_cluster[27:0]>=28'd2 &&
             next_root_cluster[27:0]<28'hffffff8 &&
             root_cluster_count<7'd63) begin
           root_cluster<={4'd0,next_root_cluster[27:0]};
           root_cluster_count<=root_cluster_count+7'd1;
           state<=ROOT_PREP;
         end else if (LOAD_FONT && found_font && found_text) state<=TEXT_PREP;
         else state<=FINISH;
       end
       TEXT_PREP: begin
         sd_sec_read_addr<=text_lba;
         byte_index<=10'd0; marker_index<=8'd0;
         text_body<=1'b0; text_invalid<=1'b0; text_end<=1'b0;
         utf_remaining<=2'd0; parsed_count<=7'd0; state<=TEXT;
       end
       TEXT: begin
         sd_sec_read<=1'b1;
         if (card_valid_q) begin
           byte_index<=byte_index+10'd1;
           if (!text_body) begin
             case(marker_index)
               8'd0: if (card_data_q!=8'hef) text_invalid<=1'b1;
               8'd1: if (card_data_q!=8'hbb) text_invalid<=1'b1;
               8'd2: if (card_data_q!=8'hbf) text_invalid<=1'b1;
               8'd3: if (card_data_q!="S") text_invalid<=1'b1;
               8'd4: if (card_data_q!="U") text_invalid<=1'b1;
               8'd5: if (card_data_q!="B") text_invalid<=1'b1;
               8'd6: if (card_data_q!="T") text_invalid<=1'b1;
               8'd7: if (card_data_q!="I") text_invalid<=1'b1;
               8'd8: if (card_data_q!="T") text_invalid<=1'b1;
               8'd9: if (card_data_q!="L") text_invalid<=1'b1;
               8'd10: if (card_data_q!="E") text_invalid<=1'b1;
               8'd11: if (card_data_q==8'h0a) text_body<=1'b1;
                      else if (card_data_q!=8'h0d) text_invalid<=1'b1;
               8'd12: if (card_data_q==8'h0a) text_body<=1'b1;
                      else text_invalid<=1'b1;
               default: ;
             endcase
             marker_index<=marker_index+8'd1;
           end else if (!text_invalid && !text_end && parsed_count<7'd64) begin
             if (card_data_q==8'h00 || card_data_q==8'h0d ||
                 card_data_q==8'h0a) text_end<=1'b1;
             else if (utf_remaining!=2'd0) begin
               if (card_data_q[7:6]==2'b10) begin
                 if (utf_remaining==2'd1) begin
                   codepoint_wr_en<=1'b1;
                   codepoint_wr_addr<=parsed_count[5:0];
                   codepoint_wr_data<={utf_code[9:0],card_data_q[5:0]};
                   parsed_count<=parsed_count+7'd1;
                 end else utf_code<={utf_code[9:0],card_data_q[5:0]};
                 utf_remaining<=utf_remaining-2'd1;
               end else utf_remaining<=2'd0;
             end else if (!card_data_q[7]) begin
               codepoint_wr_en<=1'b1;
               codepoint_wr_addr<=parsed_count[5:0];
               codepoint_wr_data<={8'd0,card_data_q};
               parsed_count<=parsed_count+7'd1;
             end else if (card_data_q[7:5]==3'b110) begin
               utf_code<={11'd0,card_data_q[4:0]}; utf_remaining<=2'd1;
             end else if (card_data_q[7:4]==4'b1110) begin
               utf_code<={12'd0,card_data_q[3:0]}; utf_remaining<=2'd2;
             end
           end
         end
         if (card_end_q) begin
           sd_sec_read<=1'b0; glyph_index<=7'd0;
           state<=TEXT_DONE;
         end
       end
       TEXT_DONE: begin
         // The last byte may complete a glyph on the sector-end cycle.
         // Allow its registered RAM write/count to settle before font lookup.
         if (text_body && !text_invalid && parsed_count!=7'd0)
           state<=FONT_PREP;
         else state<=FINISH;
       end
       FONT_PREP: begin
         if (glyph_index>=parsed_count) state<=FINISH;
         else begin
           sd_sec_read_addr<=font_lba+32'd1+
               {20'd0,codepoints[glyph_index][15:4]};
           glyph_base<={codepoints[glyph_index][3:0],5'b0};
           byte_index<=10'd0; state<=FONT;
         end
       end
       FONT: begin
         sd_sec_read<=1'b1;
         if (card_valid_q) begin
           byte_index<=byte_index+10'd1;
           if (byte_index>=glyph_base && byte_index<glyph_base+10'd32) begin
             font_wr_addr<={glyph_index[5:0],byte_index[4:0]};
             font_wr_data<=card_data_q; font_wr_en<=1'b1;
           end
         end
         if (card_end_q) begin
           sd_sec_read<=1'b0; glyph_index<=glyph_index+7'd1;
           state<=FONT_PREP;
         end
       end
       FINISH: begin
         char_count<=(LOAD_FONT && found_font && found_text &&
                      text_body && !text_invalid) ? glyph_index : 7'd0;
         done<=1'b1;
       end
       default: state<=FINISH;
     endcase
   end
 end
endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse,
    output wire button_stable_o
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
assign button_stable_o = button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule


// Shared SD sector arbitration. Ownership lasts through the whole transaction.
module mg_sd_music_arbiter(
 input wire clk,rst,initialized,
 input wire sub_req,input wire [31:0] sub_addr,
 input wire bmp_req,input wire [31:0] bmp_addr,
 input wire music_req,input wire [31:0] music_addr,input wire music_urgent,
 input wire raw_end,
 output reg card_req,output reg [31:0] card_addr,
 output reg [1:0] owner,output wire active
);
 reg [1:0] state,gap;
 assign active=(state==1);
 always @(posedge clk or posedge rst) begin
 if(rst) begin state<=0;gap<=0;card_req<=0;card_addr<=0;owner<=0;end
 else if(!initialized) begin state<=0;card_req<=0;gap<=0;end
 else case(state)
 0:begin
  card_req<=0;
  if(sub_req) begin owner<=0;card_addr<=sub_addr;card_req<=1;state<=1;end
  else if(music_req && (music_urgent || !bmp_req)) begin owner<=2;card_addr<=music_addr;card_req<=1;state<=1;end
  else if(bmp_req) begin owner<=1;card_addr<=bmp_addr;card_req<=1;state<=1;end
 end
 1:if(raw_end) begin card_req<=0;gap<=0;state<=2;end
 2:begin card_req<=0;if(gap==2) state<=0;else gap<=gap+1'b1;end
 default:begin state<=0;card_req<=0;end
 endcase
 end
endmodule

module mg_music_fifo #(parameter AW=13)(
 input wire wr_clk,wr_rst,wr_en,input wire [15:0] wr_data,
 output wire full,output wire [AW:0] wr_used,
 input wire rd_clk,rd_rst,rd_en,output reg [15:0] rd_data,
 output wire empty,output wire [AW:0] rd_used
);
 reg [15:0] mem[0:(1<<AW)-1];
 reg [AW:0] wb,rb,wg,rg;
 (* ASYNC_REG="TRUE" *) reg [AW:0] rg1,rg2,wg1,wg2;
 reg full_r,empty_r;
 function [AW:0] ungray;
 input [AW:0] a;integer k;
 begin ungray[AW]=a[AW];for(k=AW-1;k>=0;k=k-1) ungray[k]=ungray[k+1]^a[k];end
 endfunction
 wire [AW:0] wn=wb+{{AW{1'b0}},(wr_en&&!full_r)};
 wire [AW:0] rn=rb+{{AW{1'b0}},(rd_en&&!empty_r)};
 wire [AW:0] wgn=(wn>>1)^wn,rgn=(rn>>1)^rn;
 assign full=full_r;assign empty=empty_r;
 assign wr_used=wb-ungray(rg2);assign rd_used=ungray(wg2)-rb;
 always @(posedge wr_clk) if(wr_en && !full_r && !wr_rst) mem[wb[AW-1:0]]<=wr_data;
 always @(posedge rd_clk) rd_data<=mem[rb[AW-1:0]];
 always @(posedge wr_clk or posedge wr_rst) begin
 if(wr_rst) begin wb<=0;wg<=0;rg1<=0;rg2<=0;full_r<=0;end
 else begin
  rg1<=rg;rg2<=rg1;wb<=wn;wg<=wgn;
  full_r<=(wgn=={~rg2[AW:AW-1],rg2[AW-2:0]});
 end
 end
 always @(posedge rd_clk or posedge rd_rst) begin
 if(rd_rst) begin rb<=0;rg<=0;wg1<=0;wg2<=0;empty_r<=1;end
 else begin
  wg1<=wg;wg2<=wg1;rb<=rn;rg<=rgn;empty_r<=(rgn==wg2);
 end
 end
endmodule

// Prepared standard MUSIC.WAV: mono PCM16/48k, data chunk aligned at byte 512.
// FAT32 cluster links are followed so the file need not be contiguous.
module mg_tf_music #(
 parameter CLK_HZ=100000000,parameter FIFO_AW=13,parameter PREFILL=2048
)(
 input wire clk,rst,enable,
 input wire [31:0] first_cluster,file_size,fat_base,data_base,
 input wire [7:0] sectors_per_cluster,
 output reg sd_req,output reg [31:0] sd_addr,
 input wire [7:0] sd_data,input wire sd_valid,sd_end,
 output wire urgent,output reg file_error,
 input wire audio_clk,audio_rst,sample_tick,
 output reg pcm_valid,output reg [23:0] pcm_sample,
 output reg underrun
);
 localparam IDLE=0,SUB=1,SCALE=2,ADDR=3,SPACE=4,READ_HDR=5,CHECK_HDR=6,
 READ_PCM=7,ADVANCE=8,FAT_ADDR=9,READ_FAT=10,CHECK_FAT=11,FAILED=12;
 reg [3:0] state;
 reg [31:0] cluster,cluster_minus2,cluster_offset,cluster_lba;
 reg [7:0] sector_index;
 reg [9:0] byte_index;
 reg need_header;
 reg [31:0] remaining,data_length,next_cluster;
 reg [31:0] riff,wave_id,fmt_id,fmt_size,sample_rate,byte_rate,data_id;
 reg [15:0] format_code,channels,block_align,bits;
 reg [7:0] pcm_low;
 reg fifo_we;reg [15:0] fifo_data;
 wire fifo_full,fifo_empty;
 wire [FIFO_AW:0] wr_used,rd_used;
 wire [15:0] fifo_q;
 reg playing;
 wire pop=sample_tick && playing && !fifo_empty;
 wire fifo_async_reset=rst || !enable;
 (* ASYNC_REG="TRUE" *) reg [1:0] wr_reset_sync,rd_reset_sync;
 always @(posedge clk or posedge fifo_async_reset)
 if(fifo_async_reset) wr_reset_sync<=3;else wr_reset_sync<={wr_reset_sync[0],1'b0};
 wire rd_async_reset=audio_rst || fifo_async_reset;
 always @(posedge audio_clk or posedge rd_async_reset)
 if(rd_async_reset) rd_reset_sync<=3;else rd_reset_sync<={rd_reset_sync[0],1'b0};
 mg_music_fifo #(.AW(FIFO_AW)) u_fifo(
 .wr_clk(clk),.wr_rst(wr_reset_sync[1]),.wr_en(fifo_we),.wr_data(fifo_data),.full(fifo_full),.wr_used(wr_used),
 .rd_clk(audio_clk),.rd_rst(rd_reset_sync[1]),.rd_en(pop),.rd_data(fifo_q),.empty(fifo_empty),.rd_used(rd_used));
 // Register Gray-decode/subtract comparisons before the request-state mux.
 // Reservation is 512 words for a sector containing at most 256 PCM words;
 // the extra cycle of status latency cannot exhaust that safety margin.
 reg urgent_q,enough_space;
 assign urgent=urgent_q;
 always @(posedge clk or posedge fifo_async_reset) begin
  if(fifo_async_reset)begin urgent_q<=1;enough_space<=0;end
  else begin
   urgent_q<=wr_used<(1<<(FIFO_AW-1));
   enough_space<=wr_used<=((1<<FIFO_AW)-512);
  end
 end
 wire [4:0] cluster_shift=sectors_per_cluster==1?0:sectors_per_cluster==2?1:
 sectors_per_cluster==4?2:sectors_per_cluster==8?3:sectors_per_cluster==16?4:
 sectors_per_cluster==32?5:sectors_per_cluster==64?6:7;
 wire [9:0] fat_offset={1'b0,cluster[6:0],2'b00};
 reg [26:0] watchdog;
 reg watchdog_expired;
 // Predict the next count's timeout so the 27-bit comparison is not in
 // the enable path of every WAV-parser register. Keep the original deadline.
 always @(posedge clk or posedge rst) begin
  if(rst) watchdog_expired <= (CLK_HZ <= 1);
  else if(!enable || !sd_req || sd_valid || sd_end)
   watchdog_expired <= (CLK_HZ <= 1);
  else watchdog_expired <= (watchdog >= CLK_HZ-2);
 end
 always @(posedge audio_clk or posedge audio_rst) begin
 if(audio_rst) begin playing<=0;pcm_valid<=0;pcm_sample<=0;underrun<=0;end
 else begin
  pcm_valid<=sample_tick;
  if(rd_reset_sync[1]) begin playing<=0;pcm_sample<=0;underrun<=0;end
  else begin
   if(!playing && rd_used>=PREFILL) playing<=1;
   if(sample_tick) begin
    if(playing && !fifo_empty) pcm_sample<={fifo_q,8'd0};
    else begin pcm_sample<=0;if(playing) begin playing<=0;underrun<=1;end end
   end
  end
 end
 end
 always @(posedge clk or posedge rst) begin
 if(rst) begin
  state<=IDLE;sd_req<=0;sd_addr<=0;file_error<=0;watchdog<=0;
  cluster<=0;cluster_minus2<=0;cluster_offset<=0;cluster_lba<=0;
  sector_index<=0;byte_index<=0;need_header<=1;remaining<=0;data_length<=0;next_cluster<=0;
  riff<=0;wave_id<=0;fmt_id<=0;fmt_size<=0;sample_rate<=0;byte_rate<=0;data_id<=0;
  format_code<=0;channels<=0;block_align<=0;bits<=0;pcm_low<=0;fifo_we<=0;fifo_data<=0;
 end else begin
  fifo_we<=0;
  if(!enable) begin state<=IDLE;sd_req<=0;file_error<=0;watchdog<=0;end
  else if(fifo_we && fifo_full) begin state<=FAILED;sd_req<=0;file_error<=1;end
  else if(sd_req && watchdog_expired) begin state<=FAILED;sd_req<=0;file_error<=1;end
  else begin
   if(!sd_req || sd_valid || sd_end) watchdog<=0;else watchdog<=watchdog+1'b1;
   case(state)
   IDLE:begin
    sd_req<=0;file_error<=0;need_header<=1;byte_index<=0;sector_index<=0;
    if(first_cluster>=2 && file_size>512 && sectors_per_cluster!=0) begin
     cluster<=first_cluster;state<=SUB;
    end else begin file_error<=1;state<=FAILED;end
   end
   SUB:begin cluster_minus2<=cluster-2;state<=SCALE;end
   SCALE:begin cluster_offset<=cluster_minus2<<cluster_shift;state<=ADDR;end
   ADDR:begin cluster_lba<=data_base+cluster_offset;sd_addr<=data_base+cluster_offset;state<=SPACE;end
   SPACE:begin
    sd_req<=0;
    if(enough_space) begin sd_req<=1;byte_index<=0;state<=need_header?READ_HDR:READ_PCM;end
   end
   READ_HDR:begin
    if(sd_valid) begin
     byte_index<=byte_index+1'b1;
     case(byte_index)
     0:riff[7:0]<=sd_data;1:riff[15:8]<=sd_data;2:riff[23:16]<=sd_data;3:riff[31:24]<=sd_data;
     8:wave_id[7:0]<=sd_data;9:wave_id[15:8]<=sd_data;10:wave_id[23:16]<=sd_data;11:wave_id[31:24]<=sd_data;
     12:fmt_id[7:0]<=sd_data;13:fmt_id[15:8]<=sd_data;14:fmt_id[23:16]<=sd_data;15:fmt_id[31:24]<=sd_data;
     16:fmt_size[7:0]<=sd_data;17:fmt_size[15:8]<=sd_data;18:fmt_size[23:16]<=sd_data;19:fmt_size[31:24]<=sd_data;
     20:format_code[7:0]<=sd_data;21:format_code[15:8]<=sd_data;22:channels[7:0]<=sd_data;23:channels[15:8]<=sd_data;
     24:sample_rate[7:0]<=sd_data;25:sample_rate[15:8]<=sd_data;26:sample_rate[23:16]<=sd_data;27:sample_rate[31:24]<=sd_data;
     28:byte_rate[7:0]<=sd_data;29:byte_rate[15:8]<=sd_data;30:byte_rate[23:16]<=sd_data;31:byte_rate[31:24]<=sd_data;
     32:block_align[7:0]<=sd_data;33:block_align[15:8]<=sd_data;34:bits[7:0]<=sd_data;35:bits[15:8]<=sd_data;
     504:data_id[7:0]<=sd_data;505:data_id[15:8]<=sd_data;506:data_id[23:16]<=sd_data;507:data_id[31:24]<=sd_data;
     508:data_length[7:0]<=sd_data;509:data_length[15:8]<=sd_data;510:data_length[23:16]<=sd_data;511:data_length[31:24]<=sd_data;
     default:;
     endcase
    end
    if(sd_end) begin sd_req<=0;state<=CHECK_HDR;end
   end
   CHECK_HDR:begin
    if(riff!=32'h46464952 || wave_id!=32'h45564157 || fmt_id!=32'h20746d66 || fmt_size!=16 ||
       format_code!=1 || channels!=1 || sample_rate!=48000 || byte_rate!=96000 || block_align!=2 || bits!=16 ||
       data_id!=32'h61746164 || data_length==0 || data_length[0] || data_length>file_size-512) begin
     file_error<=1;state<=FAILED;
    end else begin need_header<=0;remaining<=data_length;state<=ADVANCE;end
   end
   READ_PCM:begin
    if(sd_valid) begin
     byte_index<=byte_index+1'b1;
     if(remaining!=0) begin
      remaining<=remaining-1'b1;
      if(!byte_index[0]) pcm_low<=sd_data;
      else begin fifo_data<={sd_data,pcm_low};fifo_we<=1;end
     end
    end
    if(sd_end) begin sd_req<=0;state<=ADVANCE;end
   end
   ADVANCE:begin
    sd_req<=0;
    if(remaining==0) begin cluster<=first_cluster;sector_index<=0;need_header<=1;state<=SUB;end
    else if({1'b0,sector_index}+9'd1<{1'b0,sectors_per_cluster}) begin
     sector_index<=sector_index+1'b1;sd_addr<=sd_addr+1'b1;state<=SPACE;
    end else begin next_cluster<=0;state<=FAT_ADDR;end
   end
   FAT_ADDR:begin sd_addr<=fat_base+(cluster>>7);byte_index<=0;sd_req<=1;state<=READ_FAT;end
   READ_FAT:begin
    if(sd_valid) begin
     byte_index<=byte_index+1'b1;
     if(byte_index==fat_offset) next_cluster[7:0]<=sd_data;
     else if(byte_index==fat_offset+1) next_cluster[15:8]<=sd_data;
     else if(byte_index==fat_offset+2) next_cluster[23:16]<=sd_data;
     else if(byte_index==fat_offset+3) next_cluster[31:24]<=sd_data;
    end
    if(sd_end) begin sd_req<=0;state<=CHECK_FAT;end
   end
   CHECK_FAT:begin
    if(next_cluster[27:0]>=2 && next_cluster[27:0]<28'hffffff0) begin
     cluster<={4'd0,next_cluster[27:0]};sector_index<=0;state<=SUB;
    end else begin file_error<=1;state<=FAILED;end
   end
   FAILED:sd_req<=0;
   default:begin sd_req<=0;file_error<=1;state<=FAILED;end
   endcase
  end
 end
 end
endmodule
