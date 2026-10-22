// zm_pic - V6 pictures from Infocom's own picture files, as Amiga Frotz amiga.c (LoadGraphicsFile / os_picture_data /
// os_draw_picture) and tools/infocom_pic.py (the model, checked on all 2180 pictures of the four games).
//   Files (Load Graphics, F2; ioctl extension index: 0 .mg1, 1 .eg1/.eg2 (part = byte 0), 2 .cg1, 3 Blorb)
//   go to DDR3 4 MB + slot * 1 MB: slot 0 MG1, 1 EG1, 2 EG2, 3 CG1, 4 Blorb. A file: 16-byte little-endian header
//   (word 4 picture count, byte 8 directory entry size, word 14 version), then entries: number, width, height,
//   flags (words), 3-byte big-endian data offset, + 3-byte palette offset when the entry is 14 bytes (MCGA).
//   Set: the OSD's Graphics option (sel: 0 Auto, 1 MG1, 2 Blorb, 3 EGA, 4 CGA); one that isn't loaded = Auto, which
//   takes MG1, Blorb, EGA, CGA in that order (a Blorb without pictures - sounds only - doesn't count). MCGA and Blorb =
//   320 x 200 units (each picture pixel 2 raster pixels wide), EGA / CGA = 640 x 200 (1:1).
//   Blorb (FORM IFRS; Infocom's are the MG1 pictures as PNG, same numbers, sizes and colour values): RIdx entry
//   'Pict' n -> a chunk: 'Rect' w, h = a placeholder (size only), or 'PNG ' (palette, 2 / 4 bit) decoded by
//   png_decode: index v -> 16 + v as MCGA, alpha 0 (tRNS) not drawn; PLTE entries 2..15 loaded unless the picture is
//   in APal (adaptive palette = MG1's pictures without one). Picture 0: the Pict count, RelN as the version.
//   Data offset 0 = a placeholder: its size, nothing drawn (Zork Zero 357.., Shogun 2, 45.., Arthur 5, 8..).
//   Data: LZW, 9..12-bit codes LSB first, 256 = clear, 257 = end; one value per pixel (CGA without flag bit 0: one
//   value = 8 pixels, bitmask MSB first, ceil(width / 8) values a row). Flags bit 0: value (flags >> 12) is transparent.
//   Colours (framebuffer values, zm_video's palette): MCGA value v -> 16 + v (16 black, 17 white, 18..31 = the
//   picture palettes: a picture's palette - a count byte, then RGB triples for colours 2.. - is loaded into them when
//   it is drawn, the whole screen sharing it as on the MCGA); EGA v -> 32 + v (the 16 EGA colours); CGA 2 / 3 / bit 1
//   -> white (Z 9), 3 / bit 0 -> black (Z 2).
// Requests (zm_disp): req with op 0 = picture data (r_ok, r_h, r_w in units; picture 0 = count and version),
// op 1 = draw at raster pixel (py, px), clipped to the V6 screen (rows V6_TOP .. V6_TOP + 199). busy until done.
module zm_pic #(
    parameter V6_TOP = 20
) (
    input  wire        clk,
    input  wire        reset,

    input  wire        gdl,                            // a picture file download is in progress ...
    input  wire        gwr,                            // ... and a byte of it
    input  wire [24:0] gaddr,
    input  wire  [7:0] gdata,
    input  wire  [1:0] gext,                           // ioctl_index[7:6]: which extension
    output wire        gdl_wr,                         // to zm_mem: the byte at its DDR3 address
    output wire [24:0] gdl_addr,

    output reg         g_rd_req = 1'b0,                // DDR3 byte reads (zm_ddr's second reader)
    output reg  [24:0] g_rd_addr = 25'd0,
    input  wire  [7:0] g_rd_data,
    input  wire        g_rd_ack,

    input  wire  [2:0] sel,
    input  wire        mcga2,                          // 640-unit layout (Topaz): MCGA widths reported doubled
    output wire  [1:0] gset,                            // 0 none, 1 MCGA, 2 EGA, 3 CGA
    output wire        have_blb,                        // a Blorb is in (slot 4): zm_snd's sounds

    input  wire        req,
    input  wire        op,
    input  wire [15:0] pic,
    input  wire signed [21:0] py,
    input  wire signed [21:0] px,
    output wire        busy,
    output reg         r_ok = 1'b0,
    output reg  [15:0] r_h = 16'd0,
    output reg  [15:0] r_w = 16'd0,

    output reg         pal_we = 1'b0,                  // to zm_video: palette colour pal_i (2..15) = pal_rgb
    output reg   [3:0] pal_i = 4'd0,
    output reg  [23:0] pal_rgb = 24'd0,

    output reg         fb_we = 1'b0,
    output reg  [14:0] fb_addr = 15'd0,
    output reg  [63:0] fb_wdata = 64'd0,
    output reg   [7:0] fb_be = 8'd0
);

// ------------------------------------------------ download: slot, header fields, loaded
reg  [2:0] dslot = 3'd0;
reg  [4:0] loaded = 5'd0;
reg [15:0] f_cnt [0:4];
reg  [7:0] f_esz [0:4];
reg [15:0] f_ver [0:4];
reg        gdl_d = 1'b0, got = 1'b0;                   // got: the download had bytes (an empty one loads nothing)
wire [2:0] slot_now = gaddr != 25'd0 ? dslot : gext == 2'd0 ? 3'd0 : gext == 2'd1 ? (gdata == 8'd2 ? 3'd2 : 3'd1) : gext == 2'd2 ? 3'd3 : 3'd4;
assign gdl_wr   = gdl && gwr && gaddr < 25'h100000;
assign gdl_addr = 25'h400000 + {2'd0, slot_now, 20'd0} + {5'd0, gaddr[19:0]};

always @(posedge clk) begin
    gdl_d <= gdl;
    if (gdl && !gdl_d) got <= 1'b0;
    if (gdl && gwr) begin
        got <= 1'b1;
        if (gaddr == 25'd0) begin dslot <= slot_now; loaded[slot_now] <= 1'b0; end
        if (gaddr == 25'd4)  f_cnt[slot_now][7:0]  <= gdata;
        if (gaddr == 25'd5)  f_cnt[slot_now][15:8] <= gdata;
        if (gaddr == 25'd8)  f_esz[slot_now]       <= gdata;
        if (gaddr == 25'd14) f_ver[slot_now][7:0]  <= gdata;
        if (gaddr == 25'd15) f_ver[slot_now][15:8] <= gdata;
    end
    if (gdl_d && !gdl && got) loaded[dslot] <= 1'b1;
end

// Blorb (slot 4): its top-level chunks walked as they arrive: RIdx (its count, the Pict entries counted), APal, RelN
reg [19:0] bw_nxt = 20'd0, ri_end = 20'd0, b_apal = 20'd0, b_reln = 20'hFFFFF;
reg [55:0] bw_sh = 56'd0;                              // the bytes before this one
reg  [3:0] ri_ph = 4'd0;                               // byte of a 12-byte RIdx entry
reg [15:0] b_ridn = 16'd0, b_pcnt = 16'd0, b_apn = 16'd0, b_rel = 16'd0;
wire [63:0] bw_hdr = {bw_sh, gdata};
wire [19:0] ga = gaddr[19:0];
always @(posedge clk) if (gdl && gwr && slot_now == 3'd4) begin
    bw_sh <= {bw_sh[47:0], gdata};
    if (gaddr == 25'd22) b_ridn[15:8] <= gdata;
    if (gaddr == 25'd23) b_ridn[7:0]  <= gdata;
    if (ga == bw_nxt + 20'd7) begin                    // a chunk header: type, length
        if (bw_hdr[63:32] == "RIdx") ri_end <= bw_nxt + 20'd8 + bw_hdr[19:0];
        if (bw_hdr[63:32] == "APal") begin b_apal <= bw_nxt + 20'd8; b_apn <= bw_hdr[17:2]; end
        if (bw_hdr[63:32] == "RelN") b_reln <= bw_nxt + 20'd8;
        bw_nxt <= bw_nxt + 20'd8 + bw_hdr[19:0] + {19'd0, bw_hdr[0]};
    end
    if (ga == b_reln) b_rel[15:8] <= gdata;
    if (ga == b_reln + 20'd1) b_rel[7:0] <= gdata;
    if (ga >= 20'd24 && ga < ri_end) begin
        ri_ph <= ri_ph == 4'd11 ? 4'd0 : ri_ph + 4'd1;
        if (ri_ph == 4'd3 && bw_hdr[31:0] == "Pict") b_pcnt <= b_pcnt + 16'd1;
    end
    if (gaddr == 25'd0) begin
        bw_nxt <= 20'd12; ri_end <= 20'd0; b_apn <= 16'd0; b_reln <= 20'hFFFFF; b_rel <= 16'd0; b_pcnt <= 16'd0; ri_ph <= 4'd0;
    end
end

assign have_blb = loaded[4];
wire       blbp = loaded[4] && b_pcnt != 16'd0;       // a Blorb with pictures
// kind in sel's numbering: 1 MG1, 2 Blorb, 3 EGA, 4 CGA
wire [2:0] auto_k = loaded[0] ? 3'd1 : blbp ? 3'd2 : loaded[1] ? 3'd3 : loaded[3] ? 3'd4 : 3'd0;
wire [2:0] kind = sel == 3'd1 && loaded[0] ? 3'd1 : sel == 3'd2 && blbp ? 3'd2 : sel == 3'd3 && loaded[1] ? 3'd3
                : sel == 3'd4 && loaded[3] ? 3'd4 : auto_k;
assign gset = kind == 3'd1 || kind == 3'd2 ? 2'd1 : kind == 3'd3 ? 2'd2 : kind == 3'd4 ? 2'd3 : 2'd0;
wire       ub = kind == 3'd2;                          // pictures from the Blorb
localparam [24:0] BLB = 25'h800000;
wire [2:0] first_slot = gset == 2'd2 ? 3'd1 : gset == 2'd3 ? 3'd3 : 3'd0;
function [24:0] fbase(input [2:0] s);
    fbase = 25'h400000 + {2'd0, s, 20'd0};
endfunction

// ------------------------------------------------ decoder memories
reg  [7:0] tval [0:4095];                              // LZW table: last character, previous code
reg [11:0] tseq [0:4095];
reg [11:0] t_ra = 12'd0, t_wa = 12'd0;
reg  [7:0] t_qv = 8'd0, t_wv = 8'd0;
reg [11:0] t_qs = 12'd0, t_ws = 12'd0;
reg        t_we = 1'b0;
always @(posedge clk) begin
    if (t_we) begin tval[t_wa] <= t_wv; tseq[t_wa] <= t_ws; end
    t_qv <= tval[t_ra]; t_qs <= tseq[t_ra];
end
reg  [7:0] stk [0:4095];                               // one code's characters, last first
reg [11:0] s_ra = 12'd0, s_wa = 12'd0;
reg  [7:0] s_q = 8'd0, s_wv = 8'd0;
reg        s_we = 1'b0;
always @(posedge clk) begin
    if (s_we) stk[s_wa] <= s_wv;
    s_q <= stk[s_ra];
end

// ------------------------------------------------ control
localparam [5:0]
    S_IDLE = 6'd0, S_RB = 6'd1, S_RB1 = 6'd2,
    S_L0 = 6'd3, S_L1 = 6'd4, S_L2 = 6'd5, S_L3 = 6'd6, S_L4 = 6'd7, S_L5 = 6'd8, S_L6 = 6'd9, S_L7 = 6'd10,
    S_L8 = 6'd11, S_L9 = 6'd12, S_LA = 6'd13, S_LB = 6'd14, S_LC = 6'd15, S_LD = 6'd16, S_LE = 6'd17,
    S_I0 = 6'd18, S_P0 = 6'd19, S_P1 = 6'd20, S_P2 = 6'd21, S_P3 = 6'd22, S_P4 = 6'd23,
    S_D0 = 6'd24, S_D1 = 6'd25, S_D2 = 6'd26, S_D3 = 6'd27, S_D4 = 6'd28, S_D5 = 6'd29, S_D6 = 6'd30,
    S_D7 = 6'd31, S_D8 = 6'd32, S_D9 = 6'd33, S_DA = 6'd34, S_DB = 6'd35, S_DONE = 6'd36, S_D3B = 6'd37,
    S_RN = 6'd38, S_RN2 = 6'd39, S_B0 = 6'd40, S_B1 = 6'd41, S_B2 = 6'd42, S_B3 = 6'd43, S_B4 = 6'd44, S_B5 = 6'd45,
    S_B6 = 6'd46, S_B7 = 6'd47, S_BA0 = 6'd48, S_BA1 = 6'd49, S_BF0 = 6'd50, S_BF1 = 6'd51, S_BF2 = 6'd52;

reg  [5:0] st = S_IDLE, rb_ret = S_IDLE;
reg  [7:0] rb = 8'd0;                                  // a byte read (S_RB): rb, then rb_ret
assign busy = st != S_IDLE;

reg        o_draw = 1'b0;
reg [15:0] o_pic = 16'd0;
reg signed [21:0] o_y = 22'sd0, o_x = 22'sd0;
reg  [2:0] fs = 3'd0;                                  // the file being searched
reg [15:0] li = 16'd0;                                 // entry index
reg [24:0] ep = 25'd0;                                 // entry address
reg [15:0] e_num = 16'd0, e_w = 16'd0, e_h = 16'd0, e_fl = 16'd0;
reg [23:0] e_data = 24'd0, e_pal = 24'd0;
reg  [3:0] pk = 4'd0, pn = 4'd0;                       // palette entries: index, count
reg  [1:0] pc = 2'd0;
reg [23:0] prgb = 24'd0;
// decoder
reg [24:0] dp = 25'd0;
reg [23:0] bb = 24'd0;                                 // bit buffer (LSB first)
reg  [4:0] nb = 5'd0;
reg  [3:0] bpc = 4'd9;
reg [12:0] cnt = 13'd257;
reg [11:0] code = 12'd0, prev = 12'd0, v = 12'd0;
reg [11:0] sp = 12'd0;
reg        kwk = 1'b0;
reg [15:0] col = 16'd0, row = 16'd0;
reg  [7:0] pv = 8'd0;
reg [63:0] cga_hi = 64'd0;
reg  [7:0] cga_be = 8'd0;
reg  [6:0] cga_w = 7'd0;
reg        cga_ok = 1'b0;
// Blorb
reg [31:0] rv = 32'd0;                                 // a big-endian value read (S_RN): rn bytes
reg  [2:0] rn = 3'd0;
reg        e_png = 1'b0, pl_on = 1'b0;
reg [24:0] b_len = 25'd0, fp = 25'd0, fend = 25'd0;
reg [15:0] ai = 16'd0;                                 // APal entry
reg        fh = 1'b0, g_out = 1'b0, p_seen = 1'b0, png_rst = 1'b0;
reg  [7:0] fbyte = 8'd0;
reg  [2:0] drain = 3'd0;
wire        p_in_ready, p_done, p_valid, plte_we;
wire [15:0] p_x, p_y;
wire [31:0] p_rgba;
wire  [7:0] p_idx, plte_i;
wire [23:0] plte_rgb;
png_decode #(.LB_AW(11)) png (                         // 2 KB a line: 320 pixels at 8 bits with room to spare
    .clk(clk), .reset(reset | png_rst),
    .in_valid(fh), .in_data(fbyte), .in_ready(p_in_ready),
    .img_start(), .width(), .height(), .img_done(p_done),
    .px_valid(p_valid), .px_x(p_x), .px_y(p_y), .px_rgba(p_rgba), .px_idx(p_idx), .px_ready(1'b1),
    .plte_we(plte_we), .plte_i(plte_i), .plte_rgb(plte_rgb)
);
wire signed [21:0] bry = o_y + $signed({6'd0, p_y});
wire signed [21:0] brx = o_x + $signed({5'd0, p_x, 1'b0});
wire        bry_ok = bry >= V6_TOP && bry <= V6_TOP + 199;
wire [14:0] brow = {bry[8:0], 6'd0} + {2'd0, bry[8:0], 4'd0};
wire        bdraw = st == S_BF1 || st == S_BF2;

wire        cga8 = gset == 2'd3 && !e_fl[0];           // 8 pixels a value
wire [11:0] cmask = 12'hFFF >> (4'd12 - bpc);
wire        transp = e_fl[0] && pv == {4'd0, e_fl[15:12]} && !cga8;
// the pixel(s) of value pv at (row, col)
wire signed [21:0] ry = o_y + $signed({6'd0, row});
wire signed [21:0] rx = o_x + (gset == 2'd1 ? $signed({5'd0, col, 1'b0}) : $signed({6'd0, col}));
wire        ry_ok = ry >= V6_TOP && ry <= V6_TOP + 199 && row < e_h;
wire [14:0] rrow = {ry[8:0], 6'd0} + {2'd0, ry[8:0], 4'd0};
wire  [7:0] pen = gset == 2'd1 ? 8'd16 + pv : gset == 2'd2 ? 8'd32 + {4'd0, pv[3:0]} : (pv == 8'd2 ? 8'd9 : 8'd2);
// CGA bitmask: 8 pixels (MSB first) from rx; the bits past the width dropped
reg  [7:0] cbits;
integer k;
always @* for (k = 0; k < 8; k = k + 1) cbits[k] = col + k[15:0] < e_w;
wire [15:0] cga_mask = {8'd0, cbits} << rx[2:0];
reg [127:0] cga_row;
always @* begin
    for (k = 0; k < 16; k = k + 1) cga_row[8*k +: 8] = 8'd0;
    for (k = 0; k < 8; k = k + 1) cga_row[8*k +: 8] = pv[7 - k] ? 8'd9 : 8'd2;
end
wire [127:0] cga_sh = cga_row << {rx[2:0], 3'd0};
wire signed [18:0] cw0 = rx[21:3];                     // the first word of the 8 pixels

task rd(input [24:0] a, input [5:0] ret);
    begin g_rd_req <= 1'b1; g_rd_addr <= a; rb_ret <= ret; st <= S_RB; end
endtask
task rdn(input [24:0] a, input [2:0] n, input [5:0] ret);   // n bytes from a, big-endian, into rv
    begin g_rd_req <= 1'b1; g_rd_addr <= a; rb_ret <= ret; rn <= n; st <= S_RN; end
endtask

always @(posedge clk) begin
    g_rd_req <= 1'b0;
    pal_we   <= 1'b0;
    fb_we    <= 1'b0;
    t_we     <= 1'b0;
    s_we     <= 1'b0;
    png_rst  <= 1'b0;

    // Blorb drawing: the decoder's pixels and palette as they come
    if (bdraw && p_valid && p_rgba[7:0] != 8'd0 && bry_ok && brx >= 22'sd0 && brx <= 22'sd639) begin
        fb_we <= 1'b1; fb_addr <= brow + {8'd0, brx[9:3]}; fb_wdata <= {8{8'd16 + p_idx}}; fb_be <= 8'd3 << brx[2:0];
    end
    if (bdraw && pl_on && plte_we && plte_i >= 8'd2 && plte_i <= 8'd15) begin
        pal_we <= 1'b1; pal_i <= plte_i[3:0]; pal_rgb <= plte_rgb;
    end

    if (reset) st <= S_IDLE;
    else case (st)
    S_IDLE: if (req) begin
        o_draw <= op; o_pic <= pic; o_y <= py; o_x <= px; r_ok <= 1'b0; r_h <= 16'd0; r_w <= 16'd0;
        if (gset == 2'd0) st <= S_IDLE;
        else if (pic == 16'd0 && !op) begin
            r_ok <= 1'b1; r_h <= ub ? b_pcnt : f_cnt[first_slot]; r_w <= ub ? b_rel : f_ver[first_slot];
        end
        else if (ub) begin li <= 16'd0; st <= S_B0; end
        else begin fs <= first_slot; li <= 16'd0; ep <= fbase(first_slot) + 25'd16; st <= S_L0; end
    end
    S_RB: if (g_rd_ack) begin rb <= g_rd_data; st <= rb_ret; end

    // directory search: the gset's file(s) in order
    S_L0: begin
        if (li == f_cnt[fs]) begin
            if (fs == 3'd1 && loaded[2]) begin fs <= 3'd2; li <= 16'd0; ep <= fbase(3'd2) + 25'd16; end
            else st <= S_DONE;                         // not there
        end
        else rd(ep, S_L1);
    end
    // the entry's bytes in order: each read is the one after the last (one adder)
    S_L1: begin e_num[7:0] <= rb; rd(g_rd_addr + 25'd1, S_L2); end
    S_L2: begin
        if ({rb, e_num[7:0]} == o_pic) rd(g_rd_addr + 25'd1, S_L3);
        else begin li <= li + 16'd1; ep <= ep + {17'd0, f_esz[fs]}; st <= S_L0; end
    end
    S_L3: begin e_w[7:0] <= rb; rd(g_rd_addr + 25'd1, S_L4); end
    S_L4: begin e_w[15:8] <= rb; rd(g_rd_addr + 25'd1, S_L5); end
    S_L5: begin e_h[7:0] <= rb; rd(g_rd_addr + 25'd1, S_L6); end
    S_L6: begin e_h[15:8] <= rb; rd(g_rd_addr + 25'd1, S_L7); end
    S_L7: begin e_fl[7:0] <= rb; rd(g_rd_addr + 25'd1, S_L8); end
    S_L8: begin e_fl[15:8] <= rb; rd(g_rd_addr + 25'd1, S_L9); end
    S_L9: begin e_data[23:16] <= rb; rd(g_rd_addr + 25'd1, S_LA); end
    S_LA: begin e_data[15:8] <= rb; rd(g_rd_addr + 25'd1, S_LB); end
    S_LB: begin
        e_data[7:0] <= rb; e_pal <= 24'd0;
        if (f_esz[fs] >= 8'd14) rd(g_rd_addr + 25'd1, S_LC); else st <= S_I0;
    end
    S_LC: begin e_pal[23:16] <= rb; rd(g_rd_addr + 25'd1, S_LD); end
    S_LD: begin e_pal[15:8] <= rb; rd(g_rd_addr + 25'd1, S_LE); end
    S_LE: begin e_pal[7:0] <= rb; st <= S_I0; end
    S_I0: begin                                        // found: its data; drawing goes on with the palette
        r_ok <= 1'b1; r_w <= gset == 2'd1 && mcga2 ? {e_w[14:0], 1'b0} : e_w; r_h <= e_h;   // Amiga: MCGA width *= 2
        if (!o_draw || e_data == 24'd0) st <= S_DONE;   // data 0: a size only (a placeholder), nothing to draw
        else if (gset == 2'd1 && e_pal != 24'd0) rd(fbase(fs) + {1'b0, e_pal}, S_P0);
        else st <= S_D0;
    end
    // palette: count, then RGB triples for colours 2.. (at most 14)
    S_P0: begin pn <= rb > 8'd14 ? 4'd14 : rb[3:0]; pk <= 4'd0; pc <= 2'd0; ep <= fbase(fs) + {1'b0, e_pal} + 25'd1; st <= S_P1; end
    S_P1: if (pk == pn) st <= S_D0; else rd(ep, S_P2);
    S_P2: begin
        prgb <= {prgb[15:0], rb}; ep <= ep + 25'd1;
        if (pc == 2'd2) begin pc <= 2'd0; st <= S_P3; end else begin pc <= pc + 2'd1; st <= S_P1; end
    end
    S_P3: begin pal_we <= 1'b1; pal_i <= pk + 4'd2; pal_rgb <= prgb; pk <= pk + 4'd1; st <= S_P1; end

    // LZW
    S_D0: begin
        dp <= fbase(fs) + {1'b0, e_data}; bb <= 24'd0; nb <= 5'd0; bpc <= 4'd9; cnt <= 13'd257; prev <= 12'd0;
        col <= 16'd0; row <= 16'd0; st <= S_D1;
    end
    S_D1: begin                                        // the next code
        if ({1'b0, nb} >= {2'b0, bpc}) begin
            code <= bb[11:0] & cmask; bb <= bb >> bpc; nb <= nb - {1'b0, bpc}; st <= S_D2;
        end
        else rd(dp, S_D3B);
    end
    S_D3B: begin bb <= bb | ({16'd0, rb} << nb); nb <= nb + 5'd8; dp <= dp + 25'd1; st <= S_D1; end
    S_D2: begin
        if (code == 12'd256) begin bpc <= 4'd9; cnt <= 13'd257; st <= S_D1; end
        else if (code == 12'd257) st <= S_DONE;
        else begin
            kwk <= {1'b0, code} == cnt;
            v   <= {1'b0, code} == cnt ? prev : code;
            sp  <= {1'b0, code} == cnt ? 12'd1 : 12'd0;
            st  <= S_D3;
        end
    end
    S_D3: begin                                        // follow the chain to its first character
        if (v > 12'd255) begin t_ra <= v - 12'd256; st <= S_D4; end
        else begin
            s_we <= 1'b1; s_wa <= sp; s_wv <= v[7:0];
            st <= kwk ? S_D5 : S_D6;
        end
    end
    S_D4: st <= S_DA;
    S_DA: begin s_we <= 1'b1; s_wa <= sp; s_wv <= t_qv; sp <= sp + 12'd1; v <= t_qs; st <= S_D3; end
    S_D5: begin s_we <= 1'b1; s_wa <= 12'd0; s_wv <= v[7:0]; st <= S_D6; end   // KwKwK: the first character last
    S_D6: begin                                        // the new table entry; then the characters out, last first
        if (cnt < 13'd4096) begin t_we <= 1'b1; t_wa <= cnt[11:0] - 12'd256; t_wv <= v[7:0]; t_ws <= prev; end
        cnt <= cnt + 13'd1;
        if (cnt + 13'd1 == (13'd1 << bpc) && bpc < 4'd12) bpc <= bpc + 4'd1;
        prev <= code;
        s_ra <= sp; st <= S_D7;
    end
    S_D7: st <= S_D8;
    S_D8: begin                                        // one value: new row first (Amiga: pos >= width)
        pv <= s_q;
        if (col >= e_w) begin col <= 16'd0; row <= row + 16'd1; end
        st <= S_D9;
    end
    S_D9: begin
        if (!cga8) begin
            if (!transp && ry_ok && rx >= 22'sd0 && rx <= 22'sd639) begin
                fb_we <= 1'b1; fb_addr <= rrow + {8'd0, rx[9:3]};
                fb_wdata <= {8{pen}}; fb_be <= gset == 2'd1 ? 8'd3 << rx[2:0] : 8'd1 << rx[2:0];
            end
            col <= col + 16'd1;
            st <= S_DB;
        end
        else begin                                     // CGA bitmask: 8 pixels, up to two words
            if (ry_ok && cw0 >= 19'sd0 && cw0 <= 19'sd79) begin
                fb_we <= 1'b1; fb_addr <= rrow + {8'd0, cw0[6:0]}; fb_wdata <= cga_sh[63:0]; fb_be <= cga_mask[7:0];
            end
            cga_hi <= cga_sh[127:64]; cga_be <= cga_mask[15:8]; cga_w <= cw0[6:0] + 7'd1;
            cga_ok <= ry_ok && cw0 + 19'sd1 >= 19'sd0 && cw0 + 19'sd1 <= 19'sd79;
            col <= col + 16'd8;
            st <= S_DB;
        end
    end
    S_DB: begin
        if (cga8 && cga_be != 8'd0 && cga_ok) begin
            fb_we <= 1'b1; fb_addr <= rrow + {8'd0, cga_w}; fb_wdata <= cga_hi; fb_be <= cga_be; cga_be <= 8'd0;
        end
        if (sp == 12'd0) st <= S_D1; else begin sp <= sp - 12'd1; s_ra <= sp - 12'd1; st <= S_D7; end
    end
    S_RN: if (g_rd_ack) begin
        rv <= {rv[23:0], g_rd_data};
        if (rn == 3'd1) st <= rb_ret; else begin rn <= rn - 3'd1; st <= S_RN2; end
    end
    S_RN2: begin g_rd_req <= 1'b1; g_rd_addr <= g_rd_addr + 25'd1; st <= S_RN; end

    // Blorb: RIdx entries (usage, number, start; 12 bytes from +24) for 'Pict' o_pic
    S_B0: if (li == b_ridn) st <= S_DONE;
          else rdn(BLB + 25'd24 + {6'd0, li, 3'd0} + {7'd0, li, 2'd0}, 3'd4, S_B1);
    S_B1: if (rv == "Pict") rdn(g_rd_addr + 25'd1, 3'd4, S_B2); else begin li <= li + 16'd1; st <= S_B0; end
    S_B2: if (rv == {16'd0, o_pic}) rdn(g_rd_addr + 25'd1, 3'd4, S_B3); else begin li <= li + 16'd1; st <= S_B0; end
    S_B3: begin ep <= BLB + rv[24:0]; rdn(BLB + rv[24:0], 3'd4, S_B4); end   // the chunk: type, length
    S_B4: begin e_png <= rv == "PNG "; rdn(g_rd_addr + 25'd1, 3'd4, S_B5); end
    S_B5: begin b_len <= rv[24:0]; rdn(ep + (e_png ? 25'd24 : 25'd8), 3'd4, S_B6); end   // IHDR / Rect width, height
    S_B6: begin e_w <= rv[15:0]; rdn(g_rd_addr + 25'd1, 3'd4, S_B7); end
    S_B7: begin
        r_ok <= 1'b1; r_w <= mcga2 ? {e_w[14:0], 1'b0} : e_w; r_h <= rv[15:0];
        if (!o_draw || !e_png) st <= S_DONE;           // Rect: a size only
        else begin ai <= 16'd0; pl_on <= 1'b1; st <= S_BA0; end
    end
    S_BA0: if (ai == b_apn) st <= S_BF0; else rdn(BLB + {5'd0, b_apal} + {7'd0, ai, 2'd0}, 3'd4, S_BA1);
    S_BA1: if (rv == {16'd0, o_pic}) begin pl_on <= 1'b0; st <= S_BF0; end else begin ai <= ai + 16'd1; st <= S_BA0; end
    S_BF0: begin
        png_rst <= 1'b1; fp <= ep + 25'd8; fend <= ep + 25'd8 + b_len; fh <= 1'b0; g_out <= 1'b0; p_seen <= 1'b0;
        st <= S_BF1;
    end
    // the PNG's bytes into the decoder, one read at a time; done once all are in and the last row is out
    S_BF1: begin
        if (p_done) p_seen <= 1'b1;
        if ((!fh || p_in_ready) && !g_out && fp != fend) begin g_rd_req <= 1'b1; g_rd_addr <= fp; g_out <= 1'b1; end
        if (g_out && g_rd_ack) begin fh <= 1'b1; fbyte <= g_rd_data; g_out <= 1'b0; fp <= fp + 25'd1; end
        else if (fh && p_in_ready) fh <= 1'b0;
        if (p_seen && fp == fend && !fh && !g_out) begin drain <= 3'd7; st <= S_BF2; end
    end
    S_BF2: if (drain == 3'd0) st <= S_DONE; else drain <= drain - 3'd1;   // a palette pixel lags its row by 2 clocks
    S_DONE: st <= S_IDLE;
    default: st <= S_IDLE;
    endcase
end

endmodule
