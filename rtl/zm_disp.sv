// zm_disp - the screen: turns zm_cpu's output stream (ZSCII characters + display commands) into pixels in zm_fb.
// A port of Frotz buffer.c (word buffer: flushed before a space or after a hyphen; style and font changes ride in it as
// tokens) and screen.c (8 windows with Frotz's 16 properties each, word wrap, scrolling, margins, [MORE], the V6
// window opcodes) over an os_* layer that draws pixels:
//   V1-5: units are 8x8 cells (Frotz's 1x1 font units): unit (y, x) = pixel ((y-1)*8, (x-1)*8), cols x rows.
//   V6:   320 x 200 units (MCGA: 2 pixels across, 1 down) from raster line V6_TOP. Text in Flathead (zm_ttf: the
//         user's TTF files, proportional = font 1, fixed = font 4 or the fixed style) for characters 32..126, each glyph
//         drawn 2x wide in a cell of its advance; font 3, Latin-1 and an unloaded Flathead use the built-in 8x8 font
//         (4 units). Widths are measured per character with the font and style in force (the word buffer tracks the
//         tokens in it: bf_*). ref/stdio.patch PIX draws the same.
// Bare newlines that scroll the same window add up into one pending scroll (pend_*), applied before anything else is
// drawn or read: the same pixels, but a run of N newlines costs one scroll (Zork Zero prints 65531 in a row).
// The os cursor (os_y, os_x) is separate from the windows' cursors and moves only where Frotz moves it (os_set_cursor,
// os_display_char). Window attributes as Frotz: 1 wrap, 2 scroll, 8 buffer (window 0 starts at 15, the others at 8).
// ZSCII 9 / 11 are Frotz's ZC_INDENT / ZC_GAP (V6 paragraph indent / sentence space): drawn as 3 / 2 spaces, word
// breaks like a space, dropped at the start of a wrapped line; an indent that isn't at the line start is one space.
// Deviation: ZSCII 13 always starts a new line (Frotz drops a print_char 13 while buffering is off).
// [MORE] (more_en): Frotz screen_new_line's line count per window; the prompt waits for a key of its own
// (key_valid / key_ack, more_wait while it does) and is then erased. The input cursor is zm_video's overlay at cur_*
// (V1-5). Not yet: the V6 input cursor.
// Newline interrupts (Frotz countdown -> direct_call): when a window's countdown runs out with a routine set, this
// pauses mid-item: its working state goes to sh_*, irq asks zm_cpu to run irq_addr, and the routine's output is
// taken as ordinary items until CMD_IRET restores the state and the newline finishes. As Frotz's flush_buffer lock, a
// flush inside the routine while one is in progress does nothing (fl_lock); characters it buffers then are shown with
// the paused word (Frotz: past the word's end marker, undefined). One level only: a countdown that runs out inside the
// routine raises nl_irq (the CPU stops).
module zm_disp #(
    parameter FONT_FILE  = "rtl/font/zm_font_osd.hex", // text font (fonts 1 and 4); paths from the Quartus project
    parameter FONT3_FILE = "rtl/font/zm_font3.hex",    // font 3, Beyond Zork's character graphics
    parameter V6_TOP     = 20                          // V6: first raster line of the 200-line screen
) (
    input  wire        clk,
    input  wire        reset,
    input  wire  [7:0] cols,                           // V1-5 screen size in cells (80 x 30 on 640 x 240)
    input  wire  [7:0] rows,
    input  wire  [7:0] def_fg,                         // default colours (header 0x2D / 0x2C)
    input  wire  [7:0] def_bg,
    input  wire        ttf_we,                         // zm_ttf: TTF glyph rows into the font RAM, advances, slots loaded
    input  wire [11:0] ttf_addr,
    input  wire  [7:0] ttf_data,
    input  wire [383:0] adv_prop,
    input  wire [383:0] adv_fixed,
    input  wire        have_prop,
    input  wire        have_fixed,
    input  wire        have_cell,                      // an 8-wide cell font (Topaz) is loaded: text 32..126 uses it; V6 = 640 units
    input  wire  [7:0] interp,                         // header interpreter number (4 Amiga, 6 MS-DOS): Frotz's screen.c quirks
    output wire  [1:0] wsel,                           // the os font for widths (0 built-in, 1 proportional, 2 fixed): stream 3
    input  wire  [1:0] gset,                           // zm_pic: the picture set (0 none, 1 MCGA = 320 units, 2 EGA / 3 CGA = 640)
    output reg         pic_req = 1'b0,                 // zm_pic requests: op 0 picture data, 1 draw at raster (pic_py, pic_px)
    output reg         pic_op = 1'b0,
    output reg  [15:0] pic_num = 16'd0,
    output reg signed [21:0] pic_py = 22'sd0,
    output reg signed [21:0] pic_px = 22'sd0,
    input  wire        pic_busy,
    input  wire        pic_ok,
    input  wire [15:0] pic_h,
    input  wire [15:0] pic_w,

    input  wire  [9:0] in_char,                        // zm_cpu out_* stream
    input  wire        in_cmd,
    input  wire [15:0] in_arg0,
    input  wire [15:0] in_arg1,
    input  wire [15:0] in_arg2,
    input  wire        in_valid,
    output wire        in_ready,
    output reg  [15:0] rsp_a = 16'd0,                  // answers (get_cursor, get_wind_prop, V6 set_font), valid when idle
    output reg  [15:0] rsp_b = 16'd0,
    output reg         rsp_ok = 1'b0,                  // picture_data: available
    output reg         irq = 1'b0,                     // paused at a newline countdown: run irq_addr (until CMD_IRET)
    output reg  [15:0] irq_addr = 16'd0,
    output reg         nl_irq = 1'b0,                  // a countdown ran out inside the interrupt routine (pulse)
    output reg         v6 = 1'b0,                      // the V6 screen model is active

    output reg  [14:0] fb_addr = 15'd0,                // write port: 8 pixels per word, a byte enable per pixel
    output reg  [63:0] fb_wdata = 64'd0,
    output reg   [7:0] fb_be = 8'd0,
    output reg         fb_we = 1'b0,
    output reg  [14:0] fb_raddr = 15'd0,               // read port (scroll), shared with zm_video:
    output wire        fb_rreq,                        // asking for it this clock ...
    input  wire        fb_grant,                       // ... and got it: fb_q is the word next clock
    input  wire [63:0] fb_q,

    input  wire        more_en,                        // [MORE] prompts (OSD; the sim matches the reference's setting)
    input  wire        key_valid,                      // the key for [MORE]: taken only while more_wait
    output reg         key_ack = 1'b0,
    output wire        more_wait,
    output wire signed [9:0] cur_row,                  // the os cursor cell (V1-5, 0-based screen row / column) and its colour
    output wire signed [9:0] cur_col,
    output wire  [7:0] cur_fg,

    output reg         snap = 1'b0,                    // input request or [MORE] reached, everything before it drawn (sim)
    output wire        busy
);

localparam [7:0] CMD_SBEGIN = 8'h00, CMD_SPAD = 8'h01, CMD_SEND = 8'h02,
                 CMD_ERASE_WIN = 8'h10, CMD_SPLIT = 8'h11, CMD_SETWIN = 8'h12, CMD_CURSOR = 8'h13, CMD_STYLE = 8'h14,
                 CMD_BUFMODE = 8'h15, CMD_ERASE_LINE = 8'h16, CMD_COLOUR = 8'h17, CMD_SOUND = 8'h18,
                 CMD_ECHO = 8'h19, CMD_FONT = 8'h1A, CMD_PT_BEGIN = 8'h1B, CMD_PT_ROW = 8'h1C, CMD_RESTART = 8'h1D,
                 CMD_READ = 8'h1E, CMD_FLUSH = 8'h1F,
                 CMD_GETCUR = 8'h20, CMD_WSIZE = 8'h21, CMD_WMOVE = 8'h22, CMD_MARGINS = 8'h23, CMD_WSTYLE = 8'h24,
                 CMD_PUTPROP = 8'h25, CMD_GETPROP = 8'h26, CMD_SCROLLW = 8'h27, CMD_IRET = 8'h28,
                 CMD_MAXW = 8'h29,                     // get_max_width (stream 3): a window's width less its margins
                 CMD_DRAWPIC = 8'h2A, CMD_ERASEPIC = 8'h2B, CMD_PICDATA = 8'h2C,
                 CMD_MWIN = 8'h2D, CMD_CLICK = 8'h2E,   // mouse_window; validate_click (arg0 x, arg1 y raster -> rsp)
                 CMD_RCONT = 8'h2F;                     // timed input goes on (arg0 0 read, 1 read_char): no flush

localparam [7:0]
    S_IDLE = 8'd0, S_DISP = 8'd1, S_UPC = 8'd2, S_UA = 8'd3,
    S_C_NL = 8'd4, S_C_INS = 8'd5,
    S_SB1 = 8'd8, S_PD1 = 8'd9, S_PD2 = 8'd10, S_EW1 = 8'd11, S_CU1 = 8'd12, S_BM1 = 8'd13, S_EL1 = 8'd14,
    S_CO1 = 8'd15, S_PB1 = 8'd16, S_PR1 = 8'd17, S_RD1 = 8'd18, S_RD2 = 8'd19, S_RS1 = 8'd20, S_RS2 = 8'd21,
    S_RS3 = 8'd22, S_GC1 = 8'd23, S_WZ1 = 8'd24, S_WM1 = 8'd25, S_MG1 = 8'd26, S_WT1 = 8'd27, S_PP1 = 8'd28,
    S_GP1 = 8'd29, S_SW_1 = 8'd30, S_SW_2 = 8'd31,
    S_FL0 = 8'd32, S_FL1 = 8'd33, S_FL2 = 8'd34, S_FLL = 8'd35, S_FLL1 = 8'd36, S_FLL2 = 8'd37, S_SW_3 = 8'd38,
    S_SC0 = 8'd40, S_SC1 = 8'd41,
    S_NL0 = 8'd44, S_NL1 = 8'd45, S_NL2 = 8'd46, S_NL3 = 8'd47,
    S_MO0 = 8'd48, S_MO1 = 8'd49, S_MO2 = 8'd50, S_MO3 = 8'd51, S_MO4 = 8'd52,
    S_SW0 = 8'd56, S_SW1 = 8'd57, S_SW3 = 8'd58, S_SW4 = 8'd59,
    S_TK0 = 8'd60, S_TK1 = 8'd61,
    S_EWN0 = 8'd64, S_EWN1 = 8'd65, S_EWN2 = 8'd66,
    S_SP0 = 8'd68, S_SP1 = 8'd69, S_SP2 = 8'd70, S_SP3 = 8'd71,
    S_ES0 = 8'd72, S_ES1 = 8'd73, S_ES2 = 8'd74, S_ES3 = 8'd75,
    S_G0 = 8'd80, S_G1 = 8'd81, S_G2 = 8'd82, S_G3 = 8'd83, S_G4 = 8'd84, S_G5 = 8'd85,
    S_EB0 = 8'd106, S_EB1 = 8'd107, S_EB2 = 8'd108,
    S_F0 = 8'd88, S_F1 = 8'd89,
    S_SR0 = 8'd92, S_SR1 = 8'd93, S_SR2 = 8'd94, S_SR3 = 8'd95, S_SR4 = 8'd96, S_PF0 = 8'd97, S_NL0B = 8'd98, S_NL4 = 8'd99,
    S_MW1 = 8'd105, S_FLA = 8'd100,
    S_PC0 = 8'd110, S_PC1 = 8'd111, S_PC2 = 8'd112,
    S_DP0 = 8'd113, S_DP1 = 8'd114, S_DP2 = 8'd115, S_DP3 = 8'd116, S_DP4 = 8'd117, S_DP5 = 8'd118, S_DP6 = 8'd119,
    S_DP7 = 8'd120, S_DP8 = 8'd121, S_EP0 = 8'd122, S_EP1 = 8'd123, S_QD0 = 8'd124, S_QD1 = 8'd125, S_QD2 = 8'd126,
    S_QD3 = 8'd127, S_QD4 = 8'd128, S_FLA2 = 8'd101, S_FLB = 8'd102, S_DR0 = 8'd103, S_DR1 = 8'd104,
    S_PK0 = 8'd129, S_PK1 = 8'd130, S_PK2 = 8'd131, S_CO2 = 8'd132,
    S_RC0 = 8'd133, S_RC1 = 8'd134, S_RC2 = 8'd135, S_RC3 = 8'd136, S_RCG = 8'd137, S_RC4 = 8'd138;

localparam [3:0] ST_REVERSE = 4'd1, ST_BOLD = 4'd2, ST_EMPH = 4'd4, ST_FIXED = 4'd8;

reg  [7:0] st = S_IDLE;
reg  [7:0] rs [0:7];
reg  [2:0] rsp = 3'd0;

// latched input item
reg  [7:0] ich = 8'd0;
reg  [7:0] icmd = 8'd0;
reg        iscmd = 1'b0;
reg [15:0] ia = 16'd0, ib = 16'd0, ic = 16'd0;

// Frotz wp[8]: y_pos, x_pos, y_size, x_size, y_cursor, x_cursor, left, right, nl_routine, nl_countdown, style,
// colour ({bg, fg}), font, font_size ({height, width}), attribute, line_count (zwords, as Frotz)
reg [15:0] wyp [0:7], wxp [0:7], wys [0:7], wxs [0:7], wyc [0:7], wxc [0:7], wl [0:7], wr [0:7];
reg [15:0] wnr [0:7], wnc [0:7], wst [0:7], wco [0:7], wfo [0:7], wfs [0:7], wat [0:7], wlc [0:7];
reg  [2:0] cw = 3'd0;                                  // cwin
reg  [3:0] version = 4'd3;
reg  [3:0] sid = 4'd0;                                 // Frotz story_id (zm_cpu frotz_story)
reg [15:0] rel = 16'd0;                                // release
reg        bz = 1'b0;                                  // Beyond Zork: ZSCII 155+ is not translated
reg        en_wrap = 1'b1, en_scroll = 1'b1, en_buf = 1'b1;   // Frotz enable_* (update_attributes)
reg signed [17:0] os_y = 18'sd1, os_x = 18'sd1;        // the os cursor (units)
reg  [7:0] os_fg = 8'd2, os_bg = 8'd9;                 // what the os layer draws with
reg  [3:0] os_style = 4'd0;
reg  [7:0] os_font = 8'd1;
reg        cursor_on = 1'b1;                           // set_cursor -1 / -2 (not shown yet)
reg [15:0] pt_x = 16'd1;
reg  [3:0] mo_style = 4'd0;
reg  [2:0] mo_i = 3'd0;
reg signed [17:0] mo_x = 18'sd0;

// word buffer: {token type (0 char, 1 style, 2 font), value}; bufw = its width in units
reg  [9:0] bufm [0:255];
reg  [7:0] bwa = 8'd0, bra = 8'd0;
reg  [9:0] bwd = 10'd0, brd = 10'd0;
reg        bwe = 1'b0;
reg  [8:0] bufpos = 9'd0;
reg [11:0] bufw = 12'd0;
reg  [8:0] prev_c = 9'd0;                              // last buffered code; 0x101 = a token
always @(posedge clk) begin
    if (bwe) bufm[bwa] <= bwd;
    brd <= bufm[bra];
end

// font RAM: text font glyphs 0..255, font 3, then the TTF slots from zm_ttf: proportional / fixed (characters 0..127)
// at 4096, cell (characters 0..255) at 6144; 8 rows each, bit i = pixel column i
reg  [7:0] font [0:8191];
initial begin $readmemh(FONT_FILE, font, 0, 2047); $readmemh(FONT3_FILE, font, 2048, 4095); end
reg [12:0] font_a = 13'd0;
reg  [7:0] font_q = 8'd0;
always @(posedge clk) begin
    if (ttf_we) font[{1'b1, ttf_addr}] <= ttf_data;
    font_q <= font[font_a];
end
// typed characters (echo) as drawn, so a delete takes back the right width
reg  [7:0] ech [0:255];
reg  [7:0] ech_n = 8'd0, ech_ra = 8'd0, ech_q = 8'd0, ech_wc = 8'd0, ech_wa = 8'd0;
reg        ech_we = 1'b0, ech_none = 1'b0;             // ech_none: a delete with nothing echoed (preloaded text): '0'
// timed input (Frotz console_read_input): the input line's window and width (preloaded text counted as '0's, as
// S_RD1), and input_redraw: a newline went through that window since input started (the routine's output)
reg  [2:0] in_win = 3'd0;
reg        inp_rd = 1'b0;
reg signed [17:0] inw = 18'sd0;
reg  [7:0] rc_i = 8'd0;
always @(posedge clk) begin
    if (ech_we) ech[ech_wa] <= ech_wc;
    ech_q <= ech[ech_ra];
end

// routine arguments / scratch
reg  [8:0] fl_i = 9'd0;
reg        fl_char = 1'b0;                             // flush: word doesn't fit and wrapping is off: char by char
reg  [7:0] sc_c = 8'd0;
reg  [2:0] sw_w = 3'd0, ew_w = 3'd0, aw = 3'd0;
reg  [9:0] tk_v = 10'd0;
reg [15:0] sp_h = 16'd0;
reg signed [17:0] pd_n = 18'sd0;
reg        pd_send = 1'b0, es_all = 1'b0;
reg  [7:0] dch = 8'd0, dr_c = 8'd0;
reg  [7:0] pk_c = 8'd9;                                // os_peek_colour: the pixel at the os cursor (V6), else white
reg  [1:0] dr_n = 2'd0;                                // S_DR*: spaces still to draw for an indent / gap
// pixel primitives: rectangle p_* (raster pixels, inclusive) for fill / scroll (s_n rows, > 0 up), glyph at g_*
reg signed [21:0] p_y0 = 22'sd0, p_y1 = 22'sd0, p_x0 = 22'sd0, p_x1 = 22'sd0, s_n = 22'sd0, g_y = 22'sd0, g_x = 22'sd0;
reg        f_all = 1'b0;                               // fill: the whole raster (V6 restart), not just the screen
reg  [8:0] fy = 9'd0, fy1 = 9'd0, sy = 9'd0, sy_end = 9'd0, sr_lim = 9'd0;
reg  [9:0] fx0 = 10'd0, fx1 = 10'd0;
reg  [6:0] fwd = 7'd0;
reg        s_up = 1'b0;
reg  [2:0] gi = 3'd0;
reg [63:0] g_hi = 64'd0, g_hi2 = 64'd0;
reg  [7:0] g_mk1 = 8'd0, g_mk2 = 8'd0;
reg        fl_lock = 1'b0;                             // a flush is in progress (Frotz flush_buffer's locked)
reg        int_active = 1'b0;
reg [7:0] sh_st; reg [7:0] sh_rs [0:7]; reg [2:0] sh_rsp; reg [7:0] sh_ich; reg [7:0] sh_icmd; reg sh_iscmd;
reg [15:0] sh_ia; reg [15:0] sh_ib; reg [15:0] sh_ic; reg [8:0] sh_fl_i; reg sh_fl_char; reg [7:0] sh_sc_c;
reg signed [17:0] sh_pd_n; reg sh_pd_send; reg sh_es_all; reg [15:0] sh_sp_h; reg [2:0] sh_sw_w; reg [2:0] sh_ew_w;
reg [9:0] sh_tk_v; reg [15:0] sh_pt_x; reg sh_nl_defer;
reg [15:0] dp_y = 16'd0, dp_x = 16'd0;               // draw / erase_picture: position (units), mapper picture data
reg [15:0] mh1 = 16'd0, mw1 = 16'd0, mh2 = 16'd0, mw2 = 16'd0;
reg        mok = 1'b0;
reg        pend = 1'b0, nl_defer = 1'b0;               // deferred newline scroll: pend_n pixel rows of rectangle pend_*
reg signed [21:0] pend_n = 22'sd0, pend_y0 = 22'sd0, pend_y1 = 22'sd0, pend_x0 = 22'sd0, pend_x1 = 22'sd0;

// ------------------------------------------------ units
function signed [17:0] u(input [15:0] v);              // a zword as Frotz's int arithmetic sees it
    u = $signed({2'b00, v});
endfunction
wire signed [17:0] fh = v6 ? 18'sd8 : 18'sd1;         // Frotz font_height / font_width (os_font_data)
wire        wide = v6 && (gset == 2'd2 || gset == 2'd3 || have_cell);   // 640 units, 1 pixel each (else 2): EGA / CGA, or
                                                       // Topaz (Amiga Frotz's layout: MCGA pictures 2 units wide)   // EGA / CGA pictures: 640 units, 1 pixel each (else 2)
wire signed [17:0] fw0 = !v6 ? 18'sd1 : wide ? 18'sd8 : 18'sd4;   // the built-in font's advance
wire signed [17:0] fw = !v6 ? 18'sd1 : have_prop && !have_cell ? $signed({14'd0, adv_prop[67:64]}) <<< wide : fw0;   // font_width: '0' ('0' - 32 = 16)
wire [15:0] fsz = v6 ? {8'd8, fw[7:0]} : 16'h0101;     // font_size property
wire [15:0] scr_w = v6 ? (wide ? 16'd640 : 16'd320) : {8'd0, cols};   // h_screen_width / h_screen_height
wire [15:0] scr_h = v6 ? 16'd200 : {8'd0, rows};
// mouse (Frotz screen.c): mwin = 1 at restart, mouse_window -1 = the whole screen. validate_click: the raster position
// (ia, ib) in units (V6: pixels, / 2 across in the 320 layout, from V6_TOP down; V1-5: character cells), inside the
// mouse window -> relative to it (1-based), else ignored
reg  [2:0] mw = 3'd1;
reg        mw_all = 1'b0;
wire signed [17:0] mk_x = v6 ? (wide ? $signed({8'd0, ia[9:0]}) : $signed({9'd0, ia[9:1]})) + 18'sd1 : $signed({11'd0, ia[9:3]}) + 18'sd1;
wire signed [17:0] mk_y = v6 ? $signed({9'd0, ib[8:0]}) - V6_TOP + 18'sd1 : $signed({12'd0, ib[8:3]}) + 18'sd1;
wire signed [17:0] mk_wy = $signed({2'd0, wyp[mw]}), mk_wx = $signed({2'd0, wxp[mw]});
wire        mk_in = mw_all ? mk_y >= 18'sd1 && mk_y <= $signed({2'd0, scr_h}) && mk_x >= 18'sd1 && mk_x <= $signed({2'd0, scr_w})
                           : mk_y >= mk_wy && mk_y < mk_wy + $signed({2'd0, wys[mw]}) && mk_x >= mk_wx && mk_x < mk_wx + $signed({2'd0, wxs[mw]});
wire signed [17:0] mk_rx = mw_all ? mk_x : mk_x - mk_wx + 18'sd1, mk_ry = mw_all ? mk_y : mk_y - mk_wy + 18'sd1;
wire signed [17:0] ul = u(wxs[cw]) - u(wr[cw]) - u(wxc[cw]) + 18'sd1;   // units_left
wire        zz393 = sid == 4'd3 && rel == 16'd393 && interp == 8'd6;   // Zork Zero r393 under DOS: newline countdown at the end
wire        amiga = interp == 8'd4;                    // Amiga: other windows scroll / erase in the current colours, and window
                                                       // 0's set_colour recolours the other windows (screen.c)
reg  [15:0] nf, nb, f2, b2;                            // S_CO2 (blocking)
integer     cwi;

function signed [21:0] pyof(input signed [17:0] y);    // unit row -> raster row
    pyof = v6 ? $signed({{4{y[17]}}, y}) - 22'sd1 + V6_TOP : ($signed({{4{y[17]}}, y}) - 22'sd1) * 22'sd8;
endfunction
function signed [21:0] pxof(input signed [17:0] x);    // unit column -> raster column
    pxof = ($signed({{4{x[17]}}, x}) - 22'sd1) <<< (!v6 ? 2'd3 : wide ? 2'd0 : 2'd1);   // shifts: no multiplier
endfunction
function [2:0] winarg(input [15:0] w);                 // Frotz winarg0 / winarg2: -3 = the current window
    winarg = w == 16'hFFFD ? cw : v6 ? w[2:0] : (w == 16'd1 ? 3'd1 : 3'd0);
endfunction
function [31:0] pmap(input [15:0] p);                  // Frotz mapper[]: {piece 1, piece 2} drawn under picture p, else 0
    pmap = sid == 4'd3 && p == 16'd5  ? {16'd497, 16'd498} : sid == 4'd3 && p == 16'd6 ? {16'd501, 16'd502}
         : sid == 4'd3 && p == 16'd7  ? {16'd499, 16'd500} : sid == 4'd3 && p == 16'd8 ? {16'd503, 16'd504}
         : sid == 4'd5 && p == 16'd54 ? {16'd170, 16'd171} : sid == 4'd4 && p == 16'd50 ? {16'd61, 16'd62} : 32'd0;
endfunction
function piece(input [15:0] p);                        // a piece: not available on its own
    piece = (sid == 4'd3 && p >= 16'd497 && p <= 16'd504) || (sid == 4'd5 && (p == 16'd170 || p == 16'd171))
         || (sid == 4'd4 && (p == 16'd61 || p == 16'd62));
endfunction
wire [31:0] pm = pmap(ia);                             // {piece 1, piece 2} of the picture in the command
wire [15:0] pm_1 = pm[31:16], pm_2 = pm[15:0];
function printable(input [7:0] c);                     // stdio os_display_char draws it: ASCII or Latin-1
    printable = (c >= 8'd32 && c <= 8'd126) || c >= 8'd160;
endfunction
function [1:0] fsel(input [7:0] f, input [3:0] sty);   // the font a character is drawn in: 0 built-in, 1 / 2 Flathead
    fsel = !v6 || f == 8'd3 || have_cell ? 2'd0 : (f == 8'd4 || sty[3]) ? (have_fixed ? 2'd2 : 2'd0) : (have_prop ? 2'd1 : 2'd0);
endfunction
function haswidth(input [7:0] c);                      // os_char_width is not 0: a character, ZC_INDENT, ZC_GAP
    haswidth = printable(c) || c == 8'd9 || c == 8'd11;
endfunction
function [15:0] tdiv(input signed [17:0] n);           // n / font_height, truncated toward 0 (C), as a zword
    reg signed [17:0] q;
    begin
        q = n[17] ? -((-n) >>> 3) : n >>> 3;
        tdiv = v6 ? q[15:0] : n[15:0];
    end
endfunction

// the current window's rectangle in pixels (screen_new_line's scroll area)
wire signed [21:0] pk_y = pyof(os_y), pk_x = pxof(os_x);   // os_peek_colour's pixel
wire signed [21:0] cwr_y0 = pyof(u(wyp[cw]));
wire signed [21:0] cwr_y1 = pyof(u(wyp[cw]) + u(wys[cw])) - 22'sd1;
wire signed [21:0] cwr_x0 = pxof(u(wxp[cw]));
wire signed [21:0] cwr_x1 = pxof(u(wxp[cw]) + u(wxs[cw])) - 22'sd1;
wire        pend_same = cwr_y0 == pend_y0 && cwr_y1 == pend_y1 && cwr_x0 == pend_x0 && cwr_x1 == pend_x1;

// [MORE] check (screen_new_line): above / below in lines, with Frotz's zword / short conversions
wire [15:0] nl_above = tdiv(u(wyc[cw]) - 18'sd1);
wire [15:0] nl_below = tdiv(u(wys[cw]) - u(wyc[cw]) + 18'sd1);
wire [15:0] nl_lc1   = wlc[cw] + 16'd1;
wire        nl_more  = $signed({{2{nl_lc1[15]}}, nl_lc1}) >= $signed({{2{nl_above[15]}}, nl_above}) + u(nl_below) - 18'sd1;

// the rectangle clipped to the raster (V6: its screen lines)
wire signed [21:0] cl_y0 = f_all ? 22'sd0 : v6 ? V6_TOP : 22'sd0;
wire signed [21:0] cl_y1 = f_all ? 22'sd239 : v6 ? V6_TOP + 199 : $signed({11'd0, rows, 3'd0}) - 22'sd1;
wire signed [21:0] cl_x1 = $signed({11'd0, cols, 3'd0}) - 22'sd1;
wire signed [21:0] q_y0 = p_y0 < cl_y0 ? cl_y0 : p_y0;
wire signed [21:0] q_y1 = p_y1 > cl_y1 ? cl_y1 : p_y1;
wire signed [21:0] q_x0 = p_x0 < 22'sd0 ? 22'sd0 : p_x0;
wire signed [21:0] q_x1 = p_x1 > cl_x1 ? cl_x1 : p_x1;
wire        q_empty = q_y1 < q_y0 || q_x1 < q_x0;
wire signed [21:0] q_h = q_y1 - q_y0 + 22'sd1;
wire signed [21:0] s_abs = s_n[21] ? -s_n : s_n;

function [14:0] row80(input [8:0] y);                  // first word of raster row y
    row80 = {y, 6'd0} + {2'd0, y, 4'd0};
endfunction
function [7:0] wmask(input [6:0] w, input [9:0] x0, input [9:0] x1);   // pixels x0..x1 within word w
    reg [2:0] lo, hi;
    begin
        lo = w == x0[9:3] ? x0[2:0] : 3'd0;
        hi = w == x1[9:3] ? x1[2:0] : 3'd7;
        wmask = (8'hFF << lo) & (8'hFF >> (3'd7 - hi));
    end
endfunction

// glyph row: bit i = pixel i; reverse swaps the colours, bold smears right, emphasis fills row 7
wire  [7:0] g_bits = ((os_style & ST_EMPH) != 4'd0 && gi == 3'd7) ? 8'hFF
                   : (os_style & ST_BOLD) != 4'd0 ? font_q | {font_q[6:0], 1'b0} : font_q;
wire        g_bold = (os_style & ST_BOLD) != 4'd0;
wire  [7:0] g_b2 = ((os_style & ST_EMPH) != 4'd0 && gi == 3'd7) ? 8'hFF : font_q;   // 2x glyphs: unsmeared (bold in g_row)
wire  [7:0] g_fg = (os_style & ST_REVERSE) != 4'd0 ? os_bg : os_fg;
wire  [7:0] g_bg = (os_style & ST_REVERSE) != 4'd0 ? os_fg : os_bg;
reg  [1:0] g_src = 2'd0;                               // the glyph's font: 0 built-in, 1 / 2 Flathead
reg  [3:0] g_adv = 4'd0;                               // its advance (Flathead)
reg [127:0] g_row;                                     // 16 pixels: built-in 8, Flathead 2 per font pixel
reg  [15:0] g_cell;                                    // the cell's pixels
integer gk;
always @* begin
    for (gk = 0; gk < 16; gk = gk + 1)
        g_row[8*gk +: 8] = (g_src != 2'd0 ? g_b2[gk >> 1] || (g_bold && gk > 0 && g_b2[(gk > 0 ? gk - 1 : 0) >> 1])   // 2x: bold = 1 raster px (index kept in range: see % 8)
                                          : gk < 8 && g_bits[gk % 8]) ? g_fg : g_bg;   // % 8: Quartus rejects an out-of-range constant index even when guarded
    g_cell = g_src != 2'd0 ? (16'd1 << {g_adv, 1'b0}) - 16'd1 : 16'h00FF;
end
wire [191:0] g_sh = {64'd0, g_row} << {g_x[2:0], 3'd0};
wire  [23:0] g_mk = {8'd0, g_cell} << g_x[2:0];
wire signed [21:0] g_yr = g_y + $signed({19'd0, gi});
wire signed [18:0] g_w0 = g_x[21:3];
wire signed [18:0] g_w1 = g_w0 + 19'sd1;
wire signed [18:0] g_w2 = g_w0 + 19'sd2;
wire        g_yok = g_yr >= cl_y0 && g_yr <= cl_y1;
wire        g_w0ok = g_w0 >= 19'sd0 && g_w0 <= $signed({11'd0, cols}) - 19'sd1;
wire        g_w1ok = g_w1 >= 19'sd0 && g_w1 <= $signed({11'd0, cols}) - 19'sd1;
wire        g_w2ok = g_w2 >= 19'sd0 && g_w2 <= $signed({11'd0, cols}) - 19'sd1;

reg  [7:0] bf_font = 8'd1;                             // os font / style once the buffer's tokens are applied
reg  [3:0] bf_style = 4'd0;
wire  [1:0] os_sel = fsel(os_font, os_style);
assign wsel = os_sel;
// the advances as 96-entry tables of 4 bits (a variable part-select of the flat bus builds a 384-way shifter)
wire  [3:0] advp [0:127], advf [0:127];
genvar ai;
generate for (ai = 0; ai < 128; ai = ai + 1) begin : adv_tab
    if (ai < 96) begin : in_tab                         // a generate if: Quartus never sees an index past the bus
        assign advp[ai] = adv_prop[4*ai +: 4];
        assign advf[ai] = adv_fixed[4*ai +: 4];
    end else begin : past
        assign advp[ai] = 4'd0;
        assign advf[ai] = 4'd0;
    end
end endgenerate
// the one width lookup: which character (and font) the current state asks about. lk_adv = its Flathead advance
// (pixels), lk_1 = one character's advance in units (indent / gap: a space's), lk_w = os_char_width (indent / gap 3 / 2)
wire  [7:0] lk_c = st == S_C_INS ? ich                                        // into the word buffer (its font: bf_*)
                 : st == S_DISP  ? ia[7:0]                                    // echo
                 : st == S_EB1   ? (ech_none ? 8'h30 : ech_q)                 // echo delete
                 : st == S_RCG   ? ech_q                                      // input redrawn (timed input)
                 : st == S_SC0   ? (sc_c == 8'd9 && wxc[cw] != wl[cw] + 16'd1 ? 8'h20 : sc_c)
                 : st == S_DR0   ? dr_c
                 : st == S_MO1   ? more_ch(mo_i)
                 : st == S_FLA2  ? 8'd9                                       // the indent screen_word turns to a space
                 : 8'h20;                                                     // S_DR1: a space of an indent / gap
wire  [1:0] lk_sel = st == S_C_INS ? fsel(bf_font, bf_style) : os_sel;
wire  [7:0] lk_b = lk_c == 8'd9 || lk_c == 8'd11 ? 8'h20 : lk_c;
wire  [6:0] lk_i = lk_b[6:0] - 7'd32;
wire  [3:0] lk_adv = lk_sel == 2'd1 ? advp[lk_i] : advf[lk_i];
wire signed [17:0] lk_1 = lk_sel == 2'd0 || lk_b < 8'd32 || lk_b > 8'd126 ? fw0 : $signed({14'd0, lk_adv}) <<< wide;
wire signed [17:0] lk_w = printable(lk_c) ? lk_1 : lk_c == 8'd9 ? lk_1 + (lk_1 <<< 1) : lk_c == 8'd11 ? lk_1 <<< 1 : 18'sd0;
wire [7:0] in_l;                                       // ZSCII -> Latin-1 as Frotz (zm_latin1, shared with the transcript)
zm_latin1 xl (.z(in_char), .no_xlat(bz), .l(in_l));

function [7:0] more_ch(input [2:0] i);                // "[MORE]"
    case (i)
        3'd0: more_ch = "["; 3'd1: more_ch = "M"; 3'd2: more_ch = "O"; 3'd3: more_ch = "R"; 3'd4: more_ch = "E";
        default: more_ch = "]";
    endcase
endfunction

function [15:0] wprop(input [2:0] w, input [3:0] p);  // get_wind_prop
    case (p)
        4'd0: wprop = wyp[w];  4'd1: wprop = wxp[w];  4'd2: wprop = wys[w];  4'd3: wprop = wxs[w];
        4'd4: wprop = wyc[w];  4'd5: wprop = wxc[w];  4'd6: wprop = wl[w];   4'd7: wprop = wr[w];
        4'd8: wprop = wnr[w];  4'd9: wprop = wnc[w];  4'd10: wprop = wst[w]; 4'd11: wprop = wco[w];
        4'd12: wprop = wfo[w]; 4'd13: wprop = wfs[w]; 4'd14: wprop = wat[w]; default: wprop = wlc[w];
    endcase
endfunction

assign cur_row   = os_y[9:0] - 10'sd1;                 // V1-5: the os cursor cell, 0-based
assign cur_col   = os_x[9:0] - 10'sd1;
assign cur_fg    = os_fg;
assign more_wait = st == S_MO2;
assign fb_rreq   = st == S_SR2 || st == S_PK1;
assign in_ready  = st == S_IDLE;
assign busy      = st != S_IDLE;

integer i;
task push(input [7:0] ret);
    begin rs[rsp] <= ret; rsp <= rsp + 3'd1; end
endtask
task sub_ret;
    begin st <= rs[rsp - 3'd1]; rsp <= rsp - 3'd1; end
endtask
task call(input [7:0] routine, input [7:0] ret);
    begin push(ret); st <= routine; end
endtask
task update_cursor;                                    // the os cursor to the current window's cursor
    begin os_y <= u(wyp[cw]) + u(wyc[cw]) - 18'sd1; os_x <= u(wxp[cw]) + u(wxc[cw]) - 18'sd1; end
endtask
task reset_cursor(input [2:0] w);                      // V1-4 window 0 starts on its last line (font height 1)
    begin
        wyc[w] <= (version <= 4'd4 && w == 3'd0) ? wys[0] : 16'd1;
        wxc[w] <= wl[w] + 16'd1;
        if (w == cw) begin
            os_y <= u(wyp[w]) + ((version <= 4'd4 && w == 3'd0) ? u(wys[0]) : 18'sd1) - 18'sd1;
            os_x <= u(wxp[w]) + u(wl[w]);
        end
    end
endtask
task update_attributes(input [2:0] w);                 // story hacks: Zork Zero r366, Shogun <= r295 wrap in window 0
    begin
        en_wrap   <= wat[w][0] | (w == 3'd0 && ((sid == 4'd3 && rel == 16'd366) || (sid == 4'd4 && rel <= 16'd295)));
        en_scroll <= wat[w][1];
        en_buf    <= wat[w][3];
    end
endtask
task rect_u(input signed [17:0] t, input signed [17:0] l, input signed [17:0] b, input signed [17:0] r);
    begin p_y0 <= pyof(t); p_y1 <= pyof(b + 18'sd1) - 22'sd1; p_x0 <= pxof(l); p_x1 <= pxof(r + 18'sd1) - 22'sd1; end
endtask
task glyph_at_cursor(input [7:0] c);                   // os_display_char: draw at the os cursor, advance it
    begin
        dch <= c; g_y <= pyof(os_y); g_x <= pxof(os_x); os_x <= os_x + lk_1;   // c = lk_b in every caller's state
        g_src <= c >= 8'd32 && c <= 8'd126 ? os_sel : 2'd0;
        g_adv <= lk_adv;
    end
endtask
task pause(input [7:0] at);                            // newline interrupt: save, ask, take the routine's items
    begin
        sh_st <= at; for (i = 0; i < 8; i = i + 1) sh_rs[i] <= rs[i]; sh_rsp <= rsp; sh_ich <= ich;
        sh_icmd <= icmd; sh_iscmd <= iscmd; sh_ia <= ia; sh_ib <= ib; sh_ic <= ic; sh_fl_i <= fl_i;
        sh_fl_char <= fl_char; sh_sc_c <= sc_c; sh_pd_n <= pd_n; sh_pd_send <= pd_send; sh_es_all <= es_all;
        sh_sp_h <= sp_h; sh_sw_w <= sw_w; sh_ew_w <= ew_w; sh_tk_v <= tk_v; sh_pt_x <= pt_x;
        sh_nl_defer <= nl_defer;
        irq <= 1'b1; irq_addr <= wnr[cw]; int_active <= 1'b1; st <= S_IDLE;
    end
endtask
task set_prop(input [2:0] w, input [3:0] p, input [15:0] v);
    case (p)
        4'd0: wyp[w] <= v;  4'd1: wxp[w] <= v;  4'd2: wys[w] <= v;  4'd3: wxs[w] <= v;
        4'd4: wyc[w] <= v;  4'd5: wxc[w] <= v;  4'd6: wl[w] <= v;   4'd7: wr[w] <= v;
        4'd8: wnr[w] <= v;  4'd9: wnc[w] <= v;  4'd10: wst[w] <= v; 4'd11: wco[w] <= v;
        4'd12: wfo[w] <= v; 4'd13: wfs[w] <= v; 4'd14: wat[w] <= v; default: wlc[w] <= v;
    endcase
endtask

always @(posedge clk) begin
    fb_we   <= 1'b0;
    bwe     <= 1'b0;
    ech_we  <= 1'b0;
    snap    <= 1'b0;
    key_ack <= 1'b0;
    nl_irq  <= 1'b0;

    if (reset) begin
        st <= S_IDLE; rsp <= 3'd0; bufpos <= 9'd0; bufw <= 12'd0; prev_c <= 9'd0; f_all <= 1'b0;
        irq <= 1'b0; int_active <= 1'b0; fl_lock <= 1'b0;
    end
    else case (st)

    S_IDLE: if (in_valid) begin
        ich <= in_l; icmd <= in_char[7:0]; iscmd <= in_cmd; ia <= in_arg0; ib <= in_arg1; ic <= in_arg2;
        rsp <= 3'd0; nl_defer <= 1'b0; st <= S_DISP;
        if (in_cmd && in_char[7:0] == CMD_IRET) irq <= 1'b0;   // at once: zm_cpu looks again the next clock
    end
    S_PF0: begin                                       // apply the pending scroll (tail call: returns to our caller)
        p_y0 <= pend_y0; p_y1 <= pend_y1; p_x0 <= pend_x0; p_x1 <= pend_x1; s_n <= pend_n; pend <= 1'b0;
        st <= S_SR0;
    end
    S_UPC: begin update_cursor; sub_ret; end
    S_UA:  begin update_attributes(cw); sub_ret; end

    // ------------------------------------------------ dispatch (Frotz print_char / the screen opcodes)
    S_DISP: begin
        if (pend && (iscmd || ich != 8'd13 || bufpos != 9'd0)) call(S_PF0, S_DISP);   // anything but a bare newline
        else if (!iscmd) begin
            if (ich == 8'd13) call(S_FL0, S_C_NL);
            else if (en_buf) begin
                if (ich == 8'h20 || ich == 8'd9 || ich == 8'd11 || (prev_c == 9'h02D && ich != 8'h2D)) call(S_FL0, S_C_INS);
                else st <= S_C_INS;
            end
            else begin sc_c <= ich; call(S_SC0, S_IDLE); end
        end
        else case (icmd)
            CMD_SBEGIN:     begin sw_w <= 3'd7; call(S_SW0, S_SB1); end
            CMD_SPAD:       begin pd_send <= 1'b0; call(S_FL0, S_PD1); end
            CMD_SEND:       begin pd_send <= 1'b1; ia <= 16'd0; call(S_FL0, S_PD1); end
            CMD_ERASE_WIN:  call(S_FL0, S_EW1);
            CMD_SPLIT:      begin sp_h <= ia; call(S_SP0, S_IDLE); end
            CMD_SETWIN:     begin sw_w <= winarg(ia); call(S_SW0, S_IDLE); end
            CMD_CURSOR:     call(S_FL0, S_CU1);
            CMD_STYLE: begin                           // z_set_text_style + refresh_text_style (no flush)
                if (v6) begin
                    wst[cw] <= ia == 16'd0 ? 16'd0 : wst[cw] | ia;
                    if (en_buf) begin tk_v <= {2'd1, 4'd0, ia == 16'd0 ? 4'd0 : wst[cw][3:0] | ia[3:0]}; call(S_TK0, S_IDLE); end
                    else begin os_style <= ia == 16'd0 ? 4'd0 : wst[cw][3:0] | ia[3:0]; bf_style <= ia == 16'd0 ? 4'd0 : wst[cw][3:0] | ia[3:0]; st <= S_IDLE; end
                end
                else begin
                    wst[0] <= ia == 16'd0 ? 16'd0 : wst[0] | ia;
                    if (en_buf) begin
                        tk_v <= {2'd1, 4'd0, (ia == 16'd0 ? 4'd0 : wst[0][3:0] | ia[3:0]) | (cw != 3'd0 ? ST_FIXED : 4'd0)};
                        call(S_TK0, S_IDLE);
                    end
                    else begin
                        os_style <= (ia == 16'd0 ? 4'd0 : wst[0][3:0] | ia[3:0]) | (cw != 3'd0 ? ST_FIXED : 4'd0);
                        bf_style <= (ia == 16'd0 ? 4'd0 : wst[0][3:0] | ia[3:0]) | (cw != 3'd0 ? ST_FIXED : 4'd0);
                        st <= S_IDLE;
                    end
                end
            end
            CMD_BUFMODE:    if (v6) st <= S_IDLE; else call(S_FL0, S_BM1);   // V6: ignored (Frotz)
            CMD_ERASE_LINE: call(S_FL0, S_EL1);
            CMD_COLOUR:     call(S_FL0, S_CO1);
            CMD_ECHO: begin                            // typed input, drawn at the os cursor as os_read_line would
                if (ia == 16'd13) call(S_NL0, S_IDLE);
                else if (ia == 16'd8) begin
                    ech_none <= ech_n == 8'd0;                 // preloaded text: a width of '0'
                    if (ech_n != 8'd0) begin ech_ra <= ech_n - 8'd1; ech_n <= ech_n - 8'd1; end
                    st <= S_EB0;
                end
                else if (printable(ia[7:0])) begin
                    glyph_at_cursor(ia[7:0]); wxc[cw] <= wxc[cw] + lk_1[15:0]; inw <= inw + lk_1;
                    ech_we <= 1'b1; ech_wc <= ia[7:0]; ech_wa <= ech_n; ech_n <= ech_n + 8'd1;
                    call(S_G0, S_IDLE);
                end
                else st <= S_IDLE;
            end
            CMD_FONT: begin                            // z_set_font: answers the window's previous font (0 = refused)
                if (ia == 16'd0) begin rsp_a <= wfo[v6 ? cw : 3'd0]; st <= S_IDLE; end
                else if (ia == 16'd1 || ia == 16'd3 || ia == 16'd4) begin
                    rsp_a <= wfo[v6 ? cw : 3'd0];
                    wfo[v6 ? cw : 3'd0] <= ia; wfs[v6 ? cw : 3'd0] <= fsz;
                    if (en_buf) begin tk_v <= {2'd2, ia[7:0]}; call(S_TK0, S_IDLE); end
                    else begin os_font <= ia[7:0]; bf_font <= ia[7:0]; st <= S_IDLE; end
                end
                else begin rsp_a <= 16'd0; st <= S_IDLE; end
            end
            CMD_PT_BEGIN:   call(S_FL0, S_PB1);
            CMD_PT_ROW:     call(S_FL0, S_PR1);
            CMD_RESTART:    st <= S_RS1;
            CMD_READ:       call(S_FL0, S_RD1);
            CMD_RCONT:      if (ia != 16'd0) begin snap <= 1'b1; st <= S_IDLE; end else st <= S_RC0;
            CMD_FLUSH:      call(S_FL0, S_IDLE);
            CMD_MWIN:       begin mw_all <= ia == 16'hFFFF; mw <= winarg(ia); st <= S_IDLE; end
            CMD_CLICK:      begin rsp_ok <= mk_in; rsp_a <= mk_rx[15:0]; rsp_b <= mk_ry[15:0]; st <= S_IDLE; end
            CMD_GETCUR:     call(S_FL0, S_GC1);
            CMD_WSIZE:      call(S_FL0, S_WZ1);
            CMD_WMOVE:      call(S_FL0, S_WM1);
            CMD_MARGINS:    call(S_FL0, S_MG1);
            CMD_WSTYLE:     call(S_FL0, S_WT1);
            CMD_PUTPROP:    call(S_FL0, S_PP1);
            CMD_GETPROP:    call(S_FL0, S_GP1);
            CMD_SCROLLW:    call(S_FL0, S_SW_1);
            CMD_MAXW:       call(S_FL0, S_MW1);        // after Frotz z_output_stream's flush
            CMD_DRAWPIC:    call(S_FL0, S_DP0);
            CMD_ERASEPIC:   call(S_FL0, S_EP0);
            CMD_PICDATA:    st <= S_QD0;               // z_picture_data: no flush
            CMD_IRET: begin                            // the routine returned: back to the paused newline
                st <= sh_st; for (i = 0; i < 8; i = i + 1) rs[i] <= sh_rs[i]; rsp <= sh_rsp; ich <= sh_ich;
                icmd <= sh_icmd; iscmd <= sh_iscmd; ia <= sh_ia; ib <= sh_ib; ic <= sh_ic; fl_i <= sh_fl_i;
                fl_char <= sh_fl_char; sc_c <= sh_sc_c; pd_n <= sh_pd_n; pd_send <= sh_pd_send;
                es_all <= sh_es_all; sp_h <= sh_sp_h; sw_w <= sh_sw_w; ew_w <= sh_ew_w; tk_v <= sh_tk_v;
                pt_x <= sh_pt_x; nl_defer <= sh_nl_defer;
                irq <= 1'b0; int_active <= 1'b0;
            end
            default:        st <= S_IDLE;              // sound: not yet
        endcase
    end
    S_EB0: st <= S_EB1;                                // the deleted character's width (ech_q, a clock after ech_ra)
    S_EB1: begin
        os_x <= os_x - lk_w; wxc[cw] <= wxc[cw] - lk_w[15:0]; inw <= inw - lk_w;
        rect_u(os_y, os_x - lk_w, os_y + fh - 18'sd1, os_x - 18'sd1);
        call(S_F0, S_IDLE);
    end
    S_C_NL: begin nl_defer <= 1'b1; call(S_NL0, S_IDLE); end   // a bare newline: its scroll may be deferred
    S_C_INS: begin
        if (bufpos == 9'd256) call(S_FL0, S_C_INS);   // Frotz: buffer overflow error; here: flush early
        else begin
            bwa <= bufpos[7:0]; bwd <= {2'd0, ich}; bwe <= 1'b1;
            bufpos <= bufpos + 9'd1; bufw <= bufw + lk_w[11:0]; prev_c <= {1'b0, ich};
            st <= S_IDLE;
        end
    end
    // V1-3 status line (z_show_status): window 7, reverse + fixed; pad_status_line; back to window 0
    S_SB1: begin tk_v <= {2'd1, 4'd0, ST_REVERSE | ST_FIXED}; call(S_TK0, S_IDLE); end
    S_PD1: begin pd_n <= ul - u(ia); st <= S_PD2; end
    S_PD2: begin
        if (pd_n > 18'sd0) begin pd_n <= pd_n - 18'sd1; sc_c <= 8'h20; call(S_SC0, S_PD2); end
        else if (pd_send) begin sw_w <= 3'd0; call(S_SW0, S_IDLE); end
        else st <= S_IDLE;
    end
    S_EW1: begin                                       // z_erase_window
        if (ia == 16'hFFFF || ia == 16'hFFFE) begin es_all <= ia == 16'hFFFF; call(S_ES0, S_IDLE); end
        else begin ew_w <= winarg(ia); call(S_EWN0, S_IDLE); end
    end
    S_CU1: begin                                       // z_set_cursor (V1-5: window 1, ignored in window 0)
        aw = v6 ? winarg(ic) : 3'd1;
        if (ia[15]) begin
            if (ia == 16'hFFFE) cursor_on <= 1'b1;
            if (ia == 16'hFFFF) cursor_on <= 1'b0;
            st <= S_IDLE;
        end
        else if (!v6 && cw == 3'd0) st <= S_IDLE;
        else begin
            wyc[aw] <= ia == 16'd0 ? wyc[aw] : ia;
            if (u(ib == 16'd0 ? wxc[aw] : ib) <= u(wl[aw]) || u(ib == 16'd0 ? wxc[aw] : ib) > u(wxs[aw]) - u(wr[aw]))
                wxc[aw] <= wl[aw] + 16'd1;
            else wxc[aw] <= ib == 16'd0 ? wxc[aw] : ib;
            if (aw == cw) call(S_UPC, S_IDLE); else st <= S_IDLE;
        end
    end
    S_BM1: begin wat[0][3] <= ia != 16'd0; if (cw == 3'd0) en_buf <= ia != 16'd0; st <= S_IDLE; end   // + update_attributes (cwin's)
    S_EL1: begin                                       // z_erase_line: (arg - 1) units, 0 or too many = units_left (as a zword)
        rect_u(u(wyp[cw] + wyc[cw] - 16'd1), u(wxp[cw] + wxc[cw] - 16'd1),
               u(wyp[cw] + wyc[cw] - 16'd1) + fh - 18'sd1,
               u(wxp[cw] + wxc[cw] - 16'd1) + u((ia == 16'd1 || u(ia - 16'd1) > ul) ? ul[15:0] : ia - 16'd1) - 18'sd1);
        call(S_F0, S_IDLE);
    end
    S_CO1: begin                                       // z_set_colour: -1 = os_peek_colour, 0 keep, 1 default
        if (v6 && (ia == 16'hFFFF || ib == 16'hFFFF)) st <= S_PK0;
        else begin pk_c <= 8'd9; st <= S_CO2; end      // V1-5: stdio's white
    end
    // os_peek_colour (V6): the pixel at the os cursor's top-left, as Amiga Frotz's ReadPixel (Zork Zero's status line
    // is printed in the colour of the scroll under it); off the screen: white
    S_PK0: begin
        if (pk_y < 22'sd0 || pk_y > 22'sd239 || pk_x < 22'sd0 || pk_x > 22'sd639) begin pk_c <= 8'd9; st <= S_CO2; end
        else begin fb_raddr <= row80(pk_y[8:0]) + {8'd0, pk_x[9:3]}; st <= S_PK1; end
    end
    S_PK1: if (fb_grant) st <= S_PK2;
    S_PK2: begin pk_c <= fb_q[{pk_x[2:0], 3'b000} +: 8]; st <= S_CO2; end
    S_CO2: begin                                       // colour = (bg << 8) | fg, as Frotz (a fg above 255 ORs into bg)
        aw = v6 ? winarg(ic) : 3'd0;
        nf = ia == 16'hFFFF ? {8'd0, pk_c} : ia == 16'd0 ? {8'd0, wco[aw][7:0]} : ia == 16'd1 ? {8'd0, def_fg} : ia;
        nb = ib == 16'hFFFF ? {8'd0, pk_c} : ib == 16'd0 ? {8'd0, wco[aw][15:8]} : ib == 16'd1 ? {8'd0, def_bg} : ib;
        if (v6 && amiga && aw == 3'd0)                 // Amiga: window 0's colours change the whole screen (Frotz's own test:
            for (cwi = 1; cwi < 8; cwi = cwi + 1) begin   // a colour < 16 equal to window 0's old FOREGROUND -> fg, else bg)
                b2 = {8'd0, wco[cwi][15:8]}; f2 = {8'd0, wco[cwi][7:0]};
                if (b2 < 16'd16) b2 = b2 == {8'd0, wco[0][7:0]} ? nf : nb;
                if (f2 < 16'd16) f2 = f2 == {8'd0, wco[0][7:0]} ? nf : nb;
                wco[cwi] <= {b2[7:0], 8'd0} | f2;
            end
        wco[aw] <= {nb[7:0], 8'd0} | nf;
        if (aw == cw || !v6) begin os_fg <= nf[7:0]; os_bg <= nb[7:0]; end
        st <= S_IDLE;
    end
    S_PB1: begin pt_x <= wxc[cw]; st <= S_IDLE; end
    S_PR1: begin wyc[cw] <= wyc[cw] + fh[15:0]; wxc[cw] <= pt_x; call(S_UPC, S_IDLE); end
    S_RD1: begin                                       // console_read_input: room for at least 10 characters
        inw <= $signed({10'd0, ib[7:0]}) * fw;
        if (ia == 16'd0 && cw == 3'd0 && ul + $signed({10'd0, ib[7:0]}) * fw < (fw <<< 3) + (fw <<< 1)) call(S_NL0, S_RD2);
        else st <= S_RD2;
    end
    S_RD2: begin
        snap <= 1'b1; ech_n <= 8'd0; in_win <= cw; inp_rd <= 1'b0;
        for (i = 0; i < 8; i = i + 1) wlc[i] <= 16'd0;
        st <= S_IDLE;
    end
    // CMD_RCONT, read (console_read_input continued): room for 10 characters, then screen_write_input if a newline
    // went through the input window (the typed characters at the cursor; preloaded text isn't kept here), then snap
    S_RC0: if (cw == 3'd0 && ul + inw < (fw <<< 3) + (fw <<< 1)) call(S_NL0, S_RC1); else st <= S_RC1;
    S_RC1: begin
        rc_i <= 8'd0;
        if (!inp_rd) st <= S_RC4;
        else if (ul < inw) call(S_NL0, S_RC2);
        else st <= S_RC2;
    end
    S_RC2: if (rc_i == ech_n) st <= S_RC4; else begin ech_ra <= rc_i; st <= S_RC3; end
    S_RC3: st <= S_RCG;                                // ech_q a clock after ech_ra
    S_RCG: begin glyph_at_cursor(ech_q); wxc[cw] <= wxc[cw] + lk_1[15:0]; rc_i <= rc_i + 8'd1; call(S_G0, S_RC2); end
    S_RC4: begin inp_rd <= 1'b0; snap <= 1'b1; st <= S_IDLE; end
    S_RS1: begin                                       // restart_screen (the version first: it sets the units)
        version <= ia[3:0]; v6 <= ia[3:0] == 4'd6; bz <= ib[3:0] == 4'd2; sid <= ib[3:0]; rel <= ic;
        os_fg <= def_fg; os_bg <= def_bg; os_font <= 8'd1; os_style <= 4'd0; bf_font <= 8'd1; bf_style <= 4'd0; cursor_on <= 1'b1;
        cw <= 3'd0; bufpos <= 9'd0; bufw <= 12'd0; prev_c <= 9'd0; mw <= 3'd1; mw_all <= 1'b0;
        p_y0 <= 22'sd0; p_y1 <= 22'sd239; p_x0 <= 22'sd0; p_x1 <= 22'sd639; f_all <= 1'b1;
        call(S_F0, S_RS2);                             // the whole raster (V6 leaves a border) in the default colour
    end
    S_RS2: begin
        f_all <= 1'b0;
        for (i = 0; i < 8; i = i + 1) begin
            wyp[i] <= 16'd1; wxp[i] <= 16'd1; wys[i] <= 16'd0; wxs[i] <= 16'd0; wyc[i] <= 16'd1; wxc[i] <= 16'd1;
            wl[i] <= 16'd0; wr[i] <= 16'd0; wnr[i] <= 16'd0; wnc[i] <= 16'd0; wst[i] <= 16'd0;
            wco[i] <= {def_bg, def_fg}; wfo[i] <= 16'd1; wfs[i] <= fsz; wat[i] <= 16'd8; wlc[i] <= 16'd0;
        end
        st <= S_RS3;
    end
    S_RS3: begin
        wat[0] <= 16'd15; wxs[0] <= scr_w; wxs[1] <= scr_w;
        if (version <= 4'd3) wxs[7] <= scr_w;
        es_all <= 1'b1; call(S_ES0, S_IDLE);          // erase_screen (-1)
    end
    // V6 window opcodes (after the flush)
    S_GC1: begin rsp_a <= wyc[cw]; rsp_b <= wxc[cw]; st <= S_IDLE; end   // get_cursor (1x1 units: no conversion)
    S_WZ1: begin                                       // window_size; the cursor kept inside
        aw = winarg(ia);
        wys[aw] <= ib; wxs[aw] <= ic;
        if (wyc[aw] > ib || wxc[aw] > ic) reset_cursor(aw);
        st <= S_IDLE;
    end
    S_WM1: begin                                       // move_window
        aw = winarg(ia);
        wyp[aw] <= ib; wxp[aw] <= ic;
        if (aw == cw) call(S_UPC, S_IDLE); else st <= S_IDLE;
    end
    S_MG1: begin                                       // set_margins; the cursor kept inside
        aw = winarg(ic);
        wl[aw] <= ia; wr[aw] <= ib;
        if (u(wxc[aw]) <= u(ia) || u(wxc[aw]) > u(wxs[aw]) - u(ib)) begin
            wxc[aw] <= ia + 16'd1;
            if (aw == cw) call(S_UPC, S_IDLE); else st <= S_IDLE;
        end
        else st <= S_IDLE;
    end
    S_WT1: begin                                       // window_style: 0 set, 1 or, 2 clear, 3 toggle
        aw = winarg(ia);
        if (ic[15:2] == 14'd0)                         // other operations: no change (Frotz's switch)
            case (ic[1:0])
                2'd0: wat[aw] <= ib;
                2'd1: wat[aw] <= wat[aw] | ib;
                2'd2: wat[aw] <= wat[aw] & ~ib;
                default: wat[aw] <= wat[aw] ^ ib;
            endcase
        if (aw == cw) call(S_UA, S_IDLE); else st <= S_IDLE;
    end
    S_PP1: begin if (ib < 16'd16) set_prop(winarg(ia), ib[3:0], ic); st <= S_IDLE; end   // put_wind_prop (no side effects)
    // a zm_pic request (pic_op, pic_num, pic_py, pic_px set): its answer in pic_ok / pic_h / pic_w
    S_PC0: begin pic_req <= 1'b1; st <= S_PC1; end
    S_PC1: begin pic_req <= 1'b0; st <= S_PC2; end
    S_PC2: if (!pic_busy) sub_ret;
    // z_draw_picture: 0 = the cursor; window-relative; the mapper's pieces first (at the picture's foot), Shogun's 59
    S_DP0: begin
        dp_y <= (ib == 16'd0 ? wyc[cw] : ib) + wyp[cw] - 16'd1;
        dp_x <= (ic == 16'd0 ? wxc[cw] : ic) + wxp[cw] - 16'd1;
        if (pm_1 != 16'd0) begin pic_op <= 1'b0; pic_num <= ia; call(S_PC0, S_DP1); end
        else st <= S_DP5;
    end
    S_DP1: begin mh1 <= pic_h; mw1 <= pic_w; pic_num <= pm_2; call(S_PC0, S_DP2); end
    S_DP2: begin
        mh2 <= pic_h; mw2 <= pic_w; pic_op <= 1'b1; pic_num <= pm_1;
        pic_py <= pyof(u(dp_y) + u(mh1)); pic_px <= pxof(u(dp_x) + (sid == 4'd5 ? (wide ? 18'sd4 : 18'sd2) : 18'sd0));
        call(S_PC0, S_DP3);
    end
    S_DP3: begin
        pic_num <= pm_2;
        pic_py <= pyof(u(dp_y) + u(mh1)); pic_px <= pxof(u(dp_x) + u(mw1) - u(mw2) - (sid == 4'd5 ? (wide ? 18'sd4 : 18'sd2) : 18'sd0));
        call(S_PC0, S_DP5);
    end
    S_DP5: begin pic_op <= 1'b1; pic_num <= ia; pic_py <= pyof(u(dp_y)); pic_px <= pxof(u(dp_x)); call(S_PC0, S_DP6); end
    S_DP6: if (sid == 4'd4 && ia == 16'd3) begin pic_op <= 1'b0; pic_num <= 16'd59; call(S_PC0, S_DP7); end else st <= S_IDLE;
    S_DP7: begin pic_op <= 1'b1; pic_py <= pyof(u(dp_y)); pic_px <= pxof(u(scr_w) - u(pic_w) + 18'sd1); call(S_PC0, S_IDLE); end
    // z_erase_picture: the picture's area in the background colour (nothing if there is no such picture)
    S_EP0: begin
        dp_y <= (ib == 16'd0 ? wyc[cw] : ib) + wyp[cw] - 16'd1;
        dp_x <= (ic == 16'd0 ? wxc[cw] : ic) + wxp[cw] - 16'd1;
        pic_op <= 1'b0; pic_num <= ia; call(S_PC0, S_EP1);
    end
    S_EP1: begin rect_u(u(dp_y), u(dp_x), u(dp_y) + u(pic_h) - 18'sd1, u(dp_x) + u(pic_w) - 18'sd1); call(S_F0, S_IDLE); end
    // z_picture_data: a mapped picture adds its piece's height and needs both pieces; a piece alone isn't available
    S_QD0: begin pic_op <= 1'b0; pic_num <= ia; call(S_PC0, S_QD1); end
    S_QD1: begin
        rsp_a <= pic_h; rsp_b <= pic_w; rsp_ok <= pic_ok && !piece(ia);
        if (pm_1 != 16'd0) begin mok <= pic_ok; pic_num <= pm_1; call(S_PC0, S_QD2); end
        else st <= S_IDLE;
    end
    S_QD2: begin mok <= mok & pic_ok; pic_num <= pm_2; call(S_PC0, S_QD3); end
    S_QD3: begin rsp_ok <= mok & pic_ok; rsp_a <= rsp_a + pic_h; st <= S_IDLE; end
    S_MW1: begin rsp_a <= wxs[ia[2:0]] - wl[ia[2:0]] - wr[ia[2:0]]; st <= S_IDLE; end
    S_GP1: begin rsp_a <= ib < 16'd16 ? wprop(winarg(ia), ib[3:0]) : 16'd0; st <= S_IDLE; end   // get_wind_prop
    S_SW_1: begin                                      // scroll_window: another window's colours while it scrolls (not Amiga)
        ew_w <= winarg(ia);
        if (!amiga && winarg(ia) != cw) begin os_fg <= wco[winarg(ia)][7:0]; os_bg <= wco[winarg(ia)][15:8]; end
        st <= S_SW_2;
    end
    S_SW_2: begin
        rect_u(u(wyp[ew_w]), u(wxp[ew_w]), u(wyp[ew_w]) + u(wys[ew_w]) - 18'sd1, u(wxp[ew_w]) + u(wxs[ew_w]) - 18'sd1);
        s_n <= v6 ? $signed({{6{ib[15]}}, ib}) : $signed({{6{ib[15]}}, ib}) * 22'sd8;
        call(S_SR0, S_SW_3);
    end
    S_SW_3: begin
        if (!amiga && ew_w != cw) begin os_fg <= wco[cw][7:0]; os_bg <= wco[cw][15:8]; end
        st <= S_IDLE;
    end

    // ------------------------------------------------ flush_buffer + screen_word
    S_FL0: begin
        if (bufpos == 9'd0 || fl_lock) sub_ret;
        else begin fl_lock <= 1'b1; fl_i <= 9'd0; bra <= 8'd0; st <= S_FLA; end
    end
    S_FLA: st <= S_FLA2;
    S_FLA2: begin                                      // screen_word: an indent away from the line start is a space
        if (brd == 10'h009 && wxc[cw] != wl[cw] + 16'd1) begin
            fl_i <= 9'd1; bufw <= bufw - lk_w[11:0]; sc_c <= 8'h20; call(S_SC0, S_FLB);
        end
        else st <= S_FLB;
    end
    S_FLB: begin
        if (ul < $signed({6'd0, bufw})) begin
            if (!en_wrap) begin fl_char <= 1'b1; st <= S_FLL; end
            else begin bra <= fl_i[7:0]; st <= S_FL1; end
        end
        else begin fl_char <= 1'b0; st <= S_FLL; end
    end
    S_FL1: st <= S_FL2;
    S_FL2: begin                                       // wrap: a leading space / indent / gap is dropped
        if (brd == 10'h020 || brd == 10'h009 || brd == 10'h00B) fl_i <= fl_i + 9'd1;
        fl_char <= 1'b0;
        call(S_NL0, S_FLL);
    end
    S_FLL: begin
        if (fl_i == bufpos) begin bufpos <= 9'd0; bufw <= 12'd0; prev_c <= 9'd0; fl_lock <= 1'b0; sub_ret; end
        else begin bra <= fl_i[7:0]; st <= S_FLL1; end
    end
    S_FLL1: st <= S_FLL2;
    S_FLL2: begin
        fl_i <= fl_i + 9'd1;
        if (brd[9:8] == 2'd1) begin os_style <= brd[3:0]; st <= S_FLL; end
        else if (brd[9:8] == 2'd2) begin os_font <= brd[7:0]; st <= S_FLL; end
        else if (fl_char) begin sc_c <= brd[7:0]; call(S_SC0, S_FLL); end
        else if (haswidth(brd[7:0])) begin dr_c <= brd[7:0]; call(S_DR0, S_FLL); end
        else st <= S_FLL;
    end

    // screen_char (sc_c; an indent away from the line start is a space)
    S_SC0: begin
        if (sc_c == 8'd9 && wxc[cw] != wl[cw] + 16'd1) sc_c <= 8'h20;
        if (ul < lk_w) begin                          // lk_c: sc_c, an indent away from the line start as a space
            if (!en_wrap) begin wxc[cw] <= wxs[cw] - wr[cw]; sub_ret; end
            else begin push(S_SC1); st <= S_NL0; end
        end
        else st <= S_SC1;
    end
    S_SC1: begin
        if (haswidth(sc_c)) begin dr_c <= sc_c; st <= S_DR0; end
        else sub_ret;
    end
    // os_display_char (dr_c) at the os cursor, advancing it and the window cursor: an indent / gap is 3 / 2 spaces
    S_DR0: begin
        dr_n <= dr_c == 8'd9 ? 2'd2 : dr_c == 8'd11 ? 2'd1 : 2'd0;
        glyph_at_cursor(dr_c == 8'd9 || dr_c == 8'd11 ? 8'h20 : dr_c); wxc[cw] <= wxc[cw] + lk_1[15:0];
        call(S_G0, S_DR1);
    end
    S_DR1: begin
        if (dr_n != 2'd0) begin
            dr_n <= dr_n - 2'd1; glyph_at_cursor(8'h20); wxc[cw] <= wxc[cw] + lk_1[15:0];
            call(S_G0, S_DR1);
        end
        else sub_ret;
    end

    // screen_new_line: countdown (at the start; Zork Zero r393 under DOS: at the end), next line or scroll,
    // update_cursor, then the [MORE] check (line_count -999 = never)
    S_NL0: begin
        if (pend && !(nl_defer && pend_same)) call(S_PF0, S_NL0);
        else if (!(v6 && zz393) && wnc[cw] != 16'd0) begin
            wnc[cw] <= wnc[cw] - 16'd1;
            if (wnc[cw] == 16'd1 && wnr[cw] != 16'd0) begin
                if (int_active) begin nl_irq <= 1'b1; st <= S_NL0B; end else pause(S_NL0B);
            end
            else st <= S_NL0B;
        end
        else st <= S_NL0B;
    end
    S_NL0B: begin
        wxc[cw] <= wl[cw] + 16'd1;
        if (cw == in_win) inp_rd <= 1'b1;              // Frotz screen_new_line: the input line may be gone
        if (u(wyc[cw]) + fh + fh - 18'sd1 > u(wys[cw])) begin
            if (en_scroll && nl_defer) begin         // font_height = 8 pixel rows (V6: 8 units, V1-5: 1 cell)
                if (!pend) begin pend_y0 <= cwr_y0; pend_y1 <= cwr_y1; pend_x0 <= cwr_x0; pend_x1 <= cwr_x1; end
                pend_n <= !pend ? 22'sd8 : pend_n < 22'sd240 ? pend_n + 22'sd8 : pend_n;   // saturates: >= 240 = all of it
                pend <= 1'b1;
                st <= S_NL1;
            end
            else if (en_scroll) begin
                rect_u(u(wyp[cw]), u(wxp[cw]), u(wyp[cw]) + u(wys[cw]) - 18'sd1, u(wxp[cw]) + u(wxs[cw]) - 18'sd1);
                s_n <= 22'sd8;
                call(S_SR0, S_NL1);
            end
            else begin wyc[cw] <= 16'd1; st <= S_NL1; end
        end
        else begin wyc[cw] <= wyc[cw] + fh[15:0]; st <= S_NL1; end
    end
    S_NL1: begin update_cursor; st <= S_NL2; end
    S_NL2: begin
        if (en_scroll && wlc[cw] != 16'hFC19) begin
            if (nl_more) begin wlc[cw] <= 16'd0; if (!more_en) st <= S_NL3; else if (pend) call(S_PF0, S_MO0); else st <= S_MO0; end
            else begin wlc[cw] <= nl_lc1; st <= S_NL3; end
        end
        else st <= S_NL3;
    end
    S_NL3: begin
        if (v6 && zz393 && wnc[cw] != 16'd0) begin
            wnc[cw] <= wnc[cw] - 16'd1;
            if (wnc[cw] == 16'd1 && wnr[cw] != 16'd0) begin
                if (int_active) begin nl_irq <= 1'b1; sub_ret; end else pause(S_NL4);
            end
            else sub_ret;
        end
        else sub_ret;
    end
    S_NL4: sub_ret;
    // os_more_prompt: "[MORE]" in style 0 at the os cursor, a key, the prompt erased, the cursor back
    S_MO0: begin mo_style <= os_style; os_style <= 4'd0; mo_i <= 3'd0; mo_x <= os_x; st <= S_MO1; end
    S_MO1: begin
        if (mo_i == 3'd6) begin snap <= 1'b1; st <= S_MO2; end
        else begin glyph_at_cursor(more_ch(mo_i)); mo_i <= mo_i + 3'd1; call(S_G0, S_MO1); end
    end
    S_MO2: if (key_valid && !key_ack) begin key_ack <= 1'b1; st <= S_MO3; end
    S_MO3: begin rect_u(os_y, mo_x, os_y + fh - 18'sd1, os_x - 18'sd1); call(S_F0, S_MO4); end
    S_MO4: begin os_x <= mo_x; os_style <= mo_style; st <= S_NL3; end

    // set_window (sw_w): flush, select, attributes; V6: the window's colours, font and style; V1-5:
    // refresh_text_style and window 1 / 7 cursor to 1,1; then update_cursor
    S_SW0: call(S_FL0, S_SW1);
    S_SW1: begin
        cw <= sw_w;
        update_attributes(sw_w);
        if (v6) begin
            os_fg <= wco[sw_w][7:0]; os_bg <= wco[sw_w][15:8];
            if (wfo[sw_w] == 16'd1 || wfo[sw_w] == 16'd3 || wfo[sw_w] == 16'd4) begin os_font <= wfo[sw_w][7:0]; bf_font <= wfo[sw_w][7:0]; end
            os_style <= wst[sw_w][3:0]; bf_style <= wst[sw_w][3:0];
            st <= S_SW3;
        end
        else if (wat[sw_w][3]) begin tk_v <= {2'd1, 4'd0, wst[0][3:0] | (sw_w != 3'd0 ? ST_FIXED : 4'd0)}; call(S_TK0, S_SW3); end
        else begin os_style <= wst[0][3:0] | (sw_w != 3'd0 ? ST_FIXED : 4'd0); bf_style <= wst[0][3:0] | (sw_w != 3'd0 ? ST_FIXED : 4'd0); st <= S_SW3; end
    end
    S_SW3: begin if (!v6 && cw != 3'd0) begin wyc[cw] <= 16'd1; wxc[cw] <= 16'd1; end st <= S_SW4; end
    S_SW4: begin update_cursor; sub_ret; end

    // a style / font token into the word buffer (print_char of ZC_NEW_STYLE / ZC_NEW_FONT + its argument)
    S_TK0: if (prev_c == 9'h02D || bufpos == 9'd256) call(S_FL0, S_TK1); else st <= S_TK1;
    S_TK1: begin
        bwa <= bufpos[7:0]; bwd <= tk_v; bwe <= 1'b1; bufpos <= bufpos + 9'd1; prev_c <= 9'h101;
        if (tk_v[9:8] == 2'd1) bf_style <= tk_v[3:0]; else bf_font <= tk_v[7:0];
        sub_ret;
    end

    // erase_window (ew_w): in another window's colours (V6, not Amiga), cursor reset, line count 0
    S_EWN0: begin
        if (v6 && !amiga && ew_w != cw) begin os_fg <= wco[ew_w][7:0]; os_bg <= wco[ew_w][15:8]; end
        rect_u(u(wyp[ew_w]), u(wxp[ew_w]), u(wyp[ew_w]) + u(wys[ew_w]) - 18'sd1, u(wxp[ew_w]) + u(wxs[ew_w]) - 18'sd1);
        call(S_F0, S_EWN1);
    end
    S_EWN1: begin
        if (v6 && !amiga && ew_w != cw) begin os_fg <= wco[cw][7:0]; os_bg <= wco[cw][15:8]; end
        st <= S_EWN2;
    end
    S_EWN2: begin reset_cursor(ew_w); wlc[ew_w] <= 16'd0; sub_ret; end

    // split_window (sp_h; V1-5 in lines of font height 1, V3 below the status line)
    S_SP0: call(S_FL0, S_SP1);
    S_SP1: begin
        wyc[1] <= wyc[1] + wyp[1] - 16'd1 - (version <= 4'd3 ? 16'd1 : 16'd0);
        wyp[1] <= version <= 4'd3 ? 16'd2 : 16'd1; wys[1] <= sp_h;
        wyc[0] <= wyc[0] + wyp[0] - 16'd1 - (version <= 4'd3 ? 16'd1 : 16'd0) - sp_h;
        wyp[0] <= (version <= 4'd3 ? 16'd2 : 16'd1) + sp_h; wys[0] <= scr_h - (version <= 4'd3 ? 16'd1 : 16'd0) - sp_h;
        st <= S_SP2;
    end
    S_SP2: begin
        if ($signed(wyc[1]) > $signed(wys[1])) reset_cursor(3'd1);
        st <= S_SP3;
    end
    S_SP3: begin
        if ($signed(wyc[0]) < 16'sd1) reset_cursor(3'd0);
        if (version == 4'd3 && sp_h != 16'd0) begin ew_w <= 3'd1; st <= S_EWN0; end
        else sub_ret;
    end

    // erase_screen (es_all: -1 also unsplits, selects window 0 and resets its cursor)
    S_ES0: begin
        for (i = 0; i < 8; i = i + 1) wlc[i] <= 16'd0;
        rect_u(18'sd1, 18'sd1, u(scr_h), u(scr_w));
        call(S_F0, S_ES1);
    end
    S_ES1: if (es_all) begin sp_h <= 16'd0; call(S_SP0, S_ES2); end else sub_ret;
    S_ES2: begin sw_w <= 3'd0; call(S_SW0, S_ES3); end
    S_ES3: begin reset_cursor(3'd0); sub_ret; end

    // ------------------------------------------------ pixels: one glyph (dch) at g_y, g_x, clipped
    S_G0: begin gi <= 3'd0; st <= S_G1; end
    S_G1: begin
        font_a <= g_src != 2'd0 ? {2'b10, g_src == 2'd2, dch[6:0], gi}
                : (have_cell && os_font != 8'd3 && dch >= 8'd32 && dch < 8'd127) ? {2'b11, dch, gi}   // Topaz
                : {1'b0, os_font == 8'd3, dch, gi};
        st <= S_G2;
    end
    S_G2: st <= S_G3;
    S_G3: begin                                        // the cell's row over up to 3 words, each written only where it has pixels
        if (g_yok && g_w0ok && g_mk[7:0] != 8'd0) begin
            fb_addr <= row80(g_yr[8:0]) + {8'd0, g_w0[6:0]}; fb_wdata <= g_sh[63:0]; fb_be <= g_mk[7:0]; fb_we <= 1'b1;
        end
        g_hi <= g_sh[127:64]; g_hi2 <= g_sh[191:128]; g_mk1 <= g_mk[15:8]; g_mk2 <= g_mk[23:16];
        if (g_mk[23:8] != 16'd0) st <= S_G4;
        else begin gi <= gi + 3'd1; if (gi == 3'd7) sub_ret; else st <= S_G1; end
    end
    S_G4: begin
        if (g_yok && g_w1ok && g_mk1 != 8'd0) begin
            fb_addr <= row80(g_yr[8:0]) + {8'd0, g_w1[6:0]}; fb_wdata <= g_hi; fb_be <= g_mk1; fb_we <= 1'b1;
        end
        if (g_mk2 != 8'd0) st <= S_G5;
        else begin gi <= gi + 3'd1; if (gi == 3'd7) sub_ret; else st <= S_G1; end
    end
    S_G5: begin
        if (g_yok && g_w2ok) begin
            fb_addr <= row80(g_yr[8:0]) + {8'd0, g_w2[6:0]}; fb_wdata <= g_hi2; fb_be <= g_mk2; fb_we <= 1'b1;
        end
        gi <= gi + 3'd1;
        if (gi == 3'd7) sub_ret; else st <= S_G1;
    end

    // fill the rectangle p_* (clipped) with os_bg
    S_F0: begin
        if (q_empty) sub_ret;
        else begin
            fy <= q_y0[8:0]; fy1 <= q_y1[8:0]; fx0 <= q_x0[9:0]; fx1 <= q_x1[9:0]; fwd <= q_x0[9:3];
            st <= S_F1;
        end
    end
    S_F1: begin
        fb_addr <= row80(fy) + {8'd0, fwd}; fb_wdata <= {8{os_bg}}; fb_be <= wmask(fwd, fx0, fx1); fb_we <= 1'b1;
        if (fwd == fx1[9:3]) begin
            fwd <= fx0[9:3];
            if (fy == fy1) sub_ret; else fy <= fy + 9'd1;
        end
        else fwd <= fwd + 7'd1;
    end

    // scroll the rectangle p_* (clipped) by s_n pixel rows (> 0 up, < 0 down), then fill what's uncovered: os_scroll_area
    S_SR0: begin
        if (q_empty || s_n == 22'sd0) sub_ret;
        else if (s_abs >= q_h) st <= S_F0;            // everything scrolls out: a fill
        else begin
            fx0 <= q_x0[9:0]; fx1 <= q_x1[9:0]; fwd <= q_x0[9:3];
            s_up <= !s_n[21];
            if (!s_n[21]) begin sy <= q_y0[8:0]; sy_end <= q_y1[8:0] - s_n[8:0]; sr_lim <= q_y1[8:0]; end
            else begin sy <= q_y1[8:0]; sy_end <= q_y0[8:0] + s_abs[8:0]; sr_lim <= q_y0[8:0]; end
            st <= S_SR1;
        end
    end
    S_SR1: begin fb_raddr <= row80(sy + s_n[8:0]) + {8'd0, fwd}; st <= S_SR2; end   // source row = sy + s_n
    S_SR2: if (fb_grant) st <= S_SR3;
    S_SR3: begin
        fb_addr <= row80(sy) + {8'd0, fwd}; fb_wdata <= fb_q; fb_be <= wmask(fwd, fx0, fx1); fb_we <= 1'b1;
        if (fwd == fx1[9:3]) begin
            fwd <= fx0[9:3];
            if (sy == sy_end) st <= S_SR4;
            else begin sy <= s_up ? sy + 9'd1 : sy - 9'd1; st <= S_SR1; end
        end
        else begin fwd <= fwd + 7'd1; st <= S_SR1; end
    end
    S_SR4: begin                                       // the uncovered rows
        if (s_up) begin p_y0 <= $signed({13'd0, sy_end}) + 22'sd1; p_y1 <= $signed({13'd0, sr_lim}); end
        else begin p_y0 <= $signed({13'd0, sr_lim}); p_y1 <= $signed({13'd0, sy_end}) - 22'sd1; end
        st <= S_F0;
    end

    default: st <= S_IDLE;
    endcase
end

endmodule
