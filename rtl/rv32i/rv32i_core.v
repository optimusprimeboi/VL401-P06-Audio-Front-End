// =============================================================================
// Module  : rv32i_core
// Project : P6 PDM-to-PCM Audio Front End
// Purpose : Minimal, Verifiable RISC-V RV32I Base Integer Core with APB Master
//           Executes Base 32-bit Integer ISA (RV32I).
//           Interfaces directly to memory and APB peripherals to compute
//           Audio RMS levels and Voice Activity Detection (VAD).
// =============================================================================

`timescale 1ns / 1ps

module rv32i_core #(
    parameter [31:0] RESET_ADDR = 32'h0000_0000
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // Instruction Memory Bus
    output reg  [31:0]          imem_addr,
    input  wire [31:0]          imem_rdata,

    // Data Memory / APB Master Interface
    output reg  [31:0]          dmem_addr,
    output reg  [31:0]          dmem_wdata,
    input  wire [31:0]          dmem_rdata,
    output reg                  dmem_we,
    output reg                  dmem_re,
    output reg  [3:0]           dmem_be,

    // Interrupt Input
    input  wire                 irq_in
);

// ── Program Counter ──────────────────────────────────────────────────────────
reg [31:0] pc;
reg [31:0] next_pc;

always @(posedge clk) begin
    if (!rst_n) begin
        pc        <= RESET_ADDR;
        imem_addr <= RESET_ADDR;
    end else begin
        pc        <= next_pc;
        imem_addr <= next_pc;
    end
end

// ── Instruction Decoding ─────────────────────────────────────────────────────
wire [31:0] instr = imem_rdata;

wire [6:0] opcode = instr[6:0];
wire [4:0] rd     = instr[11:7];
wire [2:0] funct3 = instr[14:12];
wire [4:0] rs1    = instr[19:15];
wire [4:0] rs2    = instr[24:20];
wire [6:0] funct7 = instr[31:25];

// Immediates
wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
wire [31:0] imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
wire [31:0] imm_u = {instr[31:12], 12'b0};
wire [31:0] imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

// ── Register File (32 x 32) ──────────────────────────────────────────────────
reg [31:0] reg_file [0:31];
reg        reg_we;
reg [31:0] reg_wdata;

wire [31:0] rf_rdata1 = (rs1 == 5'd0) ? 32'd0 : reg_file[rs1];
wire [31:0] rf_rdata2 = (rs2 == 5'd0) ? 32'd0 : reg_file[rs2];

integer ri;
always @(posedge clk) begin
    if (!rst_n) begin
        for (ri = 0; ri < 32; ri = ri + 1)
            reg_file[ri] <= 32'd0;
    end else if (reg_we && (rd != 5'd0)) begin
        reg_file[rd] <= reg_wdata;
    end
end

// ── ALU Execution ────────────────────────────────────────────────────────────
reg [31:0] alu_result;
reg        take_branch;

always @(*) begin
    // Defaults
    alu_result  = 32'd0;
    take_branch = 1'b0;
    next_pc     = pc + 32'd4;
    reg_we      = 1'b0;
    reg_wdata   = 32'd0;
    dmem_addr   = 32'd0;
    dmem_wdata  = 32'd0;
    dmem_we     = 1'b0;
    dmem_re     = 1'b0;
    dmem_be     = 4'b1111;

    case (opcode)
        7'b0110111: begin // LUI
            reg_we    = 1'b1;
            reg_wdata = imm_u;
        end

        7'b0010111: begin // AUIPC
            reg_we    = 1'b1;
            reg_wdata = pc + imm_u;
        end

        7'b1101111: begin // JAL
            reg_we    = 1'b1;
            reg_wdata = pc + 32'd4;
            next_pc   = pc + imm_j;
        end

        7'b1100111: begin // JALR
            reg_we    = 1'b1;
            reg_wdata = pc + 32'd4;
            next_pc   = (rf_rdata1 + imm_i) & ~32'd1;
        end

        7'b1100011: begin // Branches (BEQ, BNE, BLT, BGE, BLTU, BGEU)
            case (funct3)
                3'b000: take_branch = (rf_rdata1 == rf_rdata2);                     // BEQ
                3'b001: take_branch = (rf_rdata1 != rf_rdata2);                     // BNE
                3'b100: take_branch = ($signed(rf_rdata1) < $signed(rf_rdata2));   // BLT
                3'b101: take_branch = ($signed(rf_rdata1) >= $signed(rf_rdata2));  // BGE
                3'b110: take_branch = (rf_rdata1 < rf_rdata2);                      // BLTU
                3'b111: take_branch = (rf_rdata1 >= rf_rdata2);                     // BGEU
                default: take_branch = 1'b0;
            endcase
            if (take_branch) next_pc = pc + imm_b;
        end

        7'b0000011: begin // Loads (LB, LH, LW, LBU, LHU)
            dmem_addr = rf_rdata1 + imm_i;
            dmem_re   = 1'b1;
            reg_we    = 1'b1;
            case (funct3)
                3'b000: reg_wdata = {{24{dmem_rdata[7]}},  dmem_rdata[7:0]};   // LB
                3'b001: reg_wdata = {{16{dmem_rdata[15]}}, dmem_rdata[15:0]};  // LH
                3'b010: reg_wdata = dmem_rdata;                                 // LW
                3'b100: reg_wdata = {24'd0, dmem_rdata[7:0]};                  // LBU
                3'b101: reg_wdata = {16'd0, dmem_rdata[15:0]};                 // LHU
                default: reg_wdata = dmem_rdata;
            endcase
        end

        7'b0100011: begin // Stores (SB, SH, SW)
            dmem_addr  = rf_rdata1 + imm_s;
            dmem_wdata = rf_rdata2;
            dmem_we    = 1'b1;
            case (funct3)
                3'b000: dmem_be = 4'b0001; // SB
                3'b001: dmem_be = 4'b0011; // SH
                3'b010: dmem_be = 4'b1111; // SW
                default: dmem_be = 4'b1111;
            endcase
        end

        7'b0010011: begin // OP-IMM (ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI)
            reg_we = 1'b1;
            case (funct3)
                3'b000: reg_wdata = rf_rdata1 + imm_i;                                          // ADDI
                3'b010: reg_wdata = ($signed(rf_rdata1) < $signed(imm_i)) ? 32'd1 : 32'd0;     // SLTI
                3'b011: reg_wdata = (rf_rdata1 < imm_i) ? 32'd1 : 32'd0;                       // SLTIU
                3'b100: reg_wdata = rf_rdata1 ^ imm_i;                                          // XORI
                3'b110: reg_wdata = rf_rdata1 | imm_i;                                          // ORI
                3'b111: reg_wdata = rf_rdata1 & imm_i;                                          // ANDI
                3'b001: reg_wdata = rf_rdata1 << imm_i[4:0];                                   // SLLI
                3'b101: reg_wdata = (funct7[5]) ? 
                                    ($signed(rf_rdata1) >>> imm_i[4:0]) :                       // SRAI
                                    (rf_rdata1 >> imm_i[4:0]);                                  // SRLI
                default: reg_wdata = 32'd0;
            endcase
        end

        7'b0110011: begin // OP (ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND)
            reg_we = 1'b1;
            case (funct3)
                3'b000: reg_wdata = (funct7[5]) ? (rf_rdata1 - rf_rdata2) : (rf_rdata1 + rf_rdata2); // SUB / ADD
                3'b001: reg_wdata = rf_rdata1 << rf_rdata2[4:0];                                     // SLL
                3'b010: reg_wdata = ($signed(rf_rdata1) < $signed(rf_rdata2)) ? 32'd1 : 32'd0;      // SLT
                3'b011: reg_wdata = (rf_rdata1 < rf_rdata2) ? 32'd1 : 32'd0;                        // SLTU
                3'b100: reg_wdata = rf_rdata1 ^ rf_rdata2;                                           // XOR
                3'b101: reg_wdata = (funct7[5]) ? 
                                    ($signed(rf_rdata1) >>> rf_rdata2[4:0]) :                        // SRA
                                    (rf_rdata1 >> rf_rdata2[4:0]);                                   // SRL
                3'b110: reg_wdata = rf_rdata1 | rf_rdata2;                                           // OR
                3'b111: reg_wdata = rf_rdata1 & rf_rdata2;                                           // AND
                default: reg_wdata = 32'd0;
            endcase
        end

        default: ;
    endcase
end

// ── Formal Verification Assertions ───────────────────────────────────────────
`ifdef FORMAL
always @(posedge clk) begin
    if (rst_n) begin
        // Invariant: x0 must strictly stay 0
        assert(reg_file[0] == 32'b0);
    end
end
`endif

endmodule
