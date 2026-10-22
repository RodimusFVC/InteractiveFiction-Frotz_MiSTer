// zm_mouse - the PS/2 mouse from hps_io as a pointer on the 640 x 240 raster, and its clicks.
//   ps2_mouse: [24] toggles with every event, [23:16] dy, [15:8] dx, [7:0] flags (0 left, 1 right, 2 middle,
//   4 dx sign, 5 dy sign; PS/2 dy counts upward). Speed (OSD) k quarters a count: Normal 5 (1.25x), Slow 3, Fast 8,
//   Faster 12; x moves k/4 raster pixel a count, y k/8 line (a raster line is two pixels tall on 4:3), kept in quarter
//   pixels / eighth lines, clamped to the screen. Shown for 2^27 clocks (~3.7 s at 36 MHz) after the last event.
//   click: a left-button press (one clock, at the pointer); dbl with it when the press before was less than 2^24 clocks
//   (~0.47 s) earlier (Amiga Frotz: Intuition DoubleClick, a time test only).
module zm_mouse (
    input  wire        clk,
    input  wire [24:0] ps2_mouse,
    input  wire  [1:0] speed,                          // OSD: 0 Normal, 1 Slow, 2 Fast, 3 Faster
    input  wire        dbg_set,                        // harness: put the pointer at dbg_x, dbg_y
    input  wire  [9:0] dbg_x,
    input  wire  [8:0] dbg_y,
    output wire  [9:0] mx,                             // pointer hotspot: raster column 0..639
    output wire  [8:0] my,                             //                  raster line 0..239
    output reg   [2:0] btn = 3'd0,                     // buttons held: {middle, right, left}
    output wire        shown,
    output reg         click = 1'b0,
    output reg         dbl = 1'b0
);

reg         tog = 1'b0;
reg  [11:0] x4 = 12'd1280;                             // quarter pixels 0..2559
reg  [10:0] y8 = 11'd960;                              // eighth lines 0..1919
reg  [26:0] idle = 27'h7FFFFFF;                        // clocks since the last event (saturates: hidden at power-up)
reg  [24:0] since = 25'h1FFFFFF;                       // clocks since the last left press (saturates)
wire  [4:0] k = speed == 2'd1 ? 5'd3 : speed == 2'd2 ? 5'd8 : speed == 2'd3 ? 5'd12 : 5'd5;
wire signed [10:0] dx = {{3{ps2_mouse[4]}}, ps2_mouse[15:8]};   // 9-bit two's complement, sign-extended
wire signed [10:0] dy = {{3{ps2_mouse[5]}}, ps2_mouse[23:16]};
wire signed [16:0] mvx = dx * $signed(k);
wire signed [16:0] mvy = dy * $signed(k);
wire signed [17:0] xn = $signed({6'd0, x4}) + {mvx[16], mvx};
wire signed [17:0] yn = $signed({7'd0, y8}) - {mvy[16], mvy};

assign mx = x4[11:2];
assign my = {1'b0, y8[10:3]};
assign shown = idle != 27'h7FFFFFF;

always @(posedge clk) begin
    tog <= ps2_mouse[24];
    click <= 1'b0;
    if (idle != 27'h7FFFFFF) idle <= idle + 27'd1;
    if (since != 25'h1FFFFFF) since <= since + 25'd1;
    if (ps2_mouse[24] != tog) begin
        x4  <= xn < 18'sd0 ? 12'd0 : xn > 18'sd2559 ? 12'd2559 : xn[11:0];
        y8  <= yn < 18'sd0 ? 11'd0 : yn > 18'sd1919 ? 11'd1919 : yn[10:0];
        btn <= ps2_mouse[2:0];
        idle <= 27'd0;
        if (ps2_mouse[0] && !btn[0]) begin click <= 1'b1; dbl <= since[24] == 1'b0; since <= 25'd0; end
    end
    if (dbg_set) begin x4 <= {dbg_x, 2'b00}; y8 <= {dbg_y[7:0], 3'b000}; end
end

endmodule
