// zm_fb - framebuffer: 640x240 pixels, 8-bit palette index, 8 pixels per 64-bit word (pixel i of a word = bits
// 8i+7:8i, left to right), 80 words per line, 19200 words (150 KB of M10K). One write port (zm_disp) with a byte enable
// per pixel (V6 text lands on any pixel) and one read port (shared in zm_core: zm_video when it fetches, else zm_disp's
// scroll reads), so Quartus infers a single simple dual-port RAM. (With a read on the write port too it built two
// copies: 88 % of the M10Ks, build 2026-10-21.) Byte enables in the Quartus template form (packed bytes, one if each).
// The read is registered: r_q is valid the clock after r_addr.
module zm_fb (
    input  wire        clk,
    input  wire [14:0] w_addr,
    input  wire [63:0] w_data,
    input  wire  [7:0] w_be,
    input  wire        w_we,
    input  wire [14:0] r_addr,
    output reg  [63:0] r_q
);

reg [7:0][7:0] mem [0:19199];

always @(posedge clk) begin
    if (w_we) begin
        if (w_be[0]) mem[w_addr][0] <= w_data[7:0];
        if (w_be[1]) mem[w_addr][1] <= w_data[15:8];
        if (w_be[2]) mem[w_addr][2] <= w_data[23:16];
        if (w_be[3]) mem[w_addr][3] <= w_data[31:24];
        if (w_be[4]) mem[w_addr][4] <= w_data[39:32];
        if (w_be[5]) mem[w_addr][5] <= w_data[47:40];
        if (w_be[6]) mem[w_addr][6] <= w_data[55:48];
        if (w_be[7]) mem[w_addr][7] <= w_data[63:56];
    end
end
always @(posedge clk) r_q <= mem[r_addr];

endmodule
