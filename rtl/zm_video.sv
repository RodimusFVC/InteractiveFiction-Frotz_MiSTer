// zm_video - 640x240p raster at 15.7 kHz from zm_fb, for analog CRTs directly (HDMI goes through the sys scaler).
// Pixel clock = clk / CE_DIV (12 MHz: 36 MHz / 3). 762 x 262 total: 15.75 kHz, 60.1 Hz.
//   H: 640 active, 16 front porch, 56 sync (4.7 us), 50 back porch.  V: 240 active, 3 front porch, 3 sync, 16 back.
// Sync is active high (sys/ sets the output polarity). Outputs change on ce_pix.
// Each 8-pixel word is read during the word before it; the first word of a line during the back porch.
// Palette: index = Z-machine colour number (2 black .. 12 dark grey), colours from Standard 1.1 section 8.3.1;
// 16..31 = V6 MCGA picture pens (16 black, 17 white, 18..31 the picture palettes: pal_we from zm_pic, colours 2..15),
// 32..47 = the 16 EGA colours (EGA pictures).
// Input cursor: an overlay (never in the framebuffer): the bottom 2 pixel rows of cell cur_x, cur_y in cur_colour,
// blinking every 2^BLINK frames while cur_on.
// Mouse pointer (zm_mouse): an overlay above everything: an 8 x 7 arrow, hotspot = its top-left pixel at (ptr_x, ptr_y),
// while ptr_on. Fill (OSD ptr_col): White, Black, Red, Brown, Yellow, Green, Blue, Grey; the outline black, or white
// for the dark fills (Black, Brown, Blue).
module zm_video #(
    parameter [9:0] HTOT = 10'd762, HSS = 10'd656, HSE = 10'd712,
    parameter [8:0] VTOT = 9'd262,  VSS = 9'd243,  VSE = 9'd246,
    parameter       BLINK = 4,                         // cursor on / off every 2^BLINK frames
    parameter [1:0] CE_DIV = 2'd3                      // clocks per pixel (>= 3: a word fetch takes two)
) (
    input  wire        clk,
    input  wire        reset,
    output reg         ce_pix = 1'b0,
    output reg  [14:0] fb_addr = 15'd0,
    output wire        fb_req,                         // fb_addr wants the read port this clock (zm_core's mux)
    input  wire [63:0] fb_q,
    input  wire        cur_on,
    input  wire  [6:0] cur_x,
    input  wire  [4:0] cur_y,
    input  wire  [7:0] cur_colour,
    input  wire        ptr_on,
    input  wire  [9:0] ptr_x,
    input  wire  [8:0] ptr_y,
    input  wire  [2:0] ptr_col,
    input  wire        flash,                          // zm_snd: a beep as a screen flash (colours inverted)
    input  wire        pal_we,
    input  wire  [3:0] pal_i,
    input  wire [23:0] pal_rgb,
    output reg   [7:0] r = 8'd0,
    output reg   [7:0] g = 8'd0,
    output reg   [7:0] b = 8'd0,
    output reg         hs = 1'b0,
    output reg         vs = 1'b0,
    output reg         hblank = 1'b1,
    output reg         vblank = 1'b1
);

reg  [1:0] div = 2'd0;
reg  [9:0] hc = 10'd0;
reg  [8:0] vc = 9'd0;
reg [63:0] cur = 64'd0, nxt = 64'd0;
reg  [1:0] fetch = 2'd0;                               // read in flight: latch fb_q into nxt two clocks on
reg  [4:0] blink = 5'd0;                               // frame count
assign fb_req = fetch[0];

wire [8:0]  vn   = vc == VTOT - 9'd1 ? 9'd0 : vc + 9'd1;              // next line
wire [14:0] rowa = {vc[7:0], 6'd0} + {2'd0, vc[7:0], 4'd0};          // vc * 80
wire [14:0] rown = {vn[7:0], 6'd0} + {2'd0, vn[7:0], 4'd0};
wire  [7:0] pix  = cur[{hc[2:0], 3'b000} +: 8];
wire        act  = hc < 10'd640 && vc < 9'd240;
wire        curs = cur_on && blink[BLINK] && hc[9:3] == cur_x && vc[7:3] == cur_y && vc[2:1] == 2'b11;
function [15:0] ptr_row(input [2:0] pr);                // 2 bits a pixel (pixel i = bits 2i+1:2i): 0 clear, 1 black, 2 white
    case (pr)
        3'd0: ptr_row = 16'h0001;   // 1.......
        3'd1: ptr_row = 16'h0019;   // 121.....
        3'd2: ptr_row = 16'h01A9;   // 12221...
        3'd3: ptr_row = 16'h1AA9;   // 1222221.
        3'd4: ptr_row = 16'h05A9;   // 122211..
        3'd5: ptr_row = 16'h1A59;   // 1211221.
        3'd6: ptr_row = 16'h0505;   // 11..11..
        default: ptr_row = 16'h0000;
    endcase
endfunction
wire  [9:0] prx = hc - ptr_x;
wire  [8:0] pry = vc - ptr_y;
wire        pin = ptr_on && hc >= ptr_x && hc < ptr_x + 10'd8 && vc >= ptr_y && vc < ptr_y + 9'd7;
wire [15:0] prow = ptr_row(pry[2:0]);
wire  [1:0] pp = pin ? prow[{prx[2:0], 1'b0} +: 2] : 2'd0;
wire [23:0] pfill = ptr_col == 3'd1 ? 24'h000000 : ptr_col == 3'd2 ? 24'hEF0000 : ptr_col == 3'd3 ? 24'h8B4A20
                  : ptr_col == 3'd4 ? 24'hEFEF00 : ptr_col == 3'd5 ? 24'h00D600 : ptr_col == 3'd6 ? 24'h2060FF
                  : ptr_col == 3'd7 ? 24'hB5B5B5 : 24'hFFFFFF;
wire [23:0] pline = ptr_col == 3'd1 || ptr_col == 3'd3 || ptr_col == 3'd6 ? 24'hFFFFFF : 24'h000000;

reg [23:0] mp [2:15];                                  // the picture palette (MCGA pens 18..31)
always @(posedge clk) if (pal_we && pal_i >= 4'd2) mp[pal_i] <= pal_rgb;
function [23:0] ega(input [3:0] i);
    case (i)
        4'd0: ega = 24'h000000; 4'd1: ega = 24'h0000AA; 4'd2: ega = 24'h00AA00; 4'd3: ega = 24'h00AAAA;
        4'd4: ega = 24'hAA0000; 4'd5: ega = 24'hAA00AA; 4'd6: ega = 24'hAA5500; 4'd7: ega = 24'hAAAAAA;
        4'd8: ega = 24'h555555; 4'd9: ega = 24'h5555FF; 4'd10: ega = 24'h55FF55; 4'd11: ega = 24'h55FFFF;
        4'd12: ega = 24'hFF5555; 4'd13: ega = 24'hFF55FF; 4'd14: ega = 24'hFFFF55; default: ega = 24'hFFFFFF;
    endcase
endfunction
function [23:0] pal(input [7:0] i);
    if (i >= 8'd32 && i < 8'd48) pal = ega(i[3:0]);
    else if (i == 8'd16) pal = 24'h000000;
    else if (i == 8'd17) pal = 24'hFFFFFF;
    else if (i >= 8'd18 && i < 8'd32) pal = mp[i[3:0]];
    else case (i)
        8'd3:  pal = 24'hEF0000; 8'd4:  pal = 24'h00D600; 8'd5:  pal = 24'hEFEF00; 8'd6:  pal = 24'h006BB5;
        8'd7:  pal = 24'hFF00FF; 8'd8:  pal = 24'h00EFEF; 8'd9:  pal = 24'hFFFFFF; 8'd10: pal = 24'hB5B5B5;
        8'd11: pal = 24'h8C8C8C; 8'd12: pal = 24'h5A5A5A;
        default: pal = 24'h000000;                     // 2 black (and anything undefined)
    endcase
endfunction

always @(posedge clk) begin
    div    <= div == CE_DIV - 2'd1 ? 2'd0 : div + 2'd1;
    ce_pix <= div == CE_DIV - 2'd1;
    fetch  <= {fetch[0], 1'b0};
    if (fetch[1]) nxt <= fb_q;

    if (reset) begin
        hc <= 10'd0; vc <= 9'd0; hblank <= 1'b1; vblank <= 1'b1; hs <= 1'b0; vs <= 1'b0;
    end
    else if (ce_pix) begin
        {r, g, b} <= !act ? 24'd0 : (pp == 2'd1 ? pline : pp == 2'd2 ? pfill : pal(curs ? cur_colour : pix)) ^ {24{flash}};   // beep: DisplayBeep
        hblank <= hc >= 10'd640;
        vblank <= vc >= 9'd240;
        hs     <= hc >= HSS && hc < HSE;
        vs     <= vc >= VSS && vc < VSE;

        if (hc[2:0] == 3'd0 && hc < 10'd632 && vc < 9'd240) begin fb_addr <= rowa + {8'd0, hc[9:3]} + 15'd1; fetch[0] <= 1'b1; end
        if (hc == HTOT - 10'd8) begin fb_addr <= vn < 9'd240 ? rown : 15'd0; fetch[0] <= 1'b1; end
        if ((hc[2:0] == 3'd7 && hc < 10'd639) || hc == HTOT - 10'd1) cur <= nxt;

        if (hc == HTOT - 10'd1) begin hc <= 10'd0; vc <= vn; if (vn == 9'd0) blink <= blink + 5'd1; end
        else hc <= hc + 10'd1;
    end
end

endmodule
