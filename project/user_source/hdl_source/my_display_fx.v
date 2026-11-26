`timescale 1ns/1ps
//=============================================================================
// Original real-time image-processing pipeline for the HX4S20 multimedia demo.
// Modes: 0 passthrough; 1 adaptive enhancement; 2 contour fusion;
//        3 warm posterization.  key3 selects the mode at a frame boundary.
// Chinese OSD: player title, effect, brightness, panel opacity and zoom.
//=============================================================================
module my_display_fx #(
    parameter GESTURE_STATUS=0,
    parameter UNIFIED_PANEL=0,RESOLUTION_OSD=0,
    parameter GESTURE_DIAGNOSTICS=1,
    parameter ALPHA_OVERLAY=0,
    parameter ZOOM_OSD = 0,
    parameter H_ACTIVE       = 640,
    parameter V_ACTIVE       = 480,
    parameter FADE_PER_FRAME = 8'd16
)(
    input wire gesture_online,
    input wire [23:0] gesture_diagnostic,
    input wire [1:0] zoom_level,
    input  wire        video_clk,
    input  wire        sd_clk,
    input  wire        subtitle_wr_en,
    input  wire [10:0] subtitle_wr_addr,
    input  wire [7:0]  subtitle_wr_data,
    input  wire [6:0]  subtitle_count,
    input  wire        uart_subtitle_wr_en,
    input  wire        uart_subtitle_wr_bank,
    input  wire [10:0] uart_subtitle_wr_addr,
    input  wire [7:0]  uart_subtitle_wr_data,
    input  wire [6:0]  uart_subtitle_count,
    input  wire        uart_subtitle_bank,
    input  wire        uart_subtitle_commit,
    output reg         uart_subtitle_ack,
    input  wire        rst,
    input  wire        hs,
    input  wire        vs,
    input  wire        de,
    input  wire [1:0]  disp_buf_idx,
    input  wire [1:0]  image_index,
    input  wire        effect_next,
    input  wire        image_change_start,
    input  wire        brightness_next,
    input  wire        wave_gain_next,
    input  wire        overlay_toggle,
    input  wire        focus_toggle,
    input  wire        audio_valid,
    input  wire [23:0] audio_sample,
    input  wire [23:0] rgb_in,
    output reg         hs_o,
    output reg         vs_o,
    output reg         de_o,
    output reg  [23:0] rgb_o,
    output reg  [1:0]  effect_mode,
    output reg  [7:0]  scene_luma
);

    function [7:0] abs_diff8;
        input [7:0] a;
        input [7:0] b;
        begin
            abs_diff8 = (a >= b) ? (a - b) : (b - a);
        end
    endfunction

    function [7:0] clamp_s11;
        input signed [10:0] value;
        begin
            if (value < 0)
                clamp_s11 = 8'd0;
            else if (value > 11'sd255)
                clamp_s11 = 8'd255;
            else
                clamp_s11 = value[7:0];
        end
    endfunction

    function [7:0] poster_level;
        input [7:0] value;
        begin
            case (value[7:5])
                3'd0: poster_level = 8'd8;
                3'd1: poster_level = 8'd40;
                3'd2: poster_level = 8'd72;
                3'd3: poster_level = 8'd104;
                3'd4: poster_level = 8'd144;
                3'd5: poster_level = 8'd184;
                3'd6: poster_level = 8'd224;
                default: poster_level = 8'd255;
            endcase
        end
    endfunction

    // Fixed 16x16 Chinese UI glyphs, generated from the local SimSun font.
    function [15:0] chinese_row;
      input [7:0] c; input [3:0] row;
      begin case ({c,row})
12'h800: chinese_row=16'h0820;
12'h801: chinese_row=16'h4920;
12'h802: chinese_row=16'h2a20;
12'h803: chinese_row=16'h083e;
12'h804: chinese_row=16'hff44;
12'h805: chinese_row=16'h2a44;
12'h806: chinese_row=16'h4944;
12'h807: chinese_row=16'h88a4;
12'h808: chinese_row=16'h1028;
12'h809: chinese_row=16'hfe28;
12'h80a: chinese_row=16'h2210;
12'h80b: chinese_row=16'h4210;
12'h80c: chinese_row=16'h6428;
12'h80d: chinese_row=16'h1828;
12'h80e: chinese_row=16'h3444;
12'h80f: chinese_row=16'hc282;
12'h810: chinese_row=16'h0820;
12'h811: chinese_row=16'h0820;
12'h812: chinese_row=16'hfffe;
12'h813: chinese_row=16'h0820;
12'h814: chinese_row=16'h0820;
12'h815: chinese_row=16'h0200;
12'h816: chinese_row=16'h0100;
12'h817: chinese_row=16'h0080;
12'h818: chinese_row=16'h0408;
12'h819: chinese_row=16'h2404;
12'h81a: chinese_row=16'h2402;
12'h81b: chinese_row=16'h4402;
12'h81c: chinese_row=16'h8410;
12'h81d: chinese_row=16'h0410;
12'h81e: chinese_row=16'h03f0;
12'h820: chinese_row=16'h3ff8;
12'h821: chinese_row=16'h0100;
12'h822: chinese_row=16'h0100;
12'h823: chinese_row=16'h0100;
12'h824: chinese_row=16'h0100;
12'h825: chinese_row=16'hfffe;
12'h826: chinese_row=16'h0100;
12'h827: chinese_row=16'h0280;
12'h828: chinese_row=16'h0280;
12'h829: chinese_row=16'h0440;
12'h82a: chinese_row=16'h0440;
12'h82b: chinese_row=16'h0820;
12'h82c: chinese_row=16'h1010;
12'h82d: chinese_row=16'h2008;
12'h82e: chinese_row=16'hc006;
12'h830: chinese_row=16'hfffe;
12'h831: chinese_row=16'h0200;
12'h832: chinese_row=16'h0200;
12'h833: chinese_row=16'h0200;
12'h834: chinese_row=16'h0200;
12'h835: chinese_row=16'h0240;
12'h836: chinese_row=16'h0220;
12'h837: chinese_row=16'h0210;
12'h838: chinese_row=16'h0208;
12'h839: chinese_row=16'h0208;
12'h83a: chinese_row=16'h0200;
12'h83b: chinese_row=16'h0200;
12'h83c: chinese_row=16'h0200;
12'h83d: chinese_row=16'h0200;
12'h83e: chinese_row=16'h0200;
12'h840: chinese_row=16'h1110;
12'h841: chinese_row=16'h1110;
12'h842: chinese_row=16'h17fc;
12'h843: chinese_row=16'h1110;
12'h844: chinese_row=16'hfc00;
12'h845: chinese_row=16'h13f8;
12'h846: chinese_row=16'h3208;
12'h847: chinese_row=16'h3bf8;
12'h848: chinese_row=16'h5608;
12'h849: chinese_row=16'h53f8;
12'h84a: chinese_row=16'h9040;
12'h84b: chinese_row=16'h17fc;
12'h84c: chinese_row=16'h10a0;
12'h84d: chinese_row=16'h1110;
12'h84e: chinese_row=16'h1208;
12'h84f: chinese_row=16'h1406;
12'h850: chinese_row=16'h0048;
12'h851: chinese_row=16'h0044;
12'h852: chinese_row=16'h0044;
12'h853: chinese_row=16'h0040;
12'h854: chinese_row=16'hfffe;
12'h855: chinese_row=16'h0040;
12'h856: chinese_row=16'h0040;
12'h857: chinese_row=16'h3e40;
12'h858: chinese_row=16'h0840;
12'h859: chinese_row=16'h0840;
12'h85a: chinese_row=16'h0820;
12'h85b: chinese_row=16'h0822;
12'h85c: chinese_row=16'h0f12;
12'h85d: chinese_row=16'h780a;
12'h85e: chinese_row=16'h2006;
12'h85f: chinese_row=16'h0002;
12'h860: chinese_row=16'h3ffe;
12'h861: chinese_row=16'h2080;
12'h862: chinese_row=16'h2100;
12'h863: chinese_row=16'h27f0;
12'h864: chinese_row=16'h2410;
12'h865: chinese_row=16'h2410;
12'h866: chinese_row=16'h27f0;
12'h867: chinese_row=16'h2410;
12'h868: chinese_row=16'h2410;
12'h869: chinese_row=16'h27f0;
12'h86a: chinese_row=16'h2080;
12'h86b: chinese_row=16'h2490;
12'h86c: chinese_row=16'h4888;
12'h86d: chinese_row=16'h5284;
12'h86e: chinese_row=16'h8100;
12'h870: chinese_row=16'h7ffc;
12'h871: chinese_row=16'h4204;
12'h872: chinese_row=16'h4204;
12'h873: chinese_row=16'h47e4;
12'h874: chinese_row=16'h4c44;
12'h875: chinese_row=16'h5284;
12'h876: chinese_row=16'h4104;
12'h877: chinese_row=16'h46c4;
12'h878: chinese_row=16'h783c;
12'h879: chinese_row=16'h4304;
12'h87a: chinese_row=16'h4084;
12'h87b: chinese_row=16'h4604;
12'h87c: chinese_row=16'h4184;
12'h87d: chinese_row=16'h7ffc;
12'h87e: chinese_row=16'h4004;
12'h880: chinese_row=16'h2208;
12'h881: chinese_row=16'h2110;
12'h882: chinese_row=16'h2000;
12'h883: chinese_row=16'h27fc;
12'h884: chinese_row=16'h2444;
12'h885: chinese_row=16'hfd54;
12'h886: chinese_row=16'h24e4;
12'h887: chinese_row=16'h2444;
12'h888: chinese_row=16'h27fc;
12'h889: chinese_row=16'h2000;
12'h88a: chinese_row=16'h23f8;
12'h88b: chinese_row=16'h3a08;
12'h88c: chinese_row=16'he3f8;
12'h88d: chinese_row=16'h4208;
12'h88e: chinese_row=16'h03f8;
12'h88f: chinese_row=16'h0208;
12'h890: chinese_row=16'hf9fc;
12'h891: chinese_row=16'h0904;
12'h892: chinese_row=16'h0904;
12'h893: chinese_row=16'h09fc;
12'h894: chinese_row=16'h7820;
12'h895: chinese_row=16'h4020;
12'h896: chinese_row=16'h43fe;
12'h897: chinese_row=16'h4222;
12'h898: chinese_row=16'h7a22;
12'h899: chinese_row=16'h0bfe;
12'h89a: chinese_row=16'h0820;
12'h89b: chinese_row=16'h0824;
12'h89c: chinese_row=16'h0822;
12'h89d: chinese_row=16'h57fe;
12'h89e: chinese_row=16'h2002;
12'h8a0: chinese_row=16'h2040;
12'h8a1: chinese_row=16'h2040;
12'h8a2: chinese_row=16'h20a0;
12'h8a3: chinese_row=16'hfca0;
12'h8a4: chinese_row=16'h4110;
12'h8a5: chinese_row=16'h5208;
12'h8a6: chinese_row=16'h9406;
12'h8a7: chinese_row=16'hfd10;
12'h8a8: chinese_row=16'h1120;
12'h8a9: chinese_row=16'h1140;
12'h8aa: chinese_row=16'h1d80;
12'h8ab: chinese_row=16'hf100;
12'h8ac: chinese_row=16'h5104;
12'h8ad: chinese_row=16'h1104;
12'h8ae: chinese_row=16'h10fc;
12'h8af: chinese_row=16'h1000;
12'h8b0: chinese_row=16'h0080;
12'h8b1: chinese_row=16'h3ffe;
12'h8b2: chinese_row=16'h2200;
12'h8b3: chinese_row=16'h3fbc;
12'h8b4: chinese_row=16'h2024;
12'h8b5: chinese_row=16'h2fa4;
12'h8b6: chinese_row=16'h28a8;
12'h8b7: chinese_row=16'h2fa8;
12'h8b8: chinese_row=16'h2024;
12'h8b9: chinese_row=16'h2fa4;
12'h8ba: chinese_row=16'h2124;
12'h8bb: chinese_row=16'h23f4;
12'h8bc: chinese_row=16'h5e28;
12'h8bd: chinese_row=16'h4220;
12'h8be: chinese_row=16'h8a20;
12'h8bf: chinese_row=16'h0420;
12'h8c0: chinese_row=16'h0100;
12'h8c1: chinese_row=16'h2100;
12'h8c2: chinese_row=16'h11fc;
12'h8c3: chinese_row=16'h1200;
12'h8c4: chinese_row=16'h85f8;
12'h8c5: chinese_row=16'h4108;
12'h8c6: chinese_row=16'h4948;
12'h8c7: chinese_row=16'h0928;
12'h8c8: chinese_row=16'h17fe;
12'h8c9: chinese_row=16'h1108;
12'h8ca: chinese_row=16'he248;
12'h8cb: chinese_row=16'h2228;
12'h8cc: chinese_row=16'h23fc;
12'h8cd: chinese_row=16'h2008;
12'h8ce: chinese_row=16'h2050;
12'h8cf: chinese_row=16'h0020;
12'h8d0: chinese_row=16'h1000;
12'h8d1: chinese_row=16'h11fc;
12'h8d2: chinese_row=16'h1104;
12'h8d3: chinese_row=16'h1104;
12'h8d4: chinese_row=16'hfd14;
12'h8d5: chinese_row=16'h1108;
12'h8d6: chinese_row=16'h1100;
12'h8d7: chinese_row=16'h15fc;
12'h8d8: chinese_row=16'h1944;
12'h8d9: chinese_row=16'h3144;
12'h8da: chinese_row=16'hd128;
12'h8db: chinese_row=16'h1128;
12'h8dc: chinese_row=16'h1110;
12'h8dd: chinese_row=16'h1128;
12'h8de: chinese_row=16'h5144;
12'h8df: chinese_row=16'h2182;
12'h8e0: chinese_row=16'h0200;
12'h8e1: chinese_row=16'h0100;
12'h8e2: chinese_row=16'h7ffc;
12'h8e4: chinese_row=16'h1ff0;
12'h8e5: chinese_row=16'h1010;
12'h8e6: chinese_row=16'h1ff0;
12'h8e8: chinese_row=16'h7ffe;
12'h8e9: chinese_row=16'h4002;
12'h8ea: chinese_row=16'h8fe4;
12'h8eb: chinese_row=16'h0820;
12'h8ec: chinese_row=16'h0820;
12'h8ed: chinese_row=16'h1022;
12'h8ee: chinese_row=16'h2022;
12'h8ef: chinese_row=16'hc01e;
12'h8f0: chinese_row=16'h0100;
12'h8f1: chinese_row=16'h0080;
12'h8f2: chinese_row=16'h3ffe;
12'h8f3: chinese_row=16'h2220;
12'h8f4: chinese_row=16'h2220;
12'h8f5: chinese_row=16'h3ffc;
12'h8f6: chinese_row=16'h2220;
12'h8f7: chinese_row=16'h2220;
12'h8f8: chinese_row=16'h23e0;
12'h8f9: chinese_row=16'h2000;
12'h8fa: chinese_row=16'h2ff0;
12'h8fb: chinese_row=16'h2410;
12'h8fc: chinese_row=16'h4220;
12'h8fd: chinese_row=16'h41c0;
12'h8fe: chinese_row=16'h8630;
12'h8ff: chinese_row=16'h380e;
12'h900: chinese_row=16'h7ffc;
12'h901: chinese_row=16'h0080;
12'h902: chinese_row=16'h0080;
12'h903: chinese_row=16'h0100;
12'h904: chinese_row=16'h0100;
12'h905: chinese_row=16'h0340;
12'h906: chinese_row=16'h0520;
12'h907: chinese_row=16'h0910;
12'h908: chinese_row=16'h1108;
12'h909: chinese_row=16'h2104;
12'h90a: chinese_row=16'h4104;
12'h90b: chinese_row=16'h8100;
12'h90c: chinese_row=16'h0100;
12'h90d: chinese_row=16'h0100;
12'h90e: chinese_row=16'h0100;
12'h910: chinese_row=16'h0038;
12'h911: chinese_row=16'h23c0;
12'h912: chinese_row=16'h1040;
12'h913: chinese_row=16'h17fc;
12'h914: chinese_row=16'h0150;
12'h915: chinese_row=16'h0248;
12'h916: chinese_row=16'hf446;
12'h917: chinese_row=16'h13f0;
12'h918: chinese_row=16'h1110;
12'h919: chinese_row=16'h113c;
12'h91a: chinese_row=16'h1104;
12'h91b: chinese_row=16'h1214;
12'h91c: chinese_row=16'h1408;
12'h91d: chinese_row=16'h2800;
12'h91e: chinese_row=16'h47fe;
12'h920: chinese_row=16'h00fc;
12'h921: chinese_row=16'h7c84;
12'h922: chinese_row=16'h4484;
12'h923: chinese_row=16'h4484;
12'h924: chinese_row=16'h44fc;
12'h925: chinese_row=16'h7c84;
12'h926: chinese_row=16'h4484;
12'h927: chinese_row=16'h4484;
12'h928: chinese_row=16'h44fc;
12'h929: chinese_row=16'h7c84;
12'h92a: chinese_row=16'h4484;
12'h92b: chinese_row=16'h0104;
12'h92c: chinese_row=16'h0104;
12'h92d: chinese_row=16'h0214;
12'h92e: chinese_row=16'h0408;
12'h930: chinese_row=16'h2040;
12'h931: chinese_row=16'h2020;
12'h932: chinese_row=16'h27fe;
12'h933: chinese_row=16'h4402;
12'h934: chinese_row=16'h5100;
12'h935: chinese_row=16'hf1fe;
12'h936: chinese_row=16'h2210;
12'h937: chinese_row=16'h2620;
12'h938: chinese_row=16'h4a7c;
12'h939: chinese_row=16'hf244;
12'h93a: chinese_row=16'h4244;
12'h93b: chinese_row=16'h027c;
12'h93c: chinese_row=16'h3244;
12'h93d: chinese_row=16'hc244;
12'h93e: chinese_row=16'h027c;
12'h93f: chinese_row=16'h0244;
12'h940: chinese_row=16'h2040;
12'h941: chinese_row=16'h1040;
12'h942: chinese_row=16'h0040;
12'h943: chinese_row=16'hfe80;
12'h944: chinese_row=16'h20fe;
12'h945: chinese_row=16'h2108;
12'h946: chinese_row=16'h3e88;
12'h947: chinese_row=16'h2488;
12'h948: chinese_row=16'h2488;
12'h949: chinese_row=16'h2450;
12'h94a: chinese_row=16'h2450;
12'h94b: chinese_row=16'h2420;
12'h94c: chinese_row=16'h4450;
12'h94d: chinese_row=16'h5488;
12'h94e: chinese_row=16'h8904;
12'h94f: chinese_row=16'h0202;
12'h950: chinese_row=16'h0040;
12'h951: chinese_row=16'h0440;
12'h952: chinese_row=16'h0420;
12'h953: chinese_row=16'h0820;
12'h954: chinese_row=16'h1010;
12'h955: chinese_row=16'h2008;
12'h956: chinese_row=16'h4004;
12'h957: chinese_row=16'h9fe2;
12'h958: chinese_row=16'h0420;
12'h959: chinese_row=16'h0420;
12'h95a: chinese_row=16'h0420;
12'h95b: chinese_row=16'h0820;
12'h95c: chinese_row=16'h0820;
12'h95d: chinese_row=16'h1020;
12'h95e: chinese_row=16'h2140;
12'h95f: chinese_row=16'h4080;
12'h960: chinese_row=16'h2010;
12'h961: chinese_row=16'h1088;
12'h962: chinese_row=16'h1088;
12'h963: chinese_row=16'h7cbe;
12'h964: chinese_row=16'h0080;
12'h965: chinese_row=16'h2a94;
12'h966: chinese_row=16'h1288;
12'h967: chinese_row=16'hfebe;
12'h968: chinese_row=16'h1288;
12'h969: chinese_row=16'h1088;
12'h96a: chinese_row=16'h7c9c;
12'h96b: chinese_row=16'h1108;
12'h96c: chinese_row=16'h1108;
12'h96d: chinese_row=16'h2208;
12'h96e: chinese_row=16'h2408;
12'h96f: chinese_row=16'h4008;
12'h970: chinese_row=16'h0200;
12'h971: chinese_row=16'h0100;
12'h972: chinese_row=16'h7ffc;
12'h973: chinese_row=16'h0200;
12'h974: chinese_row=16'h4444;
12'h975: chinese_row=16'h2f88;
12'h976: chinese_row=16'h1110;
12'h977: chinese_row=16'h2248;
12'h978: chinese_row=16'h4fe4;
12'h979: chinese_row=16'h0020;
12'h97a: chinese_row=16'h0100;
12'h97b: chinese_row=16'hfffe;
12'h97c: chinese_row=16'h0100;
12'h97d: chinese_row=16'h0100;
12'h97e: chinese_row=16'h0100;
12'h97f: chinese_row=16'h0100;
12'h980: chinese_row=16'h0101;
12'h981: chinese_row=16'h0082;
12'h982: chinese_row=16'h0044;
12'h983: chinese_row=16'h0028;
12'h984: chinese_row=16'h0010;
12'h985: chinese_row=16'h0028;
12'h986: chinese_row=16'h0044;
12'h987: chinese_row=16'h0082;
12'h988: chinese_row=16'h0101;
        default: chinese_row=16'h0000;
      endcase end
    endfunction

    function [63:0] glyph64;
        input [7:0] c;
        begin
            case (c)
                "A": glyph64 = 64'h1824427E42424200;
                "B": glyph64 = 64'h7C42427C42427C00;
                "C": glyph64 = 64'h3C42404040423C00;
                "D": glyph64 = 64'h7844424242447800;
                "E": glyph64 = 64'h7E40407C40407E00;
                "F": glyph64 = 64'h7E40407C40404000;
                "G": glyph64 = 64'h3C42404E42423C00;
                "H": glyph64 = 64'h4242427E42424200;
                "I": glyph64 = 64'h3E08080808083E00;
                "L": glyph64 = 64'h4040404040407E00;
                "M": glyph64 = 64'h42665A5A42424200;
                "N": glyph64 = 64'h4262524A46424200;
                "O": glyph64 = 64'h3C42424242423C00;
                "P": glyph64 = 64'h7C42427C40404000;
                "R": glyph64 = 64'h7C42427C48444200;
                "S": glyph64 = 64'h3C42403C02423C00;
                "T": glyph64 = 64'h7F08080808080800;
                "U": glyph64 = 64'h4242424242423C00;
                "Z": glyph64 = 64'h7E02040810207E00;
                "%": glyph64 = 64'h62640810264C0000;
                "Y": glyph64 = 64'h4242241818181800;
                ":": glyph64 = 64'h0018180018180000;
                "-": glyph64 = 64'h0000007E00000000;
                "+": glyph64 = 64'h0010107C10100000;
                "0": glyph64 = 64'h3C464A5262423C00;
                "1": glyph64 = 64'h1838080808083E00;
                "2": glyph64 = 64'h3C42020C30607E00;
                "3": glyph64 = 64'h7C02021C02427C00;
                "4": glyph64 = 64'h0C1424447E040400;
                "5": glyph64 = 64'h7E407C0202423C00;
                "6": glyph64 = 64'h1C20407C42423C00;
                "7": glyph64 = 64'h7E02040810101000;
                "8": glyph64 = 64'h3C42423C42423C00;
                "9": glyph64 = 64'h3C42423E02043800;
                default: glyph64 = 64'h0000000000000000;
            endcase
        end
    endfunction


    // 63-character scrolling contest subtitle, rendered with the OSD font.
    function [7:0] ticker_char;
        input [5:0] index;
        begin
            case (index)
                6'd0: ticker_char = "F";
                6'd1: ticker_char = "P";
                6'd2: ticker_char = "G";
                6'd3: ticker_char = "A";
                6'd4: ticker_char = " ";
                6'd5: ticker_char = "H";
                6'd6: ticker_char = "D";
                6'd7: ticker_char = "M";
                6'd8: ticker_char = "I";
                6'd9: ticker_char = " ";
                6'd10: ticker_char = "M";
                6'd11: ticker_char = "U";
                6'd12: ticker_char = "L";
                6'd13: ticker_char = "T";
                6'd14: ticker_char = "I";
                6'd15: ticker_char = "M";
                6'd16: ticker_char = "E";
                6'd17: ticker_char = "D";
                6'd18: ticker_char = "I";
                6'd19: ticker_char = "A";
                6'd20: ticker_char = " ";
                6'd21: ticker_char = "P";
                6'd22: ticker_char = "L";
                6'd23: ticker_char = "A";
                6'd24: ticker_char = "Y";
                6'd25: ticker_char = "E";
                6'd26: ticker_char = "R";
                6'd27: ticker_char = " ";
                6'd28: ticker_char = "-";
                6'd29: ticker_char = " ";
                6'd30: ticker_char = "R";
                6'd31: ticker_char = "E";
                6'd32: ticker_char = "A";
                6'd33: ticker_char = "L";
                6'd34: ticker_char = " ";
                6'd35: ticker_char = "T";
                6'd36: ticker_char = "I";
                6'd37: ticker_char = "M";
                6'd38: ticker_char = "E";
                6'd39: ticker_char = " ";
                6'd40: ticker_char = "I";
                6'd41: ticker_char = "M";
                6'd42: ticker_char = "A";
                6'd43: ticker_char = "G";
                6'd44: ticker_char = "E";
                6'd45: ticker_char = " ";
                6'd46: ticker_char = "E";
                6'd47: ticker_char = "F";
                6'd48: ticker_char = "F";
                6'd49: ticker_char = "E";
                6'd50: ticker_char = "C";
                6'd51: ticker_char = "T";
                6'd52: ticker_char = "S";
                6'd53: ticker_char = " ";
                6'd54: ticker_char = "-";
                6'd55: ticker_char = " ";
                6'd56: ticker_char = "2";
                6'd57: ticker_char = "0";
                6'd58: ticker_char = "2";
                6'd59: ticker_char = "6";
                6'd60: ticker_char = " ";
                6'd61: ticker_char = " ";
                6'd62: ticker_char = " ";
                default: ticker_char = " ";
            endcase
        end
    endfunction

    // Zero-based coordinates while DE is asserted.
    reg [10:0] x;
    reg [10:0] y;
    reg        de_d;
    reg        vs_d;
    wire       de_rise = de & ~de_d;
    wire       frame_edge = vs & ~vs_d;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            de_d <= 1'b0;
            vs_d <= 1'b0;
            x    <= 11'd0;
            y    <= 11'd0;
        end else begin
            de_d <= de;
            vs_d <= vs;
            if (frame_edge)
                y <= 11'd0;
            else if (!de && de_d)
                y <= y + 11'd1;
            if (de)
                x <= x + 11'd1;
            else
                x <= 11'd0;
        end
    end

    // Full transition: fade old frame out, wait for the double-buffer commit,
    // then fade the new frame in. All level changes occur at frame boundaries.
    // If an SD-card read fails, leave the black wait state after about two
    // seconds so a KEY1 press can never look like a permanent system reset.
    localparam [2:0] TRANS_IDLE=3'd0, TRANS_FADE_OUT=3'd1,
                     TRANS_WAIT_NEW=3'd2, TRANS_FADE_IN=3'd3,
                     TRANS_SLIDE_IN=3'd4;
    localparam [10:0] SLIDE_PER_FRAME=11'd40;
    reg [1:0] buf_s1, buf_s2, buf_s2_d;
    reg image_change_pending, transition_req_pending, effect_change_pending;
    reg [2:0] transition_state;
    reg fading;
    reg sliding;
    reg [7:0] fade;
    reg [10:0] slide_edge;
    reg [6:0] transition_wait_frames;
    wire buffer_changed = (buf_s2 != buf_s2_d);

    // Start with the audio display visible; the long KEY3 press still hides
    // the complete overlay at a frame boundary without visible tearing.
    reg overlay_enabled;
    reg overlay_toggle_pending;
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            overlay_enabled        <= 1'b1;
            overlay_toggle_pending <= 1'b0;
        end else begin
            if (overlay_toggle)
                overlay_toggle_pending <= 1'b1;
            if (frame_edge && (overlay_toggle_pending || overlay_toggle)) begin
                overlay_enabled        <= ~overlay_enabled;
                overlay_toggle_pending <= 1'b0;
            end
        end
    end

    // First four museum pages from Desktop/New Folder (2): bronze in the
    // home page, route arrows, artifact vessel, emergency-exit instruction.
    // image_index follows the SD scanner's discovery order on the TF card.
    reg focus_enabled;
    reg focus_toggle_pending;
    reg [10:0] focus_x0, focus_x1, focus_y0, focus_y1;
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            focus_enabled        <= 1'b0;
            focus_toggle_pending <= 1'b0;
        end else begin
            if (focus_toggle)
                focus_toggle_pending <= 1'b1;
            if (frame_edge && (focus_toggle_pending || focus_toggle)) begin
                focus_enabled        <= ~focus_enabled;
                focus_toggle_pending <= 1'b0;
            end
        end
    end

    always @(*) begin
        case (image_index)
            2'd0: begin focus_x0=11'd135; focus_x1=11'd270;
                        focus_y0=11'd205; focus_y1=11'd380; end
            2'd1: begin focus_x0=11'd157; focus_x1=11'd480;
                        focus_y0=11'd93;  focus_y1=11'd355; end
            2'd2: begin focus_x0=11'd23;  focus_x1=11'd372;
                        focus_y0=11'd61;  focus_y1=11'd445; end
            default: begin focus_x0=11'd338; focus_x1=11'd633;
                           focus_y0=11'd122; focus_y1=11'd233; end
        endcase
    end

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            buf_s1<=0; buf_s2<=0; buf_s2_d<=0;
            image_change_pending<=0; transition_req_pending<=0;
            effect_change_pending<=0; effect_mode<=0;
            transition_state<=TRANS_IDLE; fading<=0; sliding<=0;
            fade<=8'd255; slide_edge<=H_ACTIVE;
            transition_wait_frames<=7'd0;
        end else begin
            buf_s1<=disp_buf_idx; buf_s2<=buf_s1; buf_s2_d<=buf_s2;
            if (buffer_changed) image_change_pending<=1'b1;
            if (image_change_start) transition_req_pending<=1'b1;
            if (effect_next) effect_change_pending<=1'b1;
            if (frame_edge) begin
                case (transition_state)
                    TRANS_IDLE: begin
                        fading<=0; sliding<=0; fade<=8'd255;
                        slide_edge<=11'd0;
                        transition_wait_frames<=7'd0;
                        if (transition_req_pending || image_change_start) begin
                            transition_req_pending<=0;
                            transition_state<=TRANS_FADE_OUT;
                            fading<=1; fade<=8'd255-FADE_PER_FRAME;
                        end else if (image_change_pending || buffer_changed) begin
                            image_change_pending<=0;
                            transition_state<=TRANS_SLIDE_IN;
                            sliding<=1; fading<=1;
                            slide_edge<=H_ACTIVE; fade<=8'd0;
                        end else if (effect_change_pending || effect_next) begin
                            effect_mode<=effect_mode+2'd1;
                            effect_change_pending<=0;
                            transition_state<=TRANS_FADE_IN;
                            fading<=1; fade<=0;
                        end
                    end
                    TRANS_FADE_OUT: begin
                        fading<=1;
                        if (fade<=FADE_PER_FRAME) begin
                            fade<=0;
                            if (image_change_pending || buffer_changed) begin
                                image_change_pending<=0;
                                transition_state<=TRANS_SLIDE_IN;
                                sliding<=1; fading<=1;
                                slide_edge<=H_ACTIVE; fade<=8'd0;
                            end else begin
                                transition_state<=TRANS_WAIT_NEW;
                                transition_wait_frames<=7'd0;
                            end
                        end else fade<=fade-FADE_PER_FRAME;
                    end
                    TRANS_WAIT_NEW: begin
                        fading<=1; fade<=0;
                        if (image_change_pending || buffer_changed) begin
                            image_change_pending<=0;
                            transition_state<=TRANS_SLIDE_IN;
                            sliding<=1; fading<=1;
                            slide_edge<=H_ACTIVE; fade<=8'd0;
                            transition_wait_frames<=7'd0;
                        end else if (transition_wait_frames==7'd119) begin
                            // Recover to the current buffer if the requested
                            // image was not committed by the SD-card path.
                            transition_state<=TRANS_FADE_IN;
                            transition_wait_frames<=7'd0;
                        end else begin
                            transition_wait_frames<=transition_wait_frames+7'd1;
                        end
                    end
                    TRANS_SLIDE_IN: begin
                        fading<=1; sliding<=1;
                        if (slide_edge<=SLIDE_PER_FRAME) begin
                            slide_edge<=11'd0; fade<=8'd255;
                            sliding<=0; fading<=0;
                            transition_state<=TRANS_IDLE;
                        end else begin
                            slide_edge<=slide_edge-SLIDE_PER_FRAME;
                            if (fade>=(8'd255-FADE_PER_FRAME))
                                fade<=8'd255;
                            else
                                fade<=fade+FADE_PER_FRAME;
                        end
                    end
                    default: begin
                        sliding<=0; fading<=1;
                        if (fade>=(8'd255-FADE_PER_FRAME)) begin
                            fade<=8'd255; fading<=0; transition_state<=TRANS_IDLE;
                        end else fade<=fade+FADE_PER_FRAME;
                    end
                endcase
            end
        end
    end

    // Frame-aligned brightness. Spectrum sensitivity is fixed internally.
    reg [2:0] brightness_level;
    wire [2:0] wave_gain_level=3'd2;
    reg brightness_pending;
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            brightness_level   <= 3'd2;
            brightness_pending <= 1'b0;
        end else begin
            if (brightness_next) brightness_pending <= 1'b1;
            if (frame_edge) begin
                if (brightness_pending || brightness_next) begin
                    brightness_level   <= (brightness_level==3'd4) ? 3'd0 :
                                          brightness_level+3'd1;
                    brightness_pending <= 1'b0;
                end

            end
        end
    end

    // The former fixed-gain key input now requests panel alpha in the new top.
    reg [1:0] alpha_level;
    reg alpha_pending;
    always @(posedge video_clk or posedge rst)begin
      if(rst)begin alpha_level<=1;alpha_pending<=0;end
      else begin
        if(ALPHA_OVERLAY && wave_gain_next)alpha_pending<=1;
        if(frame_edge && (alpha_pending || (ALPHA_OVERLAY && wave_gain_next)))begin
          alpha_level<=alpha_level+1'b1;alpha_pending<=0;
        end
      end
    end
    // Frame-local PCM peak with fast attack and slow release. No history scroll.
    reg       wave_filled;
    reg [5:0] wave_frame_peak;
    reg [5:0] wave_envelope;
    wire [5:0] audio_level_now;
    wire [6:0] fft_column=(x>=64 && x<576)?((x-64)>>2):7'd0;
    wire [6:0] fft_height_q,fft_peak_q;
    mg_spectrum_bars u_fft_bars(.clk(video_clk),.rst(rst),.frame_edge(frame_edge),
        .audio_valid(audio_valid),.audio_sample(audio_sample),.gain(wave_gain_level),
        .read_addr(fft_column),.height_out(fft_height_q),.peak_out(fft_peak_q));
    wire [23:0] audio_magnitude_now = audio_sample[23] ? (~audio_sample + 24'd1) : audio_sample;
    wire [7:0] audio_abs_now = audio_magnitude_now[23:16];
    wire [7:0] audio_base_level = {1'b0,audio_abs_now[7:1]};
    reg [8:0] audio_scaled_level;
    always @(*) begin
        case (wave_gain_level)
            3'd0: audio_scaled_level = {1'b0,audio_base_level} >> 1;
            3'd1: audio_scaled_level = {1'b0,audio_base_level} -
                                       ({1'b0,audio_base_level} >> 2);
            3'd2: audio_scaled_level = {1'b0,audio_base_level};
            3'd3: audio_scaled_level = {1'b0,audio_base_level} +
                                       ({1'b0,audio_base_level} >> 2);
            default: audio_scaled_level = {1'b0,audio_base_level} +
                                          ({1'b0,audio_base_level} >> 1);
        endcase
    end
    assign audio_level_now = (audio_scaled_level > 9'd40) ?
                                  6'd40 : audio_scaled_level[5:0];
    wire [5:0] wave_peak_now = (audio_valid && audio_level_now > wave_frame_peak) ?
                               audio_level_now : wave_frame_peak;
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            wave_filled        <= 1'b0;
            wave_frame_peak <= 6'd0;
            wave_envelope <= 6'd0;
        end else if (frame_edge) begin
            // Commit once per frame: no moving history and no partial-frame updates.
            // Include a PCM sample coinciding with this frame boundary.
            wave_filled <= 1'b1;
            wave_frame_peak <= 6'd0;
            if (wave_peak_now >= wave_envelope)
                wave_envelope <= wave_peak_now;
            else if (wave_envelope != 0)
                wave_envelope <= wave_envelope - 6'd1;
        end else if (audio_valid) begin
            wave_frame_peak <= wave_peak_now;
        end
    end

    // Sparse frame measurement: 40 x 30 samples.  The shift gives a stable,
    // intentionally highlight-biased estimate without a divider.
    reg [19:0] sample_sum;
    wire [7:0] r_now = rgb_in[23:16];
    wire [7:0] g_now = rgb_in[15:8];
    wire [7:0] b_now = rgb_in[7:0];
    wire [9:0] luma_sum_now = {2'd0, r_now} +
                               ({2'd0, g_now} << 1) + {2'd0, b_now};
    wire [7:0] luma_now = luma_sum_now[9:2];
    wire       sample_pixel = de && (x[3:0] == 4'd0) &&
                               (y[3:0] == 4'd0);

    // Two-line, 2x-scaled OSD. The title is fixed; the second line follows
    // effect_mode and therefore changes at the same frame boundary as pixels.
    wire osd_line0 = de && (x >= 11'd24) && (x < 11'd200) &&
                           (y >= 11'd24) && (y < 11'd40);
    wire osd_line1 = de && (x >= 11'd24) && (x < 11'd280) &&
                           (y >= 11'd44) && (y < 11'd60);
    wire osd_line2 = de && (x >= 11'd24) && (x < 11'd280) &&
                           (y >= 11'd64) && (y < 11'd80);
    wire osd_zoom_line=ZOOM_OSD && de && x>=24 && x<168 && y>=84 && y<100;
    wire zoom_box=ZOOM_OSD && !UNIFIED_PANEL && de && x>=16 && x<184 && y>=80 && y<104;
    wire osd_box   = de && (x >= 11'd16) && (x < 11'd288) &&
                           (y >= 11'd16) && (y < (UNIFIED_PANEL ? (RESOLUTION_OSD ? 11'd128 : 11'd104) : 11'd88));
    localparam integer H_DIGITS=H_ACTIVE>=1000?4:H_ACTIVE>=100?3:H_ACTIVE>=10?2:1;
    localparam integer V_DIGITS=V_ACTIVE>=1000?4:V_ACTIVE>=100?3:V_ACTIVE>=10?2:1;
    wire osd_resolution_line=RESOLUTION_OSD && de && x>=24 &&
        x<24+16*(5+H_DIGITS+V_DIGITS) && y>=104 && y<120;
    // All division is of constant display parameters; this is a character ROM.
    function [7:0] display_digit;
      input integer value,digits,index;
      begin case(digits-index)
        4:display_digit=8'd48+(value/1000)%10;
        3:display_digit=8'd48+(value/100)%10;
        2:display_digit=8'd48+(value/10)%10;
        1:display_digit=8'd48+value%10;
        default:display_digit=" ";
      endcase end
    endfunction
    // Fixed 11-character subtitle, 16x16 SimSun glyphs stored in logic ROM.
    // Text: 数芯天下的文博展览系统. No SD or UART writes can alter it.
    function [15:0] fixed_subtitle_row;
    input [3:0] character_index,row;
    begin case({character_index,row})
 8'h00: fixed_subtitle_row=16'h0820;
 8'h01: fixed_subtitle_row=16'h4920;
 8'h02: fixed_subtitle_row=16'h2a20;
 8'h03: fixed_subtitle_row=16'h083e;
 8'h04: fixed_subtitle_row=16'hff44;
 8'h05: fixed_subtitle_row=16'h2a44;
 8'h06: fixed_subtitle_row=16'h4944;
 8'h07: fixed_subtitle_row=16'h88a4;
 8'h08: fixed_subtitle_row=16'h1028;
 8'h09: fixed_subtitle_row=16'hfe28;
 8'h0a: fixed_subtitle_row=16'h2210;
 8'h0b: fixed_subtitle_row=16'h4210;
 8'h0c: fixed_subtitle_row=16'h6428;
 8'h0d: fixed_subtitle_row=16'h1828;
 8'h0e: fixed_subtitle_row=16'h3444;
 8'h0f: fixed_subtitle_row=16'hc282;
 8'h10: fixed_subtitle_row=16'h0820;
 8'h11: fixed_subtitle_row=16'h0820;
 8'h12: fixed_subtitle_row=16'hfffe;
 8'h13: fixed_subtitle_row=16'h0820;
 8'h14: fixed_subtitle_row=16'h0820;
 8'h15: fixed_subtitle_row=16'h0200;
 8'h16: fixed_subtitle_row=16'h0100;
 8'h17: fixed_subtitle_row=16'h0080;
 8'h18: fixed_subtitle_row=16'h0408;
 8'h19: fixed_subtitle_row=16'h2404;
 8'h1a: fixed_subtitle_row=16'h2402;
 8'h1b: fixed_subtitle_row=16'h4402;
 8'h1c: fixed_subtitle_row=16'h8410;
 8'h1d: fixed_subtitle_row=16'h0410;
 8'h1e: fixed_subtitle_row=16'h03f0;
 8'h1f: fixed_subtitle_row=16'h0000;
 8'h20: fixed_subtitle_row=16'h3ff8;
 8'h21: fixed_subtitle_row=16'h0100;
 8'h22: fixed_subtitle_row=16'h0100;
 8'h23: fixed_subtitle_row=16'h0100;
 8'h24: fixed_subtitle_row=16'h0100;
 8'h25: fixed_subtitle_row=16'hfffe;
 8'h26: fixed_subtitle_row=16'h0100;
 8'h27: fixed_subtitle_row=16'h0280;
 8'h28: fixed_subtitle_row=16'h0280;
 8'h29: fixed_subtitle_row=16'h0440;
 8'h2a: fixed_subtitle_row=16'h0440;
 8'h2b: fixed_subtitle_row=16'h0820;
 8'h2c: fixed_subtitle_row=16'h1010;
 8'h2d: fixed_subtitle_row=16'h2008;
 8'h2e: fixed_subtitle_row=16'hc006;
 8'h2f: fixed_subtitle_row=16'h0000;
 8'h30: fixed_subtitle_row=16'hfffe;
 8'h31: fixed_subtitle_row=16'h0200;
 8'h32: fixed_subtitle_row=16'h0200;
 8'h33: fixed_subtitle_row=16'h0200;
 8'h34: fixed_subtitle_row=16'h0200;
 8'h35: fixed_subtitle_row=16'h0240;
 8'h36: fixed_subtitle_row=16'h0220;
 8'h37: fixed_subtitle_row=16'h0210;
 8'h38: fixed_subtitle_row=16'h0208;
 8'h39: fixed_subtitle_row=16'h0208;
 8'h3a: fixed_subtitle_row=16'h0200;
 8'h3b: fixed_subtitle_row=16'h0200;
 8'h3c: fixed_subtitle_row=16'h0200;
 8'h3d: fixed_subtitle_row=16'h0200;
 8'h3e: fixed_subtitle_row=16'h0200;
 8'h3f: fixed_subtitle_row=16'h0000;
 8'h40: fixed_subtitle_row=16'h1040;
 8'h41: fixed_subtitle_row=16'h1040;
 8'h42: fixed_subtitle_row=16'h2040;
 8'h43: fixed_subtitle_row=16'h7e7c;
 8'h44: fixed_subtitle_row=16'h4284;
 8'h45: fixed_subtitle_row=16'h4284;
 8'h46: fixed_subtitle_row=16'h4304;
 8'h47: fixed_subtitle_row=16'h4244;
 8'h48: fixed_subtitle_row=16'h7e24;
 8'h49: fixed_subtitle_row=16'h4224;
 8'h4a: fixed_subtitle_row=16'h4204;
 8'h4b: fixed_subtitle_row=16'h4204;
 8'h4c: fixed_subtitle_row=16'h4204;
 8'h4d: fixed_subtitle_row=16'h7e04;
 8'h4e: fixed_subtitle_row=16'h4228;
 8'h4f: fixed_subtitle_row=16'h0010;
 8'h50: fixed_subtitle_row=16'h0200;
 8'h51: fixed_subtitle_row=16'h0100;
 8'h52: fixed_subtitle_row=16'h0100;
 8'h53: fixed_subtitle_row=16'hfffe;
 8'h54: fixed_subtitle_row=16'h1010;
 8'h55: fixed_subtitle_row=16'h1010;
 8'h56: fixed_subtitle_row=16'h0820;
 8'h57: fixed_subtitle_row=16'h0820;
 8'h58: fixed_subtitle_row=16'h0440;
 8'h59: fixed_subtitle_row=16'h0280;
 8'h5a: fixed_subtitle_row=16'h0100;
 8'h5b: fixed_subtitle_row=16'h0280;
 8'h5c: fixed_subtitle_row=16'h0440;
 8'h5d: fixed_subtitle_row=16'h0820;
 8'h5e: fixed_subtitle_row=16'h3018;
 8'h5f: fixed_subtitle_row=16'hc006;
 8'h60: fixed_subtitle_row=16'h2050;
 8'h61: fixed_subtitle_row=16'h2048;
 8'h62: fixed_subtitle_row=16'h2ffe;
 8'h63: fixed_subtitle_row=16'h2040;
 8'h64: fixed_subtitle_row=16'h27fc;
 8'h65: fixed_subtitle_row=16'hfc44;
 8'h66: fixed_subtitle_row=16'h27fc;
 8'h67: fixed_subtitle_row=16'h2444;
 8'h68: fixed_subtitle_row=16'h27fc;
 8'h69: fixed_subtitle_row=16'h2444;
 8'h6a: fixed_subtitle_row=16'h2008;
 8'h6b: fixed_subtitle_row=16'h2ffe;
 8'h6c: fixed_subtitle_row=16'h2208;
 8'h6d: fixed_subtitle_row=16'h2108;
 8'h6e: fixed_subtitle_row=16'h2128;
 8'h6f: fixed_subtitle_row=16'h2010;
 8'h70: fixed_subtitle_row=16'h3ffc;
 8'h71: fixed_subtitle_row=16'h2004;
 8'h72: fixed_subtitle_row=16'h2004;
 8'h73: fixed_subtitle_row=16'h3ffc;
 8'h74: fixed_subtitle_row=16'h2220;
 8'h75: fixed_subtitle_row=16'h2220;
 8'h76: fixed_subtitle_row=16'h2ff8;
 8'h77: fixed_subtitle_row=16'h2220;
 8'h78: fixed_subtitle_row=16'h2220;
 8'h79: fixed_subtitle_row=16'h3ffe;
 8'h7a: fixed_subtitle_row=16'h2488;
 8'h7b: fixed_subtitle_row=16'h2450;
 8'h7c: fixed_subtitle_row=16'h4530;
 8'h7d: fixed_subtitle_row=16'h460e;
 8'h7e: fixed_subtitle_row=16'h8400;
 8'h7f: fixed_subtitle_row=16'h0000;
 8'h80: fixed_subtitle_row=16'h0440;
 8'h81: fixed_subtitle_row=16'h2440;
 8'h82: fixed_subtitle_row=16'h247c;
 8'h83: fixed_subtitle_row=16'h2490;
 8'h84: fixed_subtitle_row=16'h2508;
 8'h85: fixed_subtitle_row=16'h0400;
 8'h86: fixed_subtitle_row=16'h1ff0;
 8'h87: fixed_subtitle_row=16'h1010;
 8'h88: fixed_subtitle_row=16'h1110;
 8'h89: fixed_subtitle_row=16'h1110;
 8'h8a: fixed_subtitle_row=16'h1110;
 8'h8b: fixed_subtitle_row=16'h1290;
 8'h8c: fixed_subtitle_row=16'h0280;
 8'h8d: fixed_subtitle_row=16'h0484;
 8'h8e: fixed_subtitle_row=16'h1884;
 8'h8f: fixed_subtitle_row=16'h607c;
 8'h90: fixed_subtitle_row=16'h00f8;
 8'h91: fixed_subtitle_row=16'h3f00;
 8'h92: fixed_subtitle_row=16'h0400;
 8'h93: fixed_subtitle_row=16'h0820;
 8'h94: fixed_subtitle_row=16'h1040;
 8'h95: fixed_subtitle_row=16'h3f80;
 8'h96: fixed_subtitle_row=16'h0100;
 8'h97: fixed_subtitle_row=16'h0610;
 8'h98: fixed_subtitle_row=16'h1808;
 8'h99: fixed_subtitle_row=16'h7ffc;
 8'h9a: fixed_subtitle_row=16'h0104;
 8'h9b: fixed_subtitle_row=16'h0920;
 8'h9c: fixed_subtitle_row=16'h1110;
 8'h9d: fixed_subtitle_row=16'h2108;
 8'h9e: fixed_subtitle_row=16'h4504;
 8'h9f: fixed_subtitle_row=16'h0200;
 8'ha0: fixed_subtitle_row=16'h1040;
 8'ha1: fixed_subtitle_row=16'h1020;
 8'ha2: fixed_subtitle_row=16'h2020;
 8'ha3: fixed_subtitle_row=16'h23fe;
 8'ha4: fixed_subtitle_row=16'h4840;
 8'ha5: fixed_subtitle_row=16'hf888;
 8'ha6: fixed_subtitle_row=16'h1104;
 8'ha7: fixed_subtitle_row=16'h23fe;
 8'ha8: fixed_subtitle_row=16'h4092;
 8'ha9: fixed_subtitle_row=16'hf890;
 8'haa: fixed_subtitle_row=16'h4090;
 8'hab: fixed_subtitle_row=16'h0090;
 8'hac: fixed_subtitle_row=16'h1912;
 8'had: fixed_subtitle_row=16'he112;
 8'hae: fixed_subtitle_row=16'h420e;
 8'haf: fixed_subtitle_row=16'h0400;
    default:fixed_subtitle_row=16'd0;
    endcase end endfunction

    // Content is fixed in ROM; only its horizontal position moves.
    // Advance at a video frame boundary to avoid tearing within a frame.
    localparam integer SUBTITLE_PERIOD=H_ACTIVE+176;
    reg [11:0] subtitle_scroll;
    always @(posedge video_clk or posedge rst) begin
      if(rst) subtitle_scroll<=(H_ACTIVE+176)/2;
      else if(frame_edge) begin
        if(subtitle_scroll>=SUBTITLE_PERIOD-2) subtitle_scroll<=0;
        else subtitle_scroll<=subtitle_scroll+12'd2;
      end
    end
    wire subtitle_box=de && (y>=11'd444) && (y<11'd476);
    wire [11:0] subtitle_position={1'b0,x}+subtitle_scroll;
    wire subtitle_line=de && (x<H_ACTIVE) && (y>=11'd452) && (y<11'd468) &&
                       (subtitle_position>=H_ACTIVE) && (subtitle_position<SUBTITLE_PERIOD);
    wire [11:0] fixed_subtitle_x=subtitle_position-H_ACTIVE;
    wire [15:0] fixed_subtitle_pixels=fixed_subtitle_row(fixed_subtitle_x[7:4],y-11'd452);
    reg subtitle_pixel_p1;
    wire subtitle_text_p1=subtitle_pixel_p1;
    wire [4:0] osd_col = (x-11'd24)>>4;
    wire [2:0] osd_font_x = (x-11'd24)>>1;
    wire [2:0] text_font_x = osd_font_x;
    wire [2:0] text_font_y = (osd_resolution_line ? ((y-11'd104)>>1) : osd_zoom_line ? ((y-11'd84)>>1) : osd_line0 ? ((y-11'd24)>>1) :
                              osd_line1 ? ((y-11'd44)>>1) : ((y-11'd64)>>1));

    reg [7:0] osd_char;
    always @* begin
      osd_char=" ";
      if(osd_resolution_line) begin
        case(osd_col)
          0:osd_char=8'd149;
          1:osd_char=8'd150;
          2:osd_char=8'd151;
          3:osd_char=":";
          default:begin
            if(osd_col<4+H_DIGITS)osd_char=display_digit(H_ACTIVE,H_DIGITS,osd_col-4);
            else if(osd_col==4+H_DIGITS)osd_char=8'd152;
            else if(osd_col<5+H_DIGITS+V_DIGITS)osd_char=display_digit(V_ACTIVE,V_DIGITS,osd_col-5-H_DIGITS);
          end
        endcase
      end else if(osd_zoom_line) begin
        case(osd_col)
              0:osd_char=8'd147;
              1:osd_char=8'd148;
              2:osd_char=":";
          3:osd_char=zoom_level==2?"1":" ";
          4:osd_char=zoom_level==0?"5":zoom_level==1?"7":"0";
          5:osd_char=zoom_level==1?"5":"0";
          6:osd_char="%";
          default:osd_char=" ";
        endcase
      end else if(osd_line0) begin
        case(osd_col)
              0:osd_char=8'd128;
              1:osd_char=8'd129;
              2:osd_char=8'd130;
              3:osd_char=8'd131;
          default:osd_char=" ";
        endcase
      end else if(osd_line1) begin
        case(osd_col)
              0:osd_char=8'd132;
              1:osd_char=8'd133;
              2:osd_char=":";
          3:case(effect_mode)
            0:osd_char=8'd134;
            1:osd_char=8'd136;
            2:osd_char=8'd138;
            3:osd_char=8'd140;
          endcase
          4:case(effect_mode)
            0:osd_char=8'd135;
            1:osd_char=8'd137;
            2:osd_char=8'd139;
            3:osd_char=8'd141;
          endcase
          default:osd_char=" ";
        endcase
      end else if(osd_line2) begin
        case(osd_col)
              0:osd_char=8'd142;
              1:osd_char=8'd143;
              2:osd_char=":";
          3:osd_char=brightness_level<2?"-":"+";
          4:case(brightness_level)0,4:osd_char="4";1,3:osd_char="2";default:osd_char="0";endcase
          5:case(brightness_level)0,4:osd_char="8";1,3:osd_char="4";default:osd_char="0";endcase
          7:osd_char=ALPHA_OVERLAY?8'd144:" ";
          8:osd_char=ALPHA_OVERLAY?8'd145:" ";
          9:osd_char=ALPHA_OVERLAY?8'd146:" ";
          10:osd_char=ALPHA_OVERLAY?8'd143:" ";
          11:osd_char=ALPHA_OVERLAY?":":" ";
          12:osd_char=ALPHA_OVERLAY && alpha_level==3?"1":" ";
          13:if(ALPHA_OVERLAY)case(alpha_level)0:osd_char="2";1:osd_char="5";2:osd_char="7";default:osd_char="0";endcase
          14:osd_char=ALPHA_OVERLAY?((alpha_level==0 || alpha_level==2)?"5":"0"):" ";
          15:osd_char=ALPHA_OVERLAY?"%":" ";
          default:osd_char=" ";
        endcase
      end
    end

    wire [63:0] osd_glyph = glyph64(osd_char);
    wire [5:0] osd_row_shift = {(3'd7-text_font_y),3'b000};
    wire [7:0] osd_glyph_row = osd_glyph >> osd_row_shift;
    wire [3:0] chinese_font_x = x-11'd24;
    wire [3:0] chinese_font_y = osd_resolution_line ? y-11'd104 : osd_zoom_line ? y-11'd84 : osd_line0 ? y-11'd24 : osd_line1 ? y-11'd44 : y-11'd64;
    wire [15:0] chinese_pixels = chinese_row(osd_char,chinese_font_y);
    wire glyph_pixel = osd_char[7] ? chinese_pixels[4'd15-chinese_font_x] : osd_glyph_row[3'd7-text_font_x];
    wire osd_text = (osd_line0 || osd_line1 || osd_line2 || osd_zoom_line || osd_resolution_line) && glyph_pixel;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            sample_sum<=20'd0; scene_luma<=8'd128;
        end else if (frame_edge) begin
            if (sample_sum > 20'd261120)
                scene_luma <= 8'd255;
            else
                scene_luma <= sample_sum[17:10];
            sample_sum <= 20'd0;
        end else if (sample_pixel) begin
            sample_sum <= sample_sum + {12'd0, luma_now};
        end
    end

    // One previous-line buffer produces a two-axis edge measure.
    reg [7:0] line_luma [0:H_ACTIVE-1];
    reg [7:0] left_luma;
    reg [8:0] edge_sum_p1;
    reg [7:0] luma_p1;
    reg [23:0] rgb_p1;
    reg        hs_p1;
    reg        vs_p1;
    reg        de_p1;
    reg [10:0] x_p1;
    reg [10:0] y_p1;
    reg        mode_bar_p1;
    reg        meter_bg_p1;
    reg        meter_fill_p1;
    reg        osd_box_p1;
    reg        osd_text_p1;
    reg        osd_marker_p1;
    reg        subtitle_box_p1;
    reg        wave_area_p1;
    reg        wave_grid_p1;
    reg        wave_zero_p1;
    reg        wave_frame_p1;
    reg [10:0] wave_y_p1;
    wire [6:0] wave_level_p1=fft_height_q;
    // Existing HDMI raster, adapted 128-bin strip (three pixels + one gap).
    wire [6:0] wave_peak_p1=fft_peak_q;
    wire [6:0] wave_magnitude=wave_level_p1;
    wire [10:0] wave_trace_y=11'd424-{4'd0,wave_magnitude};
    wire wave_trace_p1=wave_area_p1 && wave_filled && (x_p1[1:0]<3) &&
                       wave_magnitude!=0 && wave_y_p1>=wave_trace_y && wave_y_p1<424;
    wire wave_glow_p1=wave_area_p1 && wave_filled && (x_p1[1:0]==3) &&
                      wave_magnitude!=0 && wave_y_p1>=wave_trace_y && wave_y_p1<424;
    wire wave_cap_p1=wave_trace_p1 && wave_y_p1==wave_trace_y;
    wire wave_peak_marker_p1=wave_area_p1 && wave_filled && (x_p1[1:0]<3) &&
                             wave_peak_p1!=0 && wave_y_p1==424-wave_peak_p1;
    function [23:0] fft_gradient;
    input [10:0] row;
    integer h;
    reg [7:0] rr,gg,bb;
    begin
     h=(row<424)?424-row:0;
     if(h<20) begin rr=16;gg=64+h*9;bb=255;end
     else if(h<40) begin rr=16;gg=255;bb=255-(h-20)*12;end
     else if(h<60) begin rr=32+(h-40)*11;gg=255;bb=16;end
     else begin rr=255;gg=(h<81)?255-(h-60)*10:55;bb=16;end
     fft_gradient={rr,gg,bb};
    end endfunction
    wire [9:0] line_addr = (x < H_ACTIVE) ? x[9:0] : 10'd0;
    wire [7:0] edge_h_now = (x == 0) ? 8'd0 : abs_diff8(luma_now, left_luma);
    wire [7:0] edge_v_now = (y == 0) ? 8'd0 : abs_diff8(luma_now, line_luma[line_addr]);

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            left_luma     <= 8'd0;
            edge_sum_p1   <= 9'd0;
            luma_p1       <= 8'd0;
            rgb_p1        <= 24'd0;
            hs_p1         <= 1'b0;
            vs_p1         <= 1'b0;
            de_p1         <= 1'b0;
            x_p1          <= 11'd0;
            y_p1          <= 11'd0;
            mode_bar_p1   <= 1'b0;
            meter_bg_p1   <= 1'b0;
            meter_fill_p1 <= 1'b0;
            osd_box_p1    <= 1'b0;
            osd_text_p1   <= 1'b0;
            osd_marker_p1 <= 1'b0;
            subtitle_box_p1 <= 1'b0;
            uart_subtitle_ack <= 1'b0;
            subtitle_pixel_p1 <= 1'b0;
            wave_area_p1 <= 1'b0;
            wave_grid_p1 <= 1'b0;
            wave_zero_p1 <= 1'b0;
            wave_frame_p1 <= 1'b0;
            wave_y_p1 <= 11'd0;
        end else begin
            hs_p1   <= hs;
            vs_p1   <= vs;
            de_p1   <= de;
            x_p1    <= x;
            y_p1    <= y;
            rgb_p1  <= de ? rgb_in : 24'd0;
            luma_p1 <= luma_now;
            mode_bar_p1 <= overlay_enabled && de && (y < 11'd10) && (x < 11'd72);
            meter_bg_p1 <= overlay_enabled && de && (y < 11'd10) &&
                           (x >= 11'd80) && (x < 11'd336);
            meter_fill_p1 <= overlay_enabled && de && (y < 11'd10) &&
                             (x >= 11'd80) &&
                             (x < ({3'd0, scene_luma} + 11'd80));
            osd_box_p1 <= (overlay_enabled && osd_box) || zoom_box;
            osd_text_p1 <= (overlay_enabled || (!UNIFIED_PANEL && osd_zoom_line)) && osd_text;
            // Legacy input ports are retained for testbench compatibility only.
            // All mutable subtitle sources are deliberately ignored.
            subtitle_box_p1 <= subtitle_box;
            subtitle_pixel_p1 <= subtitle_line && fixed_subtitle_pixels[15-fixed_subtitle_x[3:0]];
            wave_area_p1 <= overlay_enabled && de && (x>=11'd64) && (x<11'd576) &&
                                  (y>=11'd340) && (y<11'd428);
            wave_grid_p1 <= overlay_enabled && de && (x>=11'd64) && (x<11'd576) &&
                                  (y>=11'd340) && (y<11'd428) &&
                                  ((y==11'd352) || (y==11'd384) || (y==11'd416));
            wave_zero_p1 <= overlay_enabled && de && (x>=11'd64) &&
                            (x<11'd576) && (y==11'd424);
            wave_frame_p1 <= overlay_enabled && de &&
                             (x>=11'd63) && (x<=11'd576) &&
                             (y>=11'd339) && (y<=11'd428) &&
                             ((x==11'd63) || (x==11'd576) ||
                              (y==11'd339) || (y==11'd428));
            wave_y_p1 <= y;

            osd_marker_p1 <= overlay_enabled && de && (x >= 11'd256) && (x < 11'd272) &&
                                      (y >= 11'd24) && (y < 11'd40);
            if (de) begin
                line_luma[line_addr] <= luma_now;
                left_luma    <= luma_now;
                edge_sum_p1  <= {1'b0, edge_h_now} + {1'b0, edge_v_now};
            end else begin
                left_luma   <= 8'd0;
                edge_sum_p1 <= 9'd0;
            end
        end
    end

    // Gentle endpoint-preserving tone curve. Lift dark scenes without lifting
    // absolute black; taper the adjustment near white to preserve highlights.
    function [7:0] natural_channel;
        input [7:0] value;
        input [7:0] luma;
        input [7:0] scene;
        reg signed [10:0] v, delta, chroma, limit, curve, exposure, headroom;
        begin
            v = $signed({3'd0,value});
            headroom = (value < 8'd128) ? v : (11'sd255-v);
            if (value < 8'd64) curve = -(v >>> 4);
            else if (value < 8'd128) curve = -((11'sd127-v) >>> 4);
            else if (value < 8'd192) curve = (v-11'sd128) >>> 4;
            else curve = (11'sd255-v) >>> 4;
            if (scene < 8'd64) exposure = headroom >>> 2;
            else if (scene < 8'd96) exposure = headroom >>> 3;
            else if (scene > 8'd184) exposure = -(headroom >>> 4);
            else exposure = 11'sd0;
            // Symmetric rounding keeps neutral grays neutral. Limit vibrance
            // near channel endpoints instead of clipping saturated colors.
            delta = v-$signed({3'd0,luma});
            chroma = (delta < 0) ? -((-delta) >>> 4) : (delta >>> 4);
            limit = headroom >>> 4;
            if (chroma > limit) chroma = limit;
            else if (chroma < -limit) chroma = -limit;
            if (scene < 8'd96 || scene > 8'd184) curve = 11'sd0;
            natural_channel = clamp_s11(v+curve+exposure+chroma);
        end
    endfunction
    wire [23:0] enhanced_rgb = {
        natural_channel(rgb_p1[23:16],luma_p1,scene_luma),
        natural_channel(rgb_p1[15:8],luma_p1,scene_luma),
        natural_channel(rgb_p1[7:0],luma_p1,scene_luma)};
    wire [7:0] poster_r = poster_level(rgb_p1[23:16]);
    wire [7:0] poster_g = poster_level(rgb_p1[15:8]);
    wire [7:0] poster_b = poster_level(rgb_p1[7:0]);
    wire [8:0] poster_r_warm = {1'b0, poster_r} + 9'd16;
    wire [7:0] poster_r_out = poster_r_warm[8] ? 8'hff : poster_r_warm[7:0];
    wire [7:0] poster_b_out = (poster_b < 8'd12) ? 8'd0 : (poster_b - 8'd12);
    wire [23:0] poster_rgb = {poster_r_out, poster_g, poster_b_out};

    // True foreground/background blend: round((bg*(4-a)+fg*a)/4).
    // One signed-difference multiply per channel, a=1,2,3,4.
    function [7:0] alpha_channel;
      input [7:0] bg,fg;input [2:0] a;
      reg signed [8:0] delta;
      reg signed [12:0] product,total;
      begin
        delta=$signed({1'b0,fg})-$signed({1'b0,bg});
        product=delta*$signed({1'b0,a});
        total=$signed({3'b0,bg,2'b0})+product+13'sd2;
        alpha_channel=total[9:2];
      end
    endfunction
    reg [23:0] scene_rgb_p1;
    always @*begin
      case(effect_mode)
        0:scene_rgb_p1=rgb_p1;
        1:scene_rgb_p1=enhanced_rgb;
        2:begin
          if(edge_sum_p1>96)scene_rgb_p1=24'h35e7ff;
          else if(edge_sum_p1>44)scene_rgb_p1={luma_p1,luma_p1,8'hff};
          else scene_rgb_p1={3{(luma_p1>>1)}};
        end
        default:scene_rgb_p1=poster_rgb;
      endcase
    end
    wire [23:0] panel_foreground=wave_area_p1?24'h102030:24'h101820;
    wire [2:0] alpha_weight={1'b0,alpha_level}+3'd1;
    wire [23:0] panel_rgb={
      alpha_channel(scene_rgb_p1[23:16],panel_foreground[23:16],alpha_weight),
      alpha_channel(scene_rgb_p1[15:8],panel_foreground[15:8],alpha_weight),
      alpha_channel(scene_rgb_p1[7:0],panel_foreground[7:0],alpha_weight)};
    reg [23:0] processed_p2;
    reg        hs_p2;
    reg        vs_p2;
    reg        de_p2;
    reg [10:0] x_p2;
    reg [10:0] y_p2;
    reg        overlay_p2;
    // Frame-atomic status stays entirely in the video clock domain.
    reg gesture_online_frame;
    reg [23:0] diagnostic_frame;
    always @(posedge video_clk or posedge rst)
      if(rst)diagnostic_frame<=0;
      else if(frame_edge)diagnostic_frame<=gesture_diagnostic;
    // Six hexadecimal digits: error code, last identity, failed register.
    // Independent pipeline flag avoids disturbing the existing OSD layout.
    reg diagnostic_area_p1,diagnostic_text_p1;
    reg [3:0] diagnostic_nibble;
    reg [63:0] diagnostic_glyph;
    wire [3:0] diagnostic_y=y-11'd24;
    always @*begin
      case(x[5:3])
        0:diagnostic_nibble=diagnostic_frame[23:20];
        1:diagnostic_nibble=diagnostic_frame[19:16];
        3:diagnostic_nibble=diagnostic_frame[15:12];
        4:diagnostic_nibble=diagnostic_frame[11:8];
        6:diagnostic_nibble=diagnostic_frame[7:4];
        default:diagnostic_nibble=diagnostic_frame[3:0];
      endcase
      diagnostic_glyph=glyph64(diagnostic_nibble<10 ? 8'd48+diagnostic_nibble : 8'd55+diagnostic_nibble);
    end
    always @(posedge video_clk or posedge rst)
      if(rst)begin diagnostic_area_p1<=0;diagnostic_text_p1<=0;end
      else begin
        diagnostic_area_p1<=GESTURE_STATUS && GESTURE_DIAGNOSTICS && overlay_enabled && de && x>=320 && x<384 && y>=24 && y<40;
        diagnostic_text_p1<=diagnostic_glyph[63-{diagnostic_y[3:1],x[2:0]}] && x[5:3]!=2 && x[5:3]!=5;
      end
    always @(posedge video_clk or posedge rst)
      if(rst)gesture_online_frame<=0;
      else if(frame_edge)gesture_online_frame<=gesture_online;
    reg [23:0] mode_color;

    always @(*) begin
        case (effect_mode)
            2'd0: mode_color = 24'hf4f4f4;
            2'd1: mode_color = 24'h36d66b;
            2'd2: mode_color = 24'h21d4fd;
            default: mode_color = 24'hff9f43;
        endcase
    end

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            processed_p2 <= 24'd0;
            hs_p2         <= 1'b0;
            vs_p2         <= 1'b0;
            de_p2         <= 1'b0;
            x_p2          <= 11'd0;
            y_p2          <= 11'd0;
            overlay_p2    <= 1'b0;
        end else begin
            hs_p2 <= hs_p1;
            vs_p2 <= vs_p1;
            de_p2 <= de_p1;
            x_p2  <= x_p1;
            y_p2  <= y_p1;
            // Keep status graphics visible while the picture fades. This
            // makes a slow SD-card load visibly different from a reset.
            overlay_p2 <= mode_bar_p1 || meter_bg_p1 || meter_fill_p1 ||
                          osd_text_p1 || osd_marker_p1 || diagnostic_area_p1 || subtitle_text_p1 ||
                          wave_trace_p1 || wave_glow_p1 || wave_peak_marker_p1 || wave_grid_p1 ||
                          wave_zero_p1 || wave_frame_p1;
            if (!de_p1)
                processed_p2 <= 24'd0;
            else if (diagnostic_area_p1)
                processed_p2 <= diagnostic_text_p1 ? 24'hffffff : 24'h101820;
            else if (mode_bar_p1)
                processed_p2 <= mode_color;
            else if (meter_fill_p1)
                processed_p2 <= (scene_luma < 8'd96) ? 24'hffd43b :
                                (scene_luma > 8'd184) ? 24'hff6b6b : 24'h51cf66;
            else if (meter_bg_p1)
                processed_p2 <= 24'h202830;
            else if (osd_text_p1)
                processed_p2 <= 24'hffffff;
            else if (subtitle_text_p1)
                processed_p2 <= 24'hffe66d;
            else if (osd_marker_p1)
                processed_p2 <= GESTURE_STATUS ? (gesture_online_frame?24'h36d66b:24'hff5e57) : mode_color;
            else if (wave_peak_marker_p1)
                processed_p2 <= 24'he0ffff;
            else if (wave_cap_p1)
                processed_p2 <= 24'hb8ffff;
            else if (wave_trace_p1)
                processed_p2 <= fft_gradient(wave_y_p1);
            else if (wave_glow_p1)
                processed_p2 <= 24'h163c4c;
            else if (wave_zero_p1)
                processed_p2 <= 24'h729aaa;
            else if (wave_frame_p1)
                processed_p2 <= 24'h5a8290;
            else if (wave_grid_p1)
                processed_p2 <= 24'h354e59;
            else if (wave_area_p1) begin
                if(ALPHA_OVERLAY)processed_p2<=panel_rgb;
                else                 case (effect_mode)
                    2'd0: processed_p2 <= {2'b00, rgb_p1[23:18],
                                           2'b00, rgb_p1[15:10],
                                           2'b00, rgb_p1[7:2]};
                    2'd1: processed_p2 <= {2'b00, enhanced_rgb[23:18],
                                           2'b00, enhanced_rgb[15:10],
                                           2'b00, enhanced_rgb[7:2]};
                    2'd2: processed_p2 <= 24'h101820;
                    default: processed_p2 <= {2'b00, poster_rgb[23:18],
                                              2'b00, poster_rgb[15:10],
                                              2'b00, poster_rgb[7:2]};
                endcase
            end
            else if (subtitle_box_p1) begin
                if(ALPHA_OVERLAY)processed_p2<=panel_rgb;
                else                 case (effect_mode)
                    2'd0: processed_p2 <= {2'b00, rgb_p1[23:18],
                                           2'b00, rgb_p1[15:10],
                                           2'b00, rgb_p1[7:2]};
                    2'd1: processed_p2 <= {2'b00, enhanced_rgb[23:18],
                                           2'b00, enhanced_rgb[15:10],
                                           2'b00, enhanced_rgb[7:2]};
                    2'd2: processed_p2 <= 24'h101820;
                    default: processed_p2 <= {2'b00, poster_rgb[23:18],
                                              2'b00, poster_rgb[15:10],
                                              2'b00, poster_rgb[7:2]};
                endcase
            end
            else if (osd_box_p1) begin
                if(ALPHA_OVERLAY)processed_p2<=panel_rgb;
                else                 case (effect_mode)
                    2'd0: processed_p2 <= {2'b00, rgb_p1[23:18],
                                           2'b00, rgb_p1[15:10],
                                           2'b00, rgb_p1[7:2]};
                    2'd1: processed_p2 <= {2'b00, enhanced_rgb[23:18],
                                           2'b00, enhanced_rgb[15:10],
                                           2'b00, enhanced_rgb[7:2]};
                    2'd2: processed_p2 <= 24'h101820;
                    default: processed_p2 <= {2'b00, poster_rgb[23:18],
                                              2'b00, poster_rgb[15:10],
                                              2'b00, poster_rgb[7:2]};
                endcase
            end
            else begin
                case (effect_mode)
                    2'd0: processed_p2 <= rgb_p1;
                    2'd1: processed_p2 <= enhanced_rgb;
                    2'd2: begin
                        if (edge_sum_p1 > 9'd96)
                            processed_p2 <= 24'h35e7ff;
                        else if (edge_sum_p1 > 9'd44)
                            processed_p2 <= {luma_p1, luma_p1, 8'hff};
                        else
                            processed_p2 <= {3{(luma_p1 >> 1)}};
                    end
                    default: processed_p2 <= poster_rgb;
                endcase
            end
        end
    end

    function [7:0] adjust_channel;
        input [7:0] value;
        input [2:0] bri;
        reg signed [10:0] bias;
        reg signed [10:0] result;
        begin
            case (bri)
                3'd0: bias=-11'sd48;
                3'd1: bias=-11'sd24;
                3'd2: bias=11'sd0;
                3'd3: bias=11'sd24;
                default: bias=11'sd48;
            endcase
            result=$signed({1'b0,value})+bias;
            if (result<0) adjust_channel=8'd0;
            else if (result>11'sd255) adjust_channel=8'd255;
            else adjust_channel=result[7:0];
        end
    endfunction

    wire [23:0] adjusted_rgb = {
        adjust_channel(processed_p2[23:16],brightness_level),
        adjust_channel(processed_p2[15:8], brightness_level),
        adjust_channel(processed_p2[7:0],  brightness_level)};

    // Frame-stepped fade and right-to-left reveal prevent abrupt changes.
    wire [15:0] fade_r = adjusted_rgb[23:16] * fade;
    wire [15:0] fade_g = adjusted_rgb[15:8]  * fade;
    wire [15:0] fade_b = adjusted_rgb[7:0]   * fade;
    wire [23:0] faded_rgb = {fade_r[15:8], fade_g[15:8], fade_b[15:8]};
    wire [23:0] visible_rgb = (fading && !overlay_p2) ? faded_rgb : adjusted_rgb;
    wire focus_inside = (x_p2 >= focus_x0) && (x_p2 <= focus_x1) &&
                        (y_p2 >= focus_y0) && (y_p2 <= focus_y1);
    wire focus_border = focus_inside &&
                        ((x_p2 < focus_x0 + 11'd3) ||
                         (x_p2 > focus_x1 - 11'd3) ||
                         (y_p2 < focus_y0 + 11'd3) ||
                         (y_p2 > focus_y1 - 11'd3));
    wire [23:0] dimmed_rgb = {2'b00, visible_rgb[23:18],
                              2'b00, visible_rgb[15:10],
                              2'b00, visible_rgb[7:2]};

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            hs_o  <= 1'b0;
            vs_o  <= 1'b0;
            de_o  <= 1'b0;
            rgb_o <= 24'd0;
        end else begin
            hs_o <= hs_p2;
            vs_o <= vs_p2;
            de_o <= de_p2;
            if (!de_p2)
                rgb_o <= 24'd0;
            else if (sliding && !overlay_p2 && (x_p2 < slide_edge))
                rgb_o <= 24'd0;
            else if (focus_enabled && !overlay_p2 && focus_border)
                rgb_o <= 24'hffd43b;
            else if (focus_enabled && !overlay_p2 && !focus_inside)
                rgb_o <= dimmed_rgb;
            else
                rgb_o <= visible_rgb;
        end
    end

endmodule









// v7.9: frequency-decimation FFT implementation; natural-order input,
// descending butterfly spans, rotation AFTER sum/difference, bit-reversed output.
// Historical implementation was adapted from out-of-mana8/fpga-audio-spectrum-analyzer.
// See AUDIO_PROVENANCE.md: the display envelope retains that project's influence.
// This rewrite is not a claim of clean-room authorship or contest eligibility.
module mg_fft256(
 input wire clk,rst,audio_valid,
 input wire [23:0] audio_sample,
 output reg mag_valid,
 output reg [6:0] mag_addr,
 output reg [15:0] mag_data,
 output reg done,
 output wire busy
);
 function signed [15:0] quarter_sine;
 input [6:0] phase;
 begin case(phase)
    7'd0: quarter_sine=16'sd0;
    7'd1: quarter_sine=16'sd804;
    7'd2: quarter_sine=16'sd1608;
    7'd3: quarter_sine=16'sd2410;
    7'd4: quarter_sine=16'sd3212;
    7'd5: quarter_sine=16'sd4011;
    7'd6: quarter_sine=16'sd4808;
    7'd7: quarter_sine=16'sd5602;
    7'd8: quarter_sine=16'sd6393;
    7'd9: quarter_sine=16'sd7179;
    7'd10: quarter_sine=16'sd7962;
    7'd11: quarter_sine=16'sd8739;
    7'd12: quarter_sine=16'sd9512;
    7'd13: quarter_sine=16'sd10278;
    7'd14: quarter_sine=16'sd11039;
    7'd15: quarter_sine=16'sd11793;
    7'd16: quarter_sine=16'sd12539;
    7'd17: quarter_sine=16'sd13279;
    7'd18: quarter_sine=16'sd14010;
    7'd19: quarter_sine=16'sd14732;
    7'd20: quarter_sine=16'sd15446;
    7'd21: quarter_sine=16'sd16151;
    7'd22: quarter_sine=16'sd16846;
    7'd23: quarter_sine=16'sd17530;
    7'd24: quarter_sine=16'sd18204;
    7'd25: quarter_sine=16'sd18868;
    7'd26: quarter_sine=16'sd19519;
    7'd27: quarter_sine=16'sd20159;
    7'd28: quarter_sine=16'sd20787;
    7'd29: quarter_sine=16'sd21403;
    7'd30: quarter_sine=16'sd22005;
    7'd31: quarter_sine=16'sd22594;
    7'd32: quarter_sine=16'sd23170;
    7'd33: quarter_sine=16'sd23731;
    7'd34: quarter_sine=16'sd24279;
    7'd35: quarter_sine=16'sd24811;
    7'd36: quarter_sine=16'sd25329;
    7'd37: quarter_sine=16'sd25832;
    7'd38: quarter_sine=16'sd26319;
    7'd39: quarter_sine=16'sd26790;
    7'd40: quarter_sine=16'sd27245;
    7'd41: quarter_sine=16'sd27683;
    7'd42: quarter_sine=16'sd28105;
    7'd43: quarter_sine=16'sd28510;
    7'd44: quarter_sine=16'sd28898;
    7'd45: quarter_sine=16'sd29268;
    7'd46: quarter_sine=16'sd29621;
    7'd47: quarter_sine=16'sd29956;
    7'd48: quarter_sine=16'sd30273;
    7'd49: quarter_sine=16'sd30571;
    7'd50: quarter_sine=16'sd30852;
    7'd51: quarter_sine=16'sd31113;
    7'd52: quarter_sine=16'sd31356;
    7'd53: quarter_sine=16'sd31580;
    7'd54: quarter_sine=16'sd31785;
    7'd55: quarter_sine=16'sd31971;
    7'd56: quarter_sine=16'sd32137;
    7'd57: quarter_sine=16'sd32285;
    7'd58: quarter_sine=16'sd32412;
    7'd59: quarter_sine=16'sd32521;
    7'd60: quarter_sine=16'sd32609;
    7'd61: quarter_sine=16'sd32678;
    7'd62: quarter_sine=16'sd32728;
    7'd63: quarter_sine=16'sd32757;
    7'd64: quarter_sine=16'sd32767;
 default:quarter_sine=0;
 endcase end endfunction
 function [31:0] phase_vector;
 input [6:0] phase;
 reg signed [15:0] c,sn;
 begin
 if(phase<=64) begin c=quarter_sine(64-phase);sn=quarter_sine(phase);end
 else begin c=-quarter_sine(phase-64);sn=quarter_sine(128-{1'b0,phase});end
 phase_vector={c,-sn};
 end endfunction
 function [7:0] reverse8;
 input [7:0] n;
 begin reverse8={n[0],n[1],n[2],n[3],n[4],n[5],n[6],n[7]};end
 endfunction
 function [15:0] clamp16;
 input signed [32:0] n;
 begin
 if(n>32767) clamp16=16'h7fff;
 else if(n< -32768) clamp16=16'h8000;
 else clamp16=n[15:0];
 end endfunction

 reg [15:0] samples[0:511];
 reg [7:0] sample_index,load_index;
 reg fill_bank,ready_bank,sample_ready,source_bank;
 reg [15:0] sample_q;
 always @(posedge clk) begin
  if(audio_valid && !rst) samples[{fill_bank,sample_index}]<=audio_sample[23:8];
  sample_q<=samples[{source_bank,load_index}];
 end
 always @(posedge clk or posedge rst) begin
  if(rst) begin sample_index<=0;fill_bank<=0;ready_bank<=0;sample_ready<=0;end
  else begin
   sample_ready<=0;
   if(audio_valid) begin
    sample_index<=sample_index+1'b1;
    if(sample_index==255) begin ready_bank<=fill_bank;fill_bank<=~fill_bank;sample_ready<=1;end
   end
  end
 end

 localparam S_IDLE=0,S_LOAD_WAIT=1,S_LOAD_WRITE=2,
 S_A_WAIT=3,S_A_GET=4,S_B_WAIT=5,S_B_GET=6,S_SPLIT=7,
 S_MULTIPLY=8,S_ROTATE=9,S_STORE_SUM=10,S_STORE_ROT=11,S_ADVANCE=12,
 S_BIN_WAIT=13,S_BIN_GET=14,S_POWER=15,S_ROOT=16,S_EMIT=17,S_FINISH=18;
 reg [4:0] state;
 reg [2:0] span_log;
 reg [7:0] block_start;
 reg [6:0] lane,bin_index;
 wire [7:0] separation=8'd1<<span_log;
 wire [7:0] addr_a=block_start+{1'b0,lane};
 wire [7:0] addr_b=addr_a+separation;
 wire [8:0] next_block={1'b0,block_start}+({1'b0,separation}<<1);
 wire [6:0] phase=lane<<(7-span_log);
 wire [31:0] phase_q=phase_vector(phase);
 reg signed [15:0] a_re,a_im,b_re,b_im,sum_re,sum_im,diff_re,diff_im;
 wire signed [16:0] plus_re=$signed({a_re[15],a_re})+$signed({b_re[15],b_re});
 wire signed [16:0] plus_im=$signed({a_im[15],a_im})+$signed({b_im[15],b_im});
 wire signed [16:0] minus_re=$signed({a_re[15],a_re})-$signed({b_re[15],b_re});
 wire signed [16:0] minus_im=$signed({a_im[15],a_im})-$signed({b_im[15],b_im});
 reg signed [15:0] cosine,negative_sine,rot_re,rot_im;
 reg signed [31:0] product_rc,product_is,product_rs,product_ic;
 wire signed [32:0] rotate_re=$signed({product_rc[31],product_rc})-$signed({product_is[31],product_is});
 wire signed [32:0] rotate_im=$signed({product_rs[31],product_rs})+$signed({product_ic[31],product_ic});
 reg [31:0] work_mem[0:255];
 reg [7:0] raddr,waddr;
 reg write_enable;
 reg [31:0] wdata,ram_q;
 always @(*) begin
  raddr=addr_a;waddr=addr_a;wdata=0;write_enable=0;
  case(state)
   S_LOAD_WRITE:begin write_enable=1;waddr=load_index;wdata={sample_q,16'd0};end
   S_B_WAIT,S_B_GET:raddr=addr_b;
   S_STORE_SUM:begin write_enable=1;wdata={sum_re,sum_im};end
   S_STORE_ROT:begin write_enable=1;waddr=addr_b;wdata={rot_re,rot_im};end
   S_BIN_WAIT,S_BIN_GET:raddr=reverse8({1'b0,bin_index});
   default:;
  endcase
 end
 always @(posedge clk) begin
  ram_q<=work_mem[raddr];
  if(write_enable && !rst) work_mem[waddr]<=wdata;
 end
 // Euclidean magnitude, not max(abs(re),abs(im))+min(...)/4.
 // Sixteen restoring square-root steps over the 32-bit sum of squares.
 reg signed [15:0] bin_re,bin_im;
 wire signed [31:0] square_re=bin_re*bin_re;
 wire signed [31:0] square_im=bin_im*bin_im;
 reg [31:0] radicand;
 reg [33:0] remainder;
 reg [15:0] root;
 reg [3:0] root_step;
 wire [33:0] root_trial={16'd0,root,2'b01};
 wire [33:0] shifted_rem=(remainder<<2)|{32'd0,radicand[31:30]};
 assign busy=(state!=S_IDLE);
 always @(posedge clk or posedge rst) begin
  if(rst) begin
   state<=S_IDLE;load_index<=0;source_bank<=0;span_log<=7;block_start<=0;lane<=0;bin_index<=0;
   a_re<=0;a_im<=0;b_re<=0;b_im<=0;sum_re<=0;sum_im<=0;diff_re<=0;diff_im<=0;
   cosine<=0;negative_sine<=0;rot_re<=0;rot_im<=0;
   product_rc<=0;product_is<=0;product_rs<=0;product_ic<=0;
   bin_re<=0;bin_im<=0;radicand<=0;remainder<=0;root<=0;root_step<=0;
   mag_valid<=0;mag_addr<=0;mag_data<=0;done<=0;
  end else begin
   mag_valid<=0;done<=0;
   case(state)
    S_IDLE:if(sample_ready) begin source_bank<=ready_bank;load_index<=0;state<=S_LOAD_WAIT;end
    S_LOAD_WAIT:state<=S_LOAD_WRITE;
    S_LOAD_WRITE:if(load_index==255) begin span_log<=7;block_start<=0;lane<=0;state<=S_A_WAIT;end
                 else begin load_index<=load_index+1'b1;state<=S_LOAD_WAIT;end
    S_A_WAIT:state<=S_A_GET;
    S_A_GET:begin a_re<=ram_q[31:16];a_im<=ram_q[15:0];state<=S_B_WAIT;end
    S_B_WAIT:state<=S_B_GET;
    S_B_GET:begin b_re<=ram_q[31:16];b_im<=ram_q[15:0];cosine<=phase_q[31:16];negative_sine<=phase_q[15:0];state<=S_SPLIT;end
    S_SPLIT:begin sum_re<=plus_re>>>1;sum_im<=plus_im>>>1;diff_re<=minus_re>>>1;diff_im<=minus_im>>>1;state<=S_MULTIPLY;end
    S_MULTIPLY:begin product_rc<=diff_re*cosine;product_is<=diff_im*negative_sine;product_rs<=diff_re*negative_sine;product_ic<=diff_im*cosine;state<=S_ROTATE;end
    S_ROTATE:begin rot_re<=clamp16(rotate_re>>>15);rot_im<=clamp16(rotate_im>>>15);state<=S_STORE_SUM;end
    S_STORE_SUM:state<=S_STORE_ROT;
    S_STORE_ROT:state<=S_ADVANCE;
    S_ADVANCE:begin
     if({1'b0,lane}<separation-1'b1) begin lane<=lane+1'b1;state<=S_A_WAIT;end
     else if(next_block<256) begin block_start<=next_block[7:0];lane<=0;state<=S_A_WAIT;end
     else if(span_log!=0) begin span_log<=span_log-1'b1;block_start<=0;lane<=0;state<=S_A_WAIT;end
     else begin bin_index<=0;state<=S_BIN_WAIT;end
    end
    S_BIN_WAIT:state<=S_BIN_GET;
    S_BIN_GET:begin bin_re<=ram_q[31:16];bin_im<=ram_q[15:0];state<=S_POWER;end
    S_POWER:begin radicand<=square_re+square_im;remainder<=0;root<=0;root_step<=0;state<=S_ROOT;end
    S_ROOT:begin
     radicand<=radicand<<2;
     if(shifted_rem>=root_trial) begin remainder<=shifted_rem-root_trial;root<={root[14:0],1'b1};end
     else begin remainder<=shifted_rem;root<={root[14:0],1'b0};end
     root_step<=root_step+1'b1;
     if(root_step==15) state<=S_EMIT;
    end
    S_EMIT:begin
     mag_valid<=1;mag_addr<=bin_index;mag_data<=root;
     if(bin_index==127) state<=S_FINISH;
     else begin bin_index<=bin_index+1'b1;state<=S_BIN_WAIT;end
    end
    S_FINISH:begin done<=1;state<=S_IDLE;end
    default:state<=S_IDLE;
   endcase
  end
 end
endmodule

// Port of the upstream display's logarithmic heights, rapid attack, gradual
// release and per-bin peak hold; outputs share the existing HDMI pixel clock.
module mg_spectrum_bars(
 input wire clk,rst,frame_edge,audio_valid,
 input wire [23:0] audio_sample,
 input wire [2:0] gain,
 input wire [6:0] read_addr,
 output wire [6:0] height_out,peak_out
);
 wire mag_valid,fft_done,fft_busy;
 wire [6:0] mag_addr;
 wire [15:0] mag_data;
 mg_fft256 u_fft(.clk(clk),.rst(rst),.audio_valid(audio_valid),.audio_sample(audio_sample),
 .mag_valid(mag_valid),.mag_addr(mag_addr),.mag_data(mag_data),.done(fft_done),.busy(fft_busy));
 function [6:0] log_height;
 input [15:0] m;
 input [2:0] g;
 reg [16:0] scaled;
 reg [15:0] clipped;
 integer p,k,h,frac;
 reg found;
 begin
 case(g)
 0:scaled={1'b0,m}>>1;
 1:scaled={1'b0,m}-({1'b0,m}>>2);
 2:scaled={1'b0,m};
 3:scaled={1'b0,m}+({1'b0,m}>>2);
 default:scaled={1'b0,m}+({1'b0,m}>>1);
 endcase
 clipped=scaled>65535?16'hffff:scaled[15:0];
 p=0;found=0;frac=0;h=0;
 for(k=15;k>=0;k=k-1) if(!found && clipped[k]) begin p=k;found=1;end
 if(p>=4) frac=(clipped>>(p-4))&15;
 else frac=(clipped<<(4-p))&15;
 h=(p*22+frac)>>2;
 if(clipped<8) log_height=0;
 else if(h>80) log_height=80;
 else log_height=h[6:0];
 end endfunction
 // Dual-bank completed FFT heights and dual-port draw/update state RAM.
 // Updates finish in <400 pixel clocks, inside the existing vertical blank.
 reg [6:0] target_mem[0:255];
 reg [13:0] bar_mem[0:127];
 reg write_bank,completed_bank,completed_valid;
 reg update_bank,update_busy,initialize,initialized,slow_peak;
 reg [6:0] update_index;
 reg [1:0] update_phase,peak_div;
 reg [13:0] draw_q,update_q;
 reg [6:0] target_q;
 reg [2:0] analysis_gain;
 reg busy_d;
 wire [6:0] current_level=update_q[6:0];
 wire [6:0] current_peak=update_q[13:7];
 wire [6:0] target_level=completed_valid?target_q:7'd0;
 wire [6:0] decayed_level=(current_level>3)?current_level-7'd3:7'd0;
 wire [6:0] next_level=(target_level>=current_level)?target_level:
                             ((decayed_level<target_level)?target_level:decayed_level);
 wire [6:0] next_peak=(target_level>=current_peak)?target_level:
                            ((slow_peak && current_peak!=0)?current_peak-1'b1:current_peak);
 wire bar_we=update_busy && update_phase==2;
 wire [13:0] bar_wdata=initialize?14'd0:{next_peak,next_level};
 always @(posedge clk) begin
  if(mag_valid && !rst) target_mem[{write_bank,mag_addr}]<=
                         (mag_addr==0)?7'd0:log_height(mag_data,analysis_gain);
  target_q<=target_mem[{update_bank,update_index}];
 end
 always @(posedge clk) draw_q<=bar_mem[read_addr];
 always @(posedge clk) begin
  update_q<=bar_mem[update_index];
  if(bar_we && !rst) bar_mem[update_index]<=bar_wdata;
 end
 assign height_out=initialized?draw_q[6:0]:7'd0;
 assign peak_out=initialized?draw_q[13:7]:7'd0;
 always @(posedge clk or posedge rst) begin
 if(rst) begin
  write_bank<=0;completed_bank<=0;completed_valid<=0;
  update_bank<=0;update_busy<=1;initialize<=1;initialized<=0;
  update_index<=0;update_phase<=0;peak_div<=0;slow_peak<=0;
  busy_d<=0;analysis_gain<=2;
 end else begin
  busy_d<=fft_busy;
  if(fft_busy && !busy_d) analysis_gain<=gain;
  if(fft_done) begin
   completed_bank<=write_bank;completed_valid<=1;write_bank<=~write_bank;
  end
  if(frame_edge) begin
   peak_div<=peak_div+1'b1;
   if(!update_busy) begin
    update_bank<=completed_bank;update_index<=0;update_phase<=0;
    update_busy<=1;slow_peak<=(peak_div==0);
   end
  end
  if(update_busy) begin
   if(update_phase==2) begin
    update_phase<=0;
    if(update_index==127) begin update_busy<=0;initialize<=0;initialized<=1;end
    else update_index<=update_index+1'b1;
   end else update_phase<=update_phase+1'b1;
  end
 end
 end
endmodule
