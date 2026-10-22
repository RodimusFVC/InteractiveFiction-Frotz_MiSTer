// zm_snd - sound_effect output: Blorb samples (Lurking Horror, Sherlock) and the beeps, as Amiga Frotz plays them.
//   Samples: the story's Blorb, downloaded with the pictures (DDR3 byte BLB = slot 4), is read in place: RIdx -> the
//   'Snd ' entry -> FORM AIFF -> COMM (channels, frames, bits, rate: 80-bit float, integer part) + SSND (data start).
//   8-bit mono only (every Infocom sound). Played at its own rate with no filtering (Paula), the same on both channels;
//   volume as amiga_sound.c: volume * 8 of Paula's 64, 8 and up = full; repeats 0 = once (Amiga cycles).
//   go: eff 1 prepare (a different sound than the last one stops the playing one: os_finish_with_sample), 2 play (stops
//   the playing one first), 3 stop, 4 finish with. A missing sound / no Blorb plays nothing and never ends (Frotz).
//   done: one clock when a sound has played all its repeats (Amiga: the last audio request came back); a stopped
//   sound never gives one. dbg_end (harness): end the playing sound now, as at the next input (the reference's model).
//   Beeps (number 1 high, 2 low): Amiga Frotz calls DisplayBeep, a screen flash; OSD beep_mode 0 = a tone (1 kHz /
//   500 Hz square, 1/8 s), 1 = the flash (flash high 1/8 s), 2 = off.
module zm_snd #(
    parameter integer CLK_HZ = 36000000,
    parameter [24:0]  BLB    = 25'h800000
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        have_blb,
    input  wire        go,
    input  wire [15:0] num,
    input  wire  [2:0] eff,
    input  wire  [7:0] vol,
    input  wire  [7:0] rep,
    input  wire  [1:0] beep_mode,
    input  wire        dbg_end,
    output reg         done = 1'b0,
    output wire        busy,                           // a sample is being looked up or played
    output wire        flash,
    output reg  signed [15:0] audio = 16'sd0,

    output reg         s_rd_req = 1'b0,                // DDR3 byte reads (zm_ddr's sound reader), one at a time
    output reg  [24:0] s_rd_addr = 25'd0,
    input  wire  [7:0] s_rd_data,
    input  wire        s_rd_ack
);

localparam [4:0] S_IDLE = 5'd0, S_RD = 5'd1, S_RDW = 5'd2, S_IX0 = 5'd3, S_IX1 = 5'd4, S_IX2 = 5'd5, S_IX3 = 5'd6,
                 S_IX4 = 5'd7, S_IX5 = 5'd8, S_FL = 5'd9, S_CK0 = 5'd10, S_CK1 = 5'd11, S_CK2 = 5'd12, S_CM0 = 5'd13,
                 S_CM1 = 5'd14, S_CM2 = 5'd15, S_CM3 = 5'd16, S_CM4 = 5'd17, S_SS = 5'd18, S_CKN = 5'd19, S_GO = 5'd20,
                 S_PLAY = 5'd21;

localparam [25:0] CLK26   = CLK_HZ;                   // sized: one sample period in clocks = CLK26 / rate
localparam [15:0] HALF_HI = CLK_HZ / 2000, HALF_LO = CLK_HZ / 1000;
localparam [22:0] BEEP_T  = CLK_HZ / 8;

reg  [4:0] st = S_IDLE, ret = S_IDLE;
reg [24:0] ra = 25'd0;                                 // multi-byte read: address, bytes left, big-endian result
reg  [2:0] rn = 3'd0;
reg [31:0] rv = 32'd0;
reg        out = 1'b0, pf = 1'b0;                      // a read is out / it is the player's prefetch
reg [15:0] n_snd = 16'd0, cur = 16'd0;
reg  [6:0] gain = 7'd0;
reg  [7:0] reps = 8'd0;
reg [15:0] ix_n = 16'd0, ix_i = 16'd0;                 // RIdx entries, the one read
reg [24:0] sb = 25'd0, f_end = 25'd0, q = 25'd0;       // the sound's FORM, its end, the chunk
reg [31:0] cid = 32'd0, q_len = 32'd0;
reg        got_c = 1'b0, got_s = 1'b0;
reg [15:0] ch = 16'd0, bits = 16'd0, c_exp = 16'd0;
reg [31:0] frames = 32'd0, pos = 32'd0;
reg [24:0] d0 = 25'd0;                                 // sample data start
reg [15:0] rate = 16'd0;
reg [25:0] acc = 26'd0;
reg  [7:0] nxt = 8'd0;
reg        nv = 1'b0;                                  // the next byte (at pos) is in nxt
reg signed [7:0] smp = 8'sd0;

assign busy = st != S_IDLE;

// beep: 1/8 s, a square wave of half period CLK_HZ / 2000 (number 1, 1 kHz) or / 1000 (number 2, 500 Hz)
reg [22:0] bp_t = 23'd0;
reg [15:0] bp_c = 16'd0;
reg        bp_lo = 1'b0, bp_s = 1'b0;
assign flash = bp_t != 23'd0 && beep_mode == 2'd1;
wire [15:0] bp_half = bp_lo ? HALF_LO : HALF_HI;

wire signed [16:0] sm = {{9{smp[7]}}, smp};
wire signed [16:0] gn = {10'd0, gain};
wire signed [16:0] mix = sm * gn * 17'sd4 + (bp_t != 23'd0 && beep_mode == 2'd0 ? (bp_s ? 17'sd6000 : -17'sd6000) : 17'sd0);

// AIFF COMM rate: sign + 15-bit exponent (bias 16383), mantissa's top 16 bits (explicit 1): integer part, e 0..15
wire [14:0] ex = c_exp[14:0] - 15'd16383;
wire        ex_ok = c_exp[14:0] >= 15'd16383 && c_exp[14:0] <= 15'd16398;

wire [25:0] acc_n = acc + {10'd0, rate};
wire        tick = acc_n >= CLK26;

task read(input [24:0] a, input [2:0] n, input [4:0] r);
    begin ra <= a; rn <= n; rv <= 32'd0; ret <= r; st <= S_RD; end
endtask

always @(posedge clk) begin
    done <= 1'b0;
    s_rd_req <= 1'b0;
    audio <= mix > 17'sd32767 ? 16'sd32767 : mix < -17'sd32768 ? -16'sd32768 : mix[15:0];

    if (bp_t != 23'd0) begin
        bp_t <= bp_t - 23'd1;
        if (bp_c >= bp_half) begin bp_c <= 16'd0; bp_s <= ~bp_s; end else bp_c <= bp_c + 16'd1;
    end

    if (s_rd_ack) begin
        out <= 1'b0; pf <= 1'b0;
        if (pf) begin nxt <= s_rd_data; nv <= st == S_PLAY; end
    end

    case (st)
    S_IDLE: ;
    S_RD:  if (!out) begin s_rd_req <= 1'b1; s_rd_addr <= ra; out <= 1'b1; st <= S_RDW; end
    S_RDW: if (s_rd_ack && !pf) begin
        rv <= {rv[23:0], s_rd_data};
        ra <= ra + 25'd1;
        if (rn == 3'd1) st <= ret; else begin rn <= rn - 3'd1; st <= S_RD; end
    end
    // Blorb: FORM ... IFRS, RIdx at +12 (its count at +20, entries usage / number / start of 12 bytes from +24)
    S_IX0: if (rv == "RIdx") read(BLB + 25'd20, 3'd4, S_IX1); else st <= S_IDLE;
    S_IX1: begin ix_n <= rv[15:0]; ix_i <= 16'd0; st <= S_IX2; end
    S_IX2: if (ix_i == ix_n) st <= S_IDLE;
           else read(BLB + 25'd24 + {10'd0, ix_i[11:0], 3'b000} + {11'd0, ix_i[11:0], 2'b00}, 3'd4, S_IX3);
    S_IX3: if (rv == "Snd ") read(ra, 3'd4, S_IX4); else begin ix_i <= ix_i + 16'd1; st <= S_IX2; end
    S_IX4: if (rv == {16'd0, n_snd}) read(ra, 3'd4, S_IX5); else begin ix_i <= ix_i + 16'd1; st <= S_IX2; end
    S_IX5: begin sb <= BLB + rv[24:0]; read(BLB + rv[24:0] + 25'd4, 3'd4, S_FL); end
    // FORM <len> AIFF: chunks from +12 to +8 + len
    S_FL:  begin f_end <= sb + 25'd8 + rv[24:0]; q <= sb + 25'd12; got_c <= 1'b0; got_s <= 1'b0; st <= S_CK0; end
    S_CK0: if (got_c && got_s) st <= S_GO;
           else if (q + 25'd8 > f_end) st <= S_IDLE;
           else read(q, 3'd4, S_CK1);
    S_CK1: begin cid <= rv; read(q + 25'd4, 3'd4, S_CK2); end
    S_CK2: begin
        q_len <= rv;
        if (cid == "COMM") read(q + 25'd8, 3'd2, S_CM0);
        else if (cid == "SSND") read(q + 25'd8, 3'd4, S_SS);
        else st <= S_CKN;
    end
    S_CM0: begin ch <= rv[15:0]; read(q + 25'd10, 3'd4, S_CM1); end
    S_CM1: begin frames <= rv; read(q + 25'd14, 3'd2, S_CM2); end
    S_CM2: begin bits <= rv[15:0]; read(q + 25'd16, 3'd2, S_CM3); end
    S_CM3: begin c_exp <= rv[15:0]; read(q + 25'd18, 3'd2, S_CM4); end
    S_CM4: begin rate <= ex_ok ? rv[15:0] >> (4'd15 - ex[3:0]) : 16'd0; got_c <= 1'b1; st <= S_CKN; end
    S_SS:  begin d0 <= q + 25'd16 + rv[24:0]; got_s <= 1'b1; st <= S_CKN; end
    S_CKN: begin q <= q + 25'd8 + q_len[24:0] + {24'd0, q_len[0]}; st <= S_CK0; end
    S_GO:  if (ch != 16'd1 || bits != 16'd8 || rate == 16'd0 || frames == 32'd0) st <= S_IDLE;
           else begin pos <= 32'd0; acc <= 26'd0; nv <= 1'b0; st <= S_PLAY; end
    // pos = the next byte; at the end of a cycle that is byte 0 of the next (Paula chains the repeats, no gap)
    S_PLAY: begin
        if (!out && !nv && (pos != frames || reps != 8'd1)) begin
            s_rd_req <= 1'b1; s_rd_addr <= d0 + (pos == frames ? 25'd0 : pos[24:0]); out <= 1'b1; pf <= 1'b1;
        end
        acc <= tick ? acc_n - CLK26 : acc_n;
        if (tick) begin
            if (pos == frames && reps == 8'd1) begin smp <= 8'sd0; done <= 1'b1; st <= S_IDLE; end   // the last one played
            else if (nv) begin                         // (a late byte: the last one held)
                smp <= nxt; nv <= 1'b0;
                if (pos == frames) begin pos <= 32'd1; reps <= reps - 8'd1; end else pos <= pos + 32'd1;
            end
        end
    end
    default: st <= S_IDLE;
    endcase

    if (go) begin
        if (num == 16'd1 || num == 16'd2) begin
            if (beep_mode != 2'd2) begin bp_t <= BEEP_T; bp_c <= 16'd0; bp_lo <= num == 16'd2; end
        end
        else if (eff == 3'd2) begin
            n_snd <= num; cur <= num; gain <= vol >= 8'd8 ? 7'd64 : {1'b0, vol[2:0], 3'b000}; reps <= rep == 8'd0 ? 8'd1 : rep;
            smp <= 8'sd0; nv <= 1'b0;
            if (have_blb) read(BLB + 25'd12, 3'd4, S_IX0); else st <= S_IDLE;
        end
        else if (eff == 3'd1 ? num != cur : eff == 3'd3 || eff == 3'd4) begin
            st <= S_IDLE; smp <= 8'sd0; nv <= 1'b0;
            if (eff != 3'd3) cur <= eff == 3'd1 ? num : 16'd0;
        end
    end
    if (dbg_end && st != S_IDLE) begin st <= S_IDLE; smp <= 8'sd0; nv <= 1'b0; done <= 1'b1; end
    if (reset) begin st <= S_IDLE; smp <= 8'sd0; nv <= 1'b0; bp_t <= 23'd0; cur <= 16'd0; out <= 1'b0; pf <= 1'b0; end
end

endmodule
