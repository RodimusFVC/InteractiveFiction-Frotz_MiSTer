// zm_latin1 - Frotz translate_from_zscii with the standard Unicode table: ZSCII 155..223 -> Latin-1 (the oe ligatures
// and everything above 223 -> '?'; 252..254 are Frotz's mouse codes, which print nothing = 0). Below 155 unchanged.
// no_xlat: Beyond Zork (Frotz story_id), which Frotz leaves untranslated. Shared by zm_disp (screen) and zm_cpu
// (transcript) so the two can't disagree.
module zm_latin1 (
    input  wire [9:0] z,
    input  wire       no_xlat,
    output reg  [7:0] l
);

always @* begin
    if (z > 10'd255) l = "?";
    else if (z < 10'd155 || no_xlat) l = z[7:0];
    else if (z >= 10'd252 && z <= 10'd254) l = 8'd0;
    else if (z > 10'd223 || z == 10'd220 || z == 10'd221) l = "?";
    else case (z[7:0])
        8'd155: l = 8'he4; 8'd156: l = 8'hf6; 8'd157: l = 8'hfc; 8'd158: l = 8'hc4; 8'd159: l = 8'hd6;
        8'd160: l = 8'hdc; 8'd161: l = 8'hdf; 8'd162: l = 8'hbb; 8'd163: l = 8'hab; 8'd164: l = 8'heb;
        8'd165: l = 8'hef; 8'd166: l = 8'hff; 8'd167: l = 8'hcb; 8'd168: l = 8'hcf; 8'd169: l = 8'he1;
        8'd170: l = 8'he9; 8'd171: l = 8'hed; 8'd172: l = 8'hf3; 8'd173: l = 8'hfa; 8'd174: l = 8'hfd;
        8'd175: l = 8'hc1; 8'd176: l = 8'hc9; 8'd177: l = 8'hcd; 8'd178: l = 8'hd3; 8'd179: l = 8'hda;
        8'd180: l = 8'hdd; 8'd181: l = 8'he0; 8'd182: l = 8'he8; 8'd183: l = 8'hec; 8'd184: l = 8'hf2;
        8'd185: l = 8'hf9; 8'd186: l = 8'hc0; 8'd187: l = 8'hc8; 8'd188: l = 8'hcc; 8'd189: l = 8'hd2;
        8'd190: l = 8'hd9; 8'd191: l = 8'he2; 8'd192: l = 8'hea; 8'd193: l = 8'hee; 8'd194: l = 8'hf4;
        8'd195: l = 8'hfb; 8'd196: l = 8'hc2; 8'd197: l = 8'hca; 8'd198: l = 8'hce; 8'd199: l = 8'hd4;
        8'd200: l = 8'hdb; 8'd201: l = 8'he5; 8'd202: l = 8'hc5; 8'd203: l = 8'hf8; 8'd204: l = 8'hd8;
        8'd205: l = 8'he3; 8'd206: l = 8'hf1; 8'd207: l = 8'hf5; 8'd208: l = 8'hc3; 8'd209: l = 8'hd1;
        8'd210: l = 8'hd5; 8'd211: l = 8'he6; 8'd212: l = 8'hc6; 8'd213: l = 8'he7; 8'd214: l = 8'hc7;
        8'd215: l = 8'hfe; 8'd216: l = 8'hf0; 8'd217: l = 8'hde; 8'd218: l = 8'hd0; 8'd219: l = 8'ha3;
        8'd222: l = 8'ha1; default: l = 8'hbf;                                         // 223
    endcase
end

endmodule
