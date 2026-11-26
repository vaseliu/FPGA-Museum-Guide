`timescale 1ns/1ps
// APDS-9960 host. All bus, recognition and control logic runs inside the FPGA.
// The sensor supplies raw U/D/L/R FIFO samples; no external processor is used.
module mg_i2c_register #(
 parameter integer CLK_HZ=100000000, I2C_HZ=100000, TIMEOUT_CYCLES=CLK_HZ/20
)(input clk,rst,start,read_op,input [7:0] reg_addr,write_data,
 input [7:0] read_length,inout scl,sda,
 output reg [3:0] error_code,output reg busy,done,error,rx_valid,output reg [7:0] rx_data,rx_index);
 localparam integer QDIV=(CLK_HZ+I2C_HZ*4-1)/(I2C_HZ*4);
 localparam IDLE=0,FREE=1,START_A=2,START_B=3,START_C=4,
 TX0=5,TX1=6,TX2=7,TX3=8,ACK0=9,ACK1=10,ACK2=11,ACK3=12,
 REP0=13,REP1=14,REP2=15,REP3=16,
 RX0=17,RX1=18,RX2=19,RX3=20,MA0=21,MA1=22,MA2=23,MA3=24,
 STOP0=25,STOP1=26,STOP2=27,STOP3=28,FINISH=29,REC0=30,REC1=31,REC2=32,REC3=33;
 reg [5:0] state;
 reg scl_low,sda_low,scl_s1,scl_s2,sda_s1,sda_s2;
 reg [15:0] divider;
 reg [23:0] watchdog;
 reg [7:0] addr_q,data_q,length_q,tx,rx;
 reg read_q,ack_failed;
 reg [1:0] stage;
 reg [2:0] bit_index;
 reg [3:0] recovery_pulses;
 assign scl=scl_low?1'b0:1'bz;
 assign sda=sda_low?1'b0:1'bz;
 always @(posedge clk or posedge rst)begin
  if(rst)begin scl_s1<=1;scl_s2<=1;sda_s1<=1;sda_s2<=1;end
  else begin scl_s1<=scl;scl_s2<=scl_s1;sda_s1<=sda;sda_s2<=sda_s1;end
 end
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   state<=IDLE;scl_low<=0;sda_low<=0;busy<=0;done<=0;error<=0;error_code<=0;
   divider<=0;watchdog<=0;rx_valid<=0;rx_data<=0;rx_index<=0;
   addr_q<=0;data_q<=0;length_q<=1;tx<=0;rx<=0;read_q<=0;
   stage<=0;bit_index<=7;ack_failed<=0;recovery_pulses<=0;
  end else begin
   done<=0;rx_valid<=0;
   if(!busy)begin
    divider<=0;watchdog<=0;
    if(start)begin
     busy<=1;error<=0;error_code<=0;addr_q<=reg_addr;data_q<=write_data;
     length_q<=read_length==0?8'd1:read_length;read_q<=read_op;
     rx_index<=0;state<=FREE;scl_low<=0;sda_low<=0;recovery_pulses<=0;
    end
   end else if(watchdog>=TIMEOUT_CYCLES-1)begin
    // Stuck clock/data cannot stall the media player. Release and retry later.
    busy<=0;done<=1;error<=1;error_code<=1;scl_low<=0;sda_low<=0;state<=IDLE;
   end else begin
    watchdog<=watchdog+1'b1;
    if(divider==QDIV-1)begin
     divider<=0;
     case(state)
      FREE:if(scl_s2)begin
       if(sda_s2)state<=START_A;
       else begin error<=1;error_code<=2;state<=REC0;end
      end
      START_A:begin sda_low<=1;state<=START_B;end
      START_B:begin scl_low<=1;state<=START_C;end
      START_C:begin tx<=8'h72;stage<=0;bit_index<=7;state<=TX0;end
      TX0:begin sda_low<=~tx[bit_index];state<=TX1;end
      TX1:begin scl_low<=0;state<=TX2;end
      TX2:if(scl_s2)state<=TX3;
      TX3:begin
       scl_low<=1;
       if(bit_index==0)state<=ACK0;
       else begin bit_index<=bit_index-1'b1;state<=TX0;end
      end
      ACK0:begin sda_low<=0;state<=ACK1;end
      ACK1:begin scl_low<=0;state<=ACK2;end
      ACK2:if(scl_s2)begin ack_failed<=sda_s2;state<=ACK3;end
      ACK3:begin
       scl_low<=1;
       if(ack_failed)begin error<=1;error_code<=stage==0?3:stage==1?4:read_q?6:5;state<=STOP0;end
       else if(stage==0)begin tx<=addr_q;stage<=1;bit_index<=7;state<=TX0;end
       else if(stage==1 && read_q)state<=REP0;
       else if(stage==1)begin tx<=data_q;stage<=2;bit_index<=7;state<=TX0;end
       else if(read_q)begin bit_index<=7;rx<=0;state<=RX0;end
       else state<=STOP0;
      end
      REP0:begin sda_low<=0;state<=REP1;end
      REP1:begin scl_low<=0;state<=REP2;end
      REP2:if(scl_s2)begin sda_low<=1;state<=REP3;end
      REP3:begin scl_low<=1;tx<=8'h73;stage<=2;bit_index<=7;state<=TX0;end
      RX0:begin sda_low<=0;state<=RX1;end
      RX1:begin scl_low<=0;state<=RX2;end
      RX2:if(scl_s2)begin rx[bit_index]<=sda_s2;state<=RX3;end
      RX3:begin
       scl_low<=1;
       if(bit_index==0)begin rx_data<=rx;rx_valid<=1;state<=MA0;end
       else begin bit_index<=bit_index-1'b1;state<=RX0;end
      end
      MA0:begin sda_low<=rx_index+8'd1<length_q;state<=MA1;end
      MA1:begin scl_low<=0;state<=MA2;end
      MA2:if(scl_s2)state<=MA3;
      MA3:begin
       scl_low<=1;
       if(rx_index+8'd1>=length_q)state<=STOP0;
       else begin rx_index<=rx_index+1'b1;bit_index<=7;state<=RX0;end
      end
      STOP0:begin scl_low<=1;sda_low<=1;state<=STOP1;end
      STOP1:begin scl_low<=0;state<=STOP2;end
      STOP2:if(scl_s2)state<=STOP3;
      STOP3:begin sda_low<=0;state<=FINISH;end
      FINISH:begin busy<=0;done<=1;state<=IDLE;end
      REC0:begin scl_low<=1;sda_low<=0;state<=REC1;end
      REC1:begin scl_low<=0;state<=REC2;end
      REC2:if(scl_s2)state<=REC3;
      REC3:begin
       scl_low<=1;
       if(recovery_pulses==8)state<=STOP0;
       else begin recovery_pulses<=recovery_pulses+1'b1;state<=REC0;end
      end
      default:begin error<=1;state<=STOP0;end
     endcase
    end else divider<=divider+1'b1;
   end
  end
 end
endmodule

// Ratio-sign crossings avoid a divider and reject a simple approach/retreat.
// A channel must exceed the opposite channel by >25%, with all channels >=20.
// One event per completed motion; ambiguous diagonal gestures are discarded.
module mg_gesture_decode #(
 parameter integer QUIET_MS=80,COOLDOWN_MS=350,MAX_SESSION_MS=1500
)(input clk,rst,tick_ms,abort_sample,sample_valid,
 input [7:0] up,down,left,right,
 output reg event_valid,output reg [2:0] direction);
 reg session,discard;
 reg [7:0] sample_count;
 reg [10:0] quiet_count,age_count;
 reg [9:0] cooldown;
 reg [1:0] first_ud,first_lr,last_ud,last_lr;
 wire valid_sample=up>=20 && down>=20 && left>=20 && right>=20;
 wire [8:0] down_high={1'b0,down}+{3'd0,down[7:2]};
 wire [8:0] up_high={1'b0,up}+{3'd0,up[7:2]};
 wire [8:0] right_high={1'b0,right}+{3'd0,right[7:2]};
 wire [8:0] left_high={1'b0,left}+{3'd0,left[7:2]};
 wire [1:0] ud=({1'b0,up}>down_high)?2'd1:({1'b0,down}>up_high)?2'd2:2'd0;
 wire [1:0] lr=({1'b0,left}>right_high)?2'd1:({1'b0,right}>left_high)?2'd2:2'd0;
 wire ud_cross=first_ud!=0 && last_ud!=0 && first_ud!=last_ud;
 wire lr_cross=first_lr!=0 && last_lr!=0 && first_lr!=last_lr;
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   session<=0;discard<=0;sample_count<=0;quiet_count<=0;age_count<=0;
   cooldown<=0;first_ud<=0;first_lr<=0;last_ud<=0;last_lr<=0;
   event_valid<=0;direction<=0;
  end else begin
   event_valid<=0;
   if(tick_ms && cooldown!=0)cooldown<=cooldown-1'b1;
   if(abort_sample)begin
    session<=0;discard<=0;sample_count<=0;first_ud<=0;first_lr<=0;last_ud<=0;last_lr<=0;
    quiet_count<=0;age_count<=0;
   end else if(sample_valid && valid_sample)begin
    quiet_count<=0;
    if(!session)begin
     session<=1;discard<=cooldown!=0;sample_count<=1;age_count<=0;
     first_ud<=ud;first_lr<=lr;last_ud<=ud;last_lr<=lr;
    end else begin
     if(sample_count!=255)sample_count<=sample_count+1'b1;
     if(ud!=0)begin if(first_ud==0)first_ud<=ud;last_ud<=ud;end
     if(lr!=0)begin if(first_lr==0)first_lr<=lr;last_lr<=lr;end
    end
   end else if(tick_ms && session)begin
    if(age_count<MAX_SESSION_MS)age_count<=age_count+1'b1;
    else discard<=1;
    if(quiet_count>=QUIET_MS-1)begin
     session<=0;sample_count<=0;quiet_count<=0;
     if(!discard && cooldown==0 && sample_count>=4 && (ud_cross ^ lr_cross))begin
      event_valid<=1;cooldown<=COOLDOWN_MS;
      if(lr_cross)direction<=first_lr==1?3'd1:3'd2;
      else direction<=first_ud==1?3'd3:3'd4;
     end
    end else quiet_count<=quiet_count+1'b1;
   end
  end
 end
endmodule

module mg_apds9960 #(
 parameter integer CLK_HZ=100000000,I2C_HZ=100000,
 parameter integer POWERUP_MS=20,RETRY_MS=500,POLL_MS=5,
 parameter integer I2C_TIMEOUT_CYCLES=CLK_HZ/20,
 parameter integer QUIET_MS=80,COOLDOWN_MS=350,AA_COMPAT=0
)(input clk,rst,inout scl,sda,
 output reg [23:0] diagnostic,output reg online,output event_valid,output [2:0] direction,output tick_ms);
 localparam BOOT=0,ISSUE=1,WAIT_BUS=2,COMPLETE=3,DELAY=4;
 localparam ID=0,INIT=1,STATUS=2,LEVEL=3,FIFO=4,CLEAR=5,RESUME=6,
 PROBE_OFF=7,PROBE_WRITE=8,PROBE_READ=9,PROBE_FAIL_RESTORE=10;
 reg [2:0] state;
 reg [3:0] operation,next_operation;
 reg [1:0] aa_reads,probe_index;
 wire [7:0] probe_pattern=probe_index==0?8'ha5:probe_index==1?8'h5a:8'hff;
 reg [5:0] init_index;
 reg [15:0] delay_ms;
 reg [16:0] ms_div;
 reg launch,read_op;
 reg [7:0] address,data,length,result;
 wire busy,done,error,rx_valid;
 wire [3:0] bus_error;
 reg [7:0] identity;
 wire [7:0] rx_data,rx_index;
 reg sample_valid,abort_sample;
 reg [7:0] u,d,l,r;
 reg [7:0] fifo_length;
 assign tick_ms=ms_div==CLK_HZ/1000-1;
 always @(posedge clk or posedge rst)
  if(rst)ms_div<=0;
  else if(tick_ms)ms_div<=0;
  else ms_div<=ms_div+1'b1;
 mg_i2c_register #(.CLK_HZ(CLK_HZ),.I2C_HZ(I2C_HZ),.TIMEOUT_CYCLES(I2C_TIMEOUT_CYCLES)) bus(
  .clk(clk),.rst(rst),.start(launch),.read_op(read_op),.reg_addr(address),.write_data(data),
  .read_length(length),.scl(scl),.sda(sda),.busy(busy),.done(done),.error(error),
  .rx_valid(rx_valid),.rx_data(rx_data),.rx_index(rx_index),.error_code(bus_error));
 mg_gesture_decode #(.QUIET_MS(QUIET_MS),.COOLDOWN_MS(COOLDOWN_MS)) decoder(
  .clk(clk),.rst(rst),.tick_ms(tick_ms),.abort_sample(abort_sample),
  .sample_valid(sample_valid),.up(u),.down(d),.left(l),.right(r),
  .event_valid(event_valid),.direction(direction));
 // Manufacturer register map; 0x39 is the 7-bit slave address.
 function [15:0] init_word;
 input [5:0] index;
 begin case(index)
  0:init_word=16'h8000; // Disable all engines while configuring.
  1:init_word=16'h83ff; // WTIME 2.78 ms.
  2:init_word=16'h8e87; // Proximity: eight 16-us pulses.
  3:init_word=16'h8f08; // PGAIN 4x, 100-mA LED (no boost).
  4:init_word=16'h9001; // Required reserved bit; LED boost off.
  5:init_word=16'ha028; // Gesture entry proximity threshold 40.
  6:init_word=16'ha11e; // Exit threshold 30.
  7:init_word=16'ha241; // Four-dataset threshold, exit persistence two.
  8:init_word=16'ha341; // Gesture gain 4x, wait 2.78 ms.
  9:init_word=16'ha400;
  10:init_word=16'ha500;
  11:init_word=16'ha700;
  12:init_word=16'ha900;
  13:init_word=16'ha687; // Gesture: eight 16-us pulses.
  14:init_word=16'haa00; // Both U/D and L/R pairs.
  15:init_word=16'hab04; // Clear FIFO (self-clearing bit).
  16:init_word=16'hab00; // Polling, no external INT wire required.
  default:init_word=16'h804d; // GEN | WEN | PEN | PON.
 endcase end
 endfunction
 reg [15:0] config_word;
 always @*begin
  config_word=init_word(init_index);
  read_op=1;address=8'h92;data=0;length=1;
  case(operation)
   INIT:begin read_op=0;address=config_word[15:8];data=config_word[7:0];end
   PROBE_OFF:begin read_op=0;address=8'h80;data=0;end
   PROBE_WRITE:begin read_op=0;address=8'h83;data=probe_pattern;end
   PROBE_READ:address=8'h83;
   PROBE_FAIL_RESTORE:begin read_op=0;address=8'h83;data=8'hff;end
   STATUS:address=8'haf;
   LEVEL:address=8'hae;
   FIFO:begin address=8'hfc;length=fifo_length;end
   CLEAR:begin read_op=0;address=8'hab;data=8'h04;end
   RESUME:begin read_op=0;address=8'hab;data=8'h00;end
   default:begin end
  endcase
 end
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   state<=BOOT;operation<=ID;next_operation<=ID;init_index<=0;delay_ms<=POWERUP_MS;
   launch<=0;online<=0;diagnostic<=0;identity<=0;result<=0;fifo_length<=4;sample_valid<=0;abort_sample<=0;
   u<=0;d<=0;l<=0;r<=0;aa_reads<=0;probe_index<=0;
  end else begin
   launch<=0;sample_valid<=0;abort_sample<=0;
   if(rx_valid)begin
    result<=rx_data;
    if(operation==FIFO)case(rx_index[1:0])
     0:u<=rx_data;1:d<=rx_data;2:l<=rx_data;
     3:begin r<=rx_data;sample_valid<=1;end
    endcase
   end
   case(state)
    BOOT:if(tick_ms)begin
     if(delay_ms<=1)begin operation<=ID;aa_reads<=0;state<=ISSUE;end
     else delay_ms<=delay_ms-1'b1;
    end
    ISSUE:if(!busy)begin launch<=1;state<=WAIT_BUS;end
    WAIT_BUS:if(done)begin
     if(error)begin
      online<=0;diagnostic<={4'he,bus_error,identity,address};abort_sample<=1;delay_ms<=RETRY_MS;state<=BOOT;
     end else state<=COMPLETE;
    end
    COMPLETE:case(operation)
     ID:begin identity<=result;
      if(aa_reads!=0 && result!=8'haa)begin
       online<=0;diagnostic<={8'hf2,result,8'h92};abort_sample<=1;delay_ms<=RETRY_MS;state<=BOOT;
      end else if(result==8'hab || result==8'h9c)begin init_index<=0;operation<=INIT;state<=ISSUE;end
      else if(AA_COMPAT && result==8'haa)begin
       if(aa_reads==3)begin probe_index<=0;operation<=PROBE_OFF;state<=ISSUE;end
       else begin aa_reads<=aa_reads+1'b1;delay_ms<=1;next_operation<=ID;state<=DELAY;end
      end
      else begin online<=0;diagnostic<={8'hf0,result,8'h92};abort_sample<=1;delay_ms<=RETRY_MS;state<=BOOT;end
     end
     // 0xAA is an experimental compatibility path, not a manufacturer identity claim.
     // Require four identical IDs plus full-byte WTIME write/read verification
     // with complementary patterns. Engines remain disabled during the probe.
     PROBE_OFF:begin operation<=PROBE_WRITE;state<=ISSUE;end
     PROBE_WRITE:begin operation<=PROBE_READ;state<=ISSUE;end
     PROBE_READ:if(result!=probe_pattern)begin
      online<=0;diagnostic<={8'hf1,result,8'h83};abort_sample<=1;operation<=PROBE_FAIL_RESTORE;state<=ISSUE;
     end else if(probe_index==2)begin
      init_index<=0;operation<=INIT;state<=ISSUE;
     end else begin probe_index<=probe_index+1'b1;operation<=PROBE_WRITE;state<=ISSUE;end
     PROBE_FAIL_RESTORE:begin delay_ms<=RETRY_MS;state<=BOOT;end
     INIT:if(init_index==17)begin
      online<=1;diagnostic<={8'h20,identity,8'h80};delay_ms<=10;next_operation<=STATUS;state<=DELAY;
     end else begin init_index<=init_index+1'b1;state<=ISSUE;end
     STATUS:if(result[1])begin abort_sample<=1;operation<=CLEAR;state<=ISSUE;end
      else begin operation<=LEVEL;state<=ISSUE;end
     LEVEL:if(result>32)begin abort_sample<=1;operation<=CLEAR;state<=ISSUE;end
      else if(result!=0)begin fifo_length<={result[5:0],2'b00};operation<=FIFO;state<=ISSUE;end
      else begin delay_ms<=POLL_MS;next_operation<=STATUS;state<=DELAY;end
     FIFO:begin operation<=STATUS;state<=ISSUE;end
     CLEAR:begin operation<=RESUME;state<=ISSUE;end
     default:begin operation<=STATUS;state<=ISSUE;end
    endcase
    DELAY:if(tick_ms)begin
     if(delay_ms<=1)begin operation<=next_operation;state<=ISSUE;end
     else delay_ms<=delay_ms-1'b1;
    end
    default:state<=BOOT;
   endcase
  end
 end
endmodule

// Reuse the proven media-player key debounce by holding virtual keys for 40 ms.
// Independent toggle channels transfer gesture effects to the video domain.
module mg_gesture_actions #(parameter integer KEY_HOLD_MS=40,VERTICAL_ENABLE=1)(
 input clk,rst,tick_ms,event_valid,input [2:0] direction,
 output next_active,auto_active,output zoom_pulse,output reg effect_toggle);
 reg [5:0] next_ms,auto_ms;
 assign next_active=next_ms!=0;
 assign auto_active=auto_ms!=0;
 assign zoom_pulse=VERTICAL_ENABLE && event_valid && direction==3;
 always @(posedge clk or posedge rst)begin
  if(rst)begin next_ms<=0;auto_ms<=0;effect_toggle<=0;end
  else begin
   if(tick_ms)begin
    if(next_ms!=0)next_ms<=next_ms-1'b1;
    if(auto_ms!=0)auto_ms<=auto_ms-1'b1;
   end
   if(event_valid)case(direction)
    1:next_ms<=KEY_HOLD_MS;
    2:auto_ms<=KEY_HOLD_MS;
    4:if(VERTICAL_ENABLE)effect_toggle<=~effect_toggle;
    default:begin end
   endcase
  end
 end
endmodule
