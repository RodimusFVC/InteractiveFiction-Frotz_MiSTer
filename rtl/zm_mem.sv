// zm_mem - Z-machine memory as the CPU sees it.
// 0x00000-0x0FFFF: BRAM copy (dynamic memory is always below 64 KB), filled during the download; CPU writes land here.
// 0x10000 and up:  DDR3 through zm_ddr (static/high memory, read-only). DDR3 keeps the pristine story for restart/verify.
// undo set:         undo slot uslot in DDR3, read/write: byte 16 MB + uslot * 128 KB + addr[16:0] (32 slots, 4 MB).
// picture files:    DDR3 4 MB + slot * 1 MB (zm_pic: MG1, EG1, EG2, CG1, Blorb), written by the download, read by zm_pic.
// CPU port: req is a one-clock strobe, ack a one-clock pulse; rdata is valid with ack.
module zm_mem (
    input  wire        clk,
    input  wire        reset,

    input  wire        dl_wr,
    input  wire [24:0] dl_addr,
    input  wire  [7:0] dl_data,
    output wire        dl_wait,
    input  wire        gdl_wr,                         // a picture file byte: DDR3 only (zm_pic chose the address)
    input  wire [24:0] gdl_addr,
    input  wire        g_rd_req,                       // zm_pic's reads (picture files)
    input  wire [24:0] g_rd_addr,
    output wire  [7:0] g_rd_data,
    output wire        g_rd_ack,
    input  wire        s_rd_req,                       // zm_snd's reads (Blorb sounds)
    input  wire [24:0] s_rd_addr,
    output wire  [7:0] s_rd_data,
    output wire        s_rd_ack,

    input  wire        req,
    input  wire        we,
    input  wire        orig,                           // read from DDR3 even below 64 KB (the story as loaded)
    input  wire        undo,                           // access undo slot uslot instead
    input  wire  [4:0] uslot,
    input  wire [18:0] addr,
    input  wire  [7:0] wdata,
    output wire  [7:0] rdata,
    output reg         ack = 1'b0,

    input  wire        DDRAM_BUSY,
    output wire  [7:0] DDRAM_BURSTCNT,
    output wire [28:0] DDRAM_ADDR,
    input  wire [63:0] DDRAM_DOUT,
    input  wire        DDRAM_DOUT_READY,
    output wire        DDRAM_RD,
    output wire [63:0] DDRAM_DIN,
    output wire  [7:0] DDRAM_BE,
    output wire        DDRAM_WE
);

wire       low   = addr[18:16] == 3'd0 && !(orig && !we) && !undo;
wire       dl_lo = dl_addr[24:16] == 9'd0;
wire [7:0] bram_q;
reg        bram_ack = 1'b0;
reg        hi_sel   = 1'b0;                            // the access in flight went to DDR3
wire [7:0] ddr_q;
wire       ddr_ack, ddr_wack;
wire [24:0] ddr_addr = undo ? {3'b100, uslot, addr[16:0]} : {6'd0, addr};   // undo at 16 MB (it was 8 MB: over the Blorb's slot 4)

spram #(.DATA_WIDTH(8), .ADDR_WIDTH(16)) dyn (
    .clk  (clk),
    .addr (dl_wr ? dl_addr[15:0] : addr[15:0]),
    .data (dl_wr ? dl_data : wdata),
    .we   (dl_wr ? dl_lo : (req & we & low)),           // low excludes undo
    .q    (bram_q)
);

zm_ddr ddr (
    .clk(clk), .reset(reset),
    .dl_wr(dl_wr | gdl_wr), .dl_addr(gdl_wr ? gdl_addr : dl_addr), .dl_data(dl_data), .dl_wait(dl_wait),
    .g_rd_req(g_rd_req), .g_rd_addr(g_rd_addr), .g_rd_data(g_rd_data), .g_rd_ack(g_rd_ack),
    .s_rd_req(s_rd_req), .s_rd_addr(s_rd_addr), .s_rd_data(s_rd_data), .s_rd_ack(s_rd_ack),
    .wr_req(req & we & undo), .wr_addr_in(ddr_addr), .wr_data_in(wdata), .wr_ack(ddr_wack),
    .rd_req(req & ~we & ~low), .rd_addr(ddr_addr), .rd_data(ddr_q), .rd_ack(ddr_ack),
    .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
    .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
    .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE)
);

assign rdata = hi_sel ? ddr_q : bram_q;

always @(posedge clk) begin
    bram_ack <= req & (low | (we & ~undo));            // BRAM read/write, or a dropped write to the story above 64 KB
    if (req) hi_sel <= ~low & ~we;
    ack <= bram_ack | ddr_ack | ddr_wack;
end

endmodule
