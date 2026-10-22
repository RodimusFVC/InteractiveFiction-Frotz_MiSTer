// zm_core - the whole Frotz_MiSTer machine below hps_io: story memory (BRAM + DDR3), zm_cpu, zm_kbd, zm_disp, zm_fb,
// zm_video. The MiSTer top (InteractiveFiction-Frotz.sv) and the Verilator harness (verilator/board_tb.sv) both instantiate this, so the
// sim runs the wiring that ships. Debug ports (dbg_*, tr_*, m_*, out_*, snap, key_hold) exist for the harness; the top
// ties them off.
//   cpu_run low: CPU held in reset, dbg_* reads zm_mem (load check). use_ps2: keys from ps2_key through zm_kbd, else
//   from key_valid / key_code (ZSCII). key_hold: keys held back. dbg_fb_en: zm_fb's video port goes to dbg_fb_addr.
module zm_core #(
    parameter FONT_FILE  = "rtl/font/zm_font_osd.hex",
    parameter FONT3_FILE = "rtl/font/zm_font3.hex",
    parameter BLINK      = 4
) (
    input  wire        clk,
    input  wire        reset,

    input  wire [24:0] ioctl_addr,
    input  wire  [7:0] ioctl_dout,
    input  wire        ioctl_wr0,
    output wire        ioctl_wait,
    input  wire        ttf_dl,                         // a font file download (Flathead TTF) is in progress ...
    input  wire        ttf_wr0,                        // ... and a byte of it
    input  wire        gfx_dl,                         // a picture file download (Load Graphics) ...
    input  wire        gfx_wr0,                        // ... a byte of it
    input  wire  [1:0] gfx_ext,                        // ... its extension (ioctl_index[7:6]: mg1, eg?, cg1, blb)
    input  wire  [2:0] pic_sel,                        // OSD Graphics: 0 Auto, 1 MG1, 2 Blorb, 3 EGA, 4 CGA
    input  wire        v6_need_gfx,                    // a V6 story needs its pictures (else halt 15)

    input  wire        cpu_run,
    input  wire        more_en,
    input  wire        key_valid,                      // ZSCII keys straight from the harness (use_ps2 = 0) ...
    input  wire  [9:0] key_code,
    output wire        key_ack,
    input  wire        use_ps2,                        // ... or hps_io-style ps2_key events through zm_kbd
    input  wire [10:0] ps2_key,
    input  wire [24:0] ps2_mouse,                      // hps_io's PS/2 mouse: the pointer and clicks (zm_mouse)
    input  wire  [1:0] ptr_speed,                      // OSD: 0 Normal, 1 Slow, 2 Fast, 3 Faster
    input  wire  [2:0] ptr_col,                        // OSD: pointer colour
    input  wire        dbg_ptr_set,                    // harness: put the pointer at dbg_ptr_x, dbg_ptr_y
    input  wire  [9:0] dbg_ptr_x,
    input  wire  [8:0] dbg_ptr_y,
    input  wire  [1:0] beep_mode,                      // OSD: 0 tone, 1 screen flash (Amiga DisplayBeep), 2 off
    input  wire        dbg_snd_end,                    // harness: end the playing sound now (zm_snd)
    output wire signed [15:0] audio,                   // sound_effect: Blorb samples + beeps, mono
    output wire        snd_busy,                       // harness: a sound is playing / its end not handled yet
    input  wire        dbg_tmo,                        // harness: time the running read / read_char out now
    input  wire        dbg_tmo_ext,                    // harness: only dbg_tmo times out (no real-time timeouts)
    output wire        tmo_busy,                       // harness: a timeout not handled yet
    input  wire        key_hold,                       // keys held back (framebuffer read-back)
    output wire        kbd_empty,
    output wire        input_wait,
    input  wire [15:0] rng_seed,
    input  wire        status_brief,
    input  wire  [7:0] cfg_flags1,
    input  wire [23:0] cfg_flags2_mask,                // AND masks on header byte 0x11: {V5+, V4, V1-3}
    input  wire  [7:0] cfg_interp_num,
    input  wire  [7:0] cfg_interp_ver,
    input  wire  [7:0] cfg_rows,
    input  wire  [7:0] cfg_cols,
    input  wire  [7:0] cfg_fg,
    input  wire  [7:0] cfg_bg,
    input  wire        img_mounted,                    // save file (hps_io block device 0)
    input  wire [63:0] img_size,
    output wire [31:0] sd_lba,
    output wire        sd_rd,
    output wire        sd_wr,
    input  wire        sd_ack,
    input  wire  [8:0] sd_buff_addr,
    input  wire  [7:0] sd_buff_dout,
    output wire  [7:0] sd_buff_din,
    input  wire        sd_buff_wr,
    input  wire        dbg_req,
    input  wire [18:0] dbg_addr,
    output wire  [7:0] dbg_rdata,
    output wire        dbg_ack,

    output wire  [9:0] out_char,
    output wire        out_cmd,
    output wire [15:0] out_arg0,
    output wire [15:0] out_arg1,
    output wire        out_valid,
    output wire        out_ready,
    output wire        more_wait,
    output wire        cur_on,
    output wire  [6:0] cur_x,
    output wire  [4:0] cur_y,
    output wire        snap,
    output wire        disp_busy,
    input  wire        dbg_fb_en,
    input  wire [14:0] dbg_fb_addr,
    output wire [63:0] dbg_fb_q,
    output wire        ce_pix,
    output wire  [7:0] vga_r,
    output wire  [7:0] vga_g,
    output wire  [7:0] vga_b,
    output wire        vga_hs,
    output wire        vga_vs,
    output wire        vga_hblank,
    output wire        vga_vblank,
    output wire        halted,
    output wire  [7:0] halt_code,
    output wire        tr_valid,
    output wire [18:0] tr_pc,
    output wire  [7:0] tr_op,
    output wire  [7:0] tr_ext,
    output wire  [3:0] tr_argc,
    output wire [127:0] tr_args,

    output wire        m_req,                          // CPU memory port, for the header-write snoop
    output wire        m_we,
    output wire        m_orig,
    output wire        m_undo,
    output wire [18:0] m_addr,
    output wire  [7:0] m_wdata,

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

wire [7:0] mem_q;
wire       mem_wait, ttf_busy;
assign ioctl_wait = mem_wait | ttf_busy;

// Flathead (zm_ttf): the user's TTF files -> zm_disp's font RAM + advances
wire        ttf_we, have_prop, have_fixed, have_cell;
wire [11:0] ttf_addr;
wire  [7:0] ttf_data;
wire [383:0] adv_prop, adv_fixed;
wire  [1:0] disp_wsel;

// V6 pictures (zm_pic): Infocom picture files in DDR3, drawn into zm_fb while zm_disp waits
wire        gdl_wr, g_rd_req, g_rd_ack, pic_req, pic_op, pic_busy, pic_ok, pal_we, pf_we;
wire [24:0] gdl_addr, g_rd_addr;
wire  [7:0] g_rd_data, pf_be;
wire  [1:0] gset;
wire [15:0] pic_num, pic_h, pic_w;
wire signed [21:0] pic_py, pic_px;
wire  [3:0] pal_i;
wire [23:0] pal_rgb;
wire [14:0] pf_addr;
wire [63:0] pf_wdata;
wire        have_blb;
zm_pic pics (
    .clk(clk), .reset(reset),
    .gdl(gfx_dl), .gwr(gfx_wr0), .gaddr(ioctl_addr), .gdata(ioctl_dout), .gext(gfx_ext), .gdl_wr(gdl_wr), .gdl_addr(gdl_addr),
    .g_rd_req(g_rd_req), .g_rd_addr(g_rd_addr), .g_rd_data(g_rd_data), .g_rd_ack(g_rd_ack),
    .sel(pic_sel), .mcga2(have_cell), .gset(gset), .have_blb(have_blb),
    .req(pic_req), .op(pic_op), .pic(pic_num), .py(pic_py), .px(pic_px), .busy(pic_busy), .r_ok(pic_ok), .r_h(pic_h), .r_w(pic_w),
    .pal_we(pal_we), .pal_i(pal_i), .pal_rgb(pal_rgb),
    .fb_we(pf_we), .fb_addr(pf_addr), .fb_wdata(pf_wdata), .fb_be(pf_be)
);
// V6 metrics for the header: font width ('0' of Flathead, else the built-in 4; doubled at 640 units), columns
wire        v6_wide = gset == 2'd2 || gset == 2'd3 || have_cell;   // 640 units (zm_disp's wide)
wire  [3:0] fw320 = have_prop && !have_cell ? adv_prop[67:64] : 4'd4;   // Topaz: the 8-pixel cell
wire  [7:0] v6_cols = fw320 == 4'd5 ? 8'd64 : fw320 == 4'd6 ? 8'd53 : fw320 == 4'd3 ? 8'd106 : fw320 == 4'd2 ? 8'd160
                    : fw320 == 4'd7 ? 8'd45 : fw320 == 4'd8 ? 8'd40 : 8'd80;
zm_ttf ttf (
    .clk(clk), .dl(ttf_dl), .wr(ttf_wr0), .addr(ioctl_addr), .data(ioctl_dout), .busy(ttf_busy),
    .f_we(ttf_we), .f_addr(ttf_addr), .f_data(ttf_data), .adv_prop(adv_prop), .adv_fixed(adv_fixed),
    .have_prop(have_prop), .have_fixed(have_fixed), .have_cell(have_cell)
);
wire       mem_ack;
wire [4:0] m_uslot;
wire        cpu_key_ack, cpu_input_wait, disp_key_ack, line_empty;
wire        kb_valid;
wire  [9:0] kb_code;
// mouse (zm_mouse): the pointer, and a left click as a key: ZSCII 254, 253 double (Frotz), one held until taken,
// with its raster position for the CPU's validate_click; keys go first
wire  [9:0] ptr_x;
wire  [8:0] ptr_y;
wire  [2:0] ptr_btn;
wire        ptr_on, ptr_click, ptr_dbl;
zm_mouse mouse (.clk(clk), .ps2_mouse(ps2_mouse), .speed(ptr_speed), .dbg_set(dbg_ptr_set), .dbg_x(dbg_ptr_x), .dbg_y(dbg_ptr_y),
                .mx(ptr_x), .my(ptr_y), .btn(ptr_btn), .shown(ptr_on), .click(ptr_click), .dbl(ptr_dbl));
reg         ck_pend = 1'b0;
reg   [9:0] ck_code = 10'd254, ck_x = 10'd0;
reg   [8:0] ck_y = 9'd0;
wire        keyv = use_ps2 ? kb_valid : key_valid;
always @(posedge clk) begin
    if (key_ack && !keyv) ck_pend <= 1'b0;
    if (ptr_click && !ck_pend) begin ck_pend <= 1'b1; ck_code <= ptr_dbl ? 10'd253 : 10'd254; ck_x <= ptr_x; ck_y <= ptr_y; end
    if (reset) ck_pend <= 1'b0;
end
wire        kv = (keyv | ck_pend) & ~key_hold;         // to the CPU, or to zm_disp while it waits at [MORE] (a click too)
wire  [9:0] kc = keyv ? (use_ps2 ? kb_code : key_code) : ck_code;
wire signed [9:0] cur_row, cur_col;
wire  [7:0] cur_fg;
wire [15:0] out_arg2, disp_rsp_a, disp_rsp_b;
wire        disp_nl_irq, disp_v6, disp_irq, disp_rsp_ok;
wire [15:0] disp_irq_addr;

// sound_effect (zm_snd): the CPU's commands; samples from the Blorb in DDR3 (slot 4) through zm_mem's sound reader
wire        s_rd_req, s_rd_ack, snd_go, snd_done, snd_play_busy, snd_pend, snd_flash;
wire [24:0] s_rd_addr;
wire  [7:0] s_rd_data, snd_vol, snd_rep;
wire [15:0] snd_num;
wire  [2:0] snd_eff;
zm_snd snd (
    .clk(clk), .reset(reset | ~cpu_run), .have_blb(have_blb), .go(snd_go), .num(snd_num), .eff(snd_eff), .vol(snd_vol),
    .rep(snd_rep), .beep_mode(beep_mode), .dbg_end(dbg_snd_end), .done(snd_done), .busy(snd_play_busy), .flash(snd_flash),
    .audio(audio), .s_rd_req(s_rd_req), .s_rd_addr(s_rd_addr), .s_rd_data(s_rd_data), .s_rd_ack(s_rd_ack)
);
assign snd_busy = snd_play_busy | snd_pend;
zm_mem mem (
    .clk(clk), .reset(reset),
    .dl_wr(ioctl_wr0), .dl_addr(ioctl_addr), .dl_data(ioctl_dout), .dl_wait(mem_wait),
    .gdl_wr(gdl_wr), .gdl_addr(gdl_addr), .g_rd_req(g_rd_req), .g_rd_addr(g_rd_addr), .g_rd_data(g_rd_data), .g_rd_ack(g_rd_ack),
    .s_rd_req(s_rd_req), .s_rd_addr(s_rd_addr), .s_rd_data(s_rd_data), .s_rd_ack(s_rd_ack),
    .req(cpu_run ? m_req : dbg_req), .we(cpu_run & m_we), .orig(cpu_run & m_orig), .undo(cpu_run & m_undo), .uslot(m_uslot), .addr(cpu_run ? m_addr : dbg_addr), .wdata(m_wdata),
    .rdata(mem_q), .ack(mem_ack),
    .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
    .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
    .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE)
);

assign dbg_rdata = mem_q;
assign dbg_ack   = mem_ack;

zm_cpu cpu (
    .clk(clk), .reset(reset | ~cpu_run),
    .m_req(m_req), .m_we(m_we), .m_orig(m_orig), .m_undo(m_undo), .m_uslot(m_uslot), .m_addr(m_addr), .m_wdata(m_wdata), .m_rdata(mem_q), .m_ack(mem_ack & cpu_run),
    .out_char(out_char), .out_cmd(out_cmd), .out_arg0(out_arg0), .out_arg1(out_arg1), .out_arg2(out_arg2), .out_valid(out_valid), .out_ready(out_ready),
    .v6_fw(v6_wide ? {fw320[2:0], 1'b0} : fw320), .v6_cols(v6_cols), .v6_wide(v6_wide), .gfx_ok(gset != 2'd0),
    .v6_need_gfx(v6_need_gfx), .disp_rsp_ok(disp_rsp_ok),
    .adv_prop(adv_prop), .adv_fixed(adv_fixed), .disp_wsel(disp_wsel),
    .disp_busy(disp_busy), .disp_rsp_a(disp_rsp_a), .disp_rsp_b(disp_rsp_b), .click_x(ck_x), .click_y(ck_y),
    .snd_go(snd_go), .snd_num(snd_num), .snd_eff(snd_eff), .snd_vol(snd_vol), .snd_rep(snd_rep), .snd_done(snd_done), .snd_pend(snd_pend),
    .dbg_tmo(dbg_tmo), .dbg_tmo_ext(dbg_tmo_ext), .tmo_busy(tmo_busy),
    .disp_irq(disp_irq), .disp_irq_addr(disp_irq_addr), .disp_nl_irq(disp_nl_irq),
    .key_valid(kv & ~more_wait), .key_code(kc), .key_ack(cpu_key_ack), .input_wait(cpu_input_wait), .line_empty(line_empty),
    .rng_seed(rng_seed), .status_brief(status_brief),
    .cfg_flags1(cfg_flags1), .cfg_flags2_mask(cfg_flags2_mask), .cfg_interp_num(cfg_interp_num), .cfg_interp_ver(cfg_interp_ver),
    .cfg_rows(cfg_rows), .cfg_cols(cfg_cols), .cfg_fg(cfg_fg), .cfg_bg(cfg_bg),
    .img_mounted(img_mounted), .img_size(img_size), .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
    .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr),
    .halted(halted), .halt_code(halt_code),
    .tr_valid(tr_valid), .tr_pc(tr_pc), .tr_op(tr_op), .tr_ext(tr_ext), .tr_argc(tr_argc), .tr_args(tr_args)
);

assign key_ack    = cpu_key_ack | disp_key_ack;

zm_kbd kbd (
    .clk(clk), .reset(reset), .ps2_key(ps2_key), .line_empty(line_empty),
    .key_valid(kb_valid), .key_code(kb_code), .key_ack(use_ps2 & key_ack & kb_valid), .empty(kbd_empty)
);
assign input_wait = cpu_input_wait | more_wait;
assign cur_on     = cpu_input_wait && !disp_busy && !disp_v6 && cur_row >= 0 && cur_row < $signed({2'd0, cfg_rows}) && cur_col >= 0 && cur_col < $signed({2'd0, cfg_cols});
assign cur_x      = cur_col[6:0];
assign cur_y      = cur_row[4:0];

wire [14:0] da_addr, da_raddr, vid_addr;
wire [63:0] da_wdata, fb_q;
wire  [7:0] da_be;
wire        da_we, da_rreq, vid_req;

zm_disp #(.FONT_FILE(FONT_FILE), .FONT3_FILE(FONT3_FILE)) disp (
    .clk(clk), .reset(reset), .cols(cfg_cols), .rows(cfg_rows), .def_fg(cfg_fg), .def_bg(cfg_bg),
    .ttf_we(ttf_we), .ttf_addr(ttf_addr), .ttf_data(ttf_data), .adv_prop(adv_prop), .adv_fixed(adv_fixed),
    .have_prop(have_prop), .have_fixed(have_fixed), .have_cell(have_cell), .interp(cfg_interp_num), .wsel(disp_wsel), .rsp_ok(disp_rsp_ok),
    .gset(gset), .pic_req(pic_req), .pic_op(pic_op), .pic_num(pic_num), .pic_py(pic_py), .pic_px(pic_px),
    .pic_busy(pic_busy), .pic_ok(pic_ok), .pic_h(pic_h), .pic_w(pic_w),
    .in_char(out_char), .in_cmd(out_cmd), .in_arg0(out_arg0), .in_arg1(out_arg1), .in_arg2(out_arg2), .in_valid(out_valid), .in_ready(out_ready),
    .rsp_a(disp_rsp_a), .rsp_b(disp_rsp_b), .irq(disp_irq), .irq_addr(disp_irq_addr), .nl_irq(disp_nl_irq), .v6(disp_v6),
    .fb_addr(da_addr), .fb_wdata(da_wdata), .fb_be(da_be), .fb_we(da_we),
    .fb_raddr(da_raddr), .fb_rreq(da_rreq), .fb_grant(~vid_req & ~dbg_fb_en), .fb_q(fb_q),
    .more_en(more_en), .key_valid(kv), .key_ack(disp_key_ack), .more_wait(more_wait),
    .cur_row(cur_row), .cur_col(cur_col), .cur_fg(cur_fg),
    .snap(snap), .busy(disp_busy)
);

// read port: the harness's read-back, else the video when it fetches, else the display's scroll
zm_fb fb (
    .clk(clk),
    .w_addr(pf_we ? pf_addr : da_addr), .w_data(pf_we ? pf_wdata : da_wdata), .w_be(pf_we ? pf_be : da_be), .w_we(pf_we | da_we),
    .r_addr(dbg_fb_en ? dbg_fb_addr : vid_req ? vid_addr : da_raddr), .r_q(fb_q)
);
assign dbg_fb_q = fb_q;

zm_video #(.BLINK(BLINK)) video (
    .clk(clk), .reset(reset), .ce_pix(ce_pix), .fb_addr(vid_addr), .fb_req(vid_req), .fb_q(fb_q),
    .cur_on(cur_on), .cur_x(cur_x), .cur_y(cur_y), .cur_colour(cur_fg), .pal_we(pal_we), .pal_i(pal_i), .pal_rgb(pal_rgb),
    .ptr_on(ptr_on), .ptr_x(ptr_x), .ptr_y(ptr_y), .ptr_col(ptr_col), .flash(snd_flash),
    .r(vga_r), .g(vga_g), .b(vga_b), .hs(vga_hs), .vs(vga_vs), .hblank(vga_hblank), .vblank(vga_vblank)
);

endmodule
