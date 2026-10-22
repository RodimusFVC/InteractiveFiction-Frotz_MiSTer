// zm_kbd - MiSTer keyboard (hps_io ps2_key: [10] toggles per event, [9] = 1 while held, [8] = E0 prefix, [7:0] set 2
// scan code, US layout) -> ZSCII input keys through a 16-key type-ahead FIFO (key_valid / key_code / key_ack, as zm_cpu).
// ZSCII input codes (Standard 1.1 section 3.8): 8 delete, 13 return, 27 escape, 129-132 cursor up / down / left /
// right, 133-144 F1-F12, 145-154 keypad 0-9.
// Hotkeys (Frotz_MiSTer): Shift+F1..F10 types "save", Return and the slot digit (F1 = 1 .. F9 = 9, F10 = 0); Ctrl+F1..F10
// does the same with "restore". The game's own save / restore runs, so the file is ordinary Quetzal. Only taken at an
// empty command line (line_empty) with nothing typed ahead; ignored otherwise.
module zm_kbd (
    input  wire        clk,
    input  wire        reset,
    input  wire [10:0] ps2_key,
    input  wire        line_empty,                     // zm_cpu: waiting in line input with nothing typed yet

    output wire        key_valid,
    output wire  [9:0] key_code,
    input  wire        key_ack,
    output wire        empty
);

reg  [9:0] fifo [0:15];
reg  [3:0] wp = 4'd0, rp = 4'd0;
reg  [4:0] cnt = 5'd0;
assign key_valid = cnt != 5'd0;
assign key_code  = fifo[rp];
assign empty     = cnt == 5'd0;

reg        old_tog = 1'b0;
reg        lshift = 1'b0, rshift = 1'b0, lctrl = 1'b0, rctrl = 1'b0, caps = 1'b0;
reg  [3:0] mac_n = 4'd0;                               // hotkey macro: characters left to push
reg  [3:0] mac_i = 4'd0;
reg        mac_rest = 1'b0;
reg  [7:0] mac_digit = 8'd0;

wire       pressed = ps2_key[9];
wire       ext     = ps2_key[8];
wire [7:0] code    = ps2_key[7:0];
wire       shift   = lshift | rshift;
wire       ctrl    = lctrl | rctrl;

function [7:0] fkey(input [7:0] c);                    // F1..F12 -> 1..12, else 0
    case (c)
        8'h05: fkey = 8'd1;  8'h06: fkey = 8'd2;  8'h04: fkey = 8'd3;  8'h0C: fkey = 8'd4;  8'h03: fkey = 8'd5;
        8'h0B: fkey = 8'd6;  8'h83: fkey = 8'd7;  8'h0A: fkey = 8'd8;  8'h01: fkey = 8'd9;  8'h09: fkey = 8'd10;
        8'h78: fkey = 8'd11; 8'h07: fkey = 8'd12;
        default: fkey = 8'd0;
    endcase
endfunction

function [7:0] letter(input [7:0] c);                  // a..z, else 0
    case (c)
        8'h1C: letter = "a"; 8'h32: letter = "b"; 8'h21: letter = "c"; 8'h23: letter = "d"; 8'h24: letter = "e";
        8'h2B: letter = "f"; 8'h34: letter = "g"; 8'h33: letter = "h"; 8'h43: letter = "i"; 8'h3B: letter = "j";
        8'h42: letter = "k"; 8'h4B: letter = "l"; 8'h3A: letter = "m"; 8'h31: letter = "n"; 8'h44: letter = "o";
        8'h4D: letter = "p"; 8'h15: letter = "q"; 8'h2D: letter = "r"; 8'h1B: letter = "s"; 8'h2C: letter = "t";
        8'h3C: letter = "u"; 8'h2A: letter = "v"; 8'h1D: letter = "w"; 8'h22: letter = "x"; 8'h35: letter = "y";
        8'h1A: letter = "z";
        default: letter = 8'd0;
    endcase
endfunction

function [15:0] sym(input [7:0] c);                    // {unshifted, shifted} for the other printing keys, else 0
    case (c)
        8'h16: sym = {"1", "!"}; 8'h1E: sym = {"2", "@"}; 8'h26: sym = {"3", "#"}; 8'h25: sym = {"4", "$"};
        8'h2E: sym = {"5", "%"}; 8'h36: sym = {"6", "^"}; 8'h3D: sym = {"7", "&"}; 8'h3E: sym = {"8", "*"};
        8'h46: sym = {"9", "("}; 8'h45: sym = {"0", ")"}; 8'h4E: sym = {"-", "_"}; 8'h55: sym = {"=", "+"};
        8'h54: sym = {"[", "{"}; 8'h5B: sym = {"]", "}"}; 8'h5D: sym = {8'h5C, "|"}; 8'h4C: sym = {";", ":"};
        8'h52: sym = {8'h27, 8'h22}; 8'h0E: sym = {"`", "~"}; 8'h41: sym = {",", "<"}; 8'h49: sym = {".", ">"};
        8'h4A: sym = {"/", "?"}; 8'h29: sym = {" ", " "};
        default: sym = 16'd0;
    endcase
endfunction

function [7:0] keypad(input [7:0] c);                  // keypad digit -> 145..154, operators -> ASCII, else 0
    case (c)
        8'h70: keypad = 8'd145; 8'h69: keypad = 8'd146; 8'h72: keypad = 8'd147; 8'h7A: keypad = 8'd148;
        8'h6B: keypad = 8'd149; 8'h73: keypad = 8'd150; 8'h74: keypad = 8'd151; 8'h6C: keypad = 8'd152;
        8'h75: keypad = 8'd153; 8'h7D: keypad = 8'd154;
        8'h71: keypad = "."; 8'h79: keypad = "+"; 8'h7B: keypad = "-"; 8'h7C: keypad = "*";
        default: keypad = 8'd0;
    endcase
endfunction

function [7:0] macro_ch(input rest, input [3:0] i, input [7:0] digit);   // "save\r<d>" / "restore\r<d>"
    if (!rest)
        case (i) 4'd0: macro_ch = "s"; 4'd1: macro_ch = "a"; 4'd2: macro_ch = "v"; 4'd3: macro_ch = "e";
                 4'd4: macro_ch = 8'd13; default: macro_ch = digit; endcase
    else
        case (i) 4'd0: macro_ch = "r"; 4'd1: macro_ch = "e"; 4'd2: macro_ch = "s"; 4'd3: macro_ch = "t";
                 4'd4: macro_ch = "o"; 4'd5: macro_ch = "r"; 4'd6: macro_ch = "e"; 4'd7: macro_ch = 8'd13;
                 default: macro_ch = digit; endcase
endfunction

// the ZSCII code of a key press (0 = nothing to type)
wire [7:0] fk = fkey(code);
wire [7:0] lt = letter(code);
wire [15:0] sy = sym(code);
wire [7:0] kp = keypad(code);
wire [7:0] zs = ext ? (code == 8'h75 ? 8'd129 : code == 8'h72 ? 8'd130 : code == 8'h6B ? 8'd131 : code == 8'h74 ? 8'd132 :
                       code == 8'h71 ? 8'd8   : code == 8'h5A ? 8'd13  : code == 8'h4A ? "/" : 8'd0)
              : fk != 8'd0          ? 8'd132 + fk
              : lt != 8'd0          ? ((shift ^ caps) ? lt - 8'h20 : lt)
              : sy != 16'd0         ? (shift ? sy[7:0] : sy[15:8])
              : kp != 8'd0          ? kp
              : code == 8'h66       ? 8'd8
              : code == 8'h5A       ? 8'd13
              : code == 8'h76       ? 8'd27
              : 8'd0;

reg       push = 1'b0;
reg [9:0] push_v = 10'd0;

always @(posedge clk) begin
    push <= 1'b0;
    old_tog <= ps2_key[10];

    if (reset) begin
        wp <= 4'd0; rp <= 4'd0; cnt <= 5'd0; mac_n <= 4'd0;
        lshift <= 1'b0; rshift <= 1'b0; lctrl <= 1'b0; rctrl <= 1'b0;
    end
    else begin
        if (mac_n != 4'd0) begin                        // hotkey macro: one character per clock
            push <= 1'b1; push_v <= {2'd0, macro_ch(mac_rest, mac_i, mac_digit)};
            mac_i <= mac_i + 4'd1; mac_n <= mac_n - 4'd1;
        end
        else if (old_tog != ps2_key[10]) begin
            if (!ext && code == 8'h12) lshift <= pressed;
            else if (!ext && code == 8'h59) rshift <= pressed;
            else if (code == 8'h14) begin if (ext) rctrl <= pressed; else lctrl <= pressed; end
            else if (pressed && !ext && code == 8'h58) caps <= ~caps;
            else if (pressed && !ext && fk != 8'd0 && fk <= 8'd10 && (shift || ctrl)) begin
                if (line_empty && cnt == 5'd0) begin
                    mac_rest <= ctrl; mac_i <= 4'd0; mac_n <= ctrl ? 4'd9 : 4'd6;
                    mac_digit <= fk == 8'd10 ? "0" : 8'h30 + fk;
                end
            end
            else if (pressed && zs != 8'd0) begin push <= 1'b1; push_v <= {2'd0, zs}; end
        end

        if (push && cnt != 5'd16) begin fifo[wp] <= push_v; wp <= wp + 4'd1; end
        if (key_ack && cnt != 5'd0) rp <= rp + 4'd1;
        cnt <= cnt + {4'd0, push && cnt != 5'd16} - {4'd0, key_ack && cnt != 5'd0};
    end
end

endmodule
