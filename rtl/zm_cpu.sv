// zm_cpu - Z-machine instruction engine (Z-Machine Standard 1.1). Multi-cycle FSM.
// Memory: byte port to zm_mem (req strobe / ack pulse). Stack: own 4K x 16 BRAM holding frames, locals and the
// evaluation stack. Text: ZSCII characters out on out_char/out_valid (held until out_ready).
// Shared sequences (memory/stack access, variables, objects, properties, text) are entered through an 8-deep
// return stack: push(ret) then jump; a sequence ends with sub_ret. "*_go" helpers jump without pushing (tail call).
// Anything not implemented yet halts with halt_code, so the sim stops exactly there instead of running on wrong.
//
// Frame layout (stack words, fp = first word):  fp+0 return pc[15:0]
//   fp+1 {store var[7:0], discard, args-1[2:0], 0, return pc[18:16]}   fp+2 caller fp   fp+3 local count
//   fp+4.. locals 1..n, then the routine's evaluation stack.
module zm_cpu (
    input  wire        clk,
    input  wire        reset,

    output reg         m_req = 1'b0,
    output reg         m_we  = 1'b0,
    output reg         m_orig = 1'b0,                  // read the story as loaded (DDR3), not the live BRAM copy
    output reg         m_undo = 1'b0,                  // access undo slot m_uslot (DDR3) instead
    output reg   [4:0] m_uslot = 5'd0,
    output reg  [18:0] m_addr = 19'd0,
    output reg   [7:0] m_wdata = 8'd0,
    input  wire  [7:0] m_rdata,
    input  wire        m_ack,

    output reg   [9:0] out_char = 10'd0,               // ZSCII, or the display command code (CMD_*) when out_cmd
    output reg         out_cmd = 1'b0,
    output reg  [15:0] out_arg0 = 16'd0,               // command arguments
    output reg  [15:0] out_arg1 = 16'd0,
    output reg  [15:0] out_arg2 = 16'd0,               // third argument: V6 window opcodes (set only by emit_cmd3)
    output reg         out_valid = 1'b0,               // held until out_ready
    input  wire        out_ready,
    input  wire  [3:0] v6_fw,                          // V6 font width (units): Flathead's '0', else the built-in 4 (x2 if wide)
    input  wire  [7:0] v6_cols,                        // V6 screen width in characters
    input  wire        v6_wide,                        // V6 640 units across (EGA / CGA pictures), else 320
    input  wire        gfx_ok,                         // V6 pictures are loaded (zm_pic's set)
    input  wire        v6_need_gfx,                    // V6 without pictures: stop (halt 15)
    input  wire        disp_rsp_ok,                    // picture_data: available
    input  wire [383:0] adv_prop,                      // Flathead advances (zm_ttf) and the display's os font (stream 3 widths)
    input  wire [383:0] adv_fixed,
    input  wire  [1:0] disp_wsel,
    input  wire        disp_busy,                      // zm_disp working: its answer (disp_rsp_*) is valid once it's idle
    input  wire [15:0] disp_rsp_a,
    input  wire [15:0] disp_rsp_b,
    input  wire  [9:0] click_x,                        // a mouse click's raster position (key 254 / 253; zm_core)
    input  wire  [8:0] click_y,
    output reg         snd_go = 1'b0,                  // sound_effect -> zm_snd: number, effect, volume, repeats
    output reg  [15:0] snd_num = 16'd0,
    output reg   [2:0] snd_eff = 3'd0,
    output reg   [7:0] snd_vol = 8'd0,
    output reg   [7:0] snd_rep = 8'd0,
    input  wire        snd_done,                       // zm_snd: a sound played all its repeats
    output wire        snd_pend,                       // harness: a sound's end not handled yet (keys wait for it)
    input  wire        dbg_tmo,                        // harness: time the running read / read_char out now
    input  wire        dbg_tmo_ext,                    // harness: only dbg_tmo times out (the real timer is not counted)
    output wire        tmo_busy,                       // harness: a timeout not handled yet (keys wait for it)
    input  wire        disp_irq,                       // zm_disp paused at a newline countdown: run disp_irq_addr (packed)
    input  wire [15:0] disp_irq_addr,
    input  wire        disp_nl_irq,                    // a countdown ran out inside an interrupt (not supported: halt 14)

    input  wire        key_valid,                      // next keystroke (ZSCII: 13 Return, 8 Delete), held until key_ack
    input  wire  [9:0] key_code,
    output reg         key_ack = 1'b0,
    output wire        input_wait,                     // waiting in read / read_char
    output wire        line_empty,                     // waiting in read (line input) with nothing typed: hotkeys may type

    input  wire [15:0] rng_seed,                       // random seed at start / random 0; 0 = free-running counter
    input  wire        status_brief,                   // narrow screen (< 55 columns): brief V3 status line

    input  wire  [7:0] cfg_flags1,                     // V4+ header byte 1 (bold/italic/fixed/colour/timed-input bits)
    input  wire [23:0] cfg_flags2_mask,                // AND masks on header byte 0x11 {V5+, V4, V1-3}: clear the game's requests
                                                       // the interpreter can't serve (sound, pictures, mouse, ...)
    input  wire  [7:0] cfg_interp_num,                 // header 0x1E / 0x1F
    input  wire  [7:0] cfg_interp_ver,
    input  wire  [7:0] cfg_rows,                       // screen size in characters (V4+ 0x20/0x21, V5+ 0x22/0x24 in 1x1 units)
    input  wire  [7:0] cfg_cols,
    input  wire  [7:0] cfg_fg,                         // V5+ default colours, 0x2D / 0x2C
    input  wire  [7:0] cfg_bg,

    // save file: hps_io block device 0 (Main mounts saves/<core>/<story>.sav with the story; it grows only by
    // appending). Slot n = Quetzal file at byte n x 128 KB, so slot 0 is a plain .qzl. Buffer = sd_buff_* (512 B).
    input  wire        img_mounted,
    input  wire [63:0] img_size,
    output reg  [31:0] sd_lba = 32'd0,
    output reg         sd_rd = 1'b0,
    output reg         sd_wr = 1'b0,
    input  wire        sd_ack,
    input  wire  [8:0] sd_buff_addr,
    input  wire  [7:0] sd_buff_dout,
    output wire  [7:0] sd_buff_din,
    input  wire        sd_buff_wr,

    output reg         halted = 1'b0,
    output reg   [7:0] halt_code = 8'd0,               // 1 opcode not implemented, 2 wants input (read), 3 quit,
                                                       // 4 divide by 0, 5 stack overflow, 6 return from main,
                                                       // 7 version not supported yet, 8 put_prop on a missing property,
                                                       // 9 output stream 3 nested deeper than 16,
                                                       // (10, 13: no longer used: custom alphabet tables and table save / restore are done)
                                                       // 11 throw to a frame deeper than the current one,
                                                       // 12 restore: bad save file after the state was overwritten (Frotz: fatal),
                                                       // 14 a newline interrupt inside a newline interrupt (not yet)
                                                       // 15 a V6 story without its pictures (Load Graphics)

    output reg         tr_valid = 1'b0,                // one pulse per instruction, operands resolved
    output reg  [18:0] tr_pc = 19'd0,
    output reg   [7:0] tr_op = 8'd0,
    output reg   [7:0] tr_ext = 8'd0,                  // extended opcode byte when tr_op is 0xBE (V5+)
    output reg   [3:0] tr_argc = 4'd0,
    output wire [127:0] tr_args
);

// display commands: V3 status line (begin / pad until arg0 columns are left, as Frotz pad_status_line / end),
// then the V4+ screen opcodes with their operands as arguments
localparam [7:0] CMD_SBEGIN = 8'h00, CMD_SPAD = 8'h01, CMD_SEND = 8'h02,
                 CMD_ERASE_WIN = 8'h10, CMD_SPLIT = 8'h11, CMD_SETWIN = 8'h12, CMD_CURSOR = 8'h13, CMD_STYLE = 8'h14,
                 CMD_BUFMODE = 8'h15, CMD_ERASE_LINE = 8'h16, CMD_COLOUR = 8'h17, CMD_SOUND = 8'h18,
                 CMD_ECHO = 8'h19, CMD_FONT = 8'h1A,
                 CMD_PT_BEGIN = 8'h1B, CMD_PT_ROW = 8'h1C,   // print_table: remember the cursor column / next line at it
                 CMD_RESTART = 8'h1D,                        // start / restart: reset the screen model (arg0 version, arg1 story_id, arg2 release)
                 CMD_READ = 8'h1E;                           // input next (arg0 0 line / 1 key, arg1 preloaded length):
                                                             // the display flushes its word buffer first
                                                             // (CMD_ECHO: input echo, arg0 = character, 13 = end of line,
                                                             // 8 = delete: a command so output stream 3 never captures typed text)
localparam [7:0] CMD_FLUSH = 8'h1F;                    // flush the word buffer (output_stream, V6 draw_picture / erase_picture)
// mouse: MWIN = mouse_window (arg0, -1 = the whole screen); CLICK = validate_click (arg0 x, arg1 y on the raster):
// disp_rsp_ok = inside the mouse window, disp_rsp_a / b = x / y in units relative to it (the header extension's)
localparam [7:0] CMD_MWIN = 8'h2D, CMD_CLICK = 8'h2E;
// timed input continued after the routine returned false: arg0 0 = read (console_read_input: room, the input line
// redrawn if a newline went through its window), 1 = read_char; the display snaps the screen as at CMD_READ
localparam [7:0] CMD_RCONT = 8'h2F;
// V6 window opcodes (arguments = the operands; a window argument -3 = the current window). GETCUR / GETPROP / V6 FONT
// answer on disp_rsp_a (GETCUR: y, disp_rsp_b x)
localparam [7:0] CMD_GETCUR = 8'h20, CMD_WSIZE = 8'h21, CMD_WMOVE = 8'h22, CMD_MARGINS = 8'h23, CMD_WSTYLE = 8'h24,
                 CMD_PUTPROP = 8'h25, CMD_GETPROP = 8'h26, CMD_SCROLLW = 8'h27,
                 CMD_IRET = 8'h28,                          // the newline interrupt routine has returned: finish the newline
                 CMD_MAXW = 8'h29,                          // a window's width less its margins (stream 3 width 0 / negative)
                 CMD_DRAWPIC = 8'h2A, CMD_ERASEPIC = 8'h2B,  // draw / erase_picture (picture, y, x; 0 = the cursor)
                 CMD_PICDATA = 8'h2C;                       // picture_data: height, width, available

// ---------------------------------------------------------------- states
localparam [8:0]
    S_INIT0 = 9'd0,  S_INIT1 = 9'd1,  S_INIT2 = 9'd2,  S_INIT3 = 9'd3,  S_INIT4 = 9'd4,  S_INIT5 = 9'd5,
    S_INIT6 = 9'd6,  S_INIT7 = 9'd7,  S_INIT10 = 9'd10, S_INIT11 = 9'd11, S_INIT12 = 9'd12,
    S_FETCH = 9'd16, S_OP = 9'd17, S_TY1 = 9'd18, S_TY2 = 9'd19, S_OPND = 9'd20, S_OPL1 = 9'd21, S_OPL2 = 9'd22,
    S_OPS = 9'd23, S_OPV = 9'd24, S_OPVD = 9'd25, S_TRACE = 9'd26, S_EXEC = 9'd27, S_HALT = 9'd28,
    S_RDB_W = 9'd32, S_RDW_W1 = 9'd33, S_RDW_W2 = 9'd34, S_WRB_W = 9'd35, S_WRW_W1 = 9'd36, S_WRW_W2 = 9'd37,
    S_SRD_1 = 9'd38, S_SRD_2 = 9'd39, S_VREAD = 9'd40, S_VWRITE = 9'd41, S_EMIT = 9'd42,
    S_STORE = 9'd48, S_STORE2 = 9'd49, S_BR = 9'd50, S_BR1 = 9'd51, S_BR2 = 9'd52, S_BR3 = 9'd53,
    S_RET0 = 9'd54, S_RET1 = 9'd55, S_RET2 = 9'd56, S_RET3 = 9'd57,
    S_CALL = 9'd64, S_CALL_SV = 9'd65, S_CALL_A = 9'd66, S_CALL_B = 9'd67, S_CALL_C = 9'd68, S_CALL_D = 9'd69,
    S_CALL_E = 9'd70, S_CALL_F = 9'd71, S_CALL_G = 9'd72,
    S_Z0 = 9'd80, S_Z1 = 9'd81, S_Z2 = 9'd82, S_Z3 = 9'd83, S_ZA = 9'd84, S_ZEND = 9'd85,
    S_PN0 = 9'd88, S_PN1 = 9'd89, S_PN2 = 9'd90, S_PN3 = 9'd91,
    S_DIV1 = 9'd92, S_DIV2 = 9'd93,
    S_RELRD = 9'd96, S_RELWR = 9'd97,
    S_REM0 = 9'd98, S_REM1 = 9'd99, S_REM2 = 9'd100, S_REM3 = 9'd101, S_REM4 = 9'd102, S_REM5 = 9'd103,
    S_REM6 = 9'd104, S_REM7 = 9'd105,
    S_INS1 = 9'd106, S_INS2 = 9'd107, S_INS3 = 9'd108, S_INS4 = 9'd109,
    S_PF0 = 9'd112, S_PF1 = 9'd113, S_PF2 = 9'd114, S_PF3 = 9'd115, S_PF4 = 9'd116, S_PF5 = 9'd117, S_PF6 = 9'd118,
    S_GP1 = 9'd120, S_GP2 = 9'd121, S_GPA1 = 9'd122, S_GNP1 = 9'd123, S_PP1 = 9'd124, S_GPL1 = 9'd125,
    S_INC1 = 9'd128, S_INC2 = 9'd129, S_PULL1 = 9'd130, S_RPOP1 = 9'd131, S_LOAD1 = 9'd132,
    S_REL1 = 9'd133, S_JIN1 = 9'd134, S_ATTR1 = 9'd135, S_LDW1 = 9'd136, S_PO1 = 9'd137, S_PO2 = 9'd138,
    S_PRR1 = 9'd139, S_PRR2 = 9'd140, S_INS0 = 9'd141, S_POBJ = 9'd142, S_PO3 = 9'd143,
    S_STR = 9'd144, S_RND1 = 9'd145,
    S_SS0 = 9'd150, S_SS1 = 9'd151, S_SS2 = 9'd152, S_SS3 = 9'd153, S_SS4 = 9'd154, S_SS5 = 9'd155,
    S_SS6 = 9'd156, S_SS7 = 9'd157, S_SS8 = 9'd158, S_SSEND = 9'd159,
    S_T1 = 9'd160, S_T2 = 9'd161, S_T3 = 9'd162, S_T4 = 9'd163, S_T5 = 9'd164, S_T6 = 9'd165, S_T7 = 9'd166,
    S_T8 = 9'd167, S_T9 = 9'd168,
    S_SC1 = 9'd170, S_SC2 = 9'd171, S_SC3 = 9'd172, S_SC4 = 9'd173, S_SC5 = 9'd174,
    S_EXT1 = 9'd176, S_HW = 9'd177, S_CAC1 = 9'd178,
    S_VF0 = 9'd180, S_VF1 = 9'd181, S_VF2 = 9'd182, S_VF3 = 9'd183, S_INIT6A = 9'd184, S_SSRET = 9'd185,
    S_RD0 = 9'd186, S_RD1 = 9'd187, S_RD2 = 9'd188, S_RKEY = 9'd189, S_RDONE = 9'd190, S_RDONE2 = 9'd191,
    S_RDSTORE = 9'd192, S_RCHAR = 9'd193,
    S_TL0 = 9'd194, S_TL1 = 9'd195, S_TL2 = 9'd196, S_TL3 = 9'd197, S_TL4 = 9'd198, S_TL5 = 9'd199, S_TL6 = 9'd200,
    S_TL7 = 9'd201, S_TL8 = 9'd202,
    S_TT0 = 9'd204, S_TT1 = 9'd205, S_TT2 = 9'd206, S_TT3 = 9'd207, S_TT4 = 9'd208, S_TT5 = 9'd209, S_TT6 = 9'd210,
    S_EN0 = 9'd212, S_EN1 = 9'd213, S_EN2 = 9'd214, S_EN3 = 9'd215,
    S_LK0 = 9'd216, S_LK1 = 9'd217, S_LK2 = 9'd218, S_LK3 = 9'd219, S_LK4 = 9'd220, S_LK5 = 9'd221,
    S_ET1 = 9'd224, S_ET2 = 9'd225, S_ET3 = 9'd226, S_TT7 = 9'd227,
    S_CT1 = 9'd228, S_CT2 = 9'd229, S_SCN1 = 9'd230, S_SCN2 = 9'd231,
    S_PT1 = 9'd232, S_PT2 = 9'd233, S_PT3 = 9'd234, S_INIT6B = 9'd235,
    S_SU1 = 9'd236, S_SU2 = 9'd237, S_SU4 = 9'd238, S_SU5 = 9'd239, S_SU6 = 9'd240,
    S_RU1 = 9'd241, S_RU2 = 9'd242, S_RU4 = 9'd243, S_RU4B = 9'd244, S_RU5 = 9'd245, S_RU6 = 9'd246, S_SU5B = 9'd251,
    S_RS1 = 9'd247, S_RS2 = 9'd248, S_THR1 = 9'd249, S_THR2 = 9'd250,
    // save / restore (Quetzal): slot prompt, block buffer primitives, writer, reader
    S_Q0 = 9'd256, S_Q1 = 9'd257, S_Q2 = 9'd258, S_Q3 = 9'd259, S_Q3B = 9'd260, S_Q3C = 9'd261, S_Q4 = 9'd262,
    S_Q5 = 9'd263, S_Q6 = 9'd264, S_QFAIL = 9'd265, S_QERR = 9'd266,
    S_QPUT = 9'd268, S_QFL = 9'd269, S_QW1 = 9'd270, S_QW2 = 9'd271, S_QGET = 9'd272, S_QG1 = 9'd273, S_QG2 = 9'd274,
    S_QPN = 9'd275, S_QGN = 9'd276, S_QGN1 = 9'd277,
    S_W0 = 9'd280, S_W1 = 9'd281, S_WP0 = 9'd282, S_WP1 = 9'd283, S_WP2 = 9'd284, S_WZ = 9'd285, S_WH0 = 9'd286,
    S_WH1 = 9'd287, S_CM0 = 9'd288, S_CM1 = 9'd289, S_CM2 = 9'd290, S_CM3 = 9'd291, S_CM4 = 9'd292, S_CM5 = 9'd293,
    S_WC1 = 9'd294, S_WS0 = 9'd295, S_WS1 = 9'd296, S_WF0 = 9'd297, S_WF1 = 9'd298, S_WF1B = 9'd299, S_WF2 = 9'd300,
    S_WF3 = 9'd301, S_WF4 = 9'd302, S_WF5 = 9'd303, S_WF6 = 9'd304, S_WF7 = 9'd305, S_WW0 = 9'd306, S_WW1 = 9'd307,
    S_WE0 = 9'd308,
    S_R0 = 9'd320, S_R1 = 9'd321, S_R2 = 9'd322, S_R3 = 9'd323, S_R3B = 9'd324, S_RC0 = 9'd325, S_RC1 = 9'd326,
    S_RC2 = 9'd327, S_RK0 = 9'd328, S_RPAD = 9'd329, S_RH0 = 9'd330, S_RH1 = 9'd331, S_RH2 = 9'd332, S_RH3 = 9'd333,
    S_RH4 = 9'd334, S_RH5 = 9'd335, S_RM0 = 9'd336, S_RM1 = 9'd337, S_RM2 = 9'd338, S_RM3 = 9'd339, S_RM4 = 9'd340,
    S_RM5 = 9'd341, S_RM6 = 9'd342, S_RM7 = 9'd343, S_RM8 = 9'd344, S_QU0 = 9'd345, S_QU1 = 9'd346, S_QU2 = 9'd347,
    S_QS0 = 9'd348, S_QS1 = 9'd349, S_QS2 = 9'd350, S_QS3 = 9'd351, S_QS4 = 9'd352, S_QS5 = 9'd353, S_QS6 = 9'd354,
    S_QS7 = 9'd355, S_QS8 = 9'd356, S_QS9 = 9'd357, S_QS10 = 9'd358, S_QS11 = 9'd359, S_QS12 = 9'd360,
    S_QS13 = 9'd361, S_RF = 9'd362, S_RDR = 9'd368, S_Q4R = 9'd369, S_ID0 = 9'd370, S_ID1 = 9'd371, S_BOOT0 = 9'd372, S_BOOT1 = 9'd373, S_BOOT2 = 9'd374, S_TM0 = 9'd375, S_TM1 = 9'd376, S_TM2 = 9'd377,
    S_HM0 = 9'd378, S_HM1 = 9'd379, S_HM2 = 9'd380, S_HM3 = 9'd381, S_HM4 = 9'd382, S_HM5 = 9'd383, S_HM6 = 9'd384,
    S_HM7 = 9'd385, S_HM7B = 9'd386, S_HX = 9'd387, S_HM8 = 9'd388, S_HMA = 9'd404,
    S_INIT6C = 9'd405, S_INIT6D = 9'd406, S_HW6 = 9'd407, S_V6S = 9'd408, S_PULL6 = 9'd409, S_PULL7 = 9'd410, S_PULL8 = 9'd411, S_AL0 = 9'd412, S_AL1 = 9'd413, S_EN4 = 9'd414,
    S_PS1 = 9'd415, S_PS2 = 9'd416, S_PS3 = 9'd417, S_POP1 = 9'd418, S_PDT1 = 9'd419, S_PDT2 = 9'd420, S_PDT0 = 9'd448,
    S_M3A2 = 9'd443, S_PFM1 = 9'd444, S_PFM2 = 9'd445, S_PFM3 = 9'd446, S_PFM4 = 9'd447, S_S3W = 9'd428, S_M3C = 9'd429, S_M3A = 9'd430, S_M3F0 = 9'd431, S_M3F1 = 9'd432, S_M3F2 = 9'd433,
    S_M3F3 = 9'd434, S_M3F4 = 9'd435, S_M3F5 = 9'd436, S_M3F6 = 9'd437, S_M3F9 = 9'd438, S_M3N0 = 9'd439,
    S_M3N1 = 9'd440, S_M3O1 = 9'd441, S_M3X1 = 9'd442, S_GC1 = 9'd421, S_GC2 = 9'd422, S_DRSP = 9'd423, S_ESY = 9'd424, S_INT0 = 9'd425, S_IRET = 9'd426, S_IRET2 = 9'd427,
    S_OS2 = 9'd397, S_OS3 = 9'd398, S_OS0 = 9'd399, S_SB2 = 9'd400, S_QF1 = 9'd363, S_QF2 = 9'd364, S_QF3 = 9'd365, S_QF4 = 9'd366, S_QF5 = 9'd367,
    S_CK0 = 9'd449, S_CK1 = 9'd450, S_CK2 = 9'd451, S_CK3 = 9'd452, S_CK4 = 9'd453, S_CK9 = 9'd454,
    S_RMS1 = 9'd455, S_RMS2 = 9'd456, S_RMS3 = 9'd457, S_EOS = 9'd458, S_TMO0 = 9'd459, S_TMO1 = 9'd460,
    S_X0 = 9'd461, S_X0B = 9'd462, S_X1I = 9'd463, S_X1 = 9'd464, S_X2 = 9'd465, S_X3 = 9'd466, S_X4 = 9'd467,
    S_X5 = 9'd468, S_X6 = 9'd469, S_XHIT = 9'd470, S_XNF = 9'd471, S_XR1 = 9'd472, S_XR2 = 9'd473, S_XW0 = 9'd474,
    S_XW1 = 9'd475, S_XW2 = 9'd476, S_XW3 = 9'd477, S_XW4 = 9'd478, S_XW5 = 9'd479, S_XW6 = 9'd480, S_XWE = 9'd481;

localparam [1:0] PF_FIND = 2'd0, PF_FIRST = 2'd1, PF_NEXT = 2'd2;

// ---------------------------------------------------------------- state
reg  [8:0] st = S_INIT0;
reg  [8:0] rs [0:7];
reg  [2:0] rsp = 3'd0;

reg  [3:0] version = 4'd0;
reg [15:0] id_rel = 16'd0;                             // release + serial, for Frotz's story_id (interpreter quirks)
reg [47:0] id_ser = 48'd0;
reg  [2:0] id_i = 3'd0;
reg  [3:0] story_id = 4'd0;
reg [18:0] pc = 19'd0, ipc = 19'd0;
reg [15:0] objtab = 16'd0, globals = 16'd0, abbrev = 16'd0, dict = 16'd0, static_base = 16'd0;
reg [15:0] r_off = 16'd0, s_off = 16'd0;              // V6/7 routine / string offsets (header 0x28 / 0x2A)
reg [11:0] sp = 12'd0, fp = 12'd0;
reg  [7:0] depth = 8'd0;

reg  [7:0] opbyte = 8'd0;
reg  [2:0] cls = 3'd0;                                 // 0 2OP, 1 1OP, 2 0OP, 3 VAR, 4 EXT
reg  [4:0] num = 5'd0;
reg [15:0] types = 16'hFFFF;
reg  [3:0] argc = 4'd0;
reg [15:0] ops [0:7];
reg  [7:0] tmp8 = 8'd0;
reg        hdr1_time = 1'b0;
reg  [4:0] hw_i = 5'd0;
reg        scr_on = 1'b1;                              // output stream 1
reg  [7:0] cur_font = 8'd1;
reg [15:0] ct_i = 16'd0, ct_n = 16'd0;                 // copy_table: index / count; scan_table: entries checked
reg  [1:0] ct_mode = 2'd0;                             // 0 zero fill, 1 forwards, 2 backwards
reg [15:0] sc_addr = 16'd0;
reg [15:0] pt_addr = 16'd0, pt_i = 16'd0, pt_j = 16'd0;   // print_table: address, row, column
// undo: a ring of 32 slots in DDR3 (zm_mem): slot offset 0 = dynamic memory, 0x10000 = stack words (hi, lo bytes).
// Registers per slot here. Full ring: the oldest slot is overwritten (Frotz keeps 500).
reg [15:0] u_i = 16'd0;
reg  [4:0] u_head = 5'd0;                              // next slot to save into
reg  [5:0] u_count = 6'd0;                             // saved slots available to restore
reg [18:0] sl_pc    [0:31];
reg [11:0] sl_sp    [0:31];
reg [11:0] sl_fp    [0:31];
reg  [7:0] sl_depth [0:31];
reg [15:0] sl_dyn   [0:31];                            // window 0 font (V6 per window: later)
// read / tokenise (ports of Frotz input.c z_read and text.c tokenise_line / tokenise_text / encode_text / lookup_text)
reg [15:0] rd_text = 16'd0, rd_parse = 16'd0;
reg  [7:0] rd_max = 8'd0, rd_len = 8'd0;
reg  [9:0] rd_key = 10'd0;
reg  [9:0] rd_term = 10'd13;                           // the key that ended the line (Return or a terminating key)
reg [15:0] tm_addr = 16'd0;                            // terminating characters table scan (header 0x2E)
reg        ck_line = 1'b0;                             // validate_click from read (else read_char)
reg [15:0] hx_mx = 16'd0, hx_my = 16'd0;               // Frotz hx_mouse_x / y (the last valid click; read_mouse)
reg [15:0] hx_tab = 16'd0, hx_sz = 16'd0;              // header extension table (header 0x36) and its size (word 0)
// sound (Frotz sound.c, Amiga): playing, the end-of-sound routine, Lurking Horror's queued sample (9 / 16). A sound's
// end waits for the next input (Amiga: its message is read in the input loop; stopping or starting one drops it),
// then the routine runs as a direct_call from the input wait (S_INT0 with int_snd) and the input goes on.
reg        snd_play = 1'b0, snd_endp = 1'b0, int_snd = 1'b0;
reg [15:0] snd_rtn = 16'd0, snd_cur = 16'd0, snd_nx = 16'd0;
reg  [7:0] snd_nxv = 8'd0;
reg  [8:0] int_ret = 9'd0;
assign snd_pend = snd_done | snd_endp | (int_snd & ~input_wait);   // snd_done: the clock before snd_endp, as zm_snd goes
                                                       // idle; a routine waiting for input takes keys
// timed input (Frotz z_read / z_read_char + Amiga os_read_line): time in tenths, counted from the start of input
// (keys don't restart it); at 0 the routine runs as a direct_call from the input wait. False: input goes on with a
// new period (CMD_RCONT); true: read ends with terminator 0 (no tokenising), read_char returns 0. Routine 0 = false.
localparam [21:0] TENTH = 22'd3600000;                 // clk_sys 36 MHz
reg        tm_run = 1'b0, tm_pend = 1'b0, int_tmo = 1'b0, tm_ack = 1'b0;
reg [15:0] tm_time = 16'd0, tm_rtn = 16'd0, tm_left = 16'd0, tmo_val = 16'd0;
reg [21:0] tm_pre = 22'd0;
assign tmo_busy = tm_pend | ((int_tmo | tm_ack) & ~input_wait);   // a routine waiting for input takes keys
wire [15:0] se_num = argc == 4'd0 ? 16'd1 : a;         // Amiga Frotz defaults: number 1, play, volume 8
wire [15:0] se_eff = argc < 4'd2 ? 16'd2 : b;
wire [15:0] se_vol = argc < 4'd3 ? 16'd8 : c;
wire        se_lh  = story_id == 4'd7;
function [7:0] lh_rep(input [15:0] n);                 // sound.c lh_repeats[]
    case (n)
        16'd3, 16'd6, 16'd7, 16'd8, 16'd9, 16'd11, 16'd12: lh_rep = 8'h01;
        16'd4, 16'd10, 16'd13, 16'd15, 16'd16, 16'd17, 16'd18, 16'd19: lh_rep = 8'hFF;
        default: lh_rep = 8'h00;
    endcase
endfunction
reg        scr_init = 1'b0;                            // the display has had its CMD_RESTART since reset
reg        pd_ok = 1'b0;                               // picture_data's answer, while the words are written
reg [15:0] pd_w = 16'd0;
reg        nl_pend = 1'b0;                             // a newline interrupt inside one (not supported: halt 14 at the next fetch)
// newline interrupt (V6, Frotz direct_call from screen_new_line): zm_disp pauses mid-item and raises disp_irq; the
// instruction that sent the item is stopped right there (S_ESY), so its working registers are saved here (sh_*), the
// routine runs as a call with its result discarded, and its return (back to depth int_depth) restores them (S_IRET)
// and lets the display finish. Memory, the stack, stream 3, undo and the random state are not saved: the routine's
// effects on them stay, as in Frotz.
reg        in_int = 1'b0;
reg  [7:0] int_depth = 8'd0;
integer    sh_k;
reg [8:0] sh_rs [0:7]; reg [2:0] sh_rsp; reg [18:0] sh_pc; reg [18:0] sh_ipc; reg [7:0] sh_opbyte;
reg [2:0] sh_cls; reg [4:0] sh_num; reg [15:0] sh_types; reg [3:0] sh_argc; reg [15:0] sh_ops [0:7];
reg [7:0] sh_tr_ext; reg [15:0] sh_val; reg [15:0] sh_res; reg [15:0] sh_w_val; reg [7:0] sh_v_num; reg sh_v_ind;
reg sh_cond; reg sh_then_br; reg sh_b_on; reg [13:0] sh_b_off; reg [5:0] sh_b_hi; reg [7:0] sh_c_sv; reg sh_c_disc;
reg [18:0] sh_c_raddr; reg [3:0] sh_c_n; reg [3:0] sh_c_i; reg [11:0] sh_c_nfp; reg [15:0] sh_t_pclo;
reg [15:0] sh_t_flags; reg [18:0] sh_z_addr; reg [18:0] sh_zs_addr; reg [15:0] sh_z_word; reg [15:0] sh_zs_word;
reg [1:0] sh_z_idx; reg [1:0] sh_zs_idx; reg [1:0] sh_z_shift; reg [1:0] sh_z_esc; reg [1:0] sh_z_abbr;
reg [4:0] sh_z_eschi; reg sh_z_inabbr; reg sh_z_frompc; reg [15:0] sh_pn_val; reg [15:0] sh_pn_n;
reg [2:0] sh_pn_k; reg [3:0] sh_pn_d; reg sh_pn_started; reg [15:0] sh_o_print; reg [7:0] sh_str_i;
reg [15:0] sh_pt_addr; reg [15:0] sh_pt_i; reg [15:0] sh_pt_j; reg [15:0] sh_rd_text; reg [15:0] sh_rd_parse;
reg [7:0] sh_rd_max; reg [7:0] sh_rd_len; reg [9:0] sh_rd_key; reg [9:0] sh_rd_term; reg [15:0] sh_tm_addr;
reg [19:0] sh_hx; reg [2:0] sh_hx_n;
reg [19:0] hx = 20'd0;                                 // stop message: hex digits to print (from the top) ...
reg  [2:0] hx_n = 3'd0;                                // ... and how many
reg [15:0] tk_text = 16'd0, tk_parse = 16'd0, tk_dct = 16'd0, tk_a1 = 16'd0, tk_a2 = 16'd0, tk_sep = 16'd0;
reg  [7:0] tk_len = 8'd0, tk_c = 8'd0, tk_sepn = 8'd0;
reg        tk_flag = 1'b0, tk_dosep = 1'b0;
reg [15:0] tt_len = 16'd0, tt_from = 16'd0, tt_p = 16'd0, tt_addr = 16'd0;
reg  [7:0] tt_max = 8'd0, tt_cnt = 8'd0;
reg [15:0] en_src = 16'd0, en_len = 16'd0;             // encode: source address, length (bytes)
reg  [4:0] zb [0:11];                                  // encode: Z-characters
reg  [3:0] en_zi = 4'd0, en_ci = 4'd0;
reg  [7:0] alph [0:77];                                // A0 / A1 / A2: the default, or the story's table (header 0x34, V5+)
reg  [6:0] al_i = 7'd0, en_k = 7'd0;
reg [15:0] alph_addr = 16'd0;
reg  [7:0] en_c = 8'd0;
reg  [4:0] en_pad = 5'd5;
reg [15:0] enc0 = 16'd0, enc1 = 16'd0, enc2 = 16'd0;   // encoded word
reg [15:0] lk_ent = 16'd0, lk_ea = 16'd0;
reg  [7:0] lk_elen = 8'd0;
reg        lk_sorted = 1'b0;
reg signed [16:0] lk_lo = 17'sd0, lk_hi = 17'sd0, lk_n = 17'sd0;
reg  [1:0] lk_i = 2'd0;
reg  [4:0] s3_lvl = 5'd0;                              // output stream 3 nesting (0 = off, max 16)
reg [15:0] s3_tab [0:15];
reg [15:0] s3_cnt [0:15];
// V6 stream 3 goes through Frotz's word buffer (m3_*: flushed before a space / indent / gap, after a hyphen, at a new
// line, open and close) so each word is measured: redirect width (s3_wid) / total (s3_tot), and with a width to wrap
// at (s3_xs; 0xFFFF = none) the table becomes line records [count][chars]... ending in an empty one (memory_word /
// memory_new_line / memory_close). Widths: 4 units a character, indent 12, gap 8 (the fixed font).
reg [15:0] s3_wid [0:15];
reg [15:0] s3_tot [0:15];
reg [15:0] s3_xs  [0:15];
reg [15:0] s3_cw = 16'd0;                              // the closing width: header 0x30 (H_LINE_WIDTH)
reg  [7:0] m3_buf [0:255];
reg  [7:0] m3_q = 8'd0, m3_ra = 8'd0, m3_prev = 8'd0;
reg  [8:0] m3_pos = 9'd0, m3_i = 9'd0;
reg [15:0] m3_wd = 16'd0;
reg  [1:0] m3_after = 2'd0;                            // after the flush: 0 close, 1 new line, 2 the character, 3 open
reg        m3_we = 1'b0;
reg  [7:0] m3_wc = 8'd0;
always @(posedge clk) begin
    if (m3_we) m3_buf[m3_pos[7:0]] <= m3_wc;
    m3_q <= m3_buf[m3_ra];
end                                // header write table index
reg [18:0] vf_addr = 19'd0, vf_end = 19'd0;            // verify: running address, file length
reg [15:0] vf_sum = 16'd0, vf_want = 16'd0;                           // header byte 1 bit 1: V3 status line shows time

reg [15:0] val = 16'd0;                                // result of every read sequence
reg [15:0] res = 16'd0;                                // instruction result (store / return value)
reg [15:0] w_val = 16'd0;                              // value for VWRITE / RELWR / WRW
reg  [7:0] v_num = 8'd0;
reg        v_ind = 1'b0;                               // indirect variable reference: var 0 = top of stack in place
reg        cond = 1'b0, then_br = 1'b0;
reg        b_on = 1'b0;
reg [13:0] b_off = 14'd0;
reg  [5:0] b_hi = 6'd0;

reg  [7:0] c_sv = 8'd0;
reg        c_disc = 1'b0;
reg [18:0] c_raddr = 19'd0;
reg  [3:0] c_n = 4'd0, c_i = 4'd0;
reg [11:0] c_nfp = 12'd0;
reg [15:0] t_pclo = 16'd0, t_flags = 16'd0;

reg [18:0] z_addr = 19'd0, zs_addr = 19'd0;
reg [15:0] z_word = 16'd0, zs_word = 16'd0;
reg  [1:0] z_idx = 2'd0, zs_idx = 2'd0, z_shift = 2'd0, z_esc = 2'd0, z_abbr = 2'd0;
reg  [1:0] z_lock = 2'd0, zs_lock = 2'd0;              // V1/V2 shift lock (Frotz shift_lock; 0 in V3+)
reg  [4:0] z_eschi = 5'd0;
reg        z_inabbr = 1'b0, z_frompc = 1'b0;

reg [15:0] pn_val = 16'd0, pn_n = 16'd0;
reg  [2:0] pn_k = 3'd0;
reg  [3:0] pn_d = 4'd0;
reg        pn_started = 1'b0;

reg [15:0] d_n = 16'd0, d_d = 16'd0, d_q = 16'd0, d_r = 16'd0;
reg  [3:0] d_i = 4'd0;

reg [15:0] o_print = 16'd0;
reg  [7:0] str_i = 8'd0;                               // index into the interpreter's string ROM (str_rom)
reg [15:0] g0 = 16'd0, g1 = 16'd0, g2 = 16'd0;         // show_status: location, score/hours, moves/minutes
reg [16:0] ss_h = 17'd0;

reg [31:0] rng_a = 32'd1;                              // Frotz random.c: A = 0x015a4e35 * A + 1, result (A >> 16) & 0x7fff
reg [15:0] rng_interval = 16'd0, rng_counter = 16'd0;  // seeds 1..999: counting mode
reg [14:0] tick = 15'd0;

reg [15:0] r_obj = 16'd0;
reg  [1:0] r_fld = 2'd0;                               // 0 parent, 1 sibling, 2 child
reg [15:0] o_obj = 16'd0, o_dst = 16'd0, o_par = 16'd0, o_x = 16'd0, o_sib = 16'd0;

reg [15:0] p_obj = 16'd0, p_pa = 16'd0, p_data = 16'd0;
reg  [5:0] p_num = 6'd0, p_cur = 6'd0;
reg  [6:0] p_size = 7'd0;
reg  [1:0] p_mode = PF_FIND;
reg        p_found = 1'b0;

// save / restore (Frotz quetzal.c, stdio slot prompt). sav_floor/ceil = save file length in whole / started blocks;
// Main only writes a block at or below the whole-block length (block 0 creates the file), so writes go in order.
reg        sav_mnt = 1'b0;
reg [15:0] sav_floor = 16'd0, sav_ceil = 16'd0;
reg        q_rest = 1'b0, q_dry = 1'b0, q_wr = 1'b0, q_need = 1'b0, q_first = 1'b0, q_padfirst = 1'b0, q_zeroed = 1'b0;
reg        q_bad = 1'b0, q_fatal = 1'b0, q_pad = 1'b0, q_rhdr = 1'b0;
reg  [3:0] q_slot = 4'd0;
reg  [8:0] q_bp = 9'd0;                                // block buffer position
reg [15:0] q_lba = 16'd0;                              // next block to write / read
// V5+ save / restore with a table (Frotz's auxiliary file, named by the game: zargs[2], lowercased): kept in save-file
// slots 10-15 (the prompt lists 0-9), one file each: "ZAUX", length (2), name length (1), name, the bytes. Save: the
// slot with that name, else the first free one (none: 0); restore: the bytes up to the table's size (Frotz fread),
// stores the count (no such file: 0). No prompt (Frotz stdio -V: none for these).
reg        q_aux = 1'b0;
reg [15:0] x_tab = 16'd0, x_len = 16'd0, x_nm = 16'd0, x_flen = 16'd0, x_n = 16'd0;
reg  [7:0] x_nlen = 8'd0, x_k = 8'd0;
reg  [3:0] x_free = 4'd0;
function [7:0] lc(input [7:0] ch);                     // get_default_name: A-Z lowered
    lc = ch >= 8'h41 && ch <= 8'h5A ? ch + 8'h20 : ch;
endfunction
reg  [7:0] q_byte = 8'd0, q_x = 8'd0;
reg [31:0] q_cnt = 32'd0, q_cmlen = 32'd0;             // bytes put (dry pass), CMem length
reg [15:0] q_i = 16'd0;
reg [16:0] q_run = 17'd0;
reg  [5:0] q_hi = 6'd0;
reg [47:0] q_out = 48'd0;                              // bytes to put, from the top
reg  [2:0] q_k = 3'd0;                                 // byte count for S_QPN / S_QGN
reg [31:0] q_acc = 32'd0;                              // bytes got, shifted in from the bottom
reg  [8:0] q_fk = 9'd0;                                // frame being written (0 = Quetzal's dummy frame)
reg [11:0] q_cur = 12'd0, q_nxt = 12'd0, q_wi = 12'd0, q_wend = 12'd0;
reg  [7:0] q_wn = 8'd0;
reg [15:0] q_fl = 16'd0, q_pclo = 16'd0, q_n = 16'd0;
reg [31:0] q_rem = 32'd0, q_id = 32'd0, q_clen = 32'd0, q_pcf = 32'd0;
reg  [2:0] q_got = 3'd0;                               // IFhd, Stks, memory
reg [18:0] q_npc = 19'd0;
reg  [1:0] q_f11 = 2'd0;                               // flags 2 bits 0-1 before the restore (Frotz h_flags keeps them)
reg  [7:0] q_or = 8'd0, q_oc = 8'd0, q_var = 8'd0;
reg  [8:0] b_addr = 9'd0;
reg  [7:0] b_wd = 8'd0;
reg        b_we = 1'b0;
wire [7:0] b_q;
dpram_dc #(.widthad_a(9), .width_a(8)) sdbuf (
    .clock_a(clk), .address_a(sd_buff_addr), .data_a(sd_buff_dout), .wren_a(sd_buff_wr & sd_ack), .byteena_a(1'b1), .q_a(sd_buff_din),
    .clock_b(clk), .address_b(b_addr), .data_b(b_wd), .wren_b(b_we), .byteena_b(1'b1), .q_b(b_q)
);

wire [15:0] q_base = {4'd0, q_slot, 8'd0};             // slot stride 128 KB = 256 blocks
wire [31:0] q_stkslen = 32'd8 + {19'd0, sp, 1'b0};    // every stack word once, 8-byte frame headers = 4 words
wire [31:0] q_ifzslen = 32'd42 + q_cmlen + {31'd0, q_cmlen[0]} + q_stkslen;

// stack BRAM
reg  [11:0] s_addr = 12'd0;
reg  [15:0] s_wdata = 16'd0;
reg         s_we = 1'b0;
wire [15:0] s_q;
spram #(.DATA_WIDTH(16), .ADDR_WIDTH(12)) stack (.clk(clk), .addr(s_addr), .data(s_wdata), .we(s_we), .q(s_q));

wire [15:0] a = ops[0], b = ops[1], c = ops[2], d = ops[3];
wire        v3 = version <= 4'd3;
wire  [7:0] f2_mask = version < 4'd3 ? 8'hFF : v3 ? cfg_flags2_mask[7:0] : version == 4'd4 ? cfg_flags2_mask[15:8]
                     : cfg_flags2_mask[23:16] | (version == 4'd6 && gfx_ok ? 8'h08 : 8'h00);   // V6 + pictures: bit 3 stays
wire  [7:0] oid = {cls, num};
wire        time_game = hdr1_time;
wire [31:0] rng_next = rng_a * 32'h015A4E35 + 32'd1;
wire [15:0] seed_src = rng_seed != 16'd0 ? rng_seed : {1'b0, tick};

assign tr_args = {ops[7], ops[6], ops[5], ops[4], ops[3], ops[2], ops[1], ops[0]};

// ---------------------------------------------------------------- helpers
function m3_space(input [7:0] ch);                     // space, ZC_INDENT, ZC_GAP
    m3_space = ch == 8'h20 || ch == 8'd9 || ch == 8'd11;
endfunction
// stream 3 widths: one lookup, of the character the state is measuring (S_M3F2: the flushed word's first; else
// the one being added); os_char_width in units in the display's os font (zm_disp lk_w): indent / gap = 3 / 2 spaces
wire  [7:0] m3_lc = st == S_M3F2 ? m3_q : out_char[7:0];
wire  [7:0] m3_lb = m3_lc == 8'd9 || m3_lc == 8'd11 ? 8'h20 : m3_lc;
wire  [6:0] m3_ti = m3_lb[6:0] - 7'd32;                 // its table index
wire  [3:0] advp [0:127], advf [0:127];                // 96-entry tables (not a variable part-select of the bus)
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
wire  [3:0] m3_adv = disp_wsel == 2'd1 ? advp[m3_ti] : advf[m3_ti];
wire [15:0] m3_1 = (disp_wsel == 2'd0 || m3_lb < 8'd32 || m3_lb > 8'd126 ? 16'd4 : {12'd0, m3_adv}) << v6_wide;
wire [15:0] m3_lw = (m3_lc >= 8'd32 && m3_lc <= 8'd126) || (m3_lc >= 8'd155 && m3_lc <= 8'd251) ? m3_1
                  : m3_lc == 8'd9 ? m3_1 + (m3_1 << 1) : m3_lc == 8'd11 ? m3_1 << 1 : 16'd0;

function [15:0] oaddr(input [15:0] n, input is_v3, input [15:0] tab);   // object entry address
    oaddr = is_v3 ? tab + 16'd53 + {n[12:0], 3'b000} + n                // 31 default words + 9 bytes per object
                  : tab + 16'd112 + {n[11:0], 4'b0000} - {n[14:0], 1'b0}; // 63 default words + 14 bytes per object
endfunction

function [18:0] unpack(input [15:0] p, input [3:0] ver, input [15:0] off);   // packed address (off: V6/7 offset)
    case (ver)
        4'd1, 4'd2, 4'd3: unpack = {2'b00, p, 1'b0};
        4'd6, 4'd7:       unpack = {1'b0, p, 2'b00} + {off, 3'b000};
        4'd8:             unpack = {p, 3'b000};
        default:          unpack = {1'b0, p, 2'b00};
    endcase
endfunction

function [7:0] alpha_v1(input [4:0] i);                // V1 A2: " 0123456789.,!?_#'"/\<-:()" (no new line)
    case (i)
        5'd0: alpha_v1 = " ";  5'd11: alpha_v1 = "."; 5'd12: alpha_v1 = ","; 5'd13: alpha_v1 = "!"; 5'd14: alpha_v1 = "?";
        5'd15: alpha_v1 = "_"; 5'd16: alpha_v1 = "#"; 5'd17: alpha_v1 = 8'h27; 5'd18: alpha_v1 = 8'h22; 5'd19: alpha_v1 = "/";
        5'd20: alpha_v1 = 8'h5C; 5'd21: alpha_v1 = "<"; 5'd22: alpha_v1 = "-"; 5'd23: alpha_v1 = ":"; 5'd24: alpha_v1 = "(";
        5'd25: alpha_v1 = ")";
        default: alpha_v1 = 8'h30 + {3'd0, i - 5'd1};  // 1..10: digits
    endcase
endfunction
function [1:0] zshift(input [1:0] lock, input [4:0] zch); // Frotz: (shift_lock + (c & 1) + 1) % 3
    zshift = lock == 2'd0 ? (zch[0] ? 2'd2 : 2'd1) : lock == 2'd1 ? (zch[0] ? 2'd0 : 2'd2) : (zch[0] ? 2'd1 : 2'd0);
endfunction
function [7:0] alpha(input [1:0] sh, input [4:0] zc);                 // zc 6..31, A2 6/7 handled by the caller
    reg [4:0] i;
    begin
        i = zc - 5'd6;
        case (sh)
            2'd0: alpha = 8'h61 + {3'd0, i};
            2'd1: alpha = 8'h41 + {3'd0, i};
            default:
                case (i)
                    5'd2: alpha = "0";  5'd3: alpha = "1";  5'd4: alpha = "2";  5'd5: alpha = "3";
                    5'd6: alpha = "4";  5'd7: alpha = "5";  5'd8: alpha = "6";  5'd9: alpha = "7";
                    5'd10: alpha = "8"; 5'd11: alpha = "9"; 5'd12: alpha = "."; 5'd13: alpha = ",";
                    5'd14: alpha = "!"; 5'd15: alpha = "?"; 5'd16: alpha = "_"; 5'd17: alpha = "#";
                    5'd18: alpha = 8'h27; 5'd19: alpha = 8'h22; 5'd20: alpha = "/"; 5'd21: alpha = 8'h5C;
                    5'd22: alpha = "-"; 5'd23: alpha = ":"; 5'd24: alpha = "("; 5'd25: alpha = ")";
                    default: alpha = "?";
                endcase
        endcase
    end
endfunction

// interpreter strings, each 0-terminated (13 = new line): 0 "Time: "  7 "Score: "  15 "S: "  19 "Moves: "  27 "M: "
// 31 / 52: the save-slot prompt (Frotz stdio -V)  78 restore_quetzal's wrong-story message  115..: the stop message
localparam int STR_N = 158;
localparam [8*STR_N-1:0] STRS = {"Time: ", 8'd0, "Score: ", 8'd0, "S: ", 8'd0, "Moves: ", 8'd0, "M: ", 8'd0,
                                 "Current saved games:", 8'd0, 8'd13, "Enter game number (0-9):", 8'd0,
                                 "File was not saved from this story!", 8'd13, 8'd0,
                                 8'd13, "[Frotz_MiSTer stopped: code ", 8'd0, " at ", 8'd0, " op ", 8'd0, "]", 8'd13, 8'd0};
localparam [7:0] STR_CUR = 8'd31, STR_ENTER = 8'd52, STR_NOTTHIS = 8'd78,
                 STR_STOP = 8'd115, STR_AT = 8'd145, STR_OP = 8'd150, STR_END = 8'd155;   // 115..157: the stop message
function [7:0] str_rom(input [7:0] i);
    str_rom = STRS[8 * (STR_N - 1 - {24'd0, i}) +: 8];
endfunction

// Quetzal file bytes 0..41: FORM len IFZS, IFhd 13 (release / serial / checksum come from memory, see qhaddr),
// pc + pad, then the CMem chunk header
function [7:0] qhdr(input [5:0] i, input [31:0] flen, input [31:0] clen, input [18:0] p);
    case (i)
        6'd0: qhdr = "F";  6'd1: qhdr = "O";  6'd2: qhdr = "R";  6'd3: qhdr = "M";
        6'd4: qhdr = flen[31:24]; 6'd5: qhdr = flen[23:16]; 6'd6: qhdr = flen[15:8]; 6'd7: qhdr = flen[7:0];
        6'd8: qhdr = "I";  6'd9: qhdr = "F";  6'd10: qhdr = "Z"; 6'd11: qhdr = "S";
        6'd12: qhdr = "I"; 6'd13: qhdr = "F"; 6'd14: qhdr = "h"; 6'd15: qhdr = "d"; 6'd19: qhdr = 8'd13;
        6'd30: qhdr = {5'd0, p[18:16]}; 6'd31: qhdr = p[15:8]; 6'd32: qhdr = p[7:0];
        6'd34: qhdr = "C"; 6'd35: qhdr = "M"; 6'd36: qhdr = "e"; 6'd37: qhdr = "m";
        6'd38: qhdr = clen[31:24]; 6'd39: qhdr = clen[23:16]; 6'd40: qhdr = clen[15:8]; 6'd41: qhdr = clen[7:0];
        default: qhdr = 8'd0;
    endcase
endfunction

function [18:0] qhaddr(input [3:0] i);                   // IFhd story id: release 0x02, serial 0x12-0x17, checksum 0x1C
    qhaddr = i < 4'd2 ? 19'h02 + {15'd0, i} : i < 4'd8 ? 19'h10 + {15'd0, i} : 19'h14 + {15'd0, i};
endfunction

function [3:0] qnargs(input [7:0] m);                    // Quetzal argument mask 2^n - 1 -> n; 15 = not such a mask
    case (m)
        8'h00: qnargs = 4'd0; 8'h01: qnargs = 4'd1; 8'h03: qnargs = 4'd2; 8'h07: qnargs = 4'd3;
        8'h0F: qnargs = 4'd4; 8'h1F: qnargs = 4'd5; 8'h3F: qnargs = 4'd6; 8'h7F: qnargs = 4'd7;
        default: qnargs = 4'd15;
    endcase
endfunction
wire  [3:0] q_na = qnargs(q_x);                         // restore: arguments supplied

// Frotz fastmem.c records[]: story_id from release + serial. 1 Sherlock, 2 Beyond Zork, 3 Zork Zero, 4 Shogun,
// 5 Arthur, 6 Journey, 7 Lurking Horror, 0 anything else
function [3:0] frotz_story(input [15:0] rel, input [47:0] ser);
    case ({rel, ser})
        {16'd21, "871214"}, {16'd26, "880127"}:                                         frotz_story = 4'd1;
        {16'd47, "870915"}, {16'd49, "870917"}, {16'd51, "870923"}, {16'd57, "871221"}:   frotz_story = 4'd2;
        {16'd296, "881019"}, {16'd366, "890323"}, {16'd383, "890602"}, {16'd393, "890714"}: frotz_story = 4'd3;
        {16'd292, "890314"}, {16'd295, "890321"}, {16'd311, "890510"}, {16'd322, "890706"}: frotz_story = 4'd4;
        {16'd54, "890606"}, {16'd63, "890622"}, {16'd74, "890714"}:                       frotz_story = 4'd5;
        {16'd26, "890316"}, {16'd30, "890322"}, {16'd77, "890616"}, {16'd83, "890706"}:   frotz_story = 4'd6;
        {16'd203, "870506"}, {16'd219, "870912"}, {16'd221, "870918"}:                    frotz_story = 4'd7;
        default:                                                                         frotz_story = 4'd0;
    endcase
endfunction

function [15:0] pow10(input [2:0] k);
    case (k)
        3'd0: pow10 = 16'd10000; 3'd1: pow10 = 16'd1000; 3'd2: pow10 = 16'd100; 3'd3: pow10 = 16'd10;
        default: pow10 = 16'd1;
    endcase
endfunction

wire [15:0] glob_addr = globals + {7'd0, v_num, 1'b0} - 16'd32;
wire [11:0] local_addr = fp + 12'd3 + {4'd0, v_num};
wire [15:0] rel_addr = oaddr(r_obj, v3, objtab) + (v3 ? {14'd0, r_fld} + 16'd4 : {13'd0, r_fld, 1'b0} + 16'd6);
wire [4:0]  zc = z_idx == 2'd0 ? z_word[14:10] : z_idx == 2'd1 ? z_word[9:5] : z_word[4:0];
wire [16:0] d_r2 = {d_r, d_n[15]};
wire  [3:0] s3_top = s3_lvl[3:0] - 4'd1;
wire  [3:0] en_res3 = v3 ? 4'd6 : 4'd9;                 // Z-characters per dictionary word
wire [15:0] enc_i = lk_i == 2'd0 ? enc0 : lk_i == 2'd1 ? enc1 : enc2;
wire        lk_last = lk_i == (v3 ? 2'd1 : 2'd2);
wire signed [16:0] lk_mid = lk_sorted ? (lk_lo + lk_hi) >>> 1 : lk_lo;   // entry_number (lo <= hi, both >= 0)
wire [15:0] lk_addr = lk_ent + lk_mid[15:0] * {8'd0, lk_elen};
assign input_wait = st == S_RKEY || st == S_RCHAR || st == S_Q4;
assign line_empty = st == S_RKEY && rd_len == 8'd0;

wire [15:0] neg_b = -b;
wire [15:0] art_r = $signed(a) >>> neg_b;               // own wire: inside a mixed ternary >>> would go unsigned

// ---------------------------------------------------------------- sequence helpers
task push(input [8:0] ret);
    begin rs[rsp] <= ret; rsp <= rsp + 3'd1; end
endtask
task sub_ret;
    begin st <= rs[rsp - 3'd1]; rsp <= rsp - 3'd1; end
endtask
task rdb_go(input [18:0] ad);
    begin m_addr <= ad; m_we <= 1'b0; m_orig <= 1'b0; m_undo <= 1'b0; m_req <= 1'b1; st <= S_RDB_W; end
endtask
task rdb_orig_go(input [18:0] ad);
    begin m_addr <= ad; m_we <= 1'b0; m_orig <= 1'b1; m_undo <= 1'b0; m_req <= 1'b1; st <= S_RDB_W; end
endtask
task rdw_go(input [18:0] ad);
    begin m_addr <= ad; m_we <= 1'b0; m_orig <= 1'b0; m_undo <= 1'b0; m_req <= 1'b1; st <= S_RDW_W1; end
endtask
task pcb_go;                                           // next byte at pc -> val, pc++
    begin m_addr <= pc; pc <= pc + 19'd1; m_we <= 1'b0; m_orig <= 1'b0; m_undo <= 1'b0; m_req <= 1'b1; st <= S_RDB_W; end
endtask
task wrb_go(input [18:0] ad, input [7:0] dt);
    begin m_addr <= ad; m_wdata <= dt; m_we <= 1'b1; m_undo <= 1'b0; m_req <= 1'b1; st <= S_WRB_W; end
endtask
task wrw_go(input [18:0] ad, input [15:0] dt);
    begin m_addr <= ad; m_wdata <= dt[15:8]; w_val <= dt; m_we <= 1'b1; m_undo <= 1'b0; m_req <= 1'b1; st <= S_WRW_W1; end
endtask
task rdb_undo_go(input [18:0] ad);
    begin m_addr <= ad; m_we <= 1'b0; m_orig <= 1'b0; m_undo <= 1'b1; m_req <= 1'b1; st <= S_RDB_W; end
endtask
task wrb_undo_go(input [18:0] ad, input [7:0] dt);
    begin m_addr <= ad; m_wdata <= dt; m_we <= 1'b1; m_undo <= 1'b1; m_req <= 1'b1; st <= S_WRB_W; end
endtask
task srd_go(input [11:0] ad);
    begin s_addr <= ad; st <= S_SRD_1; end
endtask
task swr(input [11:0] ad, input [15:0] dt);
    begin s_addr <= ad; s_wdata <= dt; s_we <= 1'b1; end
endtask
task emit(input [9:0] ch, input [8:0] ret);
    begin out_char <= ch; out_cmd <= 1'b0; push(ret); st <= S_EMIT; end
endtask
task emit_cmd(input [7:0] cmd, input [15:0] arg0, input [15:0] arg1, input [8:0] ret);
    begin out_char <= {2'd0, cmd}; out_arg0 <= arg0; out_arg1 <= arg1; out_cmd <= 1'b1; push(ret); st <= S_EMIT; end
endtask
task emit_cmd3(input [7:0] cmd, input [15:0] arg0, input [15:0] arg1, input [15:0] arg2, input [8:0] ret);
    begin out_char <= {2'd0, cmd}; out_arg0 <= arg0; out_arg1 <= arg1; out_arg2 <= arg2; out_cmd <= 1'b1; push(ret); st <= S_EMIT; end
endtask
task emit_str(input [7:0] at, input [8:0] ret);
    begin str_i <= at; push(ret); st <= S_STR; end
endtask
task pnum(input [15:0] v, input [8:0] ret);
    begin pn_val <= v; push(ret); st <= S_PN0; end
endtask
task pobj(input [15:0] obj, input [8:0] ret);
    begin o_print <= obj; push(ret); st <= S_POBJ; end
endtask
task zdec(input [18:0] ad, input frompc, input [8:0] ret);
    begin
        z_addr <= ad; z_frompc <= frompc; z_shift <= 2'd0; z_lock <= 2'd0; z_esc <= 2'd0; z_abbr <= 2'd0; z_inabbr <= 1'b0;
        push(ret); st <= S_Z0;
    end
endtask
task vread(input [7:0] vn, input ind, input [8:0] ret);
    begin v_num <= vn; v_ind <= ind; push(ret); st <= S_VREAD; end
endtask
task vwrite(input [7:0] vn, input ind, input [15:0] dt, input [8:0] ret);
    begin v_num <= vn; v_ind <= ind; w_val <= dt; push(ret); st <= S_VWRITE; end
endtask
task relrd(input [15:0] obj, input [1:0] fld, input [8:0] ret);
    begin r_obj <= obj; r_fld <= fld; push(ret); st <= S_RELRD; end
endtask
task relwr(input [15:0] obj, input [1:0] fld, input [15:0] dt, input [8:0] ret);
    begin r_obj <= obj; r_fld <= fld; w_val <= dt; push(ret); st <= S_RELWR; end
endtask
task pfind(input [15:0] obj, input [5:0] pn, input [1:0] mode, input [8:0] ret);
    begin p_obj <= obj; p_num <= pn; p_mode <= mode; push(ret); st <= S_PF0; end
endtask
task store(input [15:0] r);
    begin res <= r; then_br <= 1'b0; st <= S_STORE; end
endtask
task branch(input cnd);
    begin cond <= cnd; st <= S_BR; end
endtask
task halt(input [7:0] code);                           // anything but quit says so on the screen first (S_HM*)
    begin halt_code <= code; st <= code == 8'd3 ? S_HALT : S_HM0; end
endtask

// ---------------------------------------------------------------- engine
always @(posedge clk) begin
    m_req    <= 1'b0;
    s_we     <= 1'b0;
    tr_valid <= 1'b0;
    tick     <= tick + 15'd1;
    key_ack  <= 1'b0;
    snd_go   <= 1'b0;
    if (snd_done) snd_endp <= 1'b1;
    if (tm_run && !dbg_tmo_ext) begin
        if (tm_pre == TENTH - 22'd1) begin
            tm_pre <= 22'd0;
            if (tm_left <= 16'd1) begin tm_run <= 1'b0; tm_pend <= 1'b1; end else tm_left <= tm_left - 16'd1;
        end
        else tm_pre <= tm_pre + 22'd1;
    end
    if (dbg_tmo && tm_run) begin tm_run <= 1'b0; tm_pend <= 1'b1; end
    b_we     <= 1'b0;
    m3_we    <= 1'b0;
    if (img_mounted) begin                             // also while held in reset: Main mounts it during the download
        sav_mnt   <= 1'b1;
        sav_floor <= img_size[63:25] != 39'd0 ? 16'hFFFF : img_size[24:9];
        sav_ceil  <= img_size[63:25] != 39'd0 ? 16'hFFFF : img_size[24:9] + {15'd0, img_size[8:0] != 9'd0};
    end

    if (disp_nl_irq) nl_pend <= 1'b1;

    if (reset) begin
        st <= S_BOOT0; rsp <= 3'd0; out_valid <= 1'b0; halted <= 1'b0; halt_code <= 8'd0; scr_init <= 1'b0;
        ipc <= 19'd0; opbyte <= 8'd0; tr_ext <= 8'd0;     // a start-up stop reports address 0, not the last run's
        nl_pend <= 1'b0; in_int <= 1'b0;
        snd_play <= 1'b0; snd_endp <= 1'b0; int_snd <= 1'b0; snd_nx <= 16'd0; snd_cur <= 16'd0;
        tm_run <= 1'b0; tm_pend <= 1'b0; int_tmo <= 1'b0; tm_ack <= 1'b0;
    end
    else case (st)

    // ------------------------------------------------ reset = restart: dynamic memory from the story as loaded first
    S_BOOT0: begin push(S_BOOT1); rdb_orig_go(19'h0E); end
    S_BOOT1: begin tmp8 <= val[7:0]; push(S_BOOT2); rdb_orig_go(19'h0F); end
    S_BOOT2: begin static_base <= {tmp8, val[7:0]}; u_i <= 16'd0; st <= S_RS1; end

    // ------------------------------------------------ start: header fields, then the interpreter's header bytes
    S_INIT0: begin push(S_INIT1); rdb_go(19'h00); end
    S_INIT1: begin version <= val[3:0]; push(S_INIT2); rdw_go(19'h06); end
    S_INIT2: begin pc <= {3'd0, val}; push(S_INIT3); rdw_go(19'h08); end
    S_INIT3: begin dict <= val; push(S_INIT4); rdw_go(19'h0A); end
    S_INIT4: begin objtab <= val; push(S_INIT5); rdw_go(19'h0C); end
    S_INIT5: begin globals <= val; push(S_INIT6); rdw_go(19'h18); end
    S_INIT6: begin
        abbrev <= val;
        push(S_INIT6C); rdw_go(19'h28);
    end
    S_INIT6C: begin r_off <= val; push(S_INIT6D); rdw_go(19'h2A); end   // V6/7 only; harmless before
    S_INIT6D: begin s_off <= val; push(S_INIT6A); rdw_go(19'h34); end
    S_INIT6A: begin alph_addr <= version >= 4'd5 ? val : 16'd0; al_i <= 7'd0; st <= S_AL0; end
    S_AL0: begin                                       // the alphabet into alph (Frotz alphabet(): the table bytes as stored)
        if (al_i == 7'd78) begin push(S_INIT6B); rdw_go(19'h0E); end
        else if (alph_addr != 16'd0) begin push(S_AL1); rdb_go({3'd0, alph_addr + {9'd0, al_i}}); end
        else begin
            alph[al_i] <= al_i < 7'd26 ? 8'h61 + {1'b0, al_i} : al_i < 7'd52 ? 8'h41 + {1'b0, al_i} - 8'd26
                        : version == 4'd1 ? alpha_v1(al_i[4:0] - 5'd20)                                    // 52 + i -> i
                        : al_i == 7'd52 ? 8'h20 : al_i == 7'd53 ? 8'h5E : alpha(2'd2, al_i[4:0] - 5'd14);   // 52 + i -> zc i + 6
            al_i <= al_i + 7'd1;
        end
    end
    S_AL1: begin alph[al_i] <= val[7:0]; al_i <= al_i + 7'd1; st <= S_AL0; end
    S_INIT6B: begin static_base <= val; id_i <= 3'd0; push(S_ID0); rdw_go(19'h02); end
    S_ID0: begin id_rel <= val; st <= S_ID1; end
    S_ID1: begin                                       // 6 serial bytes, then Frotz's story table
        if (id_i != 3'd0) id_ser <= {id_ser[39:0], val[7:0]};
        if (id_i == 3'd6) begin story_id <= frotz_story(id_rel, {id_ser[39:0], val[7:0]}); push(S_INIT7); rdb_go(19'h01); end
        else begin id_i <= id_i + 3'd1; push(S_ID1); rdb_go(19'h12 + {16'd0, id_i}); end
    end
    S_INIT7: begin                                     // header byte 1
        hdr1_time <= val[1];
        push(S_INIT11);
        if (version == 4'd3) wrb_go(19'h01, (val[7:0] & 8'hAF) | 8'h20);   // V3: status line + split screen available, fixed-pitch default off
        else if (v3) wrb_go(19'h01, val[7:0]);              // V1/V2: as stored (Frotz sets these bits for V3 only)
        else    wrb_go(19'h01, cfg_flags1 | (version == 4'd6 && gfx_ok ? 8'h02 : 8'h00));   // V4+: the interpreter's (V6: pictures)
    end
    S_INIT11: begin push(S_INIT12); if (q_rhdr) rdb_orig_go(19'h11); else rdb_go(19'h11); end
    S_INIT12: begin                                    // flags 2: clear what the interpreter can't serve
        hw_i <= 5'd0; push(S_HW);                      // (restore: Frotz h_flags = as at start + the live bits 0-1)
        wrb_go(19'h11, q_rhdr ? (val[7:0] & f2_mask & 8'hFC) | {6'd0, q_f11} : val[7:0] & f2_mask);
    end
    S_HW: begin                                        // interpreter-written header fields (Frotz restart_header order)
        hw_i <= hw_i + 4'd1;
        case (hw_i)
            5'd0:  if (!v3) begin push(S_HW); wrb_go(19'h1E, cfg_interp_num); end   // 4 = Amiga, V6 too (as Amiga Frotz; MG1 pictures)
            5'd1:  if (!v3) begin push(S_HW); wrb_go(19'h1F, version == 4'd6 && cfg_interp_num == 8'd4 ? 8'd3 : cfg_interp_ver); end   // Amiga Frotz: V6 = 3
            // V6: zm_disp's screen, 320 x 200 units (MCGA), font 8 high x v6_fw wide; else 1x1 units
            5'd2:   if (!v3) begin push(S_HW); wrb_go(19'h20, version == 4'd6 ? 8'd25 : cfg_rows); end
            5'd3:   if (!v3) begin push(S_HW); wrb_go(19'h21, version == 4'd6 ? v6_cols : cfg_cols); end
            5'd4:   if (version >= 4'd5) begin push(S_HW); wrw_go(19'h22, version == 4'd6 ? (v6_wide ? 16'd640 : 16'd320) : {8'd0, cfg_cols}); end
            5'd5:   if (version >= 4'd5) begin push(S_HW); wrw_go(19'h24, version == 4'd6 ? 16'd200 : {8'd0, cfg_rows}); end
            5'd6:   if (version >= 4'd5) begin push(S_HW); wrb_go(19'h26, version == 4'd6 ? 8'd8 : 8'd1); end   // font height (V5: width)
            5'd7:   if (version >= 4'd5) begin push(S_HW); wrb_go(19'h27, version == 4'd6 ? {4'd0, v6_fw} : 8'd1); end
            5'd8:   if (version >= 4'd5) begin push(S_HW); wrb_go(19'h2C, cfg_bg); end
            5'd9:   if (version >= 4'd5) begin push(S_HW); wrb_go(19'h2D, cfg_fg); end
            5'd10: begin push(S_HW); wrb_go(19'h32, 8'h01); end                     // standard 1.0, as the reference reports
            5'd11: begin push(S_HW); wrb_go(19'h33, 8'h00); end
            5'd12, 5'd13, 5'd14, 5'd15: if (version == 4'd6) begin push(S_HW); wrw_go(19'h38 + {16'd0, hw_i[1:0], 1'b0}, 16'd0); end   // V6 user name
            5'd16: if (version == 4'd6) begin push(S_HW6); rdb_go(19'h10); end
            default: st <= q_rhdr ? S_QF4 : S_INIT10;
        endcase
    end
    S_HW6: begin push(S_HW); wrb_go(19'h10, val[7:0] & 8'hFE); end   // V6: the menu flag off (Frotz os_init_screen)
    S_INIT10: begin                                    // Frotz z_restart: seed_random(0)
        sp <= 12'd0; fp <= 12'd0; depth <= 8'd0; scr_on <= 1'b1; s3_lvl <= 5'd0; cur_font <= 8'd1;
        rng_a <= {16'd0, seed_src}; rng_interval <= 16'd0;
        scr_init <= 1'b1;
        emit_cmd3(CMD_RESTART, {12'd0, version}, {12'd0, story_id}, id_rel, version == 4'd6 ? S_V6S : S_FETCH);   // Frotz story_id, release
    end

    // ------------------------------------------------ fetch + decode + operands
    S_FETCH: if (nl_pend) halt(8'd14); else begin ipc <= pc; argc <= 4'd0; push(S_OP); pcb_go; end
    S_OP: begin
        opbyte <= val[7:0];
        if (!val[7]) begin                             // long form: always 2OP
            cls <= 3'd0; num <= val[4:0];
            types <= {val[6], ~val[6], val[5], ~val[5], 12'hFFF};   // bit set = variable (10), clear = small (01)
            st <= S_OPND;
        end
        else if (!val[6]) begin                        // short form
            num <= {1'b0, val[3:0]};
            types <= {val[5:4], 14'h3FFF};
            cls <= val[5:4] == 2'b11 ? 3'd2 : 3'd1;
            if (val[7:0] == 8'hBE && version >= 4'd5) begin push(S_EXT1); pcb_go; end   // extended: opcode byte, then types
            else st <= S_OPND;
        end
        else begin                                     // variable form
            cls <= val[5] ? 3'd3 : 3'd0; num <= val[4:0];
            push(S_TY1); pcb_go;
        end
    end
    S_EXT1: begin tr_ext <= val[7:0]; cls <= 3'd4; num <= val[4:0]; if (val[7:5] != 3'd0) halt(8'd1); else begin push(S_TY1); pcb_go; end end
    S_TY1: begin
        types <= {val[7:0], 8'hFF};
        if (opbyte == 8'hEC || opbyte == 8'hFA) begin push(S_TY2); pcb_go; end
        else st <= S_OPND;
    end
    S_TY2: begin types[7:0] <= val[7:0]; st <= S_OPND; end
    S_OPND: begin
        if (types[15:14] == 2'b11 || argc == 4'd8) st <= S_TRACE;
        else begin
            case (types[15:14])
                2'b00: push(S_OPL1);
                2'b01: push(S_OPS);
                default: push(S_OPV);
            endcase
            pcb_go;
        end
    end
    S_OPL1: begin tmp8 <= val[7:0]; push(S_OPL2); pcb_go; end
    S_OPL2: begin ops[argc[2:0]] <= {tmp8, val[7:0]}; argc <= argc + 4'd1; types <= {types[13:0], 2'b11}; st <= S_OPND; end
    S_OPS:  begin ops[argc[2:0]] <= {8'd0, val[7:0]}; argc <= argc + 4'd1; types <= {types[13:0], 2'b11}; st <= S_OPND; end
    S_OPV:  vread(val[7:0], 1'b0, S_OPVD);
    S_OPVD: begin ops[argc[2:0]] <= val; argc <= argc + 4'd1; types <= {types[13:0], 2'b11}; st <= S_OPND; end
    S_TRACE: begin
        tr_valid <= 1'b1; tr_pc <= ipc; tr_op <= opbyte; tr_argc <= argc;
        st <= S_EXEC;
    end

    // ------------------------------------------------ execute
    S_EXEC: begin
        then_br <= 1'b0;
        case (oid)
        // 2OP
        8'h01: branch((argc > 4'd1 && a == b) || (argc > 4'd2 && a == c) || (argc > 4'd3 && a == d));   // je
        8'h02: branch($signed(a) < $signed(b));                                                         // jl
        8'h03: branch($signed(a) > $signed(b));                                                         // jg
        8'h04, 8'h05: vread(a[7:0], 1'b1, S_INC1);                                                      // dec_chk, inc_chk
        8'h06: relrd(a, 2'd0, S_JIN1);                                                                  // jin
        8'h07: branch((a & b) == b);                                                                    // test
        8'h08: store(a | b);                                                                            // or
        8'h09: store(a & b);                                                                            // and
        8'h0A, 8'h0B, 8'h0C: begin push(S_ATTR1); rdb_go({3'd0, oaddr(a, v3, objtab) + {13'd0, b[5:3]}}); end   // test/set/clear_attr
        8'h0D: vwrite(a[7:0], 1'b1, b, S_FETCH);                                                        // store
        8'h0E: begin o_obj <= a; o_dst <= b; push(S_INS0); st <= S_REM0; end                            // insert_obj
        8'h0F: begin push(S_LDW1); rdw_go({3'd0, a + {b[14:0], 1'b0}}); end                             // loadw
        8'h10: begin push(S_LDW1); rdb_go({3'd0, a + b}); end                                           // loadb
        8'h11: pfind(a, b[5:0], PF_FIND, S_GP1);                                                        // get_prop
        8'h12: pfind(a, b[5:0], PF_FIND, S_GPA1);                                                       // get_prop_addr
        8'h13: pfind(a, b[5:0], b == 16'd0 ? PF_FIRST : PF_NEXT, S_GNP1);                               // get_next_prop
        8'h14: store(a + b);                                                                            // add
        8'h15: store(a - b);                                                                            // sub
        8'h16: store(a * b);                                                                            // mul
        8'h19, 8'h1A: begin c_disc <= oid == 8'h1A; st <= S_CALL; end                                    // call_2s, call_2n (V4+/V5+)
        8'h17, 8'h18: begin                                                                             // div, mod
            if (b == 16'd0) halt(8'd4);
            else begin
                d_n <= a[15] ? -a : a; d_d <= b[15] ? -b : b; d_q <= 16'd0; d_r <= 16'd0; d_i <= 4'd15;
                st <= S_DIV1;
            end
        end
        // 1OP
        8'h20: branch(a == 16'd0);                                                                      // jz
        8'h21: relrd(a, 2'd1, S_REL1);                                                                  // get_sibling
        8'h22: relrd(a, 2'd2, S_REL1);                                                                  // get_child
        8'h23: relrd(a, 2'd0, S_REL1);                                                                  // get_parent
        8'h24: if (a == 16'd0) store(16'd0); else begin push(S_GPL1); rdb_go({3'd0, a - 16'd1}); end    // get_prop_len
        8'h25, 8'h26: vread(a[7:0], 1'b1, S_INC1);                                                      // inc, dec
        8'h27: zdec({3'd0, a}, 1'b0, S_FETCH);                                                          // print_addr
        8'h28: begin c_disc <= 1'b0; st <= S_CALL; end                                                  // call_1s (V4+)
        8'h29: begin o_obj <= a; push(S_FETCH); st <= S_REM0; end                                       // remove_obj
        8'h2A: pobj(a, S_FETCH);                                                                        // print_obj
        8'h2B: begin res <= a; st <= S_RET0; end                                                        // ret
        8'h2C: begin pc <= pc + {{3{a[15]}}, a} - 19'd2; st <= S_FETCH; end                             // jump
        8'h2D: zdec(unpack(a, version, s_off), 1'b0, S_FETCH);                                                 // print_paddr
        8'h2E: vread(a[7:0], 1'b1, S_LOAD1);                                                            // load
        8'h2F: if (version >= 4'd5) begin c_disc <= 1'b1; st <= S_CALL; end else store(~a);             // call_1n (V5+) / not (V1-4)
        // 0OP
        8'h40: begin res <= 16'd1; st <= S_RET0; end                                                    // rtrue
        8'h41: begin res <= 16'd0; st <= S_RET0; end                                                    // rfalse
        8'h42: zdec(pc, 1'b1, S_FETCH);                                                                 // print
        8'h43: zdec(pc, 1'b1, S_PRR1);                                                                  // print_ret
        8'h44: st <= S_FETCH;                                                                           // nop
        8'h48: vread(8'd0, 1'b0, S_RPOP1);                                                              // ret_popped
        8'h49: if (version >= 4'd5) store({8'd0, depth}); else vread(8'd0, 1'b0, S_FETCH);              // catch (V5+: frame count, as Frotz's Quetzal mode) / pop (V1-4)
        8'h47: begin u_i <= 16'd0; st <= S_RS1; end                                                     // restart
        8'h1C: if (b > {8'd0, depth}) halt(8'd11); else st <= S_THR1;                                   // throw
        8'h4A: halt(8'd3);                                                                              // quit
        8'h4B: emit(10'd13, S_FETCH);                                                                   // new_line
        8'h4C: if (v3) begin push(S_FETCH); st <= S_SS0; end else st <= S_FETCH;                                                 // show_status (V4+: ignored, as Frotz)
        8'h4D: begin push(S_VF1); rdw_go(19'h1A); end                                                   // verify
        8'h4F: if (version >= 4'd5) branch(1'b1); else halt(8'd1);                                     // piracy: genuine
        8'h45, 8'h46: if (version >= 4'd5) halt(8'd1); else begin q_rest <= oid == 8'h46; st <= S_Q0; end   // save / restore (V1-3 branch, V4 store)
        8'h80, 8'h81: begin                                                                             // save / restore (V5+)
            q_rest <= oid == 8'h81; q_aux <= argc != 4'd0;
            x_tab <= a; x_len <= argc > 4'd1 ? b : 16'd0; x_nm <= argc > 4'd2 ? c : 16'd0;
            st <= argc != 4'd0 ? S_X0 : S_Q0;
        end
        // VAR
        8'h60, 8'h6C: begin c_disc <= 1'b0; st <= S_CALL; end                                           // call / call_vs, call_vs2
        8'h79, 8'h7A: begin c_disc <= 1'b1; st <= S_CALL; end                                           // call_vn, call_vn2
        8'h78: store(~a);                                                                               // not (V5+)
        8'h6A: emit_cmd(CMD_SPLIT, a, 16'd0, S_FETCH);                                                  // split_window
        8'h6B: emit_cmd(CMD_SETWIN, a, 16'd0, S_FETCH);                                                 // set_window
        8'h6D: emit_cmd(CMD_ERASE_WIN, a, 16'd0, S_FETCH);                                              // erase_window
        8'h6E: emit_cmd(CMD_ERASE_LINE, a, 16'd0, S_FETCH);                                             // erase_line
        8'h6F: emit_cmd3(CMD_CURSOR, a, b, argc > 4'd2 ? c : 16'hFFFD, S_FETCH);                          // set_cursor (V6: window)
        8'h70: emit_cmd(CMD_GETCUR, 16'd0, 16'd0, S_GC1);                                               // get_cursor
        8'h71: emit_cmd(CMD_STYLE, a, 16'd0, S_FETCH);                                                  // set_text_style
        8'h72: emit_cmd(CMD_BUFMODE, a, 16'd0, S_FETCH);                                                // buffer_mode
        8'h74: st <= S_FETCH;                                                                           // input_stream: keyboard only
        8'h75: begin                                                                                    // sound_effect (z_sound_effect)
            st <= S_FETCH;
            snd_num <= se_num; snd_vol <= se_vol[7:0];
            if (se_num >= 16'd3 || se_num == 16'd0) begin
                if (se_lh && (se_num == 16'd9 || se_num == 16'd16)) begin   // queued behind the playing one
                    if (se_eff == 16'd2) begin
                        if (snd_play) begin snd_nx <= se_num; snd_nxv <= se_vol[7:0]; end
                        else begin
                            snd_go <= 1'b1; snd_eff <= 3'd2; snd_rep <= lh_rep(se_num); snd_rtn <= 16'd0;
                            snd_play <= 1'b1; snd_endp <= 1'b0; snd_cur <= se_num; snd_nx <= 16'd0;
                        end
                    end
                end
                else begin
                    snd_play <= 1'b0;
                    if (se_eff == 16'd2) begin                 // start_sample
                        snd_go <= 1'b1; snd_eff <= 3'd2; snd_rep <= se_lh ? lh_rep(se_num) : se_vol[15:8];
                        snd_rtn <= argc == 4'd4 ? d : 16'd0; snd_play <= 1'b1; snd_endp <= 1'b0; snd_cur <= se_num;
                    end
                    else if (se_eff == 16'd1 || se_eff == 16'd3 || se_eff == 16'd4) begin
                        snd_go <= 1'b1; snd_eff <= se_eff[2:0];
                        if (se_eff != 16'd1 || se_num != snd_cur) snd_endp <= 1'b0;   // stopped: its end is dropped
                        if (se_eff != 16'd3) snd_cur <= se_eff == 16'd1 ? se_num : 16'd0;
                    end
                end
            end
            else begin snd_go <= 1'b1; snd_eff <= 3'd2; end                                  // os_beep
        end
        8'h1B: emit_cmd3(CMD_COLOUR, a, b, argc > 4'd2 ? c : 16'hFFFD, S_FETCH);                          // set_colour (V6: window)
        8'h73: begin                                   // output_stream: Frotz's z_output_stream flushes the buffer first: with
            if (s3_lvl == 5'd0) emit_cmd(CMD_FLUSH, 16'd0, 16'd0, S_OS0);   // no stream 3 that is the display's (a queued
            else st <= S_OS0;                          // set_font / style reaches the screen before stream 3 measures text)
        end
        8'h7F: begin push(S_CAC1); srd_go(fp + 12'd1); end                                              // check_arg_count
        8'h82: store($signed(b) >= 0 ? a << b : a >> (-b));                                             // log_shift
        8'h83: store($signed(b) >= 0 ? a << b : art_r);                                                 // art_shift
        8'h7D: begin                                                                                    // copy_table (Frotz table.c)
            ct_i <= 16'd0;
            if (b == 16'd0)                   begin ct_mode <= 2'd0; ct_n <= c; end
            else if (c[15] || a > b)          begin ct_mode <= 2'd1; ct_n <= c[15] ? -c : c; end
            else                              begin ct_mode <= 2'd2; ct_n <= c; end
            st <= S_CT1;
        end
        8'h77: begin sc_addr <= b; ct_i <= 16'd0; st <= S_SCN1; end                                    // scan_table
        8'h7E: begin pt_addr <= a; pt_i <= 16'd0; pt_j <= 16'd0; emit_cmd(CMD_PT_BEGIN, 16'd0, 16'd0, S_PT1); end   // print_table
        8'h89: begin m_uslot <= u_head; u_i <= 16'd0; st <= S_SU1; end                                  // save_undo
        // V6 picture opcodes, no pictures loaded yet (Frotz with os_picture_data = 0): draw / erase only flush the buffer
        8'h85: emit_cmd3(CMD_DRAWPIC, a, argc > 4'd1 ? b : 16'd0, argc > 4'd2 ? c : 16'd0, S_FETCH);   // draw_picture
        8'h87: emit_cmd3(CMD_ERASEPIC, a, argc > 4'd1 ? b : 16'd0, argc > 4'd2 ? c : 16'd0, S_FETCH);  // erase_picture
        8'h86: emit_cmd(CMD_PICDATA, a, 16'd0, S_PDT0);                                                 // picture_data
        8'h96: begin push(S_RMS1); wrw_go({3'd0, a}, hx_my); end                                        // read_mouse
        8'h97: emit_cmd(CMD_MWIN, a, 16'd0, S_FETCH);                                                   // mouse_window
        8'h9C: st <= S_FETCH;                                                                    // picture_table
        // V6 windows (zm_disp, Frotz screen.c)
        8'h88: emit_cmd3(CMD_MARGINS, a, b, argc > 4'd2 ? c : 16'hFFFD, S_FETCH);                       // set_margins
        8'h90: emit_cmd3(CMD_WMOVE, a, b, c, S_FETCH);                                                  // move_window
        8'h91: emit_cmd3(CMD_WSIZE, a, b, c, S_FETCH);                                                  // window_size
        8'h92: emit_cmd3(CMD_WSTYLE, a, b, argc > 4'd2 ? c : 16'd0, S_FETCH);                           // window_style
        8'h93: emit_cmd(CMD_GETPROP, a, b, S_DRSP);                                                     // get_wind_prop
        8'h94: emit_cmd(CMD_SCROLLW, a, b, S_FETCH);                                                    // scroll_window
        8'h99: emit_cmd3(CMD_PUTPROP, a, b, c, S_FETCH);                                                // put_wind_prop
        8'h9A: begin pt_addr <= a; pt_j <= 16'd1; st <= S_PFM1; end                                     // print_form
        8'h98: begin push(S_PS1); rdw_go({3'd0, b}); end                                                // push_stack (Frotz z_push_stack)
        8'h95: if (argc == 4'd2) begin push(S_POP1); rdw_go({3'd0, b}); end                             // pop_stack: user stack ...
               else begin sp <= sp - a[11:0]; st <= S_FETCH; end                                       // ... or a items off the game stack
        8'h8A: begin                                                                                    // restore_undo
            if (u_count == 6'd0) store(16'd0);
            else begin m_uslot <= u_head - 5'd1; u_head <= u_head - 5'd1; u_count <= u_count - 6'd1; u_i <= 16'd0; st <= S_RU1; end
        end
        8'h84: begin                                                                                    // set_font: 1 text, 3 graphics, 4 fixed; 0 = query
            if (version == 4'd6) emit_cmd(CMD_FONT, a, 16'd0, S_DRSP);                                  // V6: per window, zm_disp answers
            else if (a == 16'd0) store({8'd0, cur_font});
            else if (a == 16'd1 || a == 16'd3 || a == 16'd4) begin
                res <= {8'd0, cur_font}; then_br <= 1'b0; cur_font <= a[7:0];
                emit_cmd(CMD_FONT, a, 16'd0, S_STORE);
            end
            else store(16'd0);
        end
        8'h61: begin push(S_SB2); wrw_go({3'd0, a + {b[14:0], 1'b0}}, c); end                           // storew
        8'h62: begin push(S_SB2); wrb_go({3'd0, a + b}, c[7:0]); end                                    // storeb
        8'h63: pfind(a, b[5:0], PF_FIND, S_PP1);                                                        // put_prop
        8'h64: begin                                                                                    // sread / aread
            rd_text <= a; rd_parse <= argc > 4'd1 ? b : 16'd0;
            tm_time <= argc > 4'd2 && version >= 4'd4 ? c : 16'd0; tm_rtn <= argc > 4'd3 ? d : 16'd0;
            push(S_RD0); rdb_go({3'd0, a});
        end
        8'h76: begin                                                                                    // read_char (time, routine)
            emit_cmd(CMD_READ, 16'd1, 16'd0, S_RCHAR);
            tm_time <= argc > 4'd1 ? b : 16'd0; tm_rtn <= argc > 4'd2 ? c : 16'd0;
            tm_run <= argc > 4'd1 && b != 16'd0; tm_left <= b; tm_pre <= 22'd0; tm_pend <= 1'b0;
        end
        8'h7B: begin                                                                                    // tokenise
            tk_text <= a; tk_parse <= b; tk_dct <= (argc > 4'd2 && c != 16'd0) ? c : dict; tk_flag <= argc > 4'd3 && d != 16'd0;
            push(S_FETCH); st <= S_TL0;
        end
        8'h7C: begin en_src <= a + c; en_len <= b; en_pad <= 5'd5; push(S_ET1); st <= S_EN0; end         // encode_text
        8'h65: emit(a[9:0], S_FETCH);                                                                   // print_char
        8'h66: pnum(a, S_FETCH);                                                                        // print_num
        8'h67: begin                                                                                    // random
            if ($signed(a) <= 0) begin                 // seed: 0 = from the seed source, 1..999 counting, else A = seed
                if (a == 16'd0)            begin rng_a <= {16'd0, seed_src}; rng_interval <= 16'd0; end
                else if (-a < 16'd1000)    begin rng_counter <= 16'd0; rng_interval <= -a; end
                else                       begin rng_a <= {16'd0, -a}; rng_interval <= 16'd0; end
                store(16'd0);
            end
            else begin
                if (rng_interval != 16'd0) begin
                    d_n <= rng_counter;
                    rng_counter <= (rng_counter + 16'd1 == rng_interval) ? 16'd0 : rng_counter + 16'd1;
                end
                else begin rng_a <= rng_next; d_n <= {1'b0, rng_next[30:16]}; end
                d_d <= a; d_q <= 16'd0; d_r <= 16'd0; d_i <= 4'd15;
                st <= S_DIV1;                          // result % range + 1 (S_DIV2)
            end
        end
        8'h68: vwrite(8'd0, 1'b0, a, S_FETCH);                                                          // push
        8'h69: if (version != 4'd6) vread(8'd0, 1'b0, S_PULL1);                                         // pull (V1-5, 7, 8)
               else if (argc == 4'd1) begin push(S_PULL6); rdw_go({3'd0, a}); end                        // V6: user stack
               else vread(8'd0, 1'b0, S_PULL8);                                                         // V6: game stack
        default: halt(8'd1);
        endcase
    end

    S_INC1: begin                                      // val = variable a (indirect)
        if (oid == 8'h05 || oid == 8'h25) begin res <= val + 16'd1; vwrite(a[7:0], 1'b1, val + 16'd1, (oid == 8'h05) ? S_INC2 : S_FETCH); end
        else                              begin res <= val - 16'd1; vwrite(a[7:0], 1'b1, val - 16'd1, (oid == 8'h04) ? S_INC2 : S_FETCH); end
    end
    S_INC2:  branch(oid == 8'h05 ? $signed(res) > $signed(b) : $signed(res) < $signed(b));
    S_LOAD1: store(val);
    S_PULL1: vwrite(a[7:0], 1'b1, val, S_FETCH);
    // V6 start: Frotz z_restart calls the main routine (packed address at 0x06) with no arguments
    S_V6S: if (v6_need_gfx && !gfx_ok) halt(8'd15);   // the pictures are required (a test build may run without)
           else begin ops[0] <= pc[15:0]; pc <= 19'd0; argc <= 4'd1; c_disc <= 1'b1; st <= S_CALL; end
    // V6 pull (a store): user stack at a = size word + 1, then the word above it; else the game stack (Frotz z_pull)
    S_PULL6: begin push(S_PULL7); wrw_go({3'd0, a}, val + 16'd1); res <= val + 16'd1; end
    S_PULL7: begin push(S_PULL8); rdw_go({3'd0, a + {res[14:0], 1'b0}}); end
    S_PULL8: store(val);
    // push_stack: size word at b = free slots; the value goes to b + 2 * size, then size - 1; branch if there was room
    S_PS1: if (val == 16'd0) branch(1'b0); else begin res <= val; push(S_PS2); wrw_go({3'd0, b + {val[14:0], 1'b0}}, a); end
    S_PS2: begin push(S_PS3); wrw_go({3'd0, b}, res - 16'd1); end
    S_PS3: branch(1'b1);
    S_POP1: begin push(S_FETCH); wrw_go({3'd0, b}, val + a); end
    S_PDT0: if (!disp_busy) begin pd_ok <= disp_rsp_ok; pd_w <= disp_rsp_b; push(S_PDT1); wrw_go({3'd0, b}, disp_rsp_a); end   // height, width
    S_PDT1: begin push(S_PDT2); wrw_go({3'd0, b + 16'd2}, pd_w); end
    // zm_disp's answer, once it's idle again (the command was taken in S_EMIT, so it is busy the clock after):
    // get_cursor writes y, x to the table at a; get_wind_prop / V6 set_font store it
    S_GC1: if (!disp_busy) begin push(S_GC2); wrw_go({3'd0, a}, disp_rsp_a); end
    S_GC2: begin push(S_FETCH); wrw_go({3'd0, a + 16'd2}, disp_rsp_b); end
    S_DRSP: if (!disp_busy) store(disp_rsp_a);
    S_S3W: begin push(S_FETCH); wrw_go(19'h30, s3_cw); end
    // print_form (Frotz z_print_form): line records [count][chars] until a count of 0, a new line between them
    S_PFM1: begin push(S_PFM2); rdw_go({3'd0, pt_addr}); end
    S_PFM2: begin
        pt_i <= val; pt_addr <= pt_addr + 16'd2; pt_j <= 16'd0;
        if (val == 16'd0) st <= S_FETCH;
        else if (pt_j == 16'd0) emit(10'd13, S_PFM3);
        else st <= S_PFM3;
    end
    S_PFM3: if (pt_i == 16'd0) st <= S_PFM1; else begin push(S_PFM4); rdb_go({3'd0, pt_addr}); end
    S_PFM4: begin pt_addr <= pt_addr + 16'd1; pt_i <= pt_i - 16'd1; emit({2'd0, val[7:0]}, S_PFM3); end
    // V6 stream 3 (Frotz print_char into the word buffer, memory_word / memory_new_line / memory_open / memory_close)
    S_M3C: begin                                       // a character (out_char) for the table
        if (out_char == 10'd13) begin m3_after <= 2'd1; st <= S_M3F0; end
        else if (m3_space(out_char[7:0]) || (m3_prev == 8'h2D && out_char[7:0] != 8'h2D)) begin m3_after <= 2'd2; st <= S_M3F0; end
        else st <= S_M3A;
    end
    S_M3A: begin m3_we <= 1'b1; m3_wc <= out_char[7:0]; st <= S_M3A2; end
    S_M3A2: begin m3_pos <= m3_pos + 9'd1; m3_wd <= m3_wd + m3_lw; m3_prev <= out_char[7:0]; sub_ret; end
    S_M3F0: begin                                      // flush_buffer -> memory_word
        if (m3_pos == 9'd0 || s3_lvl == 5'd0) st <= S_M3F9;
        else if (s3_xs[s3_top] != 16'hFFFF && {1'b0, s3_wid[s3_top]} + {1'b0, m3_wd} > {1'b0, s3_xs[s3_top]}) begin
            m3_ra <= 8'd0; st <= S_M3F1;               // doesn't fit the line: a new line, without a leading space
        end
        else begin m3_i <= 9'd0; st <= S_M3F3; end
    end
    S_M3F1: st <= S_M3F2;
    S_M3F2: begin
        if (m3_space(m3_q)) begin m3_i <= 9'd1; m3_wd <= m3_wd - m3_lw; end else m3_i <= 9'd0;
        push(S_M3F3); st <= S_M3N0;
    end
    S_M3F3: begin s3_wid[s3_top] <= s3_wid[s3_top] + m3_wd; st <= S_M3F4; end
    S_M3F4: begin
        if (m3_i == m3_pos) begin
            m3_pos <= 9'd0; m3_wd <= 16'd0; m3_prev <= 8'd0;
            push(S_M3F9); wrw_go({3'd0, s3_tab[s3_top]}, s3_cnt[s3_top]);   // the count after every word, as Frotz
        end
        else begin m3_ra <= m3_i[7:0]; st <= S_M3F5; end
    end
    S_M3F5: st <= S_M3F6;
    S_M3F6: begin
        s3_cnt[s3_top] <= s3_cnt[s3_top] + 16'd1; m3_i <= m3_i + 9'd1;
        push(S_M3F4); wrb_go({3'd0, s3_tab[s3_top] + 16'd2 + s3_cnt[s3_top]}, m3_q);
    end
    S_M3F9: begin                                      // after the flush
        case (m3_after)
            2'd1: st <= S_M3N0;                        // ZSCII 13: a new line, then back to the emit's caller
            2'd2: st <= S_M3A;                         // the character that caused the flush
            2'd3: begin                                // open (Frotz memory_open): width 0 / negative = window -width
                if (argc > 4'd2 && $signed(c) <= 16'sd0) emit_cmd(CMD_MAXW, -c, 16'd0, S_M3O1);
                else st <= S_M3O1;
            end
            default: begin                             // close: formatted ends with a new line (an empty record)
                if (s3_lvl == 5'd0) st <= S_FETCH;
                else if (s3_xs[s3_top] != 16'hFFFF) begin push(S_M3X1); st <= S_M3N0; end
                else st <= S_M3X1;
            end
        endcase
    end
    S_M3O1: begin
        s3_tab[s3_lvl[3:0]] <= b; s3_cnt[s3_lvl[3:0]] <= 16'd0; s3_wid[s3_lvl[3:0]] <= 16'd0; s3_tot[s3_lvl[3:0]] <= 16'd0;
        s3_xs[s3_lvl[3:0]] <= argc <= 4'd2 ? 16'hFFFF : $signed(c) <= 16'sd0 ? disp_rsp_a : c;
        s3_lvl <= s3_lvl + 5'd1;
        push(S_FETCH); wrw_go({3'd0, b}, 16'd0);
    end
    S_M3X1: begin                                      // H_LINE_WIDTH: the total if formatted, else the last line's width
        s3_cw <= s3_xs[s3_top] != 16'hFFFF ? s3_tot[s3_top] : s3_wid[s3_top];
        s3_lvl <= s3_lvl - 5'd1;
        push(S_S3W); wrw_go({3'd0, s3_tab[s3_top]}, s3_cnt[s3_top]);
    end
    S_M3N0: begin                                      // memory_new_line (returns to the caller)
        s3_tot[s3_top] <= s3_tot[s3_top] + s3_wid[s3_top]; s3_wid[s3_top] <= 16'd0;
        if (s3_xs[s3_top] != 16'hFFFF) begin           // formatted: the next record
            s3_tab[s3_top] <= s3_tab[s3_top] + 16'd2 + s3_cnt[s3_top]; s3_cnt[s3_top] <= 16'd0;
            wrw_go({3'd0, s3_tab[s3_top] + 16'd2 + s3_cnt[s3_top]}, 16'd0);
        end
        else begin
            s3_cnt[s3_top] <= s3_cnt[s3_top] + 16'd1;
            push(S_M3N1); wrb_go({3'd0, s3_tab[s3_top] + 16'd2 + s3_cnt[s3_top]}, 8'd13);
        end
    end
    S_M3N1: wrw_go({3'd0, s3_tab[s3_top]}, s3_cnt[s3_top]);
    S_PDT2: branch(pd_ok);
    S_RPOP1: begin res <= val; st <= S_RET0; end
    S_CAC1:  branch(a <= (depth == 8'd0 ? 16'd0 : {13'd0, val[6:4]}));
    // verify: 16-bit sum of the story as loaded, 0x40 .. file length (header 0x1A, x2 / x4 / x8) == header 0x1C
    S_VF1: begin
        vf_end  <= version <= 4'd3 ? {2'd0, val, 1'b0} : version <= 4'd5 ? {1'b0, val, 2'b00} : {val, 3'b000};
        vf_addr <= 19'h40; vf_sum <= 16'd0;
        push(S_VF2); rdw_go(19'h1C);
    end
    S_VF2: begin vf_want <= val; st <= S_VF3; end
    S_VF3: if (vf_addr >= vf_end) branch(vf_sum == vf_want); else begin push(S_VF0); rdb_orig_go(vf_addr); end
    S_VF0: begin vf_sum <= vf_sum + val; vf_addr <= vf_addr + 19'd1; st <= S_VF3; end
    S_LDW1:  store(val);
    S_REL1:  begin res <= val; then_br <= oid != 8'h23; cond <= val != 16'd0; st <= S_STORE; end
    S_JIN1:  branch(val == b);
    S_ATTR1: begin
        case (oid)
            8'h0A: branch((val[7:0] & (8'h80 >> b[2:0])) != 8'd0);
            8'h0B: begin push(S_FETCH); wrb_go(m_addr, val[7:0] | (8'h80 >> b[2:0])); end
            default: begin push(S_FETCH); wrb_go(m_addr, val[7:0] & ~(8'h80 >> b[2:0])); end
        endcase
    end
    S_POBJ: begin push(S_PO1); rdw_go({3'd0, oaddr(o_print, v3, objtab) + (v3 ? 16'd7 : 16'd12)}); end
    S_PO1: begin p_pa <= val; push(S_PO2); rdb_go({3'd0, val}); end
    S_PO2: if (val[7:0] == 8'd0) sub_ret; else zdec({3'd0, p_pa + 16'd1}, 1'b0, S_PO3);
    S_PO3: sub_ret;
    S_STR: begin
        if (str_rom(str_i) == 8'd0) sub_ret;
        else begin str_i <= str_i + 8'd1; emit({2'd0, str_rom(str_i)}, S_STR); end
    end

    // ------------------------------------------------ show_status (Frotz screen.c z_show_status)
    S_SS0: begin push(S_SS1); rdw_go({3'd0, globals}); end
    S_SS1: begin g0 <= val; push(S_SS2); rdw_go({3'd0, globals + 16'd2}); end
    S_SS2: begin g1 <= val; push(S_SS3); rdw_go({3'd0, globals + 16'd4}); end
    S_SS3: begin g2 <= val; emit_cmd(CMD_SBEGIN, 16'd0, 16'd0, S_SS4); end
    S_SS4: emit(10'd32, S_SS5);
    S_SS5: pobj(g0, S_SS6);
    S_SS6: if (time_game) begin ss_h <= {1'b0, g1} + 17'd11; st <= S_SS7; end
           else emit_cmd(CMD_SPAD, status_brief ? 16'd15 : 16'd30, 16'd0, S_SC1);
    S_SS7: if (ss_h >= 17'd12) ss_h <= ss_h - 17'd12; else begin ss_h <= ss_h + 17'd1; st <= S_SS8; end   // (g1 + 11) % 12 + 1
    S_SS8: emit_cmd(CMD_SPAD, status_brief ? 16'd15 : 16'd20, 16'd0, S_T1);
    S_T1:  emit_str(8'd0, S_T2);
    S_T2:  if (ss_h < 17'd10) emit(10'd32, S_T3); else st <= S_T3;
    S_T3:  pnum(ss_h[15:0], S_T4);
    S_T4:  emit(10'h3A, S_T5);
    S_T5:  if (g2 < 16'd10) emit(10'h30, S_T6); else st <= S_T6;
    S_T6:  pnum(g2, S_T7);
    S_T7:  emit(10'd32, S_T8);
    S_T8:  emit(g1 >= 16'd12 ? 10'h70 : 10'h61, S_T9);
    S_T9:  emit(10'h6D, S_SSEND);
    S_SC1: emit_str(status_brief ? 8'd15 : 8'd7, S_SC2);
    S_SC2: pnum(g1, S_SC3);
    S_SC3: emit_cmd(CMD_SPAD, status_brief ? 16'd8 : 16'd14, 16'd0, S_SC4);
    S_SC4: emit_str(status_brief ? 8'd27 : 8'd19, S_SC5);
    S_SC5: pnum(g2, S_SSEND);
    S_SSEND: emit_cmd(CMD_SEND, 16'd0, 16'd0, S_SSRET);
    S_SSRET: sub_ret;
    S_PRR1: emit(10'd13, S_PRR2);
    S_PRR2: begin res <= 16'd1; st <= S_RET0; end

    // ------------------------------------------------ read: Frotz input.c z_read
    S_RD0: begin
        rd_max <= (version <= 4'd4 ? val[7:0] - 8'd1 : val[7:0]) > 8'd199 ? 8'd199 : (version <= 4'd4 ? val[7:0] - 8'd1 : val[7:0]);
        if (version >= 4'd5) begin push(S_RD1); rdb_go({3'd0, rd_text + 16'd1}); end
        else begin val <= 16'd0; st <= S_RD1; end
    end
    S_RD1: begin                                       // initial input size (V5 preloaded text)
        rd_len <= val[7:0];
        if (v3) begin push(S_RDR); st <= S_SS0; end    // V1-3: status line first
        else st <= S_RDR;
    end
    S_RDR: begin
        emit_cmd(CMD_READ, 16'd0, {8'd0, rd_len}, S_RKEY);
        tm_run <= tm_time != 16'd0; tm_left <= tm_time; tm_pre <= 22'd0; tm_pend <= 1'b0;
    end
    S_RKEY: if (snd_endp && !in_int && !(key_valid && !key_ack)) begin int_ret <= S_RKEY; st <= S_EOS; end
    else if (tm_pend && !in_int && !(key_valid && !key_ack)) begin int_ret <= S_RKEY; st <= S_TMO0; end
    else if (key_valid && !key_ack) begin              // line editor; letters lowered as typed
        key_ack <= 1'b1; rd_key <= key_code;
        if (key_code == 10'd13 || key_code == 10'd10) begin rd_term <= 10'd13; emit_cmd(CMD_ECHO, 16'd13, 16'd0, S_RDONE); end
        else if ((key_code >= 10'd129 && key_code <= 10'd154) || (key_code >= 10'd252 && key_code <= 10'd254)) begin
            if (version >= 4'd5) begin push(S_TM0); rdw_go(19'h2E); end   // cursor / function / keypad / mouse click: a terminator
        end                                            // only if the game's table (header 0x2E) has it; else ignored
        else if (key_code == 10'd8) begin
            if (rd_len != 8'd0) begin rd_len <= rd_len - 8'd1; emit_cmd(CMD_ECHO, 16'd8, 16'd0, S_RKEY); end
        end
        else if (((key_code >= 10'd32 && key_code <= 10'd126) || (key_code >= 10'd155 && key_code <= 10'd251)) && rd_len < rd_max) begin
            rd_len <= rd_len + 8'd1;
            push(S_RD2);
            wrb_go({3'd0, rd_text + (version <= 4'd4 ? 16'd1 : 16'd2) + {8'd0, rd_len}},
                   (key_code >= 10'h41 && key_code <= 10'h5A) ? key_code[7:0] + 8'h20 : key_code[7:0]);
        end
    end
    S_RD2: emit_cmd(CMD_ECHO, {6'd0, rd_key}, 16'd0, S_RKEY);
    // Frotz is_terminator: scan the 0-terminated table at header 0x2E; 255 = every cursor / function / keypad key.
    // A terminating key ends the line without a new line or tokenising; read stores it (z_read).
    S_TM0: if (val == 16'd0) st <= S_RKEY; else begin tm_addr <= val; push(S_TM1); rdb_go({3'd0, val}); end
    S_TM1: begin
        if (val[7:0] == 8'd0) st <= S_RKEY;
        else if (val[7:0] == 8'd255 || {2'd0, val[7:0]} == rd_key) begin   // a click is then checked (stream_read_input)
            rd_term <= rd_key;
            if (rd_key >= 10'd252) begin ck_line <= 1'b1; st <= S_CK0; end else st <= S_RDONE;
        end
        else begin tm_addr <= tm_addr + 16'd1; push(S_TM1); rdb_go({3'd0, tm_addr + 16'd1}); end
    end
    S_RDONE: begin                                     // V1-4: zero terminator; V5+: length in byte 1
        tm_run <= 1'b0;
        push(S_RDONE2);
        if (version <= 4'd4) wrb_go({3'd0, rd_text + 16'd1 + {8'd0, rd_len}}, 8'd0);
        else                 wrb_go({3'd0, rd_text + 16'd1}, rd_len);
    end
    S_RDONE2: begin                                    // tokenise only a line ended by Return (Frotz z_read)
        if (rd_parse != 16'd0 && rd_term == 10'd13) begin
            tk_text <= rd_text; tk_parse <= rd_parse; tk_dct <= dict; tk_flag <= 1'b0;
            push(S_RDSTORE); st <= S_TL0;
        end
        else st <= S_RDSTORE;
    end
    S_RDSTORE: if (version >= 4'd5) store({6'd0, rd_term}); else st <= S_FETCH;
    S_RCHAR: if (snd_endp && !in_int && !(key_valid && !key_ack)) begin int_ret <= S_RCHAR; st <= S_EOS; end
    else if (tm_pend && !in_int && !(key_valid && !key_ack)) begin int_ret <= S_RCHAR; st <= S_TMO0; end
    else if (key_valid && !key_ack) begin
        key_ack <= 1'b1; tm_run <= 1'b0;
        if (key_code >= 10'd252 && key_code <= 10'd254) begin rd_key <= key_code; ck_line <= 1'b0; st <= S_CK0; end   // stream_read_key
        else store({6'd0, key_code});
    end
    // validate_click (Frotz): the display maps the click into the mouse window; outside it the click is ignored and
    // input goes on (read: the line so far kept). Inside: header extension words 2 (y) and 1 (x), if the table has them
    S_CK0: emit_cmd(CMD_CLICK, {6'd0, click_x}, {7'd0, click_y}, S_CK1);
    S_CK1: if (!disp_busy) begin
        if (!disp_rsp_ok) st <= ck_line ? S_RKEY : S_RCHAR;
        else begin
            hx_mx <= disp_rsp_a; hx_my <= disp_rsp_b;
            if (version >= 4'd5) begin push(S_CK2); rdw_go(19'h36); end else st <= S_CK9;
        end
    end
    S_CK2: if (val == 16'd0) st <= S_CK9; else begin hx_tab <= val; push(S_CK3); rdw_go({3'd0, val}); end
    S_CK3: begin hx_sz <= val; if (val >= 16'd2) begin push(S_CK4); wrw_go({3'd0, hx_tab + 16'd4}, hx_my); end else st <= S_CK4; end
    S_CK4: if (hx_sz >= 16'd1) begin push(S_CK9); wrw_go({3'd0, hx_tab + 16'd2}, hx_mx); end else st <= S_CK9;
    S_CK9: if (ck_line) st <= S_RDONE; else store({6'd0, rd_key});
    // end_of_sound: Lurking Horror starts its queued sample (its routine is then 0), else the routine runs
    S_EOS: begin
        snd_endp <= 1'b0; snd_play <= 1'b0;
        if (se_lh && snd_nx != 16'd0) begin
            snd_go <= 1'b1; snd_num <= snd_nx; snd_eff <= 3'd2; snd_vol <= snd_nxv; snd_rep <= lh_rep(snd_nx);
            snd_rtn <= 16'd0; snd_play <= 1'b1; snd_cur <= snd_nx; snd_nx <= 16'd0; st <= int_ret;
        end
        else if (snd_rtn != 16'd0) begin int_snd <= 1'b1; st <= S_INT0; end
        else st <= int_ret;
    end
    // timeout: the routine (direct_call; address 0 = false), then go on or end the input
    S_TMO0: begin
        tm_pend <= 1'b0; tm_ack <= 1'b1;
        if (tm_rtn != 16'd0) begin int_tmo <= 1'b1; st <= S_INT0; end
        else begin tmo_val <= 16'd0; st <= S_TMO1; end
    end
    S_TMO1: begin
        tm_ack <= 1'b0;
        if (tmo_val == 16'd0) begin                    // false: again, a new period
            tm_run <= 1'b1; tm_left <= tm_time; tm_pre <= 22'd0;
            emit_cmd(CMD_RCONT, int_ret == S_RKEY ? 16'd0 : 16'd1, 16'd0, int_ret);
        end
        else if (int_ret == S_RKEY) begin rd_term <= 10'd0; st <= S_RDONE; end   // read: terminator 0, the line kept
        else store(16'd0);                             // read_char: 0
    end
    // read_mouse: y, x, buttons (Frotz: always 1), menu 0
    S_RMS1: begin push(S_RMS2); wrw_go({3'd0, a + 16'd2}, hx_mx); end
    S_RMS2: begin push(S_RMS3); wrw_go({3'd0, a + 16'd4}, 16'd1); end
    S_RMS3: begin push(S_FETCH); wrw_go({3'd0, a + 16'd6}, 16'd0); end

    // ------------------------------------------------ tokenise_line (text, parse, dct, flag)
    S_TL0: begin push(S_TL1); wrb_go({3'd0, tk_parse + 16'd1}, 8'd0); end
    S_TL1: begin
        tk_a1 <= tk_text; tk_a2 <= 16'd0;
        if (version >= 4'd5) begin push(S_TL2); rdb_go({3'd0, tk_text + 16'd1}); end
        else st <= S_TL3;
    end
    S_TL2: begin tk_len <= val[7:0]; tk_a1 <= tk_text + 16'd1; st <= S_TL3; end   // V5+: past the length byte (Frotz addr1++)
    S_TL3: begin                                       // next character
        tk_a1 <= tk_a1 + 16'd1;
        if (version >= 4'd5 && tk_a1 + 16'd1 == tk_text + 16'd2 + {8'd0, tk_len}) begin val <= 16'd0; st <= S_TL4; end
        else begin push(S_TL4); rdb_go({3'd0, tk_a1 + 16'd1}); end
    end
    S_TL4: begin tk_c <= val[7:0]; tk_sep <= tk_dct + 16'd1; push(S_TL5); rdb_go({3'd0, tk_dct}); end
    S_TL5: begin tk_sepn <= val[7:0]; push(S_TL6); rdb_go({3'd0, tk_sep}); end   // do { separator = *sep++ }
    S_TL6: begin
        tk_sep <= tk_sep + 16'd1;
        if (tk_c != val[7:0] && tk_sepn - 8'd1 != 8'd0) begin tk_sepn <= tk_sepn - 8'd1; push(S_TL6); rdb_go({3'd0, tk_sep + 16'd1}); end
        else begin
            tk_dosep <= tk_c == val[7:0] && tk_sepn != 8'd0;   // Frotz: separator only if sep_count is still non-zero
            st <= S_TL7;
        end
    end
    S_TL7: begin
        if (!tk_dosep && tk_c != 8'h20 && tk_c != 8'd0) begin
            if (tk_a2 == 16'd0) tk_a2 <= tk_a1;
            st <= S_TL8;
        end
        else if (tk_a2 != 16'd0) begin
            tt_len <= tk_a1 - tk_a2; tt_from <= tk_a2 - tk_text; tk_a2 <= 16'd0;
            push(S_TL8); st <= S_TT0;
        end
        else st <= S_TL8;
    end
    S_TL8: begin
        if (tk_dosep) begin tk_dosep <= 1'b0; tt_len <= 16'd1; tt_from <= tk_a1 - tk_text; push(S_TL8); st <= S_TT0; end
        else if (tk_c == 8'd0) sub_ret;
        else st <= S_TL3;
    end

    // tokenise_text (tt_len, tt_from)
    S_TT0: begin push(S_TT1); rdb_go({3'd0, tk_parse}); end
    S_TT1: begin tt_max <= val[7:0]; push(S_TT2); rdb_go({3'd0, tk_parse + 16'd1}); end
    S_TT2: begin
        tt_cnt <= val[7:0];
        if (val[7:0] < tt_max) begin push(S_TT3); wrb_go({3'd0, tk_parse + 16'd1}, val[7:0] + 8'd1); end
        else sub_ret;
    end
    S_TT3: begin en_src <= tk_text + tt_from; en_len <= tt_len; en_pad <= 5'd5; push(S_TT4); st <= S_EN0; end
    S_TT4: begin push(S_TT5); st <= S_LK0; end
    S_TT5: begin                                       // tt_addr = lookup result
        if (tt_addr != 16'd0 || !tk_flag) begin
            tt_p <= tk_parse + 16'd2 + {6'd0, tt_cnt, 2'b00};
            push(S_TT6); wrw_go({3'd0, tk_parse + 16'd2 + {6'd0, tt_cnt, 2'b00}}, tt_addr);
        end
        else sub_ret;
    end
    S_TT6: begin push(S_TT7); wrb_go({3'd0, tt_p + 16'd2}, tt_len[7:0]); end
    S_TT7: begin push(S_PO3); wrb_go({3'd0, tt_p + 16'd3}, tt_from[7:0]); end    // S_PO3 is a plain sub_ret

    // encode_text: en_len bytes at en_src -> enc0..enc2 (Frotz load_string + encode_text, default alphabet)
    S_EN0: begin en_zi <= 4'd0; en_ci <= 4'd0; st <= S_EN1; end
    S_EN1: begin
        if (en_zi >= en_res3) st <= S_EN3;
        else if ({12'd0, en_ci} < en_len) begin push(S_EN2); rdb_go({3'd0, en_src + {12'd0, en_ci}}); end
        else begin val <= 16'd0; st <= S_EN2; end
    end
    S_EN2: begin
        en_ci <= en_ci + 4'd1;
        if (val[7:0] == 8'd0) begin zb[en_zi] <= en_pad; en_zi <= en_zi + 4'd1; st <= S_EN1; end
        else begin en_c <= val[7:0]; en_k <= 7'd0; st <= S_EN4; end
    end
    S_EN4: begin                                       // search A0, A1, A2 in order (Frotz encode_text), else a ZSCII escape
        if (alph[en_k] == en_c) begin
            if (en_k < 7'd26) begin zb[en_zi] <= en_k[4:0] + 5'd6; en_zi <= en_zi + 4'd1; end
            else begin
                zb[en_zi] <= (en_k < 7'd52 ? 5'd1 : 5'd2) + (version <= 4'd2 ? 5'd1 : 5'd3);   // Frotz: (V1/2 1, else 3) + set
                zb[en_zi + 4'd1] <= en_k < 7'd52 ? en_k[4:0] - 5'd20 : en_k[4:0] - 5'd14;   // en_k - 26 + 6 / en_k - 52 + 6 (mod 32)
                en_zi <= en_zi + 4'd2;
            end
            st <= S_EN1;
        end
        else if (en_k == 7'd77) begin
            zb[en_zi] <= 5'd5; zb[en_zi + 4'd1] <= 5'd6; zb[en_zi + 4'd2] <= {2'd0, en_c[7:5]}; zb[en_zi + 4'd3] <= en_c[4:0];
            en_zi <= en_zi + 4'd4; st <= S_EN1;
        end
        else en_k <= en_k + 7'd1;
    end
    S_EN3: begin
        enc0 <= {1'b0, zb[0], zb[1], zb[2]};
        enc1 <= {v3, zb[3], zb[4], zb[5]};
        enc2 <= {1'b1, zb[6], zb[7], zb[8]};
        sub_ret;
    end

    // lookup_text (exact match) in tk_dct -> tt_addr
    S_LK0: begin push(S_LK1); rdb_go({3'd0, tk_dct}); end
    S_LK1: begin lk_ent <= tk_dct + 16'd1 + val; push(S_LK2); rdb_go({3'd0, tk_dct + 16'd1 + val}); end
    S_LK2: begin lk_elen <= val[7:0]; push(S_LK3); rdw_go({3'd0, lk_ent + 16'd1}); end
    S_LK3: begin
        lk_ent <= lk_ent + 16'd3;
        lk_sorted <= !val[15];
        lk_lo <= 17'sd0;
        lk_hi <= $signed({1'b0, val[15] ? -val : val}) - 17'sd1;
        st <= S_LK4;
    end
    S_LK4: begin
        if (lk_lo > lk_hi) begin tt_addr <= 16'd0; sub_ret; end
        else begin
            lk_n <= lk_mid; lk_ea <= lk_addr; lk_i <= 2'd0;
            push(S_LK5); rdw_go({3'd0, lk_addr});
        end
    end
    S_LK5: begin
        if (enc_i != val) begin
            if (!lk_sorted)      lk_lo <= lk_lo + 17'sd1;
            else if (enc_i > val) lk_lo <= lk_n + 17'sd1;
            else                  lk_hi <= lk_n - 17'sd1;
            st <= S_LK4;
        end
        else if (lk_last) begin tt_addr <= lk_ea; sub_ret; end
        else begin lk_i <= lk_i + 2'd1; push(S_LK5); rdw_go({3'd0, lk_ea + {13'd0, lk_i + 2'd1, 1'b0}}); end
    end

    // encode_text opcode: write the three words to d
    S_ET1: begin push(S_ET2); wrw_go({3'd0, d}, enc0); end
    S_ET2: begin push(S_ET3); wrw_go({3'd0, d + 16'd2}, enc1); end
    S_ET3: begin push(S_FETCH); wrw_go({3'd0, d + 16'd4}, enc2); end

    // ------------------------------------------------ undo: save copies, restore copies back and stores 2 through
    // save_undo's own store byte (the saved pc points at it), as Frotz restore_undo
    S_SU1: if (u_i == static_base) begin u_i <= 16'd0; st <= S_SU4; end
           else begin push(S_SU2); rdb_go({3'd0, u_i}); end
    S_SU2: begin u_i <= u_i + 16'd1; push(S_SU1); wrb_undo_go({3'd0, u_i}, val[7:0]); end
    S_SU4: if (u_i[11:0] == sp && u_i[15:12] == 4'd0) st <= S_SU6;
           else begin push(S_SU5); srd_go(u_i[11:0]); end
    S_SU5: begin push(S_SU5B); wrb_undo_go(19'h10000 + {6'd0, u_i[11:0], 1'b0}, val[15:8]); end
    S_SU5B: begin u_i <= u_i + 16'd1; push(S_SU4); wrb_undo_go(19'h10001 + {6'd0, u_i[11:0], 1'b0}, val[7:0]); end
    S_SU6: begin
        sl_pc[u_head] <= pc; sl_sp[u_head] <= sp; sl_fp[u_head] <= fp; sl_depth[u_head] <= depth; sl_dyn[u_head] <= static_base;
        u_head <= u_head + 5'd1; if (u_count != 6'd32) u_count <= u_count + 6'd1;
        store(16'd1);
    end
    S_RU1: if (u_i == sl_dyn[m_uslot]) begin u_i <= 16'd0; st <= S_RU4; end
           else begin push(S_RU2); rdb_undo_go({3'd0, u_i}); end
    S_RU2: begin u_i <= u_i + 16'd1; push(S_RU1); wrb_go({3'd0, u_i}, val[7:0]); end
    S_RU4: if (u_i[11:0] == sl_sp[m_uslot] && u_i[15:12] == 4'd0) st <= S_RU6;
           else begin push(S_RU4B); rdb_undo_go(19'h10000 + {6'd0, u_i[11:0], 1'b0}); end
    S_RU4B: begin tmp8 <= val[7:0]; push(S_RU5); rdb_undo_go(19'h10001 + {6'd0, u_i[11:0], 1'b0}); end
    S_RU5: begin swr(u_i[11:0], {tmp8, val[7:0]}); u_i <= u_i + 16'd1; st <= S_RU4; end
    S_RU6: begin pc <= sl_pc[m_uslot]; sp <= sl_sp[m_uslot]; fp <= sl_fp[m_uslot]; depth <= sl_depth[m_uslot]; store(16'd2); end

    // ------------------------------------------------ restart: dynamic memory from the story as loaded, then the start-up sequence
    S_RS1: if (u_i == static_base) st <= S_INIT0;                     // S_INIT10 resets the screen
           else begin push(S_RS2); rdb_orig_go({3'd0, u_i}); end
    S_RS2: begin u_i <= u_i + 16'd1; push(S_RS1); wrb_go({3'd0, u_i}, val[7:0]); end
    // throw a, b: unwind to frame count b (each frame's fp+2 holds the caller's fp), then return a from it
    S_THR1: if ({8'd0, depth} == b) begin res <= a; st <= S_RET0; end
            else begin push(S_THR2); srd_go(fp + 12'd2); end
    S_THR2: begin fp <= val[11:0]; depth <= depth - 8'd1; st <= S_THR1; end

    // ------------------------------------------------ copy_table: ct_i counts up; backwards copies index n-1-i
    S_CT1: begin
        if (ct_i == ct_n) st <= S_FETCH;
        else if (ct_mode == 2'd0) begin ct_i <= ct_i + 16'd1; push(S_CT1); wrb_go({3'd0, a + ct_i}, 8'd0); end
        else begin push(S_CT2); rdb_go({3'd0, a + (ct_mode == 2'd1 ? ct_i : ct_n - 16'd1 - ct_i)}); end
    end
    S_CT2: begin
        ct_i <= ct_i + 16'd1; push(S_CT1);
        wrb_go({3'd0, b + (ct_mode == 2'd1 ? ct_i : ct_n - 16'd1 - ct_i)}, val[7:0]);
    end
    // print_table: a text, b width, c height (default 1), d skip (default 0) (Frotz screen.c z_print_table)
    S_PT1: begin
        if (pt_j == b) begin                           // row done
            pt_j <= 16'd0; pt_i <= pt_i + 16'd1; pt_addr <= pt_addr + (argc < 4'd4 ? 16'd0 : d);
            if (pt_i + 16'd1 == (argc < 4'd3 ? 16'd1 : c)) st <= S_FETCH;
            else emit_cmd(CMD_PT_ROW, 16'd0, 16'd0, S_PT1);
        end
        else begin push(S_PT2); rdb_go({3'd0, pt_addr}); end
    end
    S_PT2: begin pt_addr <= pt_addr + 16'd1; pt_j <= pt_j + 16'd1; emit({2'd0, val[7:0]}, S_PT1); end
    // scan_table: a target, b table, c entries, d form (default 0x82: words, step 2)
    S_SCN1: begin
        if (ct_i == c) begin res <= 16'd0; cond <= 1'b0; then_br <= 1'b1; st <= S_STORE; end
        else begin
            push(S_SCN2);
            if ((argc < 4'd4) || d[7]) rdw_go({3'd0, sc_addr}); else rdb_go({3'd0, sc_addr});
        end
    end
    S_SCN2: begin
        if (val == a) begin res <= sc_addr; cond <= 1'b1; then_br <= 1'b1; st <= S_STORE; end
        else begin sc_addr <= sc_addr + {9'd0, argc < 4'd4 ? 7'd2 : d[6:0]}; ct_i <= ct_i + 16'd1; st <= S_SCN1; end
    end

    // ------------------------------------------------ properties
    S_GP1: begin
        push(S_GP2);
        if (!p_found)            rdw_go({3'd0, objtab + {b[14:0], 1'b0} - 16'd2});
        else if (p_size == 7'd1) rdb_go({3'd0, p_data});
        else                     rdw_go({3'd0, p_data});
    end
    S_GP2:  store(val);
    S_GPA1: store(p_found ? p_data : 16'd0);
    S_GNP1: store(p_found ? {10'd0, p_cur} : 16'd0);
    S_PP1: begin
        if (!p_found) halt(8'd8);
        else begin push(S_FETCH); if (p_size == 7'd1) wrb_go({3'd0, p_data}, c[7:0]); else wrw_go({3'd0, p_data}, c); end
    end
    S_GPL1: begin
        if (v3)          store({13'd0, val[7:5]} + 16'd1);
        else if (val[7]) store(val[5:0] == 6'd0 ? 16'd64 : {10'd0, val[5:0]});
        else             store(val[6] ? 16'd2 : 16'd1);
    end

    // property search: p_obj, p_num, p_mode -> p_found, p_cur, p_data, p_size
    S_PF0: begin push(S_PF1); rdw_go({3'd0, oaddr(p_obj, v3, objtab) + (v3 ? 16'd7 : 16'd12)}); end
    S_PF1: begin p_pa <= val; push(S_PF2); rdb_go({3'd0, val}); end
    S_PF2: begin p_pa <= p_pa + 16'd1 + {val[14:0], 1'b0}; st <= S_PF3; end
    S_PF3: begin push(S_PF4); rdb_go({3'd0, p_pa}); end
    S_PF4: begin
        if (val[7:0] == 8'd0) begin p_found <= 1'b0; p_cur <= 6'd0; sub_ret; end
        else if (v3) begin p_cur <= {1'b0, val[4:0]}; p_size <= {4'd0, val[7:5]} + 7'd1; p_data <= p_pa + 16'd1; st <= S_PF6; end
        else if (val[7]) begin p_cur <= val[5:0]; push(S_PF5); rdb_go({3'd0, p_pa + 16'd1}); end
        else begin p_cur <= val[5:0]; p_size <= val[6] ? 7'd2 : 7'd1; p_data <= p_pa + 16'd1; st <= S_PF6; end
    end
    S_PF5: begin p_size <= val[5:0] == 6'd0 ? 7'd64 : {1'b0, val[5:0]}; p_data <= p_pa + 16'd2; st <= S_PF6; end
    S_PF6: begin
        if (p_mode == PF_FIRST) begin p_found <= 1'b1; sub_ret; end
        else if (p_cur == p_num) begin
            if (p_mode == PF_NEXT) begin p_mode <= PF_FIRST; p_pa <= p_data + {9'd0, p_size}; st <= S_PF3; end
            else begin p_found <= 1'b1; sub_ret; end
        end
        else if (p_cur < p_num) begin p_found <= 1'b0; p_cur <= 6'd0; sub_ret; end
        else begin p_pa <= p_data + {9'd0, p_size}; st <= S_PF3; end
    end

    // ------------------------------------------------ object tree
    S_RELRD: begin
        if (r_obj == 16'd0) begin val <= 16'd0; sub_ret; end
        else if (v3) rdb_go({3'd0, rel_addr});
        else         rdw_go({3'd0, rel_addr});
    end
    S_RELWR: begin
        if (r_obj == 16'd0) sub_ret;
        else if (v3) wrb_go({3'd0, rel_addr}, w_val[7:0]);
        else         wrw_go({3'd0, rel_addr}, w_val);
    end
    // remove o_obj from its parent (a sequence: caller pushed the return)
    S_REM0: relrd(o_obj, 2'd0, S_REM1);
    S_REM1: begin o_par <= val; if (val == 16'd0) sub_ret; else relrd(o_obj, 2'd1, S_REM2); end
    S_REM2: begin o_sib <= val; relrd(o_par, 2'd2, S_REM3); end
    S_REM3: begin
        o_x <= val;
        if (val == o_obj) relwr(o_par, 2'd2, o_sib, S_REM6);
        else relrd(val, 2'd1, S_REM4);
    end
    S_REM4: begin                                      // val = sibling of o_x
        if (val == o_obj)       relwr(o_x, 2'd1, o_sib, S_REM6);
        else if (val == 16'd0)  st <= S_REM6;          // not found in the chain: just detach
        else begin o_x <= val; relrd(val, 2'd1, S_REM4); end
    end
    S_REM6: relwr(o_obj, 2'd0, 16'd0, S_REM7);
    S_REM7: relwr(o_obj, 2'd1, 16'd0, S_REM5);
    S_REM5: sub_ret;
    // insert_obj: after the remove
    S_INS0: relrd(o_dst, 2'd2, S_INS1);
    S_INS1: relwr(o_obj, 2'd1, val, S_INS2);
    S_INS2: relwr(o_obj, 2'd0, o_dst, S_INS3);
    S_INS3: relwr(o_dst, 2'd2, o_obj, S_FETCH);

    // ------------------------------------------------ arithmetic
    S_DIV1: begin
        d_n <= {d_n[14:0], 1'b0};
        if (d_r2 >= {1'b0, d_d}) begin d_r <= d_r2[15:0] - d_d; d_q <= {d_q[14:0], 1'b1}; end
        else                     begin d_r <= d_r2[15:0];       d_q <= {d_q[14:0], 1'b0}; end
        if (d_i == 4'd0) st <= S_DIV2; else d_i <= d_i - 4'd1;
    end
    S_DIV2: begin
        if (oid == 8'h67)      store(d_r + 16'd1);
        else if (oid == 8'h18) store(a[15] ? -d_r : d_r);
        else              store((a[15] ^ b[15]) ? -d_q : d_q);
    end

    S_PN0: begin
        pn_k <= 3'd0; pn_d <= 4'd0; pn_started <= 1'b0;
        if (pn_val[15]) begin pn_n <= -pn_val; emit(10'h2D, S_PN2); end
        else begin pn_n <= pn_val; st <= S_PN2; end
    end
    S_PN2: begin
        if (pn_n >= pow10(pn_k)) begin pn_n <= pn_n - pow10(pn_k); pn_d <= pn_d + 4'd1; end
        else if (pn_d != 4'd0 || pn_started || pn_k == 3'd4) begin pn_started <= 1'b1; emit(10'h30 + {6'd0, pn_d}, S_PN3); end
        else st <= S_PN3;
    end
    S_PN3: begin pn_d <= 4'd0; if (pn_k == 3'd4) sub_ret; else begin pn_k <= pn_k + 3'd1; st <= S_PN2; end end

    // ------------------------------------------------ store / branch / call / return
    S_STORE:  begin push(S_STORE2); pcb_go; end
    S_STORE2: vwrite(val[7:0], 1'b0, res, then_br ? S_BR : S_FETCH);
    S_BR:  begin push(S_BR1); pcb_go; end
    S_BR1: begin
        b_on <= val[7];
        if (val[6]) begin b_off <= {8'd0, val[5:0]}; st <= S_BR3; end
        else begin b_hi <= val[5:0]; push(S_BR2); pcb_go; end
    end
    S_BR2: begin b_off <= {b_hi, val[7:0]}; st <= S_BR3; end
    S_BR3: begin
        if (cond != b_on)            st <= S_FETCH;
        else if (b_off == 14'd0) begin res <= 16'd0; st <= S_RET0; end
        else if (b_off == 14'd1) begin res <= 16'd1; st <= S_RET0; end
        else begin pc <= pc + {{5{b_off[13]}}, b_off} - 19'd2; st <= S_FETCH; end
    end

    S_CALL:    if (c_disc) st <= S_CALL_A; else begin push(S_CALL_SV); pcb_go; end
    S_CALL_SV: begin c_sv <= val[7:0]; st <= S_CALL_A; end
    S_CALL_A: begin
        if (a == 16'd0) begin
            if (c_disc) st <= S_FETCH; else vwrite(c_sv, 1'b0, 16'd0, S_FETCH);
        end
        else if (sp > 12'd3900) halt(8'd5);
        else begin
            c_raddr <= unpack(a, version, r_off); c_nfp <= sp;
            swr(sp, pc[15:0]);
            st <= S_CALL_B;
        end
    end
    S_CALL_B: begin swr(c_nfp + 12'd1, {c_sv, c_disc, argc[2:0] - 3'd1, 1'b0, pc[18:16]}); st <= S_CALL_C; end
    S_CALL_C: begin swr(c_nfp + 12'd2, {4'd0, fp}); push(S_CALL_D); rdb_go(c_raddr); end
    S_CALL_D: begin c_n <= val[3:0]; swr(c_nfp + 12'd3, {12'd0, val[3:0]}); c_i <= 4'd0; st <= S_CALL_E; end
    S_CALL_E: begin
        if (c_i == c_n) st <= S_CALL_G;
        else if (version < 4'd5) begin push(S_CALL_F); rdw_go(c_raddr + 19'd1 + {14'd0, c_i, 1'b0}); end
        else begin val <= 16'd0; st <= S_CALL_F; end
    end
    S_CALL_F: begin
        swr(c_nfp + 12'd4 + {8'd0, c_i}, ({1'b0, c_i} < {1'b0, argc} - 5'd1) ? ops[c_i[2:0] + 3'd1] : val);
        c_i <= c_i + 4'd1; st <= S_CALL_E;
    end
    S_CALL_G: begin
        pc <= c_raddr + 19'd1 + (version < 4'd5 ? {14'd0, c_n, 1'b0} : 19'd0);
        sp <= c_nfp + 12'd4 + {8'd0, c_n}; fp <= c_nfp; depth <= depth + 8'd1;
        st <= S_FETCH;
    end

    S_RET0: begin
        if (depth == 8'd0) halt(8'd6);
        else begin sp <= fp; push(S_RET1); srd_go(fp); end
    end
    S_RET1: begin t_pclo <= val; push(S_RET2); srd_go(fp + 12'd1); end
    S_RET2: begin t_flags <= val; push(S_RET3); srd_go(fp + 12'd2); end
    S_RET3: begin
        fp <= val[11:0]; pc <= {t_flags[2:0], t_pclo}; depth <= depth - 8'd1;
        if (t_flags[7]) st <= in_int && depth == int_depth + 8'd1 ? S_IRET : S_FETCH;   // the interrupt routine's return
        else vwrite(t_flags[15:8], 1'b0, res, S_FETCH);
    end

    // ------------------------------------------------ text: Z-string at z_addr -> characters
    S_Z0: begin push(S_Z1); rdw_go(z_addr); end
    S_Z1: begin z_word <= val; z_addr <= z_addr + 19'd2; z_idx <= 2'd0; st <= S_Z2; end
    S_Z2: begin
        if (z_esc == 2'd1) begin z_eschi <= zc; z_esc <= 2'd2; st <= S_Z3; end
        else if (z_esc == 2'd2) begin z_esc <= 2'd0; emit({z_eschi, zc}, S_Z3); end
        else if (z_abbr != 2'd0) begin
            zs_addr <= z_addr; zs_word <= z_word; zs_idx <= z_idx; zs_lock <= z_lock;
            push(S_ZA); rdw_go({3'd0, abbrev + {8'd0, z_abbr - 2'd1, zc, 1'b0}});
        end
        // Frotz decode_text: after anything but a shift, the shift falls back to the lock (V1/V2: 2/3 shift one
        // character, 4/5 lock; V1: Z-char 1 = new line; V2: 1 = abbreviations 0-31; V3+: 1-3 abbreviations, 4/5 shift)
        else if (z_shift == 2'd2 && zc == 5'd6) begin z_esc <= 2'd1; z_shift <= z_lock; st <= S_Z3; end
        else if (version == 4'd1 && zc == 5'd1) begin z_shift <= z_lock; emit(10'd13, S_Z3); end
        else if (version >= 4'd2 && z_shift == 2'd2 && zc == 5'd7) begin z_shift <= z_lock; emit(10'd13, S_Z3); end
        else if (zc >= 5'd6) begin z_shift <= z_lock; emit({2'd0, alph[(z_shift == 2'd0 ? 7'd0 : z_shift == 2'd1 ? 7'd26 : 7'd52) + {2'd0, zc} - 7'd6]}, S_Z3); end
        else if (zc == 5'd0) begin z_shift <= z_lock; emit(10'd32, S_Z3); end
        else if ((version >= 4'd2 && zc == 5'd1) || (version >= 4'd3 && zc <= 5'd3)) begin
            z_abbr <= z_inabbr ? 2'd0 : zc[1:0]; z_shift <= z_lock; st <= S_Z3;
        end
        else begin                                     // a shift
            z_shift <= zshift(z_lock, zc);
            if (version <= 4'd2 && zc >= 5'd4) z_lock <= zshift(z_lock, zc);
            st <= S_Z3;
        end
    end
    S_ZA: begin z_addr <= {2'd0, val, 1'b0}; z_inabbr <= 1'b1; z_abbr <= 2'd0; z_shift <= 2'd0; z_lock <= 2'd0; z_esc <= 2'd0; st <= S_Z0; end
    S_Z3: begin
        if (z_idx != 2'd2) begin z_idx <= z_idx + 2'd1; st <= S_Z2; end
        else if (!z_word[15]) st <= S_Z0;
        else st <= S_ZEND;
    end
    S_ZEND: begin
        if (z_inabbr) begin
            z_addr <= zs_addr; z_word <= zs_word; z_idx <= zs_idx; z_inabbr <= 1'b0; z_shift <= zs_lock; z_lock <= zs_lock;
            st <= S_Z3;
        end
        else begin
            if (z_frompc) pc <= z_addr;
            sub_ret;
        end
    end

    // ------------------------------------------------ save / restore: Frotz stdio -V slot prompt (os_read_file_name),
    // then quetzal.c save_quetzal / restore_quetzal and z_restore's restart_header. pc = the instruction's store /
    // branch byte throughout, which is what IFhd records; a restore resumes there with result 2.
    S_Q0: if (!sav_mnt) st <= S_QFAIL; else begin q_slot <= 4'd0; q_first <= 1'b1; emit_str(STR_CUR, S_Q1); end
    S_Q1: begin                                        // list the slots whose first block starts "FORM"
        if (q_slot == 4'd10) emit_str(STR_ENTER, S_Q4R);
        else if (q_base >= sav_ceil) q_slot <= q_slot + 4'd1;
        else begin sd_lba <= {16'd0, q_base}; sd_rd <= 1'b1; q_wr <= 1'b0; push(S_Q2); st <= S_QW1; end
    end
    S_Q2: begin q_bp <= 9'd0; q_need <= 1'b0; q_k <= 3'd4; push(S_Q3); st <= S_QGN; end
    S_Q3: if (q_acc != "FORM") begin q_slot <= q_slot + 4'd1; st <= S_Q1; end
          else begin q_first <= 1'b0; if (q_first) st <= S_Q3B; else emit(10'h2C, S_Q3B); end
    S_Q3B: emit(10'h30 + {6'd0, q_slot}, S_Q3C);
    S_Q3C: begin q_slot <= q_slot + 4'd1; st <= S_Q1; end
    S_Q4: if (key_valid && !key_ack) begin             // a digit; anything else is ignored
        key_ack <= 1'b1;
        if (key_code >= 10'h30 && key_code <= 10'h39) begin
            q_slot <= key_code[3:0];
            st <= S_Q5;                                // not echoed (Frotz stdio's os_read_key)
        end
    end
    S_Q4R: emit_cmd(CMD_READ, 16'd1, 16'd0, S_Q4);
    S_Q5: emit(10'd13, S_Q6);
    S_Q6: if (q_rest) st <= S_R0; else st <= S_W0;
    S_QFAIL: if (v3) branch(1'b0); else store(16'd0);
    S_QERR: if (q_fatal) halt(8'd12); else st <= S_QFAIL;

    // block buffer: put q_byte (q_dry: count only), a full block goes out to q_lba; get -> val, reading q_lba when needed
    S_QPUT: begin
        if (q_dry) begin q_cnt <= q_cnt + 32'd1; sub_ret; end
        else begin
            b_addr <= q_bp; b_wd <= q_byte; b_we <= 1'b1; q_bp <= q_bp + 9'd1;
            if (q_bp == 9'd511) st <= S_QFL; else sub_ret;
        end
    end
    S_QFL: begin sd_lba <= {16'd0, q_lba}; q_lba <= q_lba + 16'd1; sd_wr <= 1'b1; q_wr <= 1'b1; st <= S_QW1; end
    S_QW1: if (sd_ack) begin sd_rd <= 1'b0; sd_wr <= 1'b0; st <= S_QW2; end
    S_QW2: if (!sd_ack) begin
        if (q_wr && sd_lba[15:0] >= sav_floor) begin
            sav_floor <= sd_lba[15:0] + 16'd1;
            if (sd_lba[15:0] >= sav_ceil) sav_ceil <= sd_lba[15:0] + 16'd1;
        end
        sub_ret;
    end
    S_QGET: begin
        if (q_need) begin
            q_need <= 1'b0; sd_lba <= {16'd0, q_lba}; q_lba <= q_lba + 16'd1; sd_rd <= 1'b1; q_wr <= 1'b0;
            push(S_QGET); st <= S_QW1;
        end
        else begin b_addr <= q_bp; st <= S_QG1; end
    end
    S_QG1: st <= S_QG2;
    S_QG2: begin val <= {8'd0, b_q}; q_bp <= q_bp + 9'd1; if (q_bp == 9'd511) q_need <= 1'b1; sub_ret; end
    S_QPN: if (q_k == 3'd0) sub_ret; else begin q_byte <= q_out[47:40]; q_out <= {q_out[39:0], 8'd0}; q_k <= q_k - 3'd1; push(S_QPN); st <= S_QPUT; end
    S_QGN: if (q_k == 3'd0) sub_ret; else begin push(S_QGN1); st <= S_QGET; end
    S_QGN1: begin q_acc <= {q_acc[23:0], val[7:0]}; q_k <= q_k - 3'd1; st <= S_QGN; end

    // save: CMem length first (dry pass), then pad the file up to the slot, then the file in one pass
    S_W0: begin q_dry <= 1'b1; q_cnt <= 32'd0; q_i <= 16'd0; q_run <= 17'd0; push(S_W1); st <= S_CM0; end
    S_W1: begin
        q_cmlen <= q_cnt; q_dry <= 1'b0; q_zeroed <= 1'b0;
        q_lba <= sav_floor; q_padfirst <= sav_floor != sav_ceil; q_bp <= 9'd0;
        st <= S_WP0;
    end
    S_WP0: begin
        if (q_lba >= q_base) begin q_lba <= q_base; q_bp <= 9'd0; q_hi <= 6'd0; st <= q_aux ? S_XW1 : S_WH0; end
        else if (q_padfirst) begin                     // a started last block: read it, write it back whole
            q_padfirst <= 1'b0; sd_lba <= {16'd0, q_lba}; sd_rd <= 1'b1; q_wr <= 1'b0; push(S_WP1); st <= S_QW1;
        end
        else if (!q_zeroed) st <= S_WZ;
        else begin sd_lba <= {16'd0, q_lba}; sd_wr <= 1'b1; q_wr <= 1'b1; push(S_WP2); st <= S_QW1; end
    end
    S_WP1: begin sd_lba <= {16'd0, q_lba}; sd_wr <= 1'b1; q_wr <= 1'b1; push(S_WP2); st <= S_QW1; end
    S_WP2: begin q_lba <= q_lba + 16'd1; st <= S_WP0; end
    S_WZ: begin
        b_addr <= q_bp; b_wd <= 8'd0; b_we <= 1'b1; q_bp <= q_bp + 9'd1;
        if (q_bp == 9'd511) begin q_zeroed <= 1'b1; st <= S_WP0; end
    end
    S_WH0: begin
        if (q_hi == 6'd42) begin q_i <= 16'd0; q_run <= 17'd0; push(S_WC1); st <= S_CM0; end
        else if (q_hi >= 6'd20 && q_hi <= 6'd29) begin push(S_WH1); rdb_go(qhaddr(q_hi[3:0] - 4'd4)); end   // 20..29 -> 0..9
        else begin q_byte <= qhdr(q_hi, q_ifzslen, q_cmlen, pc); q_hi <= q_hi + 6'd1; push(S_WH0); st <= S_QPUT; end
    end
    S_WH1: begin q_byte <= val[7:0]; q_hi <= q_hi + 6'd1; push(S_WH0); st <= S_QPUT; end
    // CMem: dynamic memory XOR the story as loaded; runs of zeros as 0, n-1 (at most 256 each); a final run is dropped
    S_CM0: if (q_i == static_base) sub_ret; else begin push(S_CM1); rdb_orig_go({3'd0, q_i}); end
    S_CM1: begin tmp8 <= val[7:0]; push(S_CM2); rdb_go({3'd0, q_i}); end
    S_CM2: begin
        q_x <= tmp8 ^ val[7:0]; q_i <= q_i + 16'd1;
        if ((tmp8 ^ val[7:0]) == 8'd0) begin q_run <= q_run + 17'd1; st <= S_CM0; end
        else st <= S_CM3;
    end
    S_CM3: begin
        if (q_run > 17'd256)       begin q_run <= q_run - 17'd256; q_byte <= 8'd0; push(S_CM4); st <= S_QPUT; end
        else if (q_run != 17'd0)   begin q_byte <= 8'd0; push(S_CM5); st <= S_QPUT; end
        else                       begin q_byte <= q_x; push(S_CM0); st <= S_QPUT; end
    end
    S_CM4: begin q_byte <= 8'hFF; push(S_CM3); st <= S_QPUT; end
    S_CM5: begin q_byte <= q_run[7:0] - 8'd1; q_run <= 17'd0; push(S_CM3); st <= S_QPUT; end
    S_WC1: if (q_cmlen[0]) begin q_byte <= 8'd0; push(S_WS0); st <= S_QPUT; end else st <= S_WS0;
    // Stks: Quetzal's dummy frame (the main routine's evaluation stack), then every frame oldest first. Frame k's
    // start = k-th caller-fp link back from fp; walking depth-k links leaves q_cur = frame k, q_nxt = the one after
    S_WS0: begin q_out <= {"Stks", 16'd0}; q_k <= 3'd4; push(S_WS1); st <= S_QPN; end
    S_WS1: begin q_out <= {q_stkslen, 16'd0}; q_k <= 3'd4; q_fk <= 9'd0; push(S_WF0); st <= S_QPN; end
    S_WF0: if (q_fk > {1'b0, depth}) st <= S_WE0;
           else begin q_cur <= fp; q_nxt <= sp; q_wn <= depth - q_fk[7:0]; st <= S_WF1; end
    S_WF1: if (q_wn == 8'd0) st <= S_WF2; else begin push(S_WF1B); srd_go(q_cur + 12'd2); end
    S_WF1B: begin q_nxt <= q_cur; q_cur <= val[11:0]; q_wn <= q_wn - 8'd1; st <= S_WF1; end
    S_WF2: if (q_fk == 9'd0) begin q_out <= 48'd0; q_k <= 3'd6; push(S_WF3); st <= S_QPN; end
           else begin push(S_WF4); srd_go(q_cur); end
    S_WF3: begin q_out <= {4'd0, q_nxt, 32'd0}; q_k <= 3'd2; q_wi <= 12'd0; q_wend <= q_nxt; push(S_WW0); st <= S_QPN; end
    S_WF4: begin q_pclo <= val; push(S_WF5); srd_go(q_cur + 12'd1); end
    S_WF5: begin q_fl <= val; push(S_WF6); srd_go(q_cur + 12'd3); end
    S_WF6: begin                                       // return pc, {procedure, locals}
        q_n <= {4'd0, q_nxt - q_cur - 12'd4 - {8'd0, val[3:0]}};
        q_out <= {5'd0, q_fl[2:0], q_pclo, 3'd0, q_fl[7], val[3:0], 16'd0}; q_k <= 3'd4;
        q_wi <= q_cur + 12'd4; q_wend <= q_nxt;
        push(S_WF7); st <= S_QPN;
    end
    S_WF7: begin                                       // result variable, argument mask, evaluation stack size
        q_out <= {q_fl[7] ? 8'd0 : q_fl[15:8], (8'd1 << q_fl[6:4]) - 8'd1, q_n, 16'd0}; q_k <= 3'd4;
        push(S_WW0); st <= S_QPN;
    end
    S_WW0: if (q_wi == q_wend) begin q_fk <= q_fk + 9'd1; st <= S_WF0; end
           else begin push(S_WW1); srd_go(q_wi); end
    S_WW1: begin q_out <= {val, 32'd0}; q_k <= 3'd2; q_wi <= q_wi + 12'd1; push(S_WW0); st <= S_QPN; end
    S_WE0: if (q_bp != 9'd0) begin q_byte <= 8'd0; push(S_WE0); st <= S_QPUT; end   // zero the rest of the last block
           else if (v3) branch(1'b1); else store(16'd1);

    // save / restore with a table: find the name in slots 10-15 (q_slot wraps to 0 after 15), then read or write
    S_X0: if (!sav_mnt) st <= S_QFAIL;
          else if (x_nm != 16'd0) begin push(S_X0B); rdb_go({3'd0, x_nm}); end
          else begin x_nlen <= 8'd0; st <= S_X1I; end
    S_X0B: begin x_nlen <= val[7:0]; st <= S_X1I; end
    S_X1I: begin q_slot <= 4'd10; x_free <= 4'd0; st <= S_X1; end
    S_X1: if (q_slot == 4'd0) st <= S_XNF;
          else if (q_base >= sav_ceil) begin if (x_free == 4'd0) x_free <= q_slot; q_slot <= q_slot + 4'd1; end
          else begin q_lba <= q_base; q_need <= 1'b1; q_bp <= 9'd0; q_k <= 3'd4; push(S_X2); st <= S_QGN; end
    S_X2: if (q_acc != "ZAUX") begin if (x_free == 4'd0) x_free <= q_slot; q_slot <= q_slot + 4'd1; st <= S_X1; end
          else begin q_k <= 3'd3; push(S_X3); st <= S_QGN; end   // length, name length
    S_X3: begin
        x_flen <= q_acc[23:8]; x_k <= 8'd0;
        if (q_acc[7:0] != x_nlen) begin q_slot <= q_slot + 4'd1; st <= S_X1; end else st <= S_X4;
    end
    S_X4: if (x_k == x_nlen) st <= S_XHIT; else begin push(S_X5); st <= S_QGET; end
    S_X5: begin q_x <= val[7:0]; push(S_X6); rdb_go({3'd0, x_nm + 16'd1 + {8'd0, x_k}}); end
    S_X6: if (lc(val[7:0]) != q_x) begin q_slot <= q_slot + 4'd1; st <= S_X1; end else begin x_k <= x_k + 8'd1; st <= S_X4; end
    S_XHIT: begin x_n <= 16'd0; st <= q_rest ? S_XR1 : S_XW0; end
    S_XNF: if (q_rest || x_free == 4'd0) st <= S_QFAIL; else begin q_slot <= x_free; st <= S_XW0; end
    S_XR1: if (x_n == x_flen || x_n == x_len) store(x_n); else begin push(S_XR2); st <= S_QGET; end
    S_XR2: begin x_n <= x_n + 16'd1; push(S_XR1); wrb_go({3'd0, x_tab + x_n}, val[7:0]); end
    S_XW0: begin                                       // as S_W1: pad the file up to the slot (S_WP0), then S_XW1
        q_dry <= 1'b0; q_zeroed <= 1'b0; q_lba <= sav_floor; q_padfirst <= sav_floor != sav_ceil; q_bp <= 9'd0;
        st <= S_WP0;
    end
    S_XW1: begin q_out <= {"ZAUX", x_len}; q_k <= 3'd6; push(S_XW2); st <= S_QPN; end
    S_XW2: begin q_byte <= x_nlen; x_k <= 8'd0; push(S_XW3); st <= S_QPUT; end
    S_XW3: if (x_k == x_nlen) begin x_n <= 16'd0; st <= S_XW5; end else begin push(S_XW4); rdb_go({3'd0, x_nm + 16'd1 + {8'd0, x_k}}); end
    S_XW4: begin q_byte <= lc(val[7:0]); x_k <= x_k + 8'd1; push(S_XW3); st <= S_QPUT; end
    S_XW5: if (x_n == x_len) st <= S_XWE; else begin push(S_XW6); rdb_go({3'd0, x_tab + x_n}); end
    S_XW6: begin q_byte <= val[7:0]; x_n <= x_n + 16'd1; push(S_XW5); st <= S_QPUT; end
    S_XWE: if (q_bp != 9'd0) begin q_byte <= 8'd0; push(S_XWE); st <= S_QPUT; end   // zero the rest of the last block
           else begin q_aux <= 1'b0; store(16'd1); end

    // restore: FORM / IFZS, then the chunks in any order; IFhd must match this story before anything is overwritten
    S_R0: if (q_base >= sav_ceil) st <= S_QFAIL;
          else begin q_lba <= q_base; q_need <= 1'b1; q_bp <= 9'd0; q_k <= 3'd4; q_fatal <= 1'b0; q_got <= 3'd0; push(S_R1); st <= S_QGN; end
    S_R1: if (q_acc != "FORM") st <= S_QFAIL; else begin q_k <= 3'd4; push(S_R2); st <= S_QGN; end
    S_R2: if (q_acc[0] || q_acc < 32'd4) st <= S_QFAIL; else begin q_rem <= q_acc - 32'd4; q_k <= 3'd4; push(S_R3); st <= S_QGN; end
    S_R3: if (q_acc != "IFZS") st <= S_QFAIL; else begin push(S_R3B); rdb_go(19'h11); end
    S_R3B: begin q_f11 <= val[1:0]; st <= S_RC0; end
    S_RC0: begin
        if (q_rem == 32'd0) st <= S_RF;
        else if (q_rem < 32'd8) st <= S_QERR;
        else begin q_k <= 3'd4; push(S_RC1); st <= S_QGN; end
    end
    S_RC1: begin q_id <= q_acc; q_k <= 3'd4; push(S_RC2); st <= S_QGN; end
    S_RC2: begin
        q_clen <= q_acc; q_pad <= q_acc[0];
        q_rem <= q_rem - 32'd8 - q_acc - {31'd0, q_acc[0]};
        if (q_rem - 32'd8 < q_acc) st <= S_QERR;       // chunk runs past the FORM
        else if (q_id == "IFhd") st <= (q_got[0] || q_acc < 32'd13) ? S_QERR : S_RH0;
        else if (q_id == "Stks") st <= q_got[1] ? S_RK0 : S_QS0;
        else if (q_id == "CMem") st <= q_got[2] ? S_RK0 : S_RM0;
        else if (q_id == "UMem") st <= (!q_got[2] && q_acc == {16'd0, static_base}) ? S_QU0 : S_RK0;
        else st <= S_RK0;
    end
    S_RK0: if (q_clen == 32'd0) st <= S_RPAD; else begin q_clen <= q_clen - 32'd1; push(S_RK0); st <= S_QGET; end
    S_RPAD: if (q_pad) begin q_pad <= 1'b0; push(S_RC0); st <= S_QGET; end else st <= S_RC0;
    // IFhd: release, serial, checksum against this story; then pc
    S_RH0: begin q_hi <= 6'd0; q_bad <= 1'b0; st <= S_RH1; end
    S_RH1: if (q_hi == 6'd10) st <= S_RH4; else begin push(S_RH2); st <= S_QGET; end
    S_RH2: begin tmp8 <= val[7:0]; push(S_RH3); rdb_go(qhaddr(q_hi[3:0])); end
    S_RH3: begin if (tmp8 != val[7:0]) q_bad <= 1'b1; q_hi <= q_hi + 6'd1; st <= S_RH1; end
    S_RH4: if (q_bad) emit_str(STR_NOTTHIS, S_QERR); else begin q_k <= 3'd3; push(S_RH5); st <= S_QGN; end
    S_RH5: begin q_npc <= q_acc[18:0]; q_fatal <= 1'b1; q_got[0] <= 1'b1; q_clen <= q_clen - 32'd13; st <= S_RK0; end
    // CMem: XOR runs against the story as loaded; a short chunk means the rest is unchanged
    S_RM0: begin q_i <= 16'd0; q_fatal <= 1'b1; st <= S_RM1; end
    S_RM1: if (q_clen == 32'd0) st <= S_RM5; else begin q_clen <= q_clen - 32'd1; push(S_RM2); st <= S_QGET; end
    S_RM2: begin
        if (val[7:0] == 8'd0) begin
            if (q_clen == 32'd0) st <= S_QERR;         // run without its length byte
            else begin q_clen <= q_clen - 32'd1; push(S_RM3); st <= S_QGET; end
        end
        else if (q_i == static_base) st <= S_QERR;     // chunk longer than dynamic memory
        else begin tmp8 <= val[7:0]; push(S_RM4); rdb_orig_go({3'd0, q_i}); end
    end
    S_RM3: begin q_run <= {9'd0, val[7:0]} + 17'd1; st <= S_RM6; end
    S_RM6: if (q_run == 17'd0 || q_i == static_base) st <= S_RM1; else begin push(S_RM7); rdb_orig_go({3'd0, q_i}); end
    S_RM7: begin q_run <= q_run - 17'd1; q_i <= q_i + 16'd1; push(S_RM6); wrb_go({3'd0, q_i}, val[7:0]); end
    S_RM4: begin q_i <= q_i + 16'd1; push(S_RM1); wrb_go({3'd0, q_i}, tmp8 ^ val[7:0]); end
    S_RM5: if (q_i == static_base) begin q_got[2] <= 1'b1; st <= S_RPAD; end
           else begin push(S_RM8); rdb_orig_go({3'd0, q_i}); end
    S_RM8: begin q_i <= q_i + 16'd1; push(S_RM5); wrb_go({3'd0, q_i}, val[7:0]); end
    // UMem: dynamic memory as is
    S_QU0: begin q_i <= 16'd0; q_fatal <= 1'b1; st <= S_QU1; end
    S_QU1: if (q_i == static_base) begin q_got[2] <= 1'b1; st <= S_RPAD; end else begin push(S_QU2); st <= S_QGET; end
    S_QU2: begin q_i <= q_i + 16'd1; push(S_QU1); wrb_go({3'd0, q_i}, val[7:0]); end
    // Stks: the dummy frame's words, then frames rebuilt in this core's layout (caller fp = the previous frame)
    S_QS0: begin
        q_fatal <= 1'b1; sp <= 12'd0; fp <= 12'd0; depth <= 8'd0;
        if (q_clen < 32'd8) st <= S_QERR; else begin q_k <= 3'd4; push(S_QS1); st <= S_QGN; end
    end
    S_QS1: if (q_acc != 32'd0) st <= S_QERR; else begin q_k <= 3'd2; push(S_QS2); st <= S_QGN; end
    S_QS2: if (q_acc[15:0] != 16'd0) st <= S_QERR; else begin q_k <= 3'd2; push(S_QS3); st <= S_QGN; end
    S_QS3: begin
        q_n <= q_acc[15:0]; q_clen <= q_clen - 32'd8;
        if (q_clen - 32'd8 < {15'd0, q_acc[15:0], 1'b0} || q_acc[15:0] > 16'd3900) st <= S_QERR; else st <= S_QS4;
    end
    S_QS4: if (q_n == 16'd0) st <= S_QS6; else begin q_k <= 3'd2; push(S_QS5); st <= S_QGN; end
    S_QS5: begin swr(sp, q_acc[15:0]); sp <= sp + 12'd1; q_n <= q_n - 16'd1; q_clen <= q_clen - 32'd2; st <= S_QS4; end
    S_QS6: begin
        if (q_clen == 32'd0) begin q_got[1] <= 1'b1; st <= S_RPAD; end
        else if (q_clen < 32'd8) st <= S_QERR;
        else begin q_k <= 3'd4; push(S_QS7); st <= S_QGN; end
    end
    S_QS7: begin q_pcf <= q_acc; push(S_QS8); st <= S_QGET; end
    S_QS8: begin q_var <= val[7:0]; push(S_QS9); st <= S_QGET; end
    S_QS9: begin q_x <= val[7:0]; q_k <= 3'd2; push(S_QS10); st <= S_QGN; end   // q_x = argument mask
    S_QS10: begin
        q_n <= q_acc[15:0] + {12'd0, q_pcf[3:0]};      // locals + evaluation stack words
        if (q_na == 4'd15 || q_clen - 32'd8 < {15'd0, q_acc[15:0] + {12'd0, q_pcf[3:0]}, 1'b0}
            || {5'd0, sp} + 17'd4 + {1'b0, q_acc[15:0]} + {13'd0, q_pcf[3:0]} > 17'd3900) st <= S_QERR;
        else begin swr(sp, q_pcf[23:8]); st <= S_QS11; end
    end
    S_QS11: begin swr(sp + 12'd1, {q_var, q_pcf[4], q_na[2:0], 1'b0, q_pcf[26:24]}); st <= S_QS12; end
    S_QS12: begin swr(sp + 12'd2, {4'd0, fp}); st <= S_QS13; end
    S_QS13: begin
        swr(sp + 12'd3, {12'd0, q_pcf[3:0]}); fp <= sp; sp <= sp + 12'd4; depth <= depth + 8'd1;
        q_clen <= q_clen - 32'd8; st <= S_QS4;
    end
    // all three chunks: pc from IFhd, then z_restore's tail (V3 split_window 0; restart_header; V4+ erase window 1
    // if the save came from another screen size), result 2 through the save's own store / branch byte
    S_RF: begin
        if (q_got != 3'b111) st <= S_QERR;
        else begin pc <= q_npc; q_rhdr <= 1'b1; if (v3) emit_cmd(CMD_SPLIT, 16'd0, 16'd0, S_QF1); else st <= S_QF1; end
    end
    S_QF1: begin push(S_QF2); rdb_go(19'h20); end
    S_QF2: begin q_or <= val[7:0]; push(S_QF3); rdb_go(19'h21); end
    S_QF3: begin q_oc <= val[7:0]; push(S_INIT7); rdb_orig_go(19'h01); end   // S_INIT7..S_HW, back at S_QF4
    S_QF4: begin
        q_rhdr <= 1'b0;
        if (!v3 && (q_or != cfg_rows || q_oc != cfg_cols)) emit_cmd(CMD_ERASE_WIN, 16'd1, 16'd0, S_QF5);
        else st <= S_QF5;
    end
    S_QF5: if (v3) branch(1'b1); else store(16'd2);

    // ------------------------------------------------ primitives
    S_RDB_W: if (m_ack) begin val <= {8'd0, m_rdata}; sub_ret; end
    S_RDW_W1: if (m_ack) begin val[15:8] <= m_rdata; m_addr <= m_addr + 19'd1; m_req <= 1'b1; st <= S_RDW_W2; end
    S_RDW_W2: if (m_ack) begin val[7:0] <= m_rdata; sub_ret; end
    S_WRB_W:  if (m_ack) sub_ret;
    S_WRW_W1: if (m_ack) begin m_addr <= m_addr + 19'd1; m_wdata <= w_val[7:0]; m_we <= 1'b1; m_req <= 1'b1; st <= S_WRW_W2; end
    S_WRW_W2: if (m_ack) sub_ret;
    S_SRD_1:  st <= S_SRD_2;
    S_SRD_2:  begin val <= s_q; sub_ret; end
    S_VREAD: begin
        if (v_num == 8'd0) begin
            if (!v_ind) sp <= sp - 12'd1;
            srd_go(sp - 12'd1);
        end
        else if (v_num < 8'd16) srd_go(local_addr);
        else rdw_go({3'd0, glob_addr});
    end
    S_VWRITE: begin
        if (v_num == 8'd0) begin
            if (v_ind) swr(sp - 12'd1, w_val);
            else begin swr(sp, w_val); sp <= sp + 12'd1; end
            sub_ret;
        end
        else if (v_num < 8'd16) begin swr(local_addr, w_val); sub_ret; end
        else wrw_go({3'd0, glob_addr}, w_val);
    end
    S_EMIT: begin
        if (out_valid & out_ready) begin out_valid <= 1'b0; if (version == 4'd6) st <= S_ESY; else sub_ret; end   // V6: in step
        else if (!out_valid && !out_cmd && out_char == 10'd0) sub_ret;   // ZSCII 0: legal, prints nothing (3.8.2.1)
        else if (!out_valid && !out_cmd && s3_lvl != 5'd0) begin   // stream 3: the character goes to the table only
            if (version == 4'd6) st <= S_M3C;
            else begin
                s3_cnt[s3_top] <= s3_cnt[s3_top] + 16'd1;
                wrb_go({3'd0, s3_tab[s3_top] + 16'd2 + s3_cnt[s3_top]}, out_char[7:0]);
            end
        end
        else if (!out_valid && !out_cmd && !scr_on) sub_ret;       // stream 1 off
        else out_valid <= 1'b1;
    end

    // V6: every item is waited for, so a newline interrupt finds the instruction that caused it stopped right here
    S_ESY: begin
        if (disp_irq && !in_int) st <= S_INT0;
        else if (!disp_busy) sub_ret;
    end
    S_INT0: begin                                      // Frotz direct_call: save, call (result discarded), run
        for (sh_k = 0; sh_k < 8; sh_k = sh_k + 1) sh_rs[sh_k] <= rs[sh_k]; sh_rsp <= rsp; sh_pc <= pc; sh_ipc <= ipc;
        sh_opbyte <= opbyte; sh_cls <= cls; sh_num <= num; sh_types <= types; sh_argc <= argc;
        for (sh_k = 0; sh_k < 8; sh_k = sh_k + 1) sh_ops[sh_k] <= ops[sh_k]; sh_tr_ext <= tr_ext; sh_val <= val; sh_res <= res;
        sh_w_val <= w_val; sh_v_num <= v_num; sh_v_ind <= v_ind; sh_cond <= cond; sh_then_br <= then_br;
        sh_b_on <= b_on; sh_b_off <= b_off; sh_b_hi <= b_hi; sh_c_sv <= c_sv; sh_c_disc <= c_disc;
        sh_c_raddr <= c_raddr; sh_c_n <= c_n; sh_c_i <= c_i; sh_c_nfp <= c_nfp; sh_t_pclo <= t_pclo;
        sh_t_flags <= t_flags; sh_z_addr <= z_addr; sh_zs_addr <= zs_addr; sh_z_word <= z_word;
        sh_zs_word <= zs_word; sh_z_idx <= z_idx; sh_zs_idx <= zs_idx; sh_z_shift <= z_shift; sh_z_esc <= z_esc;
        sh_z_abbr <= z_abbr; sh_z_eschi <= z_eschi; sh_z_inabbr <= z_inabbr; sh_z_frompc <= z_frompc;
        sh_pn_val <= pn_val; sh_pn_n <= pn_n; sh_pn_k <= pn_k; sh_pn_d <= pn_d; sh_pn_started <= pn_started;
        sh_o_print <= o_print; sh_str_i <= str_i; sh_pt_addr <= pt_addr; sh_pt_i <= pt_i; sh_pt_j <= pt_j;
        sh_rd_text <= rd_text; sh_rd_parse <= rd_parse; sh_rd_max <= rd_max; sh_rd_len <= rd_len;
        sh_rd_key <= rd_key; sh_rd_term <= rd_term; sh_tm_addr <= tm_addr; sh_hx <= hx; sh_hx_n <= hx_n;
        in_int <= 1'b1; int_depth <= depth;
        ops[0] <= int_snd ? snd_rtn : int_tmo ? tm_rtn : disp_irq_addr; argc <= 4'd1; c_disc <= 1'b1; rsp <= 3'd0; st <= S_CALL;
    end
    S_IRET: begin                                      // restored as it was at S_ESY; the display finishes its item
        for (sh_k = 0; sh_k < 8; sh_k = sh_k + 1) rs[sh_k] <= sh_rs[sh_k]; rsp <= sh_rsp; pc <= sh_pc; ipc <= sh_ipc;
        opbyte <= sh_opbyte; cls <= sh_cls; num <= sh_num; types <= sh_types; argc <= sh_argc;
        for (sh_k = 0; sh_k < 8; sh_k = sh_k + 1) ops[sh_k] <= sh_ops[sh_k]; tr_ext <= sh_tr_ext; val <= sh_val; res <= sh_res;
        w_val <= sh_w_val; v_num <= sh_v_num; v_ind <= sh_v_ind; cond <= sh_cond; then_br <= sh_then_br;
        b_on <= sh_b_on; b_off <= sh_b_off; b_hi <= sh_b_hi; c_sv <= sh_c_sv; c_disc <= sh_c_disc;
        c_raddr <= sh_c_raddr; c_n <= sh_c_n; c_i <= sh_c_i; c_nfp <= sh_c_nfp; t_pclo <= sh_t_pclo;
        t_flags <= sh_t_flags; z_addr <= sh_z_addr; zs_addr <= sh_zs_addr; z_word <= sh_z_word;
        zs_word <= sh_zs_word; z_idx <= sh_z_idx; zs_idx <= sh_zs_idx; z_shift <= sh_z_shift; z_esc <= sh_z_esc;
        z_abbr <= sh_z_abbr; z_eschi <= sh_z_eschi; z_inabbr <= sh_z_inabbr; z_frompc <= sh_z_frompc;
        pn_val <= sh_pn_val; pn_n <= sh_pn_n; pn_k <= sh_pn_k; pn_d <= sh_pn_d; pn_started <= sh_pn_started;
        o_print <= sh_o_print; str_i <= sh_str_i; pt_addr <= sh_pt_addr; pt_i <= sh_pt_i; pt_j <= sh_pt_j;
        rd_text <= sh_rd_text; rd_parse <= sh_rd_parse; rd_max <= sh_rd_max; rd_len <= sh_rd_len;
        rd_key <= sh_rd_key; rd_term <= sh_rd_term; tm_addr <= sh_tm_addr; hx <= sh_hx; hx_n <= sh_hx_n;
        in_int <= 1'b0;
        if (int_snd) begin int_snd <= 1'b0; st <= int_ret; end          // back to the input wait
        else if (int_tmo) begin int_tmo <= 1'b0; tmo_val <= res; st <= S_TMO1; end   // res: the routine's return value
        else begin out_char <= {2'd0, CMD_IRET}; out_cmd <= 1'b1; out_valid <= 1'b1; st <= S_IRET2; end
    end
    S_IRET2: if (out_valid & out_ready) begin out_valid <= 1'b0; st <= S_ESY; end

    // transcript (output stream 2): not available here; flags 2 bit 0 kept clear so the game can tell (user, 2026-10-21)
    S_OS0: begin                                       // output_stream, after the flush
            if (a == 16'd1)             begin scr_on <= 1'b1; st <= S_FETCH; end
            else if (a == 16'hFFFF)     begin scr_on <= 1'b0; st <= S_FETCH; end
            else if (a == 16'd3) begin
                if (s3_lvl == 5'd16) halt(8'd9);
                else if (version == 4'd6) begin m3_after <= 2'd3; st <= S_M3F0; end   // the word so far to the outer level
                else begin s3_tab[s3_lvl[3:0]] <= b; s3_cnt[s3_lvl[3:0]] <= 16'd0; s3_lvl <= s3_lvl + 5'd1; st <= S_FETCH; end
            end
            else if (a == 16'hFFFD) begin
                if (s3_lvl == 5'd0) st <= S_FETCH;
                else if (version == 4'd6) begin m3_after <= 2'd0; st <= S_M3F0; end
                else begin s3_lvl <= s3_lvl - 5'd1; push(S_FETCH); wrw_go({3'd0, s3_tab[s3_top]}, s3_cnt[s3_top]); end
            end
            else if (a == 16'd2 || a == 16'hFFFE) st <= S_OS2;   // transcript: not available (flags 2 bit 0 kept clear)
            else if (a == 16'd4 || a == 16'hFFFC || a == 16'd0) st <= S_FETCH;   // 4 = Frotz's command record: no file here
            else halt(8'd1);
    end
    S_OS2: begin push(S_OS3); rdb_go(19'h11); end
    S_OS3: begin push(S_FETCH); wrb_go(19'h11, {val[7:1], 1'b0}); end
    // storeb / storew that set flags 2 (byte 0x11) bit 0, a game's SCRIPT (V3): cleared again, no transcript
    S_SB2: begin
        if (((oid == 8'h62 && a + b == 16'h0011) || (oid == 8'h61 && a + {b[14:0], 1'b0} == 16'h0010)) && c[0]) begin
            push(S_FETCH); wrb_go(19'h11, {c[7:1], 1'b0});
        end
        else st <= S_FETCH;
    end

    // stop message: "[Frotz_MiSTer stopped: code N at PPPPP op OO(/EE)]" in window 0, past any memory stream
    S_HM0: begin                                       // stopped before the screen was set up (e.g. V6 at start): set it up
        s3_lvl <= 5'd0; scr_on <= 1'b1;
        if (!scr_init) begin scr_init <= 1'b1; emit_cmd(CMD_RESTART, 16'd5, 16'd0, S_HMA); end else st <= S_HMA;
    end
    S_HMA: emit_cmd(CMD_SETWIN, 16'd0, 16'd0, S_HM1);
    S_HM1: emit_str(STR_STOP, S_HM2);
    S_HM2: pnum({8'd0, halt_code}, S_HM3);
    S_HM3: emit_str(STR_AT, S_HM4);
    S_HM4: begin hx <= {1'b0, ipc}; hx_n <= 3'd5; push(S_HM5); st <= S_HX; end
    S_HM5: emit_str(STR_OP, S_HM6);
    S_HM6: begin hx <= {opbyte, 12'd0}; hx_n <= 3'd2; push(S_HM7); st <= S_HX; end
    S_HM7: if (opbyte == 8'hBE) emit(10'h2F, S_HM7B); else st <= S_HM8;
    S_HM7B: begin hx <= {tr_ext, 12'd0}; hx_n <= 3'd2; push(S_HM8); st <= S_HX; end
    S_HM8: emit_str(STR_END, S_HALT);
    S_HX: if (hx_n == 3'd0) sub_ret;
          else begin hx <= {hx[15:0], 4'd0}; hx_n <= hx_n - 3'd1; emit({2'd0, hx[19:16] < 4'd10 ? 8'h30 + {4'd0, hx[19:16]} : 8'h37 + {4'd0, hx[19:16]}}, S_HX); end
    S_HALT: halted <= 1'b1;
    default: halt(8'd255);
    endcase
end

endmodule
