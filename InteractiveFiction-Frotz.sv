//============================================================================
//  Frotz_MiSTer - native Z-machine (Infocom) interpreter. emu top level.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================
// Story files from the OSD (games/Frotz/, index 1) into BRAM + DDR3; saves in saves/Frotz/<story>.sav (Quetzal slots,
// mounted by Main with the story). Keyboard through hps_io ps2_key. Video: zm_core's 640x240p raster at 15.7 kHz
// through arcade_video (scandoubler / HQ2x / scanlines for 31 kHz, HDMI through the scaler). clk_sys = 36 MHz
// (48 MHz missed timing by 2 ns: zm_cpu's return-stack pointer behind the opcode decode, build 2026-10-21).
module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////
assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;
wire signed [15:0] audio;                              // zm_snd: sound_effect samples + beeps, both channels (Amiga)
assign AUDIO_S = 1;
assign AUDIO_L = audio;
assign AUDIO_R = audio;
assign AUDIO_MIX = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////
wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"Frotz;;",
	"H0FS1,Z? DAT,Load Story;",                       // Z? = .z1-.z8 (Main: ? matches one character; its buffer holds 4 exts).
	                                                   // H0: gone once a story is in (launchers load through it first;
	                                                   // changing games = F12, Right, Core: the launcher list)
	"H0F2,MG1EG?CG1BLB,Load Graphics;",               // V6 graphics sets; ioctl_index[7:6] = 0 MG1, 1 EG1/EG2, 2 CG1, 3 Blorb
	"H0F3,TTF,Load Font;",                             // the user's own TTF files (Flathead by Kawa, Amiga Topaz by dMG).
	                                                   // Launchers: one picture set, the fonts, the story (Main keeps 6 MGL items).
	                                                   // Main matches a launcher's file to an entry on the page shown (menu.cpp:
	                                                   // the main page), so the loads stay here until a story is in; Load Font
	                                                   // again in Game Options (a font can change mid-game)
	"H0-;",
	"P1,Game Options;",
	"P1-, -= Text =-;",
	"P1F3,TTF,Load Font;",
	"P1O[10:8],Colours,White on Black,Black on White,White on Blue,Yellow on Black,Blue on Black;",
	"P1O[2],[MORE] Prompts,On,Off;",
	"H1P1-;",
	"H1P1-, -= Pictures =-;",                          // V6 only
	"H1P1O[13:11],Graphics,Auto,MG1,Blorb,EGA,CGA;",  // Auto = the first one loaded, in this order. Changing it restarts the story.
	"P1-;",
	"P1-, -= Sound =-;",
	"P1O[21:20],Beep,Tone,Screen Flash,Off;",          // sound_effect 1 / 2; Amiga Frotz flashes the screen (DisplayBeep)
	"P1-;",
	"P1-, -= Mouse =-;",                               // zm_mouse: speed 1.25x / 0.75x / 2x / 3x; colour of the arrow's fill
	"P1O[16:15],Pointer Speed,Normal,Slow,Fast,Faster;",
	"P1O[19:17],Pointer Colour,White,Black,Red,Brown,Yellow,Green,Blue,Grey;",
	"-;",
	"O[122:121],Aspect Ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[7:5],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire         forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire  [24:0] ps2_mouse;
wire  [21:0] gamma_bus;

wire         ioctl_download, ioctl_wr, ioctl_wait;
wire  [15:0] ioctl_index;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;

wire         img_mounted, img_readonly;
wire  [63:0] img_size;
wire  [31:0] sd_lba[1];                                // unpacked arrays: VDNUM = 1
wire   [5:0] sd_blk_cnt[1];
wire   [7:0] sd_buff_din[1];
wire         sd_rd, sd_wr, sd_ack, sd_buff_wr;
wire  [13:0] sd_buff_addr;                            // hps_io: up to 16 KB blocks; 512 here
wire   [7:0] sd_buff_dout;
assign sd_blk_cnt[0] = 6'd0;                           // one 512-byte block per request

reg  loaded = 1'b0;                                    // a story has been loaded (hides Load Story: status_menumask[0])
reg  [7:0] story_ver = 8'd0;                           // its version (header byte 0); not V6 = hide Graphics (status_menumask[1])

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),
	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask({14'd0, loaded && story_ver != 8'd6, loaded}),
	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr)
);

///////////////////////   CLOCKS   ///////////////////////////////
wire clk_sys;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys)
);

// Graphics (status[13:11]: 0 Auto, 1 MG1, 2 Blorb, 3 EGA, 4 CGA) decides the V6 screen units and the picture sizes the game
// lays its windows out by, so a change restarts a V6 story (a 256-clock reset; the story stays loaded)
wire [2:0] pic_sel = status[13:11];
reg  [7:0] pic_rst = 8'd0;
always @(posedge clk_sys) begin
	reg [2:0] old_sel;
	old_sel <= pic_sel;
	if (loaded && story_ver == 8'd6 && old_sel != pic_sel) pic_rst <= 8'd255;
	else if (|pic_rst) pic_rst <= pic_rst - 1'd1;
end

wire reset = RESET | status[0] | buttons[1] | |pic_rst;

// story download (index 1); the CPU runs once a story is in and restarts after every new one
wire dl_story = ioctl_download && ioctl_index[5:0] == 6'd1;
wire dl_font  = ioctl_download && ioctl_index[5:0] == 6'd3;
wire dl_gfx   = ioctl_download && ioctl_index[5:0] == 6'd2;
always @(posedge clk_sys) begin
	reg old_dl;
	old_dl <= dl_story;
	if (old_dl & ~dl_story) loaded <= 1'b1;
	if (dl_story && ioctl_wr && ioctl_addr == 27'd0) story_ver <= ioctl_dout;
end

// colours (Z-machine numbers): white 9, black 2, blue 6, yellow 5 (status[4:3] = the old 4-choice field, unused)
wire [2:0] colsel = status[10:8];
wire [7:0] fg = colsel == 3'd1 ? 8'd2 : colsel == 3'd3 ? 8'd5 : colsel == 3'd4 ? 8'd6 : 8'd9;
wire [7:0] bg = colsel == 3'd1 ? 8'd9 : colsel == 3'd2 ? 8'd6 : 8'd2;

wire       ce_pix, hs, vs, hblank, vblank;
wire [7:0] r, g, b;

zm_core core
(
	.clk(clk_sys),
	.reset(reset),
	.ioctl_addr(ioctl_addr[24:0]),
	.ioctl_dout(ioctl_dout),
	.ioctl_wr0(ioctl_wr & dl_story),
	.ttf_dl(dl_font), .ttf_wr0(ioctl_wr & dl_font),
	.gfx_dl(dl_gfx), .gfx_wr0(ioctl_wr & dl_gfx), .gfx_ext(ioctl_index[7:6]), .pic_sel(pic_sel), .v6_need_gfx(1'b1),
	.ioctl_wait(ioctl_wait),

	.cpu_run(loaded & ~dl_story),
	.more_en(~status[2]),
	.key_valid(1'b0), .key_code(10'd0), .key_ack(),
	.use_ps2(1'b1), .ps2_key(ps2_key), .ps2_mouse(ps2_mouse), .key_hold(1'b0), .kbd_empty(),
	.ptr_speed(status[16:15]), .ptr_col(status[19:17]), .dbg_ptr_set(1'b0), .dbg_ptr_x(10'd0), .dbg_ptr_y(9'd0),
	.beep_mode(status[21:20]), .dbg_snd_end(1'b0), .audio(audio), .snd_busy(),
	.dbg_tmo(1'b0), .dbg_tmo_ext(1'b0), .tmo_busy(),
	.input_wait(),
	.rng_seed(16'd0),                                  // 0 = free-running counter
	.status_brief(1'b0),
	// header as the interpreter reports it: V4+ byte 1 = colours, bold, italic, fixed; flags-2 masks clear the
	// game's picture request (V5+ keeps colour, mouse, sound and undo). Interpreter 4 'C' (Amiga), as the
	// reference everything was verified against; V6 too (Amiga Frotz reports 4 / version 3 with the MCGA pictures,
	// and Zork Zero then draws its status line on the scroll: as 6 / IBM it prints reverse-video boxes).
	.cfg_flags1(8'h1D),
	.cfg_flags2_mask(24'hF7FFFF),                      // keeps the game's sound (V3 bit 4, V4+ bit 7) and mouse (bit 5) requests
	.cfg_interp_num(8'd4),
	.cfg_interp_ver("C"),
	.cfg_rows(8'd30),
	.cfg_cols(8'd80),
	.cfg_fg(fg),
	.cfg_bg(bg),

	.img_mounted(img_mounted),
	.img_size(img_size),
	.sd_lba(sd_lba[0]),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr[8:0]),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din[0]),
	.sd_buff_wr(sd_buff_wr),

	.dbg_req(1'b0), .dbg_addr(19'd0), .dbg_rdata(), .dbg_ack(),
	.out_char(), .out_cmd(), .out_arg0(), .out_arg1(), .out_valid(), .out_ready(), .more_wait(),
	.cur_on(), .cur_x(), .cur_y(), .snap(), .disp_busy(),
	.dbg_fb_en(1'b0), .dbg_fb_addr(15'd0), .dbg_fb_q(),
	.ce_pix(ce_pix), .vga_r(r), .vga_g(g), .vga_b(b), .vga_hs(hs), .vga_vs(vs), .vga_hblank(hblank), .vga_vblank(vblank),
	.halted(), .halt_code(), .tr_valid(), .tr_pc(), .tr_op(), .tr_ext(), .tr_argc(), .tr_args(),
	.m_req(), .m_we(), .m_orig(), .m_undo(), .m_addr(), .m_wdata(),

	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE)
);
assign DDRAM_CLK = clk_sys;

arcade_video #(.WIDTH(640), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(ce_pix),
	.RGB_in({r, g, b}),
	.HBlank(hblank),
	.VBlank(vblank),
	.HSync(hs),
	.VSync(vs),
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_HS(VGA_HS),
	.VGA_VS(VGA_VS),
	.VGA_DE(VGA_DE),
	.VGA_SL(VGA_SL),
	.fx(status[7:5]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

assign LED_USER = ioctl_download;
assign LED_DISK = {1'b1, sd_ack};

endmodule
