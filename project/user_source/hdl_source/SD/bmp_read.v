module bmp_read #(
    parameter integer BILINEAR = 0,
    parameter integer ENABLE_SCALER = 0,
    parameter integer ENABLE_ZOOM = 0,
    parameter integer CLK_FREQ_HZ = 100_000_000
)(
    input [1:0] zoom_level,
    input write_pause, sd_busy,
    input                       clk,
    input                       rst,
    output                      ready,

    // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [2:0]                scan_target_count,
    output wire                  scan_done,
    output wire                  scan_found_valid,
    output wire [31:0]           scan_found_sector,
    output wire [2:0]            scan_found_total,

    // 按指定扇区加载一张图到 SDRAM
    input                       load_start,
    input  [31:0]               load_sector,

    input                       sd_init_done,
    output wire [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,

    output wire                  write_req,
    input                       write_req_ack,

    output wire                  sd_sec_read,
    output wire [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    output wire                  bmp_data_wr_en,
    output wire [23:0]           bmp_data,
    output wire                  operation_error
);
generate if (ENABLE_SCALER) begin : scaled
mg_bmp_scale #(.BILINEAR(BILINEAR),.CLK_FREQ_HZ(CLK_FREQ_HZ),.ENABLE_ZOOM(ENABLE_ZOOM)) core (
.zoom_level(zoom_level), .write_pause(write_pause), .sd_busy(sd_busy),
    .clk(clk),
    .rst(rst),
    .ready(ready),
    .scan_start(scan_start),
    .scan_start_sector(scan_start_sector),
    .scan_max_sector(scan_max_sector),
    .scan_target_count(scan_target_count),
    .scan_done(scan_done),
    .scan_found_valid(scan_found_valid),
    .scan_found_sector(scan_found_sector),
    .scan_found_total(scan_found_total),
    .load_start(load_start),
    .load_sector(load_sector),
    .sd_init_done(sd_init_done),
    .state_code(state_code),
    .bmp_width(bmp_width),
    .bmp_height(bmp_height),
    .write_req(write_req),
    .write_req_ack(write_req_ack),
    .sd_sec_read(sd_sec_read),
    .sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_sec_read_data),
    .sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_end(sd_sec_read_end),
    .bmp_data_wr_en(bmp_data_wr_en),
    .bmp_data(bmp_data),
    .operation_error(operation_error)
);
end else begin : legacy
bmp_read_v7 #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) core (
    .clk(clk),
    .rst(rst),
    .ready(ready),
    .scan_start(scan_start),
    .scan_start_sector(scan_start_sector),
    .scan_max_sector(scan_max_sector),
    .scan_target_count(scan_target_count),
    .scan_done(scan_done),
    .scan_found_valid(scan_found_valid),
    .scan_found_sector(scan_found_sector),
    .scan_found_total(scan_found_total),
    .load_start(load_start),
    .load_sector(load_sector),
    .sd_init_done(sd_init_done),
    .state_code(state_code),
    .bmp_width(bmp_width),
    .bmp_height(bmp_height),
    .write_req(write_req),
    .write_req_ack(write_req_ack),
    .sd_sec_read(sd_sec_read),
    .sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_sec_read_data),
    .sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_end(sd_sec_read_end),
    .bmp_data_wr_en(bmp_data_wr_en),
    .bmp_data(bmp_data),
    .operation_error(operation_error)
);
end endgenerate
endmodule

module bmp_read_v7 #(
    parameter integer CLK_FREQ_HZ = 100_000_000
)(
    input                       clk,
    input                       rst,
    output                      ready,

    // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [2:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [2:0]            scan_found_total,

    // 按指定扇区加载一张图到 SDRAM
    input                       load_start,
    input  [31:0]               load_sector,

    input                       sd_init_done,
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,

    output reg                  write_req,
    input                       write_req_ack,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    output reg                  bmp_data_wr_en,
    output reg [23:0]           bmp_data,
    output reg                  operation_error
);

localparam ST_IDLE      = 3'd0;
localparam ST_SCAN      = 3'd1;
localparam ST_LOAD_HDR  = 3'd2;
localparam ST_LOAD_WAIT = 3'd3;
localparam ST_LOAD_DATA = 3'd4;
localparam ST_SCAN_CHECK = 3'd5;
localparam ST_LOAD_CHECK = 3'd6;

reg [2:0]  state;
reg [9:0]  rd_cnt;

reg [7:0]  header_0;
reg [7:0]  header_1;
reg [31:0] file_len;
reg [31:0] pixel_offset;
reg [31:0] width;
reg [31:0] height;
reg [31:0] dib_size;
reg [15:0] planes;
reg [15:0] bit_count;
reg [31:0] compression;

reg [31:0] scan_sector;
reg [31:0] load_sector_latched;
reg [31:0] bmp_len_cnt;
reg [1:0]  bmp_byte_idx;
reg [31:0] watchdog_count;
reg        error_latched;
reg        header_match_latched;

wire header_match;
wire bmp_data_valid;
reg [31:0] file_sector_count;
reg [31:0] next_scan_sector_if_match;
wire [31:0] next_scan_sector_if_miss;
wire [31:0] pixel_data_end;
reg [32:0] pixel_data_end_wide;
wire        watchdog_active;
wire        watchdog_kick;
wire        watchdog_timeout;

localparam [31:0] EXPECTED_PIXEL_BYTES = 32'd921600; // 640*480*3

assign ready = (state == ST_IDLE);
assign header_match = (header_0 == "B") &&
                      (header_1 == "M") &&
                      (width  == {16'd0,bmp_width}) &&
                      (height == {16'd0,bmp_height}) &&
                      (planes == 16'd1) &&
                      (dib_size >= 32'd40) &&
                      (bit_count    == 16'd24) &&
                      (compression  == 32'd0) &&
                      (pixel_offset >= 32'd54) &&
                      (dib_size <= pixel_offset-32'd14) &&
                      !pixel_data_end_wide[32] &&
                      (file_len >= pixel_data_end);
assign bmp_data_valid = (sd_sec_read_data_valid == 1'b1) &&
                         (bmp_len_cnt >= pixel_offset) &&
                         (bmp_len_cnt <  pixel_data_end);
// Pipeline the header length skip before the 512-byte header completes.
always @(posedge clk or posedge rst) begin
    if (rst) begin
        file_sector_count <= 32'd1;
        next_scan_sector_if_match <= 32'd1;
    end else begin
        file_sector_count <= (file_len == 32'd0) ? 32'd1 :
                             (file_len >> 9) + {31'd0,(|file_len[8:0])};
        next_scan_sector_if_match <= scan_sector + file_sector_count;
    end
end
assign next_scan_sector_if_miss  = scan_sector + 32'd1;
// Offset bytes finish early in the 512-byte header sector. Register their
// derived end before header validation/data loading, separating addition from
// the byte-boundary comparisons and SD address clock-enable logic.
always @(posedge clk or posedge rst) begin
    if (rst)
        pixel_data_end_wide <= 33'd921654;
    else
        pixel_data_end_wide <= {1'b0,pixel_offset} + {1'b0,EXPECTED_PIXEL_BYTES};
end
assign pixel_data_end = pixel_data_end_wide[31:0];
assign watchdog_active = (state != ST_IDLE);
assign watchdog_kick = sd_sec_read_data_valid || sd_sec_read_end ||
                       ((state == ST_LOAD_WAIT) && write_req_ack);
assign watchdog_timeout = watchdog_active &&
                          (watchdog_count >= (CLK_FREQ_HZ - 1));

// One-second no-progress watchdog.  It is reset by any byte, sector-end or
// SDRAM request acknowledgement, so normal long scans do not trip it.
always @(posedge clk or posedge rst) begin
    if (rst || !watchdog_active || watchdog_kick)
        watchdog_count <= 32'd0;
    else if (!watchdog_timeout)
        watchdog_count <= watchdog_count + 32'd1;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
    end else if ((state == ST_SCAN) || (state == ST_LOAD_HDR)) begin
        if (sd_sec_read_data_valid)
            rd_cnt <= rd_cnt + 10'd1;
        else if (sd_sec_read_end)
            rd_cnt <= 10'd0;
    end else begin
        rd_cnt <= 10'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0     <= 8'd0;
        header_1     <= 8'd0;
        file_len     <= 32'd0;
        pixel_offset <= 32'd54;
        width        <= 32'd0;
        height       <= 32'd0;
        dib_size     <= 32'd0;
        planes       <= 16'd0;
        bit_count    <= 16'd0;
        compression  <= 32'd0;
    end else if (((state == ST_SCAN) || (state == ST_LOAD_HDR)) && sd_sec_read_data_valid) begin
        case (rd_cnt)
            10'd0 : header_0 <= sd_sec_read_data;
            10'd1 : header_1 <= sd_sec_read_data;

            10'd2 : file_len[7:0] <= sd_sec_read_data;
            10'd3 : file_len[15:8] <= sd_sec_read_data;
            10'd4 : file_len[23:16] <= sd_sec_read_data;
            10'd5 : file_len[31:24] <= sd_sec_read_data;

            10'd10: pixel_offset[7:0] <= sd_sec_read_data;
            10'd11: pixel_offset[15:8] <= sd_sec_read_data;
            10'd12: pixel_offset[23:16] <= sd_sec_read_data;
            10'd13: pixel_offset[31:24] <= sd_sec_read_data;

            10'd14: dib_size[7:0] <= sd_sec_read_data;
            10'd15: dib_size[15:8] <= sd_sec_read_data;
            10'd16: dib_size[23:16] <= sd_sec_read_data;
            10'd17: dib_size[31:24] <= sd_sec_read_data;

            10'd18: width[7:0] <= sd_sec_read_data;
            10'd19: width[15:8] <= sd_sec_read_data;
            10'd20: width[23:16] <= sd_sec_read_data;
            10'd21: width[31:24] <= sd_sec_read_data;

            10'd22: height[7:0] <= sd_sec_read_data;
            10'd23: height[15:8] <= sd_sec_read_data;
            10'd24: height[23:16] <= sd_sec_read_data;
            10'd25: height[31:24] <= sd_sec_read_data;

            10'd26: planes[7:0] <= sd_sec_read_data;
            10'd27: planes[15:8] <= sd_sec_read_data;

            10'd28: bit_count[7:0] <= sd_sec_read_data;
            10'd29: bit_count[15:8] <= sd_sec_read_data;

            10'd30: compression[7:0] <= sd_sec_read_data;
            10'd31: compression[15:8] <= sd_sec_read_data;
            10'd32: compression[23:16] <= sd_sec_read_data;
            10'd33: compression[31:24] <= sd_sec_read_data;
            default: ;
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_len_cnt <= 32'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (sd_sec_read_data_valid)
            bmp_len_cnt <= bmp_len_cnt + 32'd1;
    end else begin
        bmp_len_cnt <= 32'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_byte_idx <= 2'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid)
            bmp_byte_idx <= (bmp_byte_idx == 2'd2) ? 2'd0 : (bmp_byte_idx + 2'd1);
    end else begin
        bmp_byte_idx <= 2'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_data_wr_en <= 1'b0;
        bmp_data       <= 24'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid) begin
            case (bmp_byte_idx)
                2'd0: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[7:0]  <= sd_sec_read_data;
                end
                2'd1: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[15:8] <= sd_sec_read_data;
                end
                2'd2: begin
                    bmp_data_wr_en  <= 1'b1;
                    bmp_data[23:16] <= sd_sec_read_data;
                end
                default: begin
                    bmp_data_wr_en <= 1'b0;
                end
            endcase
        end else begin
            bmp_data_wr_en <= 1'b0;
        end
    end else begin
        bmp_data_wr_en <= 1'b0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
        operation_error      <= 1'b0;
        error_latched        <= 1'b0;
        header_match_latched <= 1'b0;
    end else if (!sd_init_done) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
        operation_error      <= 1'b0;
        error_latched        <= 1'b0;
        header_match_latched <= 1'b0;
    end else begin
        scan_found_valid <= 1'b0;
        operation_error  <= 1'b0;

        if (watchdog_timeout) begin
            state            <= ST_IDLE;
            state_code       <= 4'he;
            sd_sec_read      <= 1'b0;
            write_req        <= 1'b0;
            operation_error  <= 1'b1;
            error_latched    <= 1'b1;
            if ((state == ST_SCAN) || (state == ST_SCAN_CHECK))
                scan_done <= 1'b1;
        end else case (state)
            ST_IDLE: begin
                state_code  <= error_latched ? 4'he : 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;

                if (scan_start) begin
                    error_latched    <= 1'b0;
                    state_code       <= 4'd1;
                    scan_done        <= 1'b0;
                    scan_found_total <= 3'd0;
                    scan_sector      <= scan_start_sector;
                    sd_sec_read_addr <= scan_start_sector;
                    state            <= ST_SCAN;
                end else if (load_start) begin
                    error_latched       <= 1'b0;
                    state_code          <= 4'd1;
                    load_sector_latched <= load_sector;
                    sd_sec_read_addr    <= load_sector;
                    state               <= ST_LOAD_HDR;
                end
            end

            ST_SCAN: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    header_match_latched <= header_match;
                    state <= ST_SCAN_CHECK;
                end
            end

            ST_SCAN_CHECK: begin
                    if (header_match_latched) begin
                        scan_found_valid  <= 1'b1;
                        scan_found_sector <= scan_sector;
                        scan_found_total  <= scan_found_total + 3'd1;

                        if ((scan_found_total + 3'd1 >= scan_target_count) || (next_scan_sector_if_match > scan_max_sector)) begin
                            scan_done        <= 1'b1;
                            state            <= ST_IDLE;
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                            state            <= ST_SCAN;
                        end
                    end else begin
                        if (scan_sector >= scan_max_sector) begin
                            scan_done <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_miss;
                            scan_sector      <= next_scan_sector_if_miss;
                            state            <= ST_SCAN;
                        end
                    end
            end

            ST_LOAD_HDR: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    header_match_latched <= header_match;
                    state <= ST_LOAD_CHECK;
                end
            end

            ST_LOAD_CHECK: begin
                    if (header_match_latched) begin
                        write_req        <= 1'b1;
                        sd_sec_read_addr <= load_sector_latched;
                        state            <= ST_LOAD_WAIT;
                    end else begin
                        state           <= ST_IDLE;
                        operation_error <= 1'b1;
                        error_latched   <= 1'b1;
                    end
            end

            ST_LOAD_WAIT: begin
                state_code <= 4'd3;
                if (write_req_ack) begin
                    write_req <= 1'b0;
                    state     <= ST_LOAD_DATA;
                end
            end

            ST_LOAD_DATA: begin
                state_code  <= 4'd4;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if ((bmp_len_cnt >= pixel_data_end) ||
                        (sd_sec_read_data_valid && bmp_len_cnt == pixel_data_end-32'd1)) begin
                        state <= ST_IDLE;
                    end else begin
                        sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                    end
                end
            end

            default: begin
                state       <= ST_IDLE;
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
            end
        endcase
    end
end

endmodule

// Load-time nearest-neighbour resampler. Only two small RAMs are used:
// one SD sector and one source row. Output remains bottom-up for v7 SDRAM.
module mg_bmp_scale #(
 parameter integer BILINEAR=0,
 parameter integer CLK_FREQ_HZ=100000000,
 parameter integer ENABLE_ZOOM=0,
 parameter integer DST_WIDTH=640, DST_HEIGHT=480,
 parameter integer MAX_DIM=1920
)(
 input [1:0] zoom_level,
 input clk,rst,write_pause,sd_busy,
 output ready,
 input scan_start,input [31:0] scan_start_sector,scan_max_sector,
 input [2:0] scan_target_count,
 output reg scan_done,scan_found_valid,
 output reg [31:0] scan_found_sector,
 output reg [2:0] scan_found_total,
 input load_start,input [31:0] load_sector,
 input sd_init_done,output [3:0] state_code,
 input [15:0] bmp_width,bmp_height,
 output reg write_req,input write_req_ack,
 output reg sd_sec_read,output reg [31:0] sd_sec_read_addr,
 input [7:0] sd_sec_read_data,
 input sd_sec_read_data_valid,sd_sec_read_end,
 output reg bmp_data_wr_en,output reg [23:0] bmp_data,
 output reg operation_error
);
localparam IDLE=0,REQ=1,RX=2,GAP=3,HEADER=4,MATH1=5,MATH2=6,
 CHECK=7,DIV=8,GEOM=9,ACK=10,SETTLE=11,ROW=12,BYTE=13,
 BYTE_WAIT=14,BYTE_GOT=15,PIX=16,PIX_WAIT=17,EMIT=18,
 XADV=19,YADV=20,NEXTROW=21,SCAN_NEXT=22,ZOOM_FIT=23,VALIDATE=24;
reg [36:0] state,return_state;
// Every assignment below selects a single named state or the one-hot return_state.
// Parallel decoding is therefore valid by induction from reset.
// synthesis translate_off
always @(posedge clk) if(!rst) begin
 if((^state===1'bx) || state==0 || ((state & (state-37'd1))!=0) ||
    (^return_state===1'bx) || return_state==0 || ((return_state & (return_state-37'd1))!=0)) begin
  $display("FAIL scaler state one-hot invariant");$finish;
 end
end
// synthesis translate_on
reg [1:0] zoom_latched;
reg scan_mode,header_read;
reg [31:0] base_lba,scan_lba;
reg [9:0] receive_count;
reg [7:0] signature0,signature1;
reg [31:0] file_len,pixel_offset,dib_size,width_raw,height_raw,compression;
reg [15:0] planes,bits;
reg [15:0] src_w,src_h;
reg top_down;
reg [31:0] stride,required_bytes,aspect_w,aspect_h;
reg [32:0] end_byte;
reg [32:0] rounded_len,last_lba_exclusive,dib_end;
reg validated_header;
reg cache_valid;
reg [31:0] cache_index,request_index,stream_pos,row_base;
reg [7:0] sector_ram[0:511];
reg [7:0] sector_q;
reg [23:0] row_ram[0:(BILINEAR?4095:2047)];
reg [23:0] row_q;
reg [10:0] row_write_addr;
reg [1:0] channel;
reg [7:0] blue,green;
reg [15:0] cached_y;
reg row_valid;
reg [15:0] fit_w,fit_h,pad_x,pad_y;
reg [15:0] dx,dy,sx,sy;
reg signed [17:0] x_acc,y_acc;
reg [23:0] pixel_pending;
reg [5:0] settle_count;
reg [31:0] dividend,quotient,divisor;
reg [32:0] remainder;
reg [5:0] div_count;
reg fit_by_width;
wire [32:0] trial={remainder[31:0],dividend[31]};
wire div_ge=(trial >= {1'b0,divisor});
wire [31:0] next_quotient={quotient[30:0],div_ge};
reg [16:0] fit_end_x,fit_end_y;
// Geometry is fixed throughout a frame. Compute the exclusive bounds
// during the write handshake, before SETTLE, rather than in each pixel test.
always @(posedge clk) begin
 if(rst)begin fit_end_x<=0;fit_end_y<=0;end
 else if(state[ACK])begin
  fit_end_x<={1'b0,pad_x}+{1'b0,fit_w};
  fit_end_y<={1'b0,pad_y}+{1'b0,fit_h};
 end
end
wire inside_y=(dy>=pad_y && {1'b0,dy}<fit_end_y);
wire inside_x=(dx>=pad_x && {1'b0,dx}<fit_end_x);
wire header_ok=signature0==8'h42 && signature1==8'h4d &&
 dib_size>=40 && pixel_offset>=54 && dib_end<={1'b0,pixel_offset} &&
 width_raw>0 && width_raw<=MAX_DIM && src_h>0 && src_h<=MAX_DIM &&
 planes==1 && bits==24 && compression==0 && !end_byte[32] &&
 end_byte<=file_len && last_lba_exclusive<=33'h100000000;
// Center-aligned bilinear coordinates: (d+0.5)*source/fit - 0.5.
// Two parity-tagged RGB888 line caches; edge coordinates clamp to last pixel.
localparam FRAC_X=25,FRAC_Y=26,CHECK_ROWS=27,READ_CORNERS=28,
           BLEND_H=29,BLEND_V=30,BLEND_OUT=31,INIT_X=32,INIT_Y=33,V_MUL=34,V_SUM=35,H_SUM=36;
reg x_initial_ready;
reg [1:0] valid_rows;
reg [15:0] row_tag0,row_tag1,load_y;
reg [17:0] frac_rem,frac_den;
reg [7:0] frac_bits,wx,wy;
reg [2:0] frac_iter,corner_phase;
reg [15:0] src_last_x,src_last_y;
wire [18:0] frac_trial={frac_rem,1'b0};
wire frac_ge=frac_trial>={1'b0,frac_den};
wire [7:0] frac_next={frac_bits[6:0],frac_ge};
wire [15:0] sx1=(sx<src_last_x)?sx+1'b1:sx;
wire [15:0] sy1=(sy<src_last_y && wy!=0)?sy+1'b1:sy;
wire row0_present=valid_rows[sy[0]] && (sy[0]?row_tag1:row_tag0)==sy;
wire row1_present=valid_rows[sy1[0]] && (sy1[0]?row_tag1:row_tag0)==sy1;
wire [11:0] corner_addr={(corner_phase[2]?sy1[0]:sy[0]),
                        (corner_phase[1]?sx1[10:0]:sx[10:0])};
reg signed [17:0] hp0r,hp0g,hp0b,hp1r,hp1g,hp1b;
reg [23:0] p00,p01,p10,p11;
reg [15:0] h0r,h0g,h0b,h1r,h1g,h1b;
reg [23:0] vr,vg,vb;
reg signed [16:0] vd_r,vd_g,vd_b;
reg signed [25:0] vp_r,vp_g,vp_b;
reg [15:0] va_r,va_g,va_b;
function [15:0] horizontal;
 input [7:0] a,b,w;
 reg signed [8:0] delta;
 reg signed [17:0] product,total;
 begin
  delta=$signed({1'b0,b})-$signed({1'b0,a});
  product=delta*$signed({1'b0,w});
  total=$signed({2'b0,a,8'd0})+product;
  horizontal=total[15:0];
 end
endfunction
function [23:0] vertical;
 input [15:0] a,b;input [7:0] w;
 reg signed [16:0] delta;
 reg signed [25:0] product,total;
 begin
  delta=$signed({1'b0,b})-$signed({1'b0,a});
  product=delta*$signed({1'b0,w});
  total=$signed({2'b0,a,8'd0})+product+26'sd32768;
  vertical=total[23:0];
 end
endfunction
assign ready=(state[IDLE] && !sd_busy);
assign state_code=state[IDLE] ? 0 : (state[ACK] ? 3 : (scan_mode ? 1 : 4));
// Synchronous reads allow both arrays to infer block RAM.
always @(posedge clk) begin
 if(state[RX] && sd_sec_read_data_valid && receive_count<512)
   sector_ram[receive_count[8:0]]<=sd_sec_read_data;
 sector_q<=sector_ram[stream_pos[8:0]];
 if(state[BYTE_GOT] && channel==2)
   row_ram[BILINEAR?{load_y[0],row_write_addr}: {1'b0,row_write_addr}]<={sector_q,green,blue};
 row_q<=row_ram[BILINEAR ? corner_addr : {1'b0,sx[10:0]}];
end

reg [31:0] watchdog;
reg expired;
wire progress=(!state[REQ] && !state[RX] && !state[ACK] && !state[EMIT]) ||
 sd_sec_read_data_valid || sd_sec_read_end || write_req_ack ||
 (state[EMIT] && !write_pause);
always @(posedge clk) begin
 if(rst || state[IDLE] || progress) begin watchdog<=0;expired<=0;end
 else begin watchdog<=watchdog+1'b1;expired<=(watchdog>=CLK_FREQ_HZ-1);end
end
always @(posedge clk) begin
 if(rst) begin
  hp0r<=0;hp0g<=0;hp0b<=0;hp1r<=0;hp1g<=0;hp1b<=0;
  src_last_x<=0;src_last_y<=0;vd_r<=0;vd_g<=0;vd_b<=0;vp_r<=0;vp_g<=0;vp_b<=0;va_r<=0;va_g<=0;va_b<=0;
  x_initial_ready<=0;valid_rows<=0;row_tag0<=0;row_tag1<=0;load_y<=0;
  frac_rem<=0;frac_den<=1;frac_bits<=0;frac_iter<=0;wx<=0;wy<=0;
  corner_phase<=0;p00<=0;p01<=0;p10<=0;p11<=0;
  h0r<=0;h0g<=0;h0b<=0;h1r<=0;h1g<=0;h1b<=0;vr<=0;vg<=0;vb<=0;
  zoom_latched<=2;state<=(37'b1<<IDLE);return_state<=(37'b1<<IDLE);write_req<=0;sd_sec_read<=0;
  sd_sec_read_addr<=0;bmp_data_wr_en<=0;bmp_data<=0;operation_error<=0;
  scan_done<=0;scan_found_valid<=0;scan_found_sector<=0;scan_found_total<=0;
  rounded_len<=0;last_lba_exclusive<=0;dib_end<=0;validated_header<=0;
  cache_valid<=0;row_valid<=0;receive_count<=0;
  signature0<=0;signature1<=0;file_len<=0;pixel_offset<=0;dib_size<=0;
  width_raw<=0;height_raw<=0;planes<=0;bits<=0;compression<=0;
  scan_mode<=0;header_read<=0;base_lba<=0;scan_lba<=0;
  src_w<=0;src_h<=0;top_down<=0;stride<=0;required_bytes<=0;
  aspect_w<=0;aspect_h<=0;end_byte<=0;request_index<=0;cache_index<=0;
  stream_pos<=0;row_base<=0;row_write_addr<=0;channel<=0;blue<=0;green<=0;
  cached_y<=0;fit_w<=0;fit_h<=0;pad_x<=0;pad_y<=0;
  dx<=0;dy<=0;sx<=0;sy<=0;x_acc<=0;y_acc<=0;pixel_pending<=0;
  settle_count<=0;dividend<=0;quotient<=0;divisor<=1;remainder<=0;div_count<=0;fit_by_width<=0;
 end else begin
  bmp_data_wr_en<=0;operation_error<=0;scan_found_valid<=0;
  case(1'b1) // synthesis parallel_case
   state[IDLE]: if(sd_init_done && !sd_busy && (scan_start || load_start)) begin
    zoom_latched<=ENABLE_ZOOM ? zoom_level : 2;
    scan_mode<=scan_start;scan_done<=0;
    if(scan_start) begin base_lba<=scan_start_sector;scan_lba<=scan_start_sector;scan_found_total<=0;end
    else base_lba<=load_sector;
    state<=(37'b1<<HEADER);
   end
   state[HEADER]: begin
    signature0<=0;signature1<=0;file_len<=0;pixel_offset<=0;dib_size<=0;
    width_raw<=0;height_raw<=0;planes<=0;bits<=0;compression<=0;
    header_read<=1;request_index<=0;cache_valid<=0;row_valid<=0;
    valid_rows<=0;return_state<=(37'b1<<MATH1);state<=(37'b1<<REQ);
   end
   state[REQ]: begin
    receive_count<=0;sd_sec_read_addr<=base_lba+request_index;
    sd_sec_read<=1;state<=(37'b1<<RX);
   end
   state[RX]: begin
    if(sd_sec_read_data_valid && receive_count<512) begin
     receive_count<=receive_count+1'b1;
     if(header_read) case(receive_count)
      0:signature0<=sd_sec_read_data;1:signature1<=sd_sec_read_data;
      2,3,4,5:file_len<={sd_sec_read_data,file_len[31:8]};
      10,11,12,13:pixel_offset<={sd_sec_read_data,pixel_offset[31:8]};
      14,15,16,17:dib_size<={sd_sec_read_data,dib_size[31:8]};
      18,19,20,21:width_raw<={sd_sec_read_data,width_raw[31:8]};
      22,23,24,25:height_raw<={sd_sec_read_data,height_raw[31:8]};
      26,27:planes<={sd_sec_read_data,planes[15:8]};
      28,29:bits<={sd_sec_read_data,bits[15:8]};
      30,31,32,33:compression<={sd_sec_read_data,compression[31:8]};
     endcase
    end
    if(sd_sec_read_end) begin
     sd_sec_read<=0;cache_index<=request_index;cache_valid<=1;header_read<=0;state<=(37'b1<<GAP);
     if(receive_count!=512 && !(receive_count==511 && sd_sec_read_data_valid)) begin
      state<=(37'b1<<IDLE);operation_error<=1;cache_valid<=0;
     end
    end
   end
   state[GAP]: state<=return_state;
   state[MATH1]: begin
    rounded_len<={1'b0,file_len}+33'd511;dib_end<={1'b0,dib_size}+33'd14;
    src_w<=width_raw[15:0];top_down<=height_raw[31];
    src_h<=height_raw[31] ? (~height_raw+1'b1) : height_raw;
    stride<=(width_raw*3+3)&32'hfffffffc;state<=(37'b1<<MATH2);
   end
   state[MATH2]: begin
    src_last_x<=src_w-1'b1;src_last_y<=src_h-1'b1;
    last_lba_exclusive<={1'b0,base_lba}+(rounded_len>>9);
    required_bytes<=stride*src_h;aspect_w<=src_w*DST_HEIGHT;aspect_h<=src_h*DST_WIDTH;
    end_byte<={1'b0,pixel_offset}+stride*src_h;state<=(37'b1<<VALIDATE);
   end
   state[VALIDATE]: begin
    validated_header<=header_ok && (height_raw[31] ? (~height_raw+1'b1)<=MAX_DIM : height_raw<=MAX_DIM);
    state<=(37'b1<<CHECK);
   end
   state[CHECK]: begin
    if(validated_header) begin
     if(scan_mode) begin
      scan_found_valid<=1;scan_found_sector<=base_lba;scan_found_total<=scan_found_total+1'b1;
      request_index<=(file_len>>9)+(|file_len[8:0]);state<=(37'b1<<SCAN_NEXT);
     end else begin
      fit_by_width<=aspect_w>=aspect_h;
      if(aspect_w>=aspect_h) begin dividend<=aspect_h;divisor<=src_w;fit_w<=DST_WIDTH;end
      else begin dividend<=aspect_w;divisor<=src_h;fit_h<=DST_HEIGHT;end
      quotient<=0;remainder<=0;div_count<=0;state<=(37'b1<<DIV);
     end
    end else if(scan_mode) begin request_index<=1;state<=(37'b1<<SCAN_NEXT);end
    else begin operation_error<=1;state<=(37'b1<<IDLE);end
   end
   state[DIV]: begin
    dividend<={dividend[30:0],1'b0};quotient<=next_quotient;
    remainder<=div_ge ? trial-divisor : trial;
    if(div_count==31) begin
     if(fit_by_width) fit_h<=next_quotient==0 ? 1 : next_quotient[15:0];
     else fit_w<=next_quotient==0 ? 1 : next_quotient[15:0];
     state<=(37'b1<<ZOOM_FIT);
    end else div_count<=div_count+1'b1;
   end
   state[ZOOM_FIT]: begin
    case(zoom_latched)
     0:begin fit_w<=(fit_w<2) ? 1 : (fit_w>>1);fit_h<=(fit_h<2) ? 1 : (fit_h>>1);end
     1:begin
      fit_w<=(fit_w<2) ? 1 : (({2'b0,fit_w}+({2'b0,fit_w}<<1))>>2);
      fit_h<=(fit_h<2) ? 1 : (({2'b0,fit_h}+({2'b0,fit_h}<<1))>>2);
     end
     default:begin end
    endcase
    state<=(37'b1<<GEOM);
   end
   state[GEOM]: begin
    pad_x<=(DST_WIDTH-fit_w)/2;pad_y<=(DST_HEIGHT-fit_h)/2;
    row_base<=top_down ? pixel_offset+required_bytes-stride : pixel_offset;
    dx<=0;dy<=0;sx<=0;sy<=0;
    x_acc<=BILINEAR ? $signed({2'b0,src_w})-$signed({2'b0,fit_w}):18'sd0;
    y_acc<=BILINEAR ? $signed({2'b0,src_h})-$signed({2'b0,fit_h}):18'sd0;
    write_req<=1;state<=(37'b1<<ACK);
   end
   state[ACK]: if(write_req_ack) begin write_req<=0;settle_count<=20;state<=(37'b1<<SETTLE);end
   state[SETTLE]: if(settle_count==0) state<=BILINEAR?(37'b1<<INIT_Y):(37'b1<<ROW);else settle_count<=settle_count-1'b1;
   state[ROW]: begin
    dx<=0;sx<=0;x_initial_ready<=0;
    x_acc<=BILINEAR ? $signed({2'b0,src_w})-$signed({2'b0,fit_w}):18'sd0;
    if(BILINEAR && inside_y) begin
     if(y_acc<0 || sy>=src_last_y)begin wy<=0;state<=(37'b1<<CHECK_ROWS);end
     else begin frac_rem<=y_acc;frac_den<={fit_h,1'b0};frac_bits<=0;frac_iter<=0;state<=(37'b1<<FRAC_Y);end
    end else if(inside_y && (!row_valid || cached_y!=sy)) begin
     row_write_addr<=0;channel<=0;stream_pos<=row_base;state<=(37'b1<<BYTE);
    end else state<=(37'b1<<PIX);
   end
   state[BYTE]: if(cache_valid && cache_index==(stream_pos>>9)) state<=(37'b1<<BYTE_WAIT);
    else begin request_index<=stream_pos>>9;return_state<=(37'b1<<BYTE);state<=(37'b1<<REQ);end
   state[BYTE_WAIT]: state<=(37'b1<<BYTE_GOT);
   state[BYTE_GOT]: begin
    stream_pos<=stream_pos+1'b1;
    case(channel)
     0:begin blue<=sector_q;channel<=1;state<=(37'b1<<BYTE);end
     1:begin green<=sector_q;channel<=2;state<=(37'b1<<BYTE);end
     2:begin
      channel<=0;
      if(row_write_addr==src_last_x) begin
       if(BILINEAR)begin
        valid_rows[load_y[0]]<=1;
        if(load_y[0])row_tag1<=load_y;else row_tag0<=load_y;
        state<=(37'b1<<CHECK_ROWS);
       end else begin row_valid<=1;cached_y<=sy;state<=(37'b1<<PIX);end
      end
      else begin row_write_addr<=row_write_addr+1'b1;state<=(37'b1<<BYTE);end
     end
    endcase
   end
   state[PIX]: if(inside_y && inside_x) begin
    if(BILINEAR)begin
     if(!x_initial_ready)state<=(37'b1<<INIT_X);
     else if(x_acc<0 || sx>=src_last_x)begin wx<=0;corner_phase<=0;state<=(37'b1<<READ_CORNERS);end
     else begin frac_rem<=x_acc;frac_den<={fit_w,1'b0};frac_bits<=0;frac_iter<=0;state<=(37'b1<<FRAC_X);end
    end else state<=(37'b1<<PIX_WAIT);
   end
    else begin pixel_pending<=0;state<=(37'b1<<EMIT);end
   state[PIX_WAIT]: begin pixel_pending<=row_q;state<=(37'b1<<EMIT);end
   state[EMIT]: if(!write_pause) begin
    bmp_data<=pixel_pending;bmp_data_wr_en<=1;
    if(dx==DST_WIDTH-1) begin
     if(dy==DST_HEIGHT-1) state<=(37'b1<<IDLE);
     else begin
      if(inside_y) begin y_acc<=y_acc+(BILINEAR?{src_h,1'b0}:{1'b0,src_h});state<=(37'b1<<YADV);end
      else state<=(37'b1<<NEXTROW);
     end
    end else begin
     dx<=dx+1'b1;
     if(inside_y && inside_x) begin x_acc<=x_acc+(BILINEAR?{src_w,1'b0}:{1'b0,src_w});state<=(37'b1<<XADV);end
     else state<=(37'b1<<PIX);
    end
   end
   state[XADV]: if(x_acc >= $signed(BILINEAR?{1'b0,fit_w,1'b0}:{2'b0,fit_w})) begin x_acc<=x_acc-(BILINEAR?{fit_w,1'b0}:fit_w);sx<=sx+1'b1;end else state<=(37'b1<<PIX);
   state[YADV]: if(y_acc >= $signed(BILINEAR?{1'b0,fit_h,1'b0}:{2'b0,fit_h})) begin
    y_acc<=y_acc-(BILINEAR?{fit_h,1'b0}:fit_h);sy<=sy+1'b1;
    row_base<=top_down ? row_base-stride : row_base+stride;
   end else state<=(37'b1<<NEXTROW);
   state[NEXTROW]: begin dy<=dy+1'b1;state<=(37'b1<<ROW);end
   state[INIT_Y]:if(y_acc >= $signed({1'b0,fit_h,1'b0}))begin
    y_acc<=y_acc-{fit_h,1'b0};sy<=sy+1'b1;
    row_base<=top_down?row_base-stride:row_base+stride;
   end else state<=(37'b1<<ROW);
   state[INIT_X]:if(x_acc >= $signed({1'b0,fit_w,1'b0}))begin
    x_acc<=x_acc-{fit_w,1'b0};sx<=sx+1'b1;
   end else begin x_initial_ready<=1;state<=(37'b1<<PIX);end
   (state[FRAC_X] || state[FRAC_Y]):begin
    frac_rem<=frac_ge ? frac_trial-{1'b0,frac_den}:frac_trial;
    frac_bits<=frac_next;
    if(frac_iter==7)begin
     if(state[FRAC_X])begin wx<=frac_next;corner_phase<=0;state<=(37'b1<<READ_CORNERS);end
     else begin wy<=frac_next;state<=(37'b1<<CHECK_ROWS);end
    end else frac_iter<=frac_iter+1'b1;
   end
   state[CHECK_ROWS]:begin
    if(!row0_present)begin
     load_y<=sy;stream_pos<=row_base;row_write_addr<=0;channel<=0;state<=(37'b1<<BYTE);
    end else if(!row1_present)begin
     load_y<=sy1;
     stream_pos<=(sy1==sy)?row_base:(top_down?row_base-stride:row_base+stride);
     row_write_addr<=0;channel<=0;state<=(37'b1<<BYTE);
    end else state<=(37'b1<<PIX);
   end
   state[READ_CORNERS]:begin
    case(corner_phase)
     1:p00<=row_q;
     3:p01<=row_q;
     5:p10<=row_q;
     7:p11<=row_q;
    endcase
    if(corner_phase==7)state<=(37'b1<<BLEND_H);
    else corner_phase<=corner_phase+1'b1;
   end
   state[BLEND_H]:begin
    hp0r<=($signed({1'b0,p01[23:16]})-$signed({1'b0,p00[23:16]}))*$signed({1'b0,wx});
    hp0g<=($signed({1'b0,p01[15:8]})-$signed({1'b0,p00[15:8]}))*$signed({1'b0,wx});
    hp0b<=($signed({1'b0,p01[7:0]})-$signed({1'b0,p00[7:0]}))*$signed({1'b0,wx});
    hp1r<=($signed({1'b0,p11[23:16]})-$signed({1'b0,p10[23:16]}))*$signed({1'b0,wx});
    hp1g<=($signed({1'b0,p11[15:8]})-$signed({1'b0,p10[15:8]}))*$signed({1'b0,wx});
    hp1b<=($signed({1'b0,p11[7:0]})-$signed({1'b0,p10[7:0]}))*$signed({1'b0,wx});
    state<=(37'b1<<H_SUM);
   end
   state[H_SUM]:begin
    h0r<=$signed({2'b0,p00[23:16],8'd0})+hp0r;
    h0g<=$signed({2'b0,p00[15:8],8'd0})+hp0g;
    h0b<=$signed({2'b0,p00[7:0],8'd0})+hp0b;
    h1r<=$signed({2'b0,p10[23:16],8'd0})+hp1r;
    h1g<=$signed({2'b0,p10[15:8],8'd0})+hp1g;
    h1b<=$signed({2'b0,p10[7:0],8'd0})+hp1b;
    state<=(37'b1<<BLEND_V);
   end
   state[BLEND_V]:begin
    vd_r<=$signed({1'b0,h1r})-$signed({1'b0,h0r});
    vd_g<=$signed({1'b0,h1g})-$signed({1'b0,h0g});
    vd_b<=$signed({1'b0,h1b})-$signed({1'b0,h0b});
    va_r<=h0r;va_g<=h0g;va_b<=h0b;state<=(37'b1<<V_MUL);
   end
   state[V_MUL]:begin
    vp_r<=vd_r*$signed({1'b0,wy});vp_g<=vd_g*$signed({1'b0,wy});vp_b<=vd_b*$signed({1'b0,wy});
    state<=(37'b1<<V_SUM);
   end
   state[V_SUM]:begin
    vr<=$signed({2'b0,va_r,8'd0})+vp_r+26'sd32768;
    vg<=$signed({2'b0,va_g,8'd0})+vp_g+26'sd32768;
    vb<=$signed({2'b0,va_b,8'd0})+vp_b+26'sd32768;
    state<=(37'b1<<BLEND_OUT);
   end
   state[BLEND_OUT]:begin pixel_pending<={vr[23:16],vg[23:16],vb[23:16]};state<=(37'b1<<EMIT);end
   state[SCAN_NEXT]: begin
    if(scan_found_total>=scan_target_count || {1'b0,base_lba}+request_index>scan_max_sector) begin
     scan_done<=1;state<=(37'b1<<IDLE);
    end else begin base_lba<=base_lba+request_index;state<=(37'b1<<HEADER);end
   end
   default:state<=(37'b1<<IDLE);
  endcase
  if(!state[IDLE] && expired) begin
   operation_error<=1;write_req<=0;sd_sec_read<=0;state<=(37'b1<<IDLE);cache_valid<=0;row_valid<=0;
   if(scan_mode) scan_done<=1;
  end
 end
end
endmodule

