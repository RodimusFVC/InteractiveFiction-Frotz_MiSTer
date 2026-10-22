// zm_ddr - story/picture store in DDR3 (MiSTer DDRAM Avalon port, burst 1).
// Download side: ioctl bytes -> one byte-enabled DDR3 write each; dl_wait holds hps_io off while one is pending.
// CPU writes (undo slots): wr_req strobe, wr_ack pulses when the write is on the bus; one at a time.
// Read side: byte reads through a one-word (8-byte) cache. rd_req is a strobe; rd_data is valid with rd_ack.
// A second reader (g_*, zm_pic: picture files) and a third (s_*, zm_snd: Blorb sounds) have their own request and
// one-word cache; the CPU's reads go first, then the sound's (a byte every ~1100 clocks at most), then the pictures'.
// Byte address a lives in DDR3 word BASE + a[24:3], byte lane a[2:0] (bits 8*lane+7 : 8*lane).
module zm_ddr #(
    parameter [28:0] BASE = 29'h0600_0000              // byte 0x30000000, the usual core window
) (
    input  wire        clk,
    input  wire        reset,                          // clears a pending read only; download runs under reset

    input  wire        dl_wr,
    input  wire [24:0] dl_addr,
    input  wire  [7:0] dl_data,
    output wire        dl_wait,

    input  wire        wr_req,
    input  wire [24:0] wr_addr_in,
    input  wire  [7:0] wr_data_in,
    output reg         wr_ack = 1'b0,

    input  wire        rd_req,
    input  wire [24:0] rd_addr,
    output reg   [7:0] rd_data = 8'd0,
    output reg         rd_ack  = 1'b0,

    input  wire        g_rd_req,
    input  wire [24:0] g_rd_addr,
    output reg   [7:0] g_rd_data = 8'd0,
    output reg         g_rd_ack  = 1'b0,

    input  wire        s_rd_req,
    input  wire [24:0] s_rd_addr,
    output reg   [7:0] s_rd_data = 8'd0,
    output reg         s_rd_ack  = 1'b0,

    input  wire        DDRAM_BUSY,
    output wire  [7:0] DDRAM_BURSTCNT,
    output wire [28:0] DDRAM_ADDR,
    input  wire [63:0] DDRAM_DOUT,
    input  wire        DDRAM_DOUT_READY,
    output reg         DDRAM_RD = 1'b0,
    output wire [63:0] DDRAM_DIN,
    output wire  [7:0] DDRAM_BE,
    output reg         DDRAM_WE = 1'b0
);

reg [21:0] op_word = 22'd0;                            // word of the bus op in flight
reg [63:0] op_din  = 64'd0;
reg  [7:0] op_be   = 8'd0;
reg        rd_wait = 1'b0;                             // read accepted, waiting for DOUT_READY

reg        wr_pend = 1'b0;                             // download / CPU byte waiting for the bus
reg        wr_cpu  = 1'b0;                             // ... and it came from the CPU (ack it when it goes out)
reg [24:0] wr_addr = 25'd0;
reg  [7:0] wr_data = 8'd0;

reg        rq_pend = 1'b0;                             // read request waiting to be served
reg [24:0] rq_addr = 25'd0;

reg        c_valid = 1'b0;
reg [21:0] c_word  = 22'd0;
reg [63:0] c_data  = 64'd0;

reg        gq_pend = 1'b0;                             // the picture reader's request, cache, and whose read is out
reg [24:0] gq_addr = 25'd0;
reg        g_valid = 1'b0;
reg [21:0] g_word  = 22'd0;
reg [63:0] g_data  = 64'd0;
reg        rd_g    = 1'b0;
reg        sq_pend = 1'b0;                             // the sound reader's
reg [24:0] sq_addr = 25'd0;
reg        s_valid = 1'b0;
reg [21:0] s_word  = 22'd0;
reg [63:0] s_data  = 64'd0;
reg        rd_s    = 1'b0;

assign dl_wait        = wr_pend;
assign DDRAM_BURSTCNT = 8'd1;
assign DDRAM_ADDR     = BASE + {7'd0, op_word};
assign DDRAM_DIN      = op_din;
assign DDRAM_BE       = op_be;

wire idle = ~DDRAM_WE & ~DDRAM_RD & ~rd_wait;

always @(posedge clk) begin
    rd_ack <= 1'b0;
    wr_ack <= 1'b0;
    g_rd_ack <= 1'b0;
    s_rd_ack <= 1'b0;
    if (~DDRAM_BUSY) begin
        DDRAM_WE <= 1'b0;
        DDRAM_RD <= 1'b0;
    end
    if (rd_wait & DDRAM_DOUT_READY) begin
        rd_wait <= 1'b0;
        if (rd_s)      begin s_valid <= 1'b1; s_word <= op_word; s_data <= DDRAM_DOUT; end
        else if (rd_g) begin g_valid <= 1'b1; g_word <= op_word; g_data <= DDRAM_DOUT; end
        else      begin c_valid <= 1'b1; c_word <= op_word; c_data <= DDRAM_DOUT; end
    end

    if (wr_pend & idle) begin                          // download writes win; nothing reads during a load
        wr_pend  <= 1'b0;
        wr_ack   <= wr_cpu;
        DDRAM_WE <= 1'b1;
        op_word  <= wr_addr[24:3];
        op_din   <= {8{wr_data}};
        op_be    <= 8'd1 << wr_addr[2:0];
        if (c_word == wr_addr[24:3]) c_valid <= 1'b0;
        if (g_word == wr_addr[24:3]) g_valid <= 1'b0;
        if (s_word == wr_addr[24:3]) s_valid <= 1'b0;
    end
    else if (rq_pend) begin
        if (c_valid & (c_word == rq_addr[24:3])) begin
            rq_pend <= 1'b0;
            rd_ack  <= 1'b1;
            rd_data <= c_data[{rq_addr[2:0], 3'b000} +: 8];
        end
        else if (idle) begin
            DDRAM_RD <= 1'b1;
            rd_wait  <= 1'b1;
            rd_g     <= 1'b0;
            rd_s     <= 1'b0;
            op_word  <= rq_addr[24:3];
        end
    end
    else if (sq_pend) begin
        if (s_valid & (s_word == sq_addr[24:3])) begin
            sq_pend   <= 1'b0;
            s_rd_ack  <= 1'b1;
            s_rd_data <= s_data[{sq_addr[2:0], 3'b000} +: 8];
        end
        else if (idle) begin
            DDRAM_RD <= 1'b1;
            rd_wait  <= 1'b1;
            rd_g     <= 1'b0;
            rd_s     <= 1'b1;
            op_word  <= sq_addr[24:3];
        end
    end
    else if (gq_pend) begin
        if (g_valid & (g_word == gq_addr[24:3])) begin
            gq_pend   <= 1'b0;
            g_rd_ack  <= 1'b1;
            g_rd_data <= g_data[{gq_addr[2:0], 3'b000} +: 8];
        end
        else if (idle) begin
            DDRAM_RD <= 1'b1;
            rd_wait  <= 1'b1;
            rd_g     <= 1'b1;
            rd_s     <= 1'b0;
            op_word  <= gq_addr[24:3];
        end
    end

    if (dl_wr) begin
        wr_pend <= 1'b1; wr_cpu <= 1'b0;
        wr_addr <= dl_addr;
        wr_data <= dl_data;
    end
    else if (wr_req) begin                             // the CPU waits for wr_ack before the next one
        wr_pend <= 1'b1; wr_cpu <= 1'b1;
        wr_addr <= wr_addr_in;
        wr_data <= wr_data_in;
    end
    if (rd_req) begin
        rq_pend <= 1'b1;
        rq_addr <= rd_addr;
    end
    if (g_rd_req) begin
        gq_pend <= 1'b1;
        gq_addr <= g_rd_addr;
    end
    if (s_rd_req) begin
        sq_pend <= 1'b1;
        sq_addr <= s_rd_addr;
    end
    if (reset) begin rq_pend <= 1'b0; gq_pend <= 1'b0; sq_pend <= 1'b0; end
end

endmodule
