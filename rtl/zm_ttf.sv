// zm_ttf - TrueType pixel-font loader: the user's own font file (never built into the core: Flathead by Kawa, 2014, a
// recreation of the Zork Zero font; Amiga Topaz Unicode by dMG of Trueschool and Divine Stylers, 2009, Topaz (c) Amiga
// Inc) arrives as an ioctl download, is kept in a 64 KB buffer and turned into an 8-row bitmap per character 32..126
// plus its advance, written to zm_disp's font RAM. Slot (decided before any glyph): cell = '0' is 8 pixels wide (Topaz:
// the V1-V5 text cells), else the file's post.isFixedPitch: fixed / proportional. Model: tools/ttf_font.py (same
// algorithm; the sim reference draws its output).
//   Tables: head (indexToLocFormat), hhea (ascender, descender, numberOfHMetrics), hmtx, cmap (the Mac 1/0 format 0
//   subtable), loca, glyf (simple glyphs, straight segments), post.
//   Grid from the font's metrics: H = ascender - descender; TALL when 2 * advance('0') <= H (Topaz: 8 x 16 drawn,
//   each output row = the OR of a row pair, two passes over the edges), else 8 rows; u = H / 16 or H / 8 units per
//   pixel (Flathead 125, Topaz 100); rounding thresholds (k + 1) u - (u - 1) / 2 set once; top row = round(asc / u) - 1.
//   Raster: points snapped to the nearest grid line, then for every vertical edge (one a clock) the winding counters
//   of the pixels whose centre lies to its right and within its height step by +1 / -1; set = non-zero winding.
//   Anything unexpected (no format 0 cmap, a composite glyph, > 64 points or 8 contours, a file > 64 KB) leaves that
//   glyph blank or the slot unloaded; zm_disp keeps its built-in font for an unloaded slot.
// busy (ioctl_wait) holds the next download while a font is parsed. Not reset by the core reset: a font stays loaded.
module zm_ttf (
    input  wire        clk,
    input  wire        dl,                             // the font download is in progress
    input  wire        wr,                             // a byte of it
    input  wire [24:0] addr,
    input  wire  [7:0] data,
    output wire        busy,

    output reg         f_we = 1'b0,                    // to zm_disp's font RAM: {slot, char, row}
    output reg  [11:0] f_addr = 12'd0,
    output reg   [7:0] f_data = 8'd0,
    output reg  [383:0] adv_prop = 384'd0,             // advances (pixels, 4 bits) of characters 32..127, slot 0 / 1
    output reg  [383:0] adv_fixed = 384'd0,
    output reg         have_prop = 1'b0,
    output reg         have_fixed = 1'b0,
    output reg         have_cell = 1'b0
);

reg  [7:0] buff [0:65535];
reg [15:0] ra = 16'd0;
reg  [7:0] q = 8'd0;
reg        over = 1'b0;                                // the file didn't fit
always @(posedge clk) begin
    if (wr && dl && addr < 25'd65536) buff[addr[15:0]] <= data;
    q <= buff[ra];
end

localparam [5:0]
    S_IDLE = 6'd0, S_RDA = 6'd1, S_RDB = 6'd2, S_RDC = 6'd3,
    S_P0 = 6'd4, S_P1 = 6'd5, S_P2 = 6'd6, S_P3 = 6'd7, S_P4 = 6'd8, S_P5 = 6'd9, S_P6 = 6'd10, S_P7 = 6'd11,
    S_C0 = 6'd12, S_C1 = 6'd13, S_C2 = 6'd14, S_C3 = 6'd15, S_C4 = 6'd16,
    S_G0 = 6'd17, S_G1 = 6'd18, S_G2 = 6'd19, S_G3 = 6'd20, S_G4 = 6'd21, S_G5 = 6'd22, S_G6 = 6'd23,
    S_E0 = 6'd24, S_E1 = 6'd25, S_E2 = 6'd26, S_E3 = 6'd27, S_E4 = 6'd28,
    S_F0 = 6'd29, S_F1 = 6'd30, S_F2 = 6'd31, S_F3 = 6'd32,
    S_X0 = 6'd33, S_X1 = 6'd34, S_X2 = 6'd35, S_X3 = 6'd36,
    S_W0 = 6'd37, S_W1 = 6'd38, S_DONE = 6'd39,
    S_M0 = 6'd40, S_M1 = 6'd41, S_M2 = 6'd42, S_M3 = 6'd43, S_M4 = 6'd44, S_M5 = 6'd45, S_M6 = 6'd46, S_M7 = 6'd47;

reg  [5:0] st = S_IDLE, rd_ret = S_IDLE;
reg        dl_d = 1'b0;
reg [15:0] rp = 16'd0;                                 // multi-byte big-endian read: rn bytes at rp -> rv
reg  [2:0] rn = 3'd0, rk = 3'd0;
reg [31:0] rv = 32'd0;
assign busy = st != S_IDLE;

reg [15:0] ntab = 16'd0, ti = 16'd0;
reg [15:0] t_head = 16'd0, t_hhea = 16'd0, t_hmtx = 16'd0, t_cmap = 16'd0, t_loca = 16'd0, t_glyf = 16'd0, t_post = 16'd0;
reg [15:0] cmap0 = 16'd0;
reg        loc_long = 1'b0, fixed = 1'b0, ok = 1'b0;
reg [15:0] nhm = 16'd0, nsub = 16'd0;
reg [31:0] tag = 32'd0;
reg  [6:0] ch = 7'd0;                                  // character - 32
reg  [7:0] g = 8'd0;
reg  [3:0] adv = 4'd0;
reg [31:0] l0 = 32'd0;
reg [15:0] p = 16'd0;                                  // glyph data pointer
reg  [3:0] nc = 4'd0, ci = 4'd0;
reg  [6:0] npt = 7'd0, pi = 7'd0, rep = 7'd0;
reg  [5:0] ends [0:7];
reg  [5:0] fl [0:63];                                  // {y same, x same, y short, x short, on-curve, 0} (flag bits 5 4 2 1 0)
reg signed [5:0] xs [0:63], ys [0:63];
reg signed [15:0] acc = 16'sd0;
reg  [6:0] cs = 7'd0;                                  // contour start
reg  [2:0] wr_r = 3'd0;
reg        rd_y = 1'b0;                                // reading y (else x) coordinates
wire [15:0] hm_g = {8'd0, rv[7:0]} < nhm ? {8'd0, rv[7:0]} : nhm - 16'd1;   // hmtx entry (the last repeats)
reg signed [3:0] w [0:63];                             // winding per pixel, {row, col}

// grid (S_M*): u units per pixel, tall = 16 rows drawn (two passes, ORed), top = the grid line under row 0, cellk = slot
reg signed [15:0] asc = 16'sd0, desc = 16'sd0;
reg [15:0] u = 16'd125, a0 = 16'd0, mu = 16'd0;
reg        tall = 1'b0, pass = 1'b0, cellk = 1'b0;
reg signed [5:0] top = 6'sd5;
reg  [4:0] tk = 5'd0;
reg [15:0] th [0:19];                                  // th[k] = (k + 1) u - (u - 1) / 2: round(v / u) = #{k: |v| >= th[k]}
reg [63:0] wlat = 64'd0;                               // tall fonts: the first pass's pixels
wire [16:0] hgt = {asc[15], asc} - {desc[15], desc};   // cell height in font units
wire        tall_n = {rv[15:0], 1'b0} <= hgt;          // S_M3: rv = advance('0')

// the edge from point pe to point pi (vertical ones count): every pixel right of it, within its height
reg  [6:0] pe = 7'd0;
wire signed [5:0] ex = xs[pe[5:0]], ea = ys[pe[5:0]], eb = ys[pi[5:0]];
wire        evert = xs[pe[5:0]] == xs[pi[5:0]];
wire signed [5:0] elo = ea < eb ? ea : eb, ehi = ea < eb ? eb : ea;
wire signed [31:0] ex32 = {{26{ex[5]}}, ex}, elo32 = {{26{elo[5]}}, elo}, ehi32 = {{26{ehi[5]}}, ehi};
wire signed [31:0] top32 = {{26{top[5]}}, top};
wire signed [31:0] pass32 = {31'd0, pass};            // signed: an unsigned pass would make the row compare unsigned
wire  [7:0] chz = {1'b0, ch} + 8'd32;                  // the character
wire  [2:0] nc_last = nc[2:0] - 3'd1;                  // the last contour (8 -> 7)
// the next coordinate (S_X1: a byte, + if same else -; S_X2: a word) and the one rounding of it
wire        cur_same = rd_y ? fl[pi[5:0]][5] : fl[pi[5:0]][4];
wire signed [15:0] acc_new = st == S_X1 ? (cur_same ? acc + $signed({8'd0, rv[7:0]}) : acc - $signed({8'd0, rv[7:0]}))
                                        : acc + $signed(rv[15:0]);
wire [15:0] acc_abs = acc_new[15] ? 16'd0 - acc_new : acc_new;
reg  [4:0] n_acc, n_rv;                                // round(|acc_new| / u), round(rv[15:0] / u)
integer tq;
always @* begin
    n_acc = 5'd0; n_rv = 5'd0;
    for (tq = 0; tq < 20; tq = tq + 1) begin
        if (acc_abs >= th[tq]) n_acc = n_acc + 5'd1;
        if (rv[15:0] >= th[tq]) n_rv = n_rv + 5'd1;
    end
end
wire signed [5:0] acc_snap = acc_new[15] ? 6'sd0 - $signed({1'b0, n_acc}) : $signed({1'b0, n_acc});
integer rr, cc;
reg  [7:0] wrow;                                       // S_W0: row wr_r, both passes
integer wc;
always @* for (wc = 0; wc < 8; wc = wc + 1) wrow[wc] = (w[wr_r * 8 + wc] != 4'sd0) | wlat[wr_r * 8 + wc];

task rd(input [15:0] at, input [2:0] n, input [5:0] ret);
    begin rp <= at; rn <= n; rk <= 3'd0; rv <= 32'd0; rd_ret <= ret; st <= S_RDA; end
endtask

always @(posedge clk) begin
    f_we <= 1'b0;
    dl_d <= dl;
    if (dl && !dl_d) over <= 1'b0;
    if (wr && dl && addr >= 25'd65536) over <= 1'b1;

    case (st)
    S_IDLE: if (dl_d && !dl && !over) begin ok <= 1'b0; t_post <= 16'd0; rd(16'd4, 3'd2, S_P0); end
    S_RDA: begin ra <= rp + {13'd0, rk}; st <= S_RDB; end
    S_RDB: st <= S_RDC;
    S_RDC: begin
        rv <= {rv[23:0], q}; rk <= rk + 3'd1;
        st <= rk + 3'd1 == rn ? rd_ret : S_RDA;
    end

    // table directory
    S_P0: begin ntab <= rv[15:0]; ti <= 16'd0; st <= S_P1; end
    S_P1: if (ti == ntab) rd(t_head + 16'd50, 3'd2, S_P3); else rd(16'd12 + {3'd0, ti[8:0], 4'd0}, 3'd4, S_P2);
    S_P2: begin tag <= rv; rd(16'd12 + {3'd0, ti[8:0], 4'd0} + 16'd8, 3'd4, S_P4); end
    S_P4: begin
        case (tag)
            "head": t_head <= rv[15:0];  "hhea": t_hhea <= rv[15:0];  "hmtx": t_hmtx <= rv[15:0];
            "cmap": t_cmap <= rv[15:0];  "loca": t_loca <= rv[15:0];  "glyf": t_glyf <= rv[15:0];
            "post": t_post <= rv[15:0];
            default: ;
        endcase
        ti <= ti + 16'd1; st <= S_P1;
    end
    S_P3: begin loc_long <= rv[15:0] == 16'd1; rd(t_hhea + 16'd34, 3'd2, S_P5); end
    S_P5: begin nhm <= rv[15:0]; if (t_post != 16'd0) rd(t_post + 16'd12, 3'd4, S_P6); else begin rv <= 32'd0; st <= S_P6; end end
    S_P6: begin fixed <= rv != 32'd0; rd(t_cmap + 16'd2, 3'd2, S_P7); end
    S_P7: begin nsub <= rv[15:0]; ti <= 16'd0; st <= S_C0; end
    // cmap: the (1, 0) subtable, format 0
    S_C0: if (ti == nsub) st <= ok ? S_M0 : S_DONE; else rd(t_cmap + 16'd4 + {3'd0, ti[9:0], 3'd0}, 3'd4, S_C1);
    S_C1: begin
        if (rv == 32'h00010000) rd(t_cmap + 16'd4 + {3'd0, ti[9:0], 3'd0} + 16'd4, 3'd4, S_C2);
        else begin ti <= ti + 16'd1; st <= S_C0; end
    end
    S_C2: begin cmap0 <= t_cmap + rv[15:0]; rd(t_cmap + rv[15:0], 3'd2, S_C3); end
    S_C3: begin if (rv[15:0] == 16'd0 && !ok) begin ok <= 1'b1; cmap0 <= cmap0 + 16'd6; end ti <= ti + 16'd1; st <= S_C0; end

    // grid from the font's metrics (see the header)
    S_M0: rd(t_hhea + 16'd4, 3'd4, S_M1);
    S_M1: begin asc <= rv[31:16]; desc <= rv[15:0]; rd(cmap0 + 16'd48, 3'd1, S_M2); end
    S_M2: rd(t_hmtx + {hm_g[13:0], 2'b00}, 3'd2, S_M3);   // rv[7:0] = the glyph of '0'
    S_M3: begin
        a0 <= rv[15:0]; tall <= tall_n; u <= tall_n ? {3'd0, hgt[16:4]} : {2'd0, hgt[16:3]};
        mu <= 16'd0; tk <= 5'd0; st <= S_M4;
    end
    S_M4: begin
        th[tk] <= mu + u - ((u - 16'd1) >> 1); mu <= mu + u; tk <= tk + 5'd1;
        if (tk == 5'd19) st <= S_M5;
    end
    S_M5: begin rv <= {16'd0, asc}; st <= S_M6; end
    S_M6: begin top <= $signed({1'b0, n_rv}) - 6'sd1; rv <= {16'd0, a0}; st <= S_M7; end
    S_M7: begin cellk <= n_rv == 5'd8; st <= S_G0; end

    // per character: glyph number, advance, glyph location
    S_G0: begin ch <= 7'd0; st <= S_G1; end
    S_G1: if (ch == 7'd95) st <= S_DONE; else rd(cmap0 + 16'd32 + {9'd0, ch}, 3'd1, S_G2);
    S_G2: begin
        g <= rv[7:0];
        rd(t_hmtx + {hm_g[13:0], 2'b00}, 3'd2, S_G3);
    end
    S_G3: begin
        adv <= n_rv > 5'd15 ? 4'd15 : n_rv[3:0];
        if (loc_long) rd(t_loca + {6'd0, g, 2'b00}, 3'd4, S_G4); else rd(t_loca + {7'd0, g, 1'b0}, 3'd2, S_G4);
        for (rr = 0; rr < 64; rr = rr + 1) w[rr] <= 4'sd0;
        wlat <= 64'd0; pass <= 1'b0;
    end
    S_G4: begin
        l0 <= loc_long ? rv : {15'd0, rv[15:0], 1'b0};
        if (loc_long) rd(t_loca + {6'd0, g, 2'b00} + 16'd4, 3'd4, S_G5); else rd(t_loca + {7'd0, g, 1'b0} + 16'd2, 3'd2, S_G5);
    end
    S_G5: begin                                        // empty glyph (space): just the advance
        if ((loc_long ? rv : {15'd0, rv[15:0], 1'b0}) <= l0) begin wr_r <= 3'd0; st <= S_W0; end
        else begin p <= t_glyf + l0[15:0]; rd(t_glyf + l0[15:0], 3'd2, S_G6); end
    end
    S_G6: begin                                        // contours (negative = composite: blank)
        if (rv[15] || rv[15:0] == 16'd0 || rv[15:0] > 16'd8) begin wr_r <= 3'd0; st <= S_W0; end
        else begin nc <= rv[3:0]; ci <= 4'd0; p <= p + 16'd10; st <= S_E0; end
    end
    // end points
    S_E0: if (ci == nc) begin rd(p, 3'd2, S_E2); end else rd(p, 3'd2, S_E1);
    S_E1: begin ends[ci[2:0]] <= rv[5:0]; ci <= ci + 4'd1; p <= p + 16'd2; if (rv[15:6] != 10'd0) begin wr_r <= 3'd0; st <= S_W0; end else st <= S_E0; end
    S_E2: begin                                        // instructions skipped; n points
        p <= p + 16'd2 + rv[15:0]; npt <= {1'b0, ends[nc_last]} + 7'd1; pi <= 7'd0; st <= S_F0;
    end
    // flags (with repeats)
    S_F0: if (pi == npt) begin pi <= 7'd0; acc <= 16'sd0; st <= S_X0; end else rd(p, 3'd1, S_F1);
    S_F1: begin
        fl[pi[5:0]] <= {rv[5], rv[4], rv[2], rv[1], rv[0], 1'b0}; pi <= pi + 7'd1; p <= p + 16'd1;
        if (rv[3]) rd(p + 16'd1, 3'd1, S_F2); else st <= S_F0;
    end
    S_F2: begin rep <= rv[6:0]; p <= p + 16'd1; st <= S_F3; end
    S_F3: if (rep == 7'd0 || pi == npt) st <= S_F0; else begin fl[pi[5:0]] <= fl[pi[5:0] - 6'd1]; pi <= pi + 7'd1; rep <= rep - 7'd1; end
    // x then y: short = an unsigned byte (+ if same), else same = unchanged, else a signed word
    S_X0: begin
        if (pi == npt) begin
            if (!rd_y) begin rd_y <= 1'b1; pi <= 7'd0; acc <= 16'sd0; end
            else begin rd_y <= 1'b0; pi <= 7'd0; ci <= 4'd0; cs <= 7'd0; pe <= {1'b0, ends[0]}; st <= S_X3; end
        end
        else if (rd_y ? fl[pi[5:0]][3] : fl[pi[5:0]][2]) rd(p, 3'd1, S_X1);
        else if (rd_y ? fl[pi[5:0]][5] : fl[pi[5:0]][4]) begin rv <= 32'd0; st <= S_X2; end
        else rd(p, 3'd2, S_X2);
    end
    S_X1: begin                                        // short
        acc <= acc_new;
        if (rd_y) ys[pi[5:0]] <= acc_snap; else xs[pi[5:0]] <= acc_snap;
        p <= p + 16'd1; pi <= pi + 7'd1; st <= S_X0;
    end
    S_X2: begin                                        // a word, or unchanged (rv = 0)
        acc <= acc_new;
        if (rd_y) ys[pi[5:0]] <= acc_snap; else xs[pi[5:0]] <= acc_snap;
        if (rv != 32'd0 || !(rd_y ? fl[pi[5:0]][5] : fl[pi[5:0]][4])) p <= p + 16'd2;
        pi <= pi + 7'd1; st <= S_X0;
    end
    // edges, one a clock: pe -> pi around each contour (the first from its last point). Row rr samples the grid line
    // top - rr (tall fonts: top - 2 rr, then top - 2 rr - 1 in a second pass, ORed)
    S_X3: begin
        if (ci == nc) begin
            if (tall && !pass) begin
                for (rr = 0; rr < 64; rr = rr + 1) begin wlat[rr] <= w[rr] != 4'sd0; w[rr] <= 4'sd0; end
                pass <= 1'b1; ci <= 4'd0; pi <= 7'd0; cs <= 7'd0; pe <= {1'b0, ends[0]};
            end
            else begin wr_r <= 3'd0; st <= S_W0; end
        end
        else begin
            if (evert)
                for (rr = 0; rr < 8; rr = rr + 1)
                    for (cc = 0; cc < 8; cc = cc + 1)
                        if (ex32 <= cc && elo32 <= (tall ? top32 - 2 * rr - pass32 : top32 - rr) && (tall ? top32 - 2 * rr - pass32 : top32 - rr) < ehi32)
                            w[rr * 8 + cc] <= w[rr * 8 + cc] + (eb > ea ? 4'sd1 : -4'sd1);
            pe <= pi;
            if (pi[5:0] == ends[ci[2:0]]) begin ci <= ci + 4'd1; cs <= pi + 7'd1; pi <= pi + 7'd1; pe <= {1'b0, ends[ci[2:0] + 3'd1]}; end
            else pi <= pi + 7'd1;
        end
    end
    // the 8 rows and the advance
    S_W0: begin
        f_we <= 1'b1;                                  // {slot, character 32 + ch, row}; cell: 2048 + {character, row}
        f_addr <= cellk ? {1'b1, chz, wr_r} : {1'b0, fixed, ch, wr_r} + 12'd256;
        f_data <= wrow;
        wr_r <= wr_r + 3'd1;
        if (wr_r == 3'd7) st <= S_W1;
    end
    S_W1: begin
        if (!cellk) begin if (fixed) adv_fixed[{ch, 2'b00} +: 4] <= adv; else adv_prop[{ch, 2'b00} +: 4] <= adv; end
        ch <= ch + 7'd1; st <= S_G1;
    end
    S_DONE: begin
        if (ok) begin if (cellk) have_cell <= 1'b1; else if (fixed) have_fixed <= 1'b1; else have_prop <= 1'b1; end
        st <= S_IDLE;
    end
    default: st <= S_IDLE;
    endcase
end

endmodule
