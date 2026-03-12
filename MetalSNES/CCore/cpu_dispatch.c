#include "cpu_dispatch.h"
#include <string.h>
#include <stdio.h>

// ============================================================
// 65C816 CPU Emulator — dispatch table implementation
// ============================================================

typedef void (*OpcodeHandler)(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx);

static OpcodeHandler dispatch_table[256];

// --- Helpers ---

static inline uint32_t full_addr(uint8_t bank, uint16_t offset) {
    return ((uint32_t)bank << 16) | offset;
}

static inline uint8_t fetch8(CPURegisters *r, BusReadFunc rd, void *ctx) {
    uint8_t val = rd(ctx, full_addr(r->PBR, r->PC));
    r->PC++;
    return val;
}

static inline uint16_t fetch16(CPURegisters *r, BusReadFunc rd, void *ctx) {
    uint8_t lo = fetch8(r, rd, ctx);
    uint8_t hi = fetch8(r, rd, ctx);
    return (uint16_t)hi << 8 | lo;
}

static inline uint32_t fetch24(CPURegisters *r, BusReadFunc rd, void *ctx) {
    uint8_t lo = fetch8(r, rd, ctx);
    uint8_t hi = fetch8(r, rd, ctx);
    uint8_t bank = fetch8(r, rd, ctx);
    return ((uint32_t)bank << 16) | ((uint32_t)hi << 8) | lo;
}

static inline void push8(CPURegisters *r, BusWriteFunc wr, void *ctx, uint8_t val) {
    wr(ctx, full_addr(0, r->S), val);
    if (r->emulationMode) {
        r->S = 0x0100 | ((r->S - 1) & 0xFF);
    } else {
        r->S--;
    }
}

static inline void push16(CPURegisters *r, BusWriteFunc wr, void *ctx, uint16_t val) {
    push8(r, wr, ctx, val >> 8);
    push8(r, wr, ctx, val & 0xFF);
}

static inline uint8_t pull8(CPURegisters *r, BusReadFunc rd, void *ctx) {
    if (r->emulationMode) {
        r->S = 0x0100 | ((r->S + 1) & 0xFF);
    } else {
        r->S++;
    }
    return rd(ctx, full_addr(0, r->S));
}

static inline uint16_t pull16(CPURegisters *r, BusReadFunc rd, void *ctx) {
    uint8_t lo = pull8(r, rd, ctx);
    uint8_t hi = pull8(r, rd, ctx);
    return (uint16_t)hi << 8 | lo;
}

static inline bool flag_m(CPURegisters *r) {
    return r->emulationMode || (r->P & FLAG_M);
}

static inline bool flag_x(CPURegisters *r) {
    return r->emulationMode || (r->P & FLAG_X);
}

static inline void set_nz8(CPURegisters *r, uint8_t val) {
    r->P &= ~(FLAG_N | FLAG_Z);
    if (val == 0) r->P |= FLAG_Z;
    if (val & 0x80) r->P |= FLAG_N;
}

static inline void set_nz16(CPURegisters *r, uint16_t val) {
    r->P &= ~(FLAG_N | FLAG_Z);
    if (val == 0) r->P |= FLAG_Z;
    if (val & 0x8000) r->P |= FLAG_N;
}

// --- Addressing modes ---

static inline uint32_t addr_dp(CPURegisters *r, BusReadFunc rd, void *ctx) {
    uint8_t off = fetch8(r, rd, ctx);
    return (r->D + off) & 0xFFFF;
}

static inline uint32_t addr_dp_x(CPURegisters *r, BusReadFunc rd, void *ctx) {
    uint8_t off = fetch8(r, rd, ctx);
    if (r->emulationMode && (r->D & 0xFF) == 0) {
        return (r->D & 0xFF00) | ((off + (uint8_t)r->X) & 0xFF);
    }
    return (r->D + off + r->X) & 0xFFFF;
}

static inline uint32_t addr_dp_y(CPURegisters *r, BusReadFunc rd, void *ctx) {
    uint8_t off = fetch8(r, rd, ctx);
    if (r->emulationMode && (r->D & 0xFF) == 0) {
        return (r->D & 0xFF00) | ((off + (uint8_t)r->Y) & 0xFF);
    }
    return (r->D + off + r->Y) & 0xFFFF;
}

static inline uint32_t addr_abs(CPURegisters *r, BusReadFunc rd, void *ctx) {
    uint16_t a = fetch16(r, rd, ctx);
    return full_addr(r->DBR, a);
}

static inline uint32_t addr_abs_x(CPURegisters *r, BusReadFunc rd, void *ctx) {
    uint16_t a = fetch16(r, rd, ctx);
    return full_addr(r->DBR, a + r->X);
}

static inline uint32_t addr_abs_y(CPURegisters *r, BusReadFunc rd, void *ctx) {
    uint16_t a = fetch16(r, rd, ctx);
    return full_addr(r->DBR, a + r->Y);
}

static inline uint32_t addr_long(CPURegisters *r, BusReadFunc rd, void *ctx) {
    return fetch24(r, rd, ctx);
}

static inline uint32_t addr_long_x(CPURegisters *r, BusReadFunc rd, void *ctx) {
    uint32_t a = fetch24(r, rd, ctx);
    return a + r->X;
}

static inline uint32_t addr_dp_ind(CPURegisters *r, BusReadFunc rd, void *ctx) {
    uint32_t dp = addr_dp(r, rd, ctx);
    uint8_t lo = rd(ctx, dp);
    uint8_t hi = rd(ctx, (dp + 1) & 0xFFFF);
    return full_addr(r->DBR, (uint16_t)hi << 8 | lo);
}

static inline uint32_t addr_dp_ind_long(CPURegisters *r, BusReadFunc rd, void *ctx) {
    uint32_t dp = addr_dp(r, rd, ctx);
    uint8_t lo = rd(ctx, dp);
    uint8_t hi = rd(ctx, (dp + 1) & 0xFFFF);
    uint8_t bank = rd(ctx, (dp + 2) & 0xFFFF);
    return full_addr(bank, (uint16_t)hi << 8 | lo);
}

static inline uint32_t addr_dp_x_ind(CPURegisters *r, BusReadFunc rd, void *ctx) {
    uint32_t dp = addr_dp_x(r, rd, ctx);
    uint8_t lo = rd(ctx, dp);
    uint8_t hi = rd(ctx, (dp + 1) & 0xFFFF);
    return full_addr(r->DBR, (uint16_t)hi << 8 | lo);
}

static inline uint32_t addr_dp_ind_y(CPURegisters *r, BusReadFunc rd, void *ctx) {
    uint32_t dp = addr_dp(r, rd, ctx);
    uint8_t lo = rd(ctx, dp);
    uint8_t hi = rd(ctx, (dp + 1) & 0xFFFF);
    uint16_t base = (uint16_t)hi << 8 | lo;
    return full_addr(r->DBR, base + r->Y);
}

static inline uint32_t addr_dp_ind_long_y(CPURegisters *r, BusReadFunc rd, void *ctx) {
    uint32_t dp = addr_dp(r, rd, ctx);
    uint8_t lo = rd(ctx, dp);
    uint8_t hi = rd(ctx, (dp + 1) & 0xFFFF);
    uint8_t bank = rd(ctx, (dp + 2) & 0xFFFF);
    uint32_t base = full_addr(bank, (uint16_t)hi << 8 | lo);
    return base + r->Y;
}

static inline uint32_t addr_sr(CPURegisters *r, BusReadFunc rd, void *ctx) {
    uint8_t off = fetch8(r, rd, ctx);
    return (r->S + off) & 0xFFFF;
}

static inline uint32_t addr_sr_ind_y(CPURegisters *r, BusReadFunc rd, void *ctx) {
    uint32_t sp = addr_sr(r, rd, ctx);
    uint8_t lo = rd(ctx, sp);
    uint8_t hi = rd(ctx, (sp + 1) & 0xFFFF);
    return full_addr(r->DBR, ((uint16_t)hi << 8 | lo) + r->Y);
}

// --- Read helpers ---

static inline uint8_t read8(BusReadFunc rd, void *ctx, uint32_t addr) {
    return rd(ctx, addr);
}

static inline uint16_t read16(BusReadFunc rd, void *ctx, uint32_t addr) {
    uint8_t lo = rd(ctx, addr);
    uint8_t hi = rd(ctx, addr + 1);
    return (uint16_t)hi << 8 | lo;
}

// ============================================================
// Opcode implementations
// ============================================================

// --- ADC ---

static inline void do_adc8(CPURegisters *r, uint8_t val) {
    uint8_t a = r->A & 0xFF;
    int result;
    if (r->P & FLAG_D) {
        result = (a & 0x0F) + (val & 0x0F) + ((r->P & FLAG_C) ? 1 : 0);
        if (result > 0x09) result += 0x06;
        if (result > 0x0F) {
            r->P |= FLAG_C;
        } else {
            r->P &= ~FLAG_C;
        }
        result = (a & 0xF0) + (val & 0xF0) + ((r->P & FLAG_C) ? 0x10 : 0) + (result & 0x0F);
    } else {
        result = a + val + ((r->P & FLAG_C) ? 1 : 0);
    }

    r->P &= ~FLAG_V;
    if (~(a ^ val) & (a ^ result) & 0x80) r->P |= FLAG_V;
    if ((r->P & FLAG_D) && result > 0x9F) result += 0x60;
    if (result > 0xFF) {
        r->P |= FLAG_C;
    } else {
        r->P &= ~FLAG_C;
    }

    r->A = (r->A & 0xFF00) | (result & 0xFF);
    set_nz8(r, result & 0xFF);
}

static inline void do_adc16(CPURegisters *r, uint16_t val) {
    uint16_t a = r->A;
    int result;
    if (r->P & FLAG_D) {
        result = (a & 0x000F) + (val & 0x000F) + ((r->P & FLAG_C) ? 1 : 0);
        if (result > 0x0009) result += 0x0006;
        if (result > 0x000F) {
            r->P |= FLAG_C;
        } else {
            r->P &= ~FLAG_C;
        }

        result = (a & 0x00F0) + (val & 0x00F0) + ((r->P & FLAG_C) ? 0x0010 : 0) + (result & 0x000F);
        if (result > 0x009F) result += 0x0060;
        if (result > 0x00FF) {
            r->P |= FLAG_C;
        } else {
            r->P &= ~FLAG_C;
        }

        result = (a & 0x0F00) + (val & 0x0F00) + ((r->P & FLAG_C) ? 0x0100 : 0) + (result & 0x00FF);
        if (result > 0x09FF) result += 0x0600;
        if (result > 0x0FFF) {
            r->P |= FLAG_C;
        } else {
            r->P &= ~FLAG_C;
        }

        result = (a & 0xF000) + (val & 0xF000) + ((r->P & FLAG_C) ? 0x1000 : 0) + (result & 0x0FFF);
    } else {
        result = a + val + ((r->P & FLAG_C) ? 1 : 0);
    }

    r->P &= ~FLAG_V;
    if (~(a ^ val) & (a ^ result) & 0x8000) r->P |= FLAG_V;
    if ((r->P & FLAG_D) && result > 0x9FFF) result += 0x6000;
    if (result > 0xFFFF) {
        r->P |= FLAG_C;
    } else {
        r->P &= ~FLAG_C;
    }

    r->A = result & 0xFFFF;
    set_nz16(r, r->A);
}

// --- SBC ---

static inline void do_sbc8(CPURegisters *r, uint8_t val) {
    uint8_t a = r->A & 0xFF;
    uint8_t data = (uint8_t)~val;
    int result;
    if (r->P & FLAG_D) {
        result = (a & 0x0F) + (data & 0x0F) + ((r->P & FLAG_C) ? 1 : 0);
        if (result <= 0x0F) result -= 0x06;
        if (result > 0x0F) {
            r->P |= FLAG_C;
        } else {
            r->P &= ~FLAG_C;
        }
        result = (a & 0xF0) + (data & 0xF0) + ((r->P & FLAG_C) ? 0x10 : 0) + (result & 0x0F);
    } else {
        result = a + data + ((r->P & FLAG_C) ? 1 : 0);
    }

    r->P &= ~FLAG_V;
    if (~(a ^ data) & (a ^ result) & 0x80) r->P |= FLAG_V;
    if ((r->P & FLAG_D) && result <= 0xFF) result -= 0x60;
    if (result > 0xFF) {
        r->P |= FLAG_C;
    } else {
        r->P &= ~FLAG_C;
    }

    r->A = (r->A & 0xFF00) | (result & 0xFF);
    set_nz8(r, result & 0xFF);
}

static inline void do_sbc16(CPURegisters *r, uint16_t val) {
    uint16_t a = r->A;
    uint16_t data = (uint16_t)~val;
    int result;
    if (r->P & FLAG_D) {
        result = (a & 0x000F) + (data & 0x000F) + ((r->P & FLAG_C) ? 1 : 0);
        if (result <= 0x000F) result -= 0x0006;
        if (result > 0x000F) {
            r->P |= FLAG_C;
        } else {
            r->P &= ~FLAG_C;
        }

        result = (a & 0x00F0) + (data & 0x00F0) + ((r->P & FLAG_C) ? 0x0010 : 0) + (result & 0x000F);
        if (result <= 0x00FF) result -= 0x0060;
        if (result > 0x00FF) {
            r->P |= FLAG_C;
        } else {
            r->P &= ~FLAG_C;
        }

        result = (a & 0x0F00) + (data & 0x0F00) + ((r->P & FLAG_C) ? 0x0100 : 0) + (result & 0x00FF);
        if (result <= 0x0FFF) result -= 0x0600;
        if (result > 0x0FFF) {
            r->P |= FLAG_C;
        } else {
            r->P &= ~FLAG_C;
        }

        result = (a & 0xF000) + (data & 0xF000) + ((r->P & FLAG_C) ? 0x1000 : 0) + (result & 0x0FFF);
    } else {
        result = a + data + ((r->P & FLAG_C) ? 1 : 0);
    }

    r->P &= ~FLAG_V;
    if (~(a ^ data) & (a ^ result) & 0x8000) r->P |= FLAG_V;
    if ((r->P & FLAG_D) && result <= 0xFFFF) result -= 0x6000;
    if (result > 0xFFFF) {
        r->P |= FLAG_C;
    } else {
        r->P &= ~FLAG_C;
    }

    r->A = result & 0xFFFF;
    set_nz16(r, r->A);
}

// --- CMP helpers ---

static inline void do_cmp8(CPURegisters *r, uint8_t a, uint8_t val) {
    uint16_t result = (uint16_t)a - val;
    r->P &= ~(FLAG_C | FLAG_N | FLAG_Z);
    if (a >= val) r->P |= FLAG_C;
    if ((result & 0xFF) == 0) r->P |= FLAG_Z;
    if (result & 0x80) r->P |= FLAG_N;
}

static inline void do_cmp16(CPURegisters *r, uint16_t a, uint16_t val) {
    uint32_t result = (uint32_t)a - val;
    r->P &= ~(FLAG_C | FLAG_N | FLAG_Z);
    if (a >= val) r->P |= FLAG_C;
    if ((result & 0xFFFF) == 0) r->P |= FLAG_Z;
    if (result & 0x8000) r->P |= FLAG_N;
}

// ============================================================
// Macros for generating opcode handlers
// ============================================================

#define OP_LDA(name, addr_fn) \
static void name(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) { \
    uint32_t addr = addr_fn(r, rd, ctx); \
    if (flag_m(r)) { \
        uint8_t val = read8(rd, ctx, addr); \
        r->A = (r->A & 0xFF00) | val; \
        set_nz8(r, val); \
        r->cycles = 4; \
    } else { \
        uint16_t val = read16(rd, ctx, addr); \
        r->A = val; \
        set_nz16(r, val); \
        r->cycles = 5; \
    } \
}

#define OP_LDX(name, addr_fn) \
static void name(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) { \
    uint32_t addr = addr_fn(r, rd, ctx); \
    if (flag_x(r)) { \
        uint8_t val = read8(rd, ctx, addr); \
        r->X = val; \
        set_nz8(r, val); \
        r->cycles = 4; \
    } else { \
        uint16_t val = read16(rd, ctx, addr); \
        r->X = val; \
        set_nz16(r, val); \
        r->cycles = 5; \
    } \
}

#define OP_LDY(name, addr_fn) \
static void name(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) { \
    uint32_t addr = addr_fn(r, rd, ctx); \
    if (flag_x(r)) { \
        uint8_t val = read8(rd, ctx, addr); \
        r->Y = val; \
        set_nz8(r, val); \
        r->cycles = 4; \
    } else { \
        uint16_t val = read16(rd, ctx, addr); \
        r->Y = val; \
        set_nz16(r, val); \
        r->cycles = 5; \
    } \
}

#define OP_STA(name, addr_fn) \
static void name(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) { \
    uint32_t addr = addr_fn(r, rd, ctx); \
    if (flag_m(r)) { \
        wr(ctx, addr, r->A & 0xFF); \
        r->cycles = 4; \
    } else { \
        wr(ctx, addr, r->A & 0xFF); \
        wr(ctx, addr + 1, r->A >> 8); \
        r->cycles = 5; \
    } \
}

#define OP_STX(name, addr_fn) \
static void name(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) { \
    uint32_t addr = addr_fn(r, rd, ctx); \
    if (flag_x(r)) { \
        wr(ctx, addr, r->X & 0xFF); \
        r->cycles = 4; \
    } else { \
        wr(ctx, addr, r->X & 0xFF); \
        wr(ctx, addr + 1, r->X >> 8); \
        r->cycles = 5; \
    } \
}

#define OP_STY(name, addr_fn) \
static void name(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) { \
    uint32_t addr = addr_fn(r, rd, ctx); \
    if (flag_x(r)) { \
        wr(ctx, addr, r->Y & 0xFF); \
        r->cycles = 4; \
    } else { \
        wr(ctx, addr, r->Y & 0xFF); \
        wr(ctx, addr + 1, r->Y >> 8); \
        r->cycles = 5; \
    } \
}

#define OP_STZ(name, addr_fn) \
static void name(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) { \
    uint32_t addr = addr_fn(r, rd, ctx); \
    if (flag_m(r)) { \
        wr(ctx, addr, 0); \
        r->cycles = 4; \
    } else { \
        wr(ctx, addr, 0); \
        wr(ctx, addr + 1, 0); \
        r->cycles = 5; \
    } \
}

#define OP_ADC(name, addr_fn) \
static void name(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) { \
    uint32_t addr = addr_fn(r, rd, ctx); \
    if (flag_m(r)) { \
        do_adc8(r, read8(rd, ctx, addr)); \
        r->cycles = 4; \
    } else { \
        do_adc16(r, read16(rd, ctx, addr)); \
        r->cycles = 5; \
    } \
}

#define OP_SBC(name, addr_fn) \
static void name(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) { \
    uint32_t addr = addr_fn(r, rd, ctx); \
    if (flag_m(r)) { \
        do_sbc8(r, read8(rd, ctx, addr)); \
        r->cycles = 4; \
    } else { \
        do_sbc16(r, read16(rd, ctx, addr)); \
        r->cycles = 5; \
    } \
}

#define OP_AND(name, addr_fn) \
static void name(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) { \
    uint32_t addr = addr_fn(r, rd, ctx); \
    if (flag_m(r)) { \
        uint8_t val = read8(rd, ctx, addr); \
        r->A = (r->A & 0xFF00) | ((r->A & val) & 0xFF); \
        set_nz8(r, r->A & 0xFF); \
        r->cycles = 4; \
    } else { \
        uint16_t val = read16(rd, ctx, addr); \
        r->A &= val; \
        set_nz16(r, r->A); \
        r->cycles = 5; \
    } \
}

#define OP_ORA(name, addr_fn) \
static void name(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) { \
    uint32_t addr = addr_fn(r, rd, ctx); \
    if (flag_m(r)) { \
        uint8_t val = read8(rd, ctx, addr); \
        r->A = (r->A & 0xFF00) | ((r->A | val) & 0xFF); \
        set_nz8(r, r->A & 0xFF); \
        r->cycles = 4; \
    } else { \
        uint16_t val = read16(rd, ctx, addr); \
        r->A |= val; \
        set_nz16(r, r->A); \
        r->cycles = 5; \
    } \
}

#define OP_EOR(name, addr_fn) \
static void name(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) { \
    uint32_t addr = addr_fn(r, rd, ctx); \
    if (flag_m(r)) { \
        uint8_t val = read8(rd, ctx, addr); \
        r->A = (r->A & 0xFF00) | ((r->A ^ val) & 0xFF); \
        set_nz8(r, r->A & 0xFF); \
        r->cycles = 4; \
    } else { \
        uint16_t val = read16(rd, ctx, addr); \
        r->A ^= val; \
        set_nz16(r, r->A); \
        r->cycles = 5; \
    } \
}

#define OP_CMP(name, addr_fn) \
static void name(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) { \
    uint32_t addr = addr_fn(r, rd, ctx); \
    if (flag_m(r)) { \
        do_cmp8(r, r->A & 0xFF, read8(rd, ctx, addr)); \
        r->cycles = 4; \
    } else { \
        do_cmp16(r, r->A, read16(rd, ctx, addr)); \
        r->cycles = 5; \
    } \
}

#define OP_CPX(name, addr_fn) \
static void name(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) { \
    uint32_t addr = addr_fn(r, rd, ctx); \
    if (flag_x(r)) { \
        do_cmp8(r, r->X & 0xFF, read8(rd, ctx, addr)); \
        r->cycles = 4; \
    } else { \
        do_cmp16(r, r->X, read16(rd, ctx, addr)); \
        r->cycles = 5; \
    } \
}

#define OP_CPY(name, addr_fn) \
static void name(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) { \
    uint32_t addr = addr_fn(r, rd, ctx); \
    if (flag_x(r)) { \
        do_cmp8(r, r->Y & 0xFF, read8(rd, ctx, addr)); \
        r->cycles = 4; \
    } else { \
        do_cmp16(r, r->Y, read16(rd, ctx, addr)); \
        r->cycles = 5; \
    } \
}

#define OP_BIT(name, addr_fn) \
static void name(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) { \
    uint32_t addr = addr_fn(r, rd, ctx); \
    if (flag_m(r)) { \
        uint8_t val = read8(rd, ctx, addr); \
        r->P &= ~(FLAG_N | FLAG_V | FLAG_Z); \
        if ((r->A & val & 0xFF) == 0) r->P |= FLAG_Z; \
        r->P |= (val & (FLAG_N | FLAG_V)); \
        r->cycles = 4; \
    } else { \
        uint16_t val = read16(rd, ctx, addr); \
        r->P &= ~(FLAG_N | FLAG_V | FLAG_Z); \
        if ((r->A & val) == 0) r->P |= FLAG_Z; \
        r->P |= ((val >> 8) & (FLAG_N | FLAG_V)); \
        r->cycles = 5; \
    } \
}

#define OP_INC_MEM(name, addr_fn) \
static void name(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) { \
    uint32_t addr = addr_fn(r, rd, ctx); \
    if (flag_m(r)) { \
        uint8_t val = read8(rd, ctx, addr) + 1; \
        wr(ctx, addr, val); \
        set_nz8(r, val); \
        r->cycles = 6; \
    } else { \
        uint16_t val = read16(rd, ctx, addr) + 1; \
        wr(ctx, addr, val & 0xFF); \
        wr(ctx, addr + 1, val >> 8); \
        set_nz16(r, val); \
        r->cycles = 8; \
    } \
}

#define OP_DEC_MEM(name, addr_fn) \
static void name(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) { \
    uint32_t addr = addr_fn(r, rd, ctx); \
    if (flag_m(r)) { \
        uint8_t val = read8(rd, ctx, addr) - 1; \
        wr(ctx, addr, val); \
        set_nz8(r, val); \
        r->cycles = 6; \
    } else { \
        uint16_t val = read16(rd, ctx, addr) - 1; \
        wr(ctx, addr, val & 0xFF); \
        wr(ctx, addr + 1, val >> 8); \
        set_nz16(r, val); \
        r->cycles = 8; \
    } \
}

#define OP_ASL_MEM(name, addr_fn) \
static void name(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) { \
    uint32_t addr = addr_fn(r, rd, ctx); \
    if (flag_m(r)) { \
        uint8_t val = read8(rd, ctx, addr); \
        r->P &= ~FLAG_C; \
        if (val & 0x80) r->P |= FLAG_C; \
        val <<= 1; \
        wr(ctx, addr, val); \
        set_nz8(r, val); \
        r->cycles = 6; \
    } else { \
        uint16_t val = read16(rd, ctx, addr); \
        r->P &= ~FLAG_C; \
        if (val & 0x8000) r->P |= FLAG_C; \
        val <<= 1; \
        wr(ctx, addr, val & 0xFF); \
        wr(ctx, addr + 1, val >> 8); \
        set_nz16(r, val); \
        r->cycles = 8; \
    } \
}

#define OP_LSR_MEM(name, addr_fn) \
static void name(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) { \
    uint32_t addr = addr_fn(r, rd, ctx); \
    if (flag_m(r)) { \
        uint8_t val = read8(rd, ctx, addr); \
        r->P &= ~FLAG_C; \
        if (val & 0x01) r->P |= FLAG_C; \
        val >>= 1; \
        wr(ctx, addr, val); \
        set_nz8(r, val); \
        r->cycles = 6; \
    } else { \
        uint16_t val = read16(rd, ctx, addr); \
        r->P &= ~FLAG_C; \
        if (val & 0x0001) r->P |= FLAG_C; \
        val >>= 1; \
        wr(ctx, addr, val & 0xFF); \
        wr(ctx, addr + 1, val >> 8); \
        set_nz16(r, val); \
        r->cycles = 8; \
    } \
}

#define OP_ROL_MEM(name, addr_fn) \
static void name(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) { \
    uint32_t addr = addr_fn(r, rd, ctx); \
    if (flag_m(r)) { \
        uint8_t val = read8(rd, ctx, addr); \
        uint8_t c = (r->P & FLAG_C) ? 1 : 0; \
        r->P &= ~FLAG_C; \
        if (val & 0x80) r->P |= FLAG_C; \
        val = (val << 1) | c; \
        wr(ctx, addr, val); \
        set_nz8(r, val); \
        r->cycles = 6; \
    } else { \
        uint16_t val = read16(rd, ctx, addr); \
        uint16_t c = (r->P & FLAG_C) ? 1 : 0; \
        r->P &= ~FLAG_C; \
        if (val & 0x8000) r->P |= FLAG_C; \
        val = (val << 1) | c; \
        wr(ctx, addr, val & 0xFF); \
        wr(ctx, addr + 1, val >> 8); \
        set_nz16(r, val); \
        r->cycles = 8; \
    } \
}

#define OP_ROR_MEM(name, addr_fn) \
static void name(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) { \
    uint32_t addr = addr_fn(r, rd, ctx); \
    if (flag_m(r)) { \
        uint8_t val = read8(rd, ctx, addr); \
        uint8_t c = (r->P & FLAG_C) ? 0x80 : 0; \
        r->P &= ~FLAG_C; \
        if (val & 0x01) r->P |= FLAG_C; \
        val = (val >> 1) | c; \
        wr(ctx, addr, val); \
        set_nz8(r, val); \
        r->cycles = 6; \
    } else { \
        uint16_t val = read16(rd, ctx, addr); \
        uint16_t c = (r->P & FLAG_C) ? 0x8000 : 0; \
        r->P &= ~FLAG_C; \
        if (val & 0x0001) r->P |= FLAG_C; \
        val = (val >> 1) | c; \
        wr(ctx, addr, val & 0xFF); \
        wr(ctx, addr + 1, val >> 8); \
        set_nz16(r, val); \
        r->cycles = 8; \
    } \
}

// Generate all addressing mode variants

// LDA
OP_LDA(op_lda_dp, addr_dp)
OP_LDA(op_lda_dp_x, addr_dp_x)
OP_LDA(op_lda_abs, addr_abs)
OP_LDA(op_lda_abs_x, addr_abs_x)
OP_LDA(op_lda_abs_y, addr_abs_y)
OP_LDA(op_lda_long, addr_long)
OP_LDA(op_lda_long_x, addr_long_x)
OP_LDA(op_lda_dp_x_ind, addr_dp_x_ind)
OP_LDA(op_lda_dp_ind, addr_dp_ind)
OP_LDA(op_lda_dp_ind_y, addr_dp_ind_y)
OP_LDA(op_lda_dp_ind_long, addr_dp_ind_long)
OP_LDA(op_lda_dp_ind_long_y, addr_dp_ind_long_y)
OP_LDA(op_lda_sr, addr_sr)
OP_LDA(op_lda_sr_ind_y, addr_sr_ind_y)

// LDX
OP_LDX(op_ldx_dp, addr_dp)
OP_LDX(op_ldx_dp_y, addr_dp_y)
OP_LDX(op_ldx_abs, addr_abs)
OP_LDX(op_ldx_abs_y, addr_abs_y)

// LDY
OP_LDY(op_ldy_dp, addr_dp)
OP_LDY(op_ldy_dp_x, addr_dp_x)
OP_LDY(op_ldy_abs, addr_abs)
OP_LDY(op_ldy_abs_x, addr_abs_x)

// STA
OP_STA(op_sta_dp, addr_dp)
OP_STA(op_sta_dp_x, addr_dp_x)
OP_STA(op_sta_abs, addr_abs)
OP_STA(op_sta_abs_x, addr_abs_x)
OP_STA(op_sta_abs_y, addr_abs_y)
OP_STA(op_sta_long, addr_long)
OP_STA(op_sta_long_x, addr_long_x)
OP_STA(op_sta_dp_x_ind, addr_dp_x_ind)
OP_STA(op_sta_dp_ind, addr_dp_ind)
OP_STA(op_sta_dp_ind_y, addr_dp_ind_y)
OP_STA(op_sta_dp_ind_long, addr_dp_ind_long)
OP_STA(op_sta_dp_ind_long_y, addr_dp_ind_long_y)
OP_STA(op_sta_sr, addr_sr)
OP_STA(op_sta_sr_ind_y, addr_sr_ind_y)

// STX
OP_STX(op_stx_dp, addr_dp)
OP_STX(op_stx_dp_y, addr_dp_y)
OP_STX(op_stx_abs, addr_abs)

// STY
OP_STY(op_sty_dp, addr_dp)
OP_STY(op_sty_dp_x, addr_dp_x)
OP_STY(op_sty_abs, addr_abs)

// STZ
OP_STZ(op_stz_dp, addr_dp)
OP_STZ(op_stz_dp_x, addr_dp_x)
OP_STZ(op_stz_abs, addr_abs)
OP_STZ(op_stz_abs_x, addr_abs_x)

// ADC
OP_ADC(op_adc_dp, addr_dp)
OP_ADC(op_adc_dp_x, addr_dp_x)
OP_ADC(op_adc_abs, addr_abs)
OP_ADC(op_adc_abs_x, addr_abs_x)
OP_ADC(op_adc_abs_y, addr_abs_y)
OP_ADC(op_adc_long, addr_long)
OP_ADC(op_adc_long_x, addr_long_x)
OP_ADC(op_adc_dp_x_ind, addr_dp_x_ind)
OP_ADC(op_adc_dp_ind, addr_dp_ind)
OP_ADC(op_adc_dp_ind_y, addr_dp_ind_y)
OP_ADC(op_adc_dp_ind_long, addr_dp_ind_long)
OP_ADC(op_adc_dp_ind_long_y, addr_dp_ind_long_y)
OP_ADC(op_adc_sr, addr_sr)
OP_ADC(op_adc_sr_ind_y, addr_sr_ind_y)

// SBC
OP_SBC(op_sbc_dp, addr_dp)
OP_SBC(op_sbc_dp_x, addr_dp_x)
OP_SBC(op_sbc_abs, addr_abs)
OP_SBC(op_sbc_abs_x, addr_abs_x)
OP_SBC(op_sbc_abs_y, addr_abs_y)
OP_SBC(op_sbc_long, addr_long)
OP_SBC(op_sbc_long_x, addr_long_x)
OP_SBC(op_sbc_dp_x_ind, addr_dp_x_ind)
OP_SBC(op_sbc_dp_ind, addr_dp_ind)
OP_SBC(op_sbc_dp_ind_y, addr_dp_ind_y)
OP_SBC(op_sbc_dp_ind_long, addr_dp_ind_long)
OP_SBC(op_sbc_dp_ind_long_y, addr_dp_ind_long_y)
OP_SBC(op_sbc_sr, addr_sr)
OP_SBC(op_sbc_sr_ind_y, addr_sr_ind_y)

// AND
OP_AND(op_and_dp, addr_dp)
OP_AND(op_and_dp_x, addr_dp_x)
OP_AND(op_and_abs, addr_abs)
OP_AND(op_and_abs_x, addr_abs_x)
OP_AND(op_and_abs_y, addr_abs_y)
OP_AND(op_and_long, addr_long)
OP_AND(op_and_long_x, addr_long_x)
OP_AND(op_and_dp_x_ind, addr_dp_x_ind)
OP_AND(op_and_dp_ind, addr_dp_ind)
OP_AND(op_and_dp_ind_y, addr_dp_ind_y)
OP_AND(op_and_dp_ind_long, addr_dp_ind_long)
OP_AND(op_and_dp_ind_long_y, addr_dp_ind_long_y)
OP_AND(op_and_sr, addr_sr)
OP_AND(op_and_sr_ind_y, addr_sr_ind_y)

// ORA
OP_ORA(op_ora_dp, addr_dp)
OP_ORA(op_ora_dp_x, addr_dp_x)
OP_ORA(op_ora_abs, addr_abs)
OP_ORA(op_ora_abs_x, addr_abs_x)
OP_ORA(op_ora_abs_y, addr_abs_y)
OP_ORA(op_ora_long, addr_long)
OP_ORA(op_ora_long_x, addr_long_x)
OP_ORA(op_ora_dp_x_ind, addr_dp_x_ind)
OP_ORA(op_ora_dp_ind, addr_dp_ind)
OP_ORA(op_ora_dp_ind_y, addr_dp_ind_y)
OP_ORA(op_ora_dp_ind_long, addr_dp_ind_long)
OP_ORA(op_ora_dp_ind_long_y, addr_dp_ind_long_y)
OP_ORA(op_ora_sr, addr_sr)
OP_ORA(op_ora_sr_ind_y, addr_sr_ind_y)

// EOR
OP_EOR(op_eor_dp, addr_dp)
OP_EOR(op_eor_dp_x, addr_dp_x)
OP_EOR(op_eor_abs, addr_abs)
OP_EOR(op_eor_abs_x, addr_abs_x)
OP_EOR(op_eor_abs_y, addr_abs_y)
OP_EOR(op_eor_long, addr_long)
OP_EOR(op_eor_long_x, addr_long_x)
OP_EOR(op_eor_dp_x_ind, addr_dp_x_ind)
OP_EOR(op_eor_dp_ind, addr_dp_ind)
OP_EOR(op_eor_dp_ind_y, addr_dp_ind_y)
OP_EOR(op_eor_dp_ind_long, addr_dp_ind_long)
OP_EOR(op_eor_dp_ind_long_y, addr_dp_ind_long_y)
OP_EOR(op_eor_sr, addr_sr)
OP_EOR(op_eor_sr_ind_y, addr_sr_ind_y)

// CMP
OP_CMP(op_cmp_dp, addr_dp)
OP_CMP(op_cmp_dp_x, addr_dp_x)
OP_CMP(op_cmp_abs, addr_abs)
OP_CMP(op_cmp_abs_x, addr_abs_x)
OP_CMP(op_cmp_abs_y, addr_abs_y)
OP_CMP(op_cmp_long, addr_long)
OP_CMP(op_cmp_long_x, addr_long_x)
OP_CMP(op_cmp_dp_x_ind, addr_dp_x_ind)
OP_CMP(op_cmp_dp_ind, addr_dp_ind)
OP_CMP(op_cmp_dp_ind_y, addr_dp_ind_y)
OP_CMP(op_cmp_dp_ind_long, addr_dp_ind_long)
OP_CMP(op_cmp_dp_ind_long_y, addr_dp_ind_long_y)
OP_CMP(op_cmp_sr, addr_sr)
OP_CMP(op_cmp_sr_ind_y, addr_sr_ind_y)

// CPX
OP_CPX(op_cpx_dp, addr_dp)
OP_CPX(op_cpx_abs, addr_abs)

// CPY
OP_CPY(op_cpy_dp, addr_dp)
OP_CPY(op_cpy_abs, addr_abs)

// BIT
OP_BIT(op_bit_dp, addr_dp)
OP_BIT(op_bit_dp_x, addr_dp_x)
OP_BIT(op_bit_abs, addr_abs)
OP_BIT(op_bit_abs_x, addr_abs_x)

// INC memory
OP_INC_MEM(op_inc_dp, addr_dp)
OP_INC_MEM(op_inc_dp_x, addr_dp_x)
OP_INC_MEM(op_inc_abs, addr_abs)
OP_INC_MEM(op_inc_abs_x, addr_abs_x)

// DEC memory
OP_DEC_MEM(op_dec_dp, addr_dp)
OP_DEC_MEM(op_dec_dp_x, addr_dp_x)
OP_DEC_MEM(op_dec_abs, addr_abs)
OP_DEC_MEM(op_dec_abs_x, addr_abs_x)

// ASL memory
OP_ASL_MEM(op_asl_dp, addr_dp)
OP_ASL_MEM(op_asl_dp_x, addr_dp_x)
OP_ASL_MEM(op_asl_abs, addr_abs)
OP_ASL_MEM(op_asl_abs_x, addr_abs_x)

// LSR memory
OP_LSR_MEM(op_lsr_dp, addr_dp)
OP_LSR_MEM(op_lsr_dp_x, addr_dp_x)
OP_LSR_MEM(op_lsr_abs, addr_abs)
OP_LSR_MEM(op_lsr_abs_x, addr_abs_x)

// ROL memory
OP_ROL_MEM(op_rol_dp, addr_dp)
OP_ROL_MEM(op_rol_dp_x, addr_dp_x)
OP_ROL_MEM(op_rol_abs, addr_abs)
OP_ROL_MEM(op_rol_abs_x, addr_abs_x)

// ROR memory
OP_ROR_MEM(op_ror_dp, addr_dp)
OP_ROR_MEM(op_ror_dp_x, addr_dp_x)
OP_ROR_MEM(op_ror_abs, addr_abs)
OP_ROR_MEM(op_ror_abs_x, addr_abs_x)

// ============================================================
// Immediate mode opcodes
// ============================================================

static void op_lda_imm(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_m(r)) {
        uint8_t val = fetch8(r, rd, ctx);
        r->A = (r->A & 0xFF00) | val;
        set_nz8(r, val);
        r->cycles = 2;
    } else {
        uint16_t val = fetch16(r, rd, ctx);
        r->A = val;
        set_nz16(r, val);
        r->cycles = 3;
    }
}

static void op_ldx_imm(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_x(r)) {
        uint8_t val = fetch8(r, rd, ctx);
        r->X = val;
        set_nz8(r, val);
        r->cycles = 2;
    } else {
        uint16_t val = fetch16(r, rd, ctx);
        r->X = val;
        set_nz16(r, val);
        r->cycles = 3;
    }
}

static void op_ldy_imm(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_x(r)) {
        uint8_t val = fetch8(r, rd, ctx);
        r->Y = val;
        set_nz8(r, val);
        r->cycles = 2;
    } else {
        uint16_t val = fetch16(r, rd, ctx);
        r->Y = val;
        set_nz16(r, val);
        r->cycles = 3;
    }
}

static void op_adc_imm(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_m(r)) {
        do_adc8(r, fetch8(r, rd, ctx));
        r->cycles = 2;
    } else {
        do_adc16(r, fetch16(r, rd, ctx));
        r->cycles = 3;
    }
}

static void op_sbc_imm(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_m(r)) {
        do_sbc8(r, fetch8(r, rd, ctx));
        r->cycles = 2;
    } else {
        do_sbc16(r, fetch16(r, rd, ctx));
        r->cycles = 3;
    }
}

static void op_and_imm(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_m(r)) {
        uint8_t val = fetch8(r, rd, ctx);
        r->A = (r->A & 0xFF00) | ((r->A & val) & 0xFF);
        set_nz8(r, r->A & 0xFF);
        r->cycles = 2;
    } else {
        r->A &= fetch16(r, rd, ctx);
        set_nz16(r, r->A);
        r->cycles = 3;
    }
}

static void op_ora_imm(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_m(r)) {
        uint8_t val = fetch8(r, rd, ctx);
        r->A = (r->A & 0xFF00) | ((r->A | val) & 0xFF);
        set_nz8(r, r->A & 0xFF);
        r->cycles = 2;
    } else {
        r->A |= fetch16(r, rd, ctx);
        set_nz16(r, r->A);
        r->cycles = 3;
    }
}

static void op_eor_imm(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_m(r)) {
        uint8_t val = fetch8(r, rd, ctx);
        r->A = (r->A & 0xFF00) | ((r->A ^ val) & 0xFF);
        set_nz8(r, r->A & 0xFF);
        r->cycles = 2;
    } else {
        r->A ^= fetch16(r, rd, ctx);
        set_nz16(r, r->A);
        r->cycles = 3;
    }
}

static void op_cmp_imm(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_m(r)) {
        do_cmp8(r, r->A & 0xFF, fetch8(r, rd, ctx));
        r->cycles = 2;
    } else {
        do_cmp16(r, r->A, fetch16(r, rd, ctx));
        r->cycles = 3;
    }
}

static void op_cpx_imm(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_x(r)) {
        do_cmp8(r, r->X & 0xFF, fetch8(r, rd, ctx));
        r->cycles = 2;
    } else {
        do_cmp16(r, r->X, fetch16(r, rd, ctx));
        r->cycles = 3;
    }
}

static void op_cpy_imm(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_x(r)) {
        do_cmp8(r, r->Y & 0xFF, fetch8(r, rd, ctx));
        r->cycles = 2;
    } else {
        do_cmp16(r, r->Y, fetch16(r, rd, ctx));
        r->cycles = 3;
    }
}

static void op_bit_imm(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_m(r)) {
        uint8_t val = fetch8(r, rd, ctx);
        r->P &= ~FLAG_Z;
        if ((r->A & val & 0xFF) == 0) r->P |= FLAG_Z;
        // BIT immediate does NOT affect N and V
        r->cycles = 2;
    } else {
        uint16_t val = fetch16(r, rd, ctx);
        r->P &= ~FLAG_Z;
        if ((r->A & val) == 0) r->P |= FLAG_Z;
        r->cycles = 3;
    }
}

// ============================================================
// Accumulator shift/rotate
// ============================================================

static void op_asl_a(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_m(r)) {
        r->P &= ~FLAG_C;
        if (r->A & 0x80) r->P |= FLAG_C;
        r->A = (r->A & 0xFF00) | ((r->A << 1) & 0xFF);
        set_nz8(r, r->A & 0xFF);
    } else {
        r->P &= ~FLAG_C;
        if (r->A & 0x8000) r->P |= FLAG_C;
        r->A <<= 1;
        set_nz16(r, r->A);
    }
    r->cycles = 2;
}

static void op_lsr_a(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_m(r)) {
        r->P &= ~FLAG_C;
        if (r->A & 0x01) r->P |= FLAG_C;
        r->A = (r->A & 0xFF00) | ((r->A >> 1) & 0x7F);
        set_nz8(r, r->A & 0xFF);
    } else {
        r->P &= ~FLAG_C;
        if (r->A & 0x0001) r->P |= FLAG_C;
        r->A >>= 1;
        set_nz16(r, r->A);
    }
    r->cycles = 2;
}

static void op_rol_a(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    uint8_t c = (r->P & FLAG_C) ? 1 : 0;
    if (flag_m(r)) {
        r->P &= ~FLAG_C;
        if (r->A & 0x80) r->P |= FLAG_C;
        r->A = (r->A & 0xFF00) | (((r->A << 1) | c) & 0xFF);
        set_nz8(r, r->A & 0xFF);
    } else {
        r->P &= ~FLAG_C;
        if (r->A & 0x8000) r->P |= FLAG_C;
        r->A = (r->A << 1) | c;
        set_nz16(r, r->A);
    }
    r->cycles = 2;
}

static void op_ror_a(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_m(r)) {
        uint8_t c = (r->P & FLAG_C) ? 0x80 : 0;
        r->P &= ~FLAG_C;
        if (r->A & 0x01) r->P |= FLAG_C;
        r->A = (r->A & 0xFF00) | (((r->A >> 1) & 0x7F) | c);
        set_nz8(r, r->A & 0xFF);
    } else {
        uint16_t c = (r->P & FLAG_C) ? 0x8000 : 0;
        r->P &= ~FLAG_C;
        if (r->A & 0x0001) r->P |= FLAG_C;
        r->A = (r->A >> 1) | c;
        set_nz16(r, r->A);
    }
    r->cycles = 2;
}

// ============================================================
// Branches
// ============================================================

#define OP_BRANCH(name, flag, set) \
static void name(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) { \
    int8_t off = (int8_t)fetch8(r, rd, ctx); \
    if ((!!(r->P & flag)) == set) { \
        r->PC = (uint16_t)(r->PC + off); \
        r->cycles = 3; \
    } else { \
        r->cycles = 2; \
    } \
}

OP_BRANCH(op_bcc, FLAG_C, 0)
OP_BRANCH(op_bcs, FLAG_C, 1)
OP_BRANCH(op_bne, FLAG_Z, 0)
OP_BRANCH(op_beq, FLAG_Z, 1)
OP_BRANCH(op_bpl, FLAG_N, 0)
OP_BRANCH(op_bmi, FLAG_N, 1)
OP_BRANCH(op_bvc, FLAG_V, 0)
OP_BRANCH(op_bvs, FLAG_V, 1)

static void op_bra(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    int8_t off = (int8_t)fetch8(r, rd, ctx);
    r->PC = (uint16_t)(r->PC + off);
    r->cycles = 3;
}

static void op_brl(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    int16_t off = (int16_t)fetch16(r, rd, ctx);
    r->PC = (uint16_t)(r->PC + off);
    r->cycles = 4;
}

// ============================================================
// Jumps & Calls
// ============================================================

static void op_jmp_abs(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    r->PC = fetch16(r, rd, ctx);
    r->cycles = 3;
}

static void op_jmp_long(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    uint32_t addr = fetch24(r, rd, ctx);
    r->PC = addr & 0xFFFF;
    r->PBR = (addr >> 16) & 0xFF;
    r->cycles = 4;
}

static void op_jmp_abs_ind(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    uint16_t ptr = fetch16(r, rd, ctx);
    r->PC = read16(rd, ctx, ptr);
    r->cycles = 5;
}

static void op_jmp_abs_x_ind(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    uint16_t ptr = fetch16(r, rd, ctx) + r->X;
    uint32_t addr = full_addr(r->PBR, ptr);
    r->PC = read16(rd, ctx, addr);
    r->cycles = 6;
}

static void op_jmp_abs_ind_long(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    uint16_t ptr = fetch16(r, rd, ctx);
    uint8_t lo = rd(ctx, ptr);
    uint8_t hi = rd(ctx, ptr + 1);
    uint8_t bank = rd(ctx, ptr + 2);
    r->PC = (uint16_t)hi << 8 | lo;
    r->PBR = bank;
    r->cycles = 6;
}

static void op_jsr_abs(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    uint16_t addr = fetch16(r, rd, ctx);
    push16(r, wr, ctx, r->PC - 1);
    r->PC = addr;
    r->cycles = 6;
}

static void op_jsr_long(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    uint32_t addr = fetch24(r, rd, ctx);
    push8(r, wr, ctx, r->PBR);
    push16(r, wr, ctx, r->PC - 1);
    r->PC = addr & 0xFFFF;
    r->PBR = (addr >> 16) & 0xFF;
    r->cycles = 8;
}

static void op_jsr_abs_x_ind(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    uint16_t ptr = fetch16(r, rd, ctx);
    push16(r, wr, ctx, r->PC - 1);
    uint32_t addr = full_addr(r->PBR, ptr + r->X);
    r->PC = read16(rd, ctx, addr);
    r->cycles = 8;
}

static void op_rts(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    r->PC = pull16(r, rd, ctx) + 1;
    r->cycles = 6;
}

static void op_rtl(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    r->PC = pull16(r, rd, ctx) + 1;
    r->PBR = pull8(r, rd, ctx);
    r->cycles = 6;
}

static void op_rti(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    r->P = pull8(r, rd, ctx);
    r->PC = pull16(r, rd, ctx);
    if (!r->emulationMode) {
        r->PBR = pull8(r, rd, ctx);
    }
    r->cycles = 7;
}

// ============================================================
// Stack operations
// ============================================================

static void op_pha(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_m(r)) {
        push8(r, wr, ctx, r->A & 0xFF);
        r->cycles = 3;
    } else {
        push16(r, wr, ctx, r->A);
        r->cycles = 4;
    }
}

static void op_pla(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_m(r)) {
        uint8_t val = pull8(r, rd, ctx);
        r->A = (r->A & 0xFF00) | val;
        set_nz8(r, val);
        r->cycles = 4;
    } else {
        r->A = pull16(r, rd, ctx);
        set_nz16(r, r->A);
        r->cycles = 5;
    }
}

static void op_phx(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_x(r)) {
        push8(r, wr, ctx, r->X & 0xFF);
        r->cycles = 3;
    } else {
        push16(r, wr, ctx, r->X);
        r->cycles = 4;
    }
}

static void op_plx(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_x(r)) {
        r->X = pull8(r, rd, ctx);
        set_nz8(r, r->X & 0xFF);
        r->cycles = 4;
    } else {
        r->X = pull16(r, rd, ctx);
        set_nz16(r, r->X);
        r->cycles = 5;
    }
}

static void op_phy(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_x(r)) {
        push8(r, wr, ctx, r->Y & 0xFF);
        r->cycles = 3;
    } else {
        push16(r, wr, ctx, r->Y);
        r->cycles = 4;
    }
}

static void op_ply(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_x(r)) {
        r->Y = pull8(r, rd, ctx);
        set_nz8(r, r->Y & 0xFF);
        r->cycles = 4;
    } else {
        r->Y = pull16(r, rd, ctx);
        set_nz16(r, r->Y);
        r->cycles = 5;
    }
}

static void op_php(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    push8(r, wr, ctx, r->P);
    r->cycles = 3;
}

static void op_plp(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    r->P = pull8(r, rd, ctx);
    if (r->emulationMode) {
        r->P |= (FLAG_M | FLAG_X);
    }
    if (r->P & FLAG_X) {
        r->X &= 0xFF;
        r->Y &= 0xFF;
    }
    r->cycles = 4;
}

static void op_phb(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    push8(r, wr, ctx, r->DBR);
    r->cycles = 3;
}

static void op_plb(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    r->DBR = pull8(r, rd, ctx);
    set_nz8(r, r->DBR);
    r->cycles = 4;
}

static void op_phk(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    push8(r, wr, ctx, r->PBR);
    r->cycles = 3;
}

static void op_phd(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    push16(r, wr, ctx, r->D);
    r->cycles = 4;
}

static void op_pld(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    r->D = pull16(r, rd, ctx);
    set_nz16(r, r->D);
    r->cycles = 5;
}

static void op_pea(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    uint16_t val = fetch16(r, rd, ctx);
    push16(r, wr, ctx, val);
    r->cycles = 5;
}

static void op_pei(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    uint32_t dp = addr_dp(r, rd, ctx);
    uint16_t val = read16(rd, ctx, dp);
    push16(r, wr, ctx, val);
    r->cycles = 6;
}

static void op_per(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    int16_t off = (int16_t)fetch16(r, rd, ctx);
    push16(r, wr, ctx, (uint16_t)(r->PC + off));
    r->cycles = 6;
}

// ============================================================
// Transfers
// ============================================================

static void op_tax(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_x(r)) {
        r->X = r->A & 0xFF;
        set_nz8(r, r->X & 0xFF);
    } else {
        r->X = r->A;
        set_nz16(r, r->X);
    }
    r->cycles = 2;
}

static void op_tay(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_x(r)) {
        r->Y = r->A & 0xFF;
        set_nz8(r, r->Y & 0xFF);
    } else {
        r->Y = r->A;
        set_nz16(r, r->Y);
    }
    r->cycles = 2;
}

static void op_txa(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_m(r)) {
        r->A = (r->A & 0xFF00) | (r->X & 0xFF);
        set_nz8(r, r->A & 0xFF);
    } else {
        r->A = r->X;
        set_nz16(r, r->A);
    }
    r->cycles = 2;
}

static void op_tya(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_m(r)) {
        r->A = (r->A & 0xFF00) | (r->Y & 0xFF);
        set_nz8(r, r->A & 0xFF);
    } else {
        r->A = r->Y;
        set_nz16(r, r->A);
    }
    r->cycles = 2;
}

static void op_txs(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (r->emulationMode) {
        r->S = 0x0100 | (r->X & 0xFF);
    } else {
        r->S = r->X;
    }
    r->cycles = 2;
}

static void op_tsx(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_x(r)) {
        r->X = r->S & 0xFF;
        set_nz8(r, r->X & 0xFF);
    } else {
        r->X = r->S;
        set_nz16(r, r->X);
    }
    r->cycles = 2;
}

static void op_tcd(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    r->D = r->A;
    set_nz16(r, r->D);
    r->cycles = 2;
}

static void op_tdc(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    r->A = r->D;
    set_nz16(r, r->A);
    r->cycles = 2;
}

static void op_tcs(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    r->S = r->A;
    r->cycles = 2;
}

static void op_tsc(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    r->A = r->S;
    set_nz16(r, r->A);
    r->cycles = 2;
}

static void op_txy(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_x(r)) {
        r->Y = r->X & 0xFF;
        set_nz8(r, r->Y & 0xFF);
    } else {
        r->Y = r->X;
        set_nz16(r, r->Y);
    }
    r->cycles = 2;
}

static void op_tyx(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_x(r)) {
        r->X = r->Y & 0xFF;
        set_nz8(r, r->X & 0xFF);
    } else {
        r->X = r->Y;
        set_nz16(r, r->X);
    }
    r->cycles = 2;
}

// ============================================================
// Increment / Decrement registers
// ============================================================

static void op_inx(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_x(r)) {
        r->X = (r->X + 1) & 0xFF;
        set_nz8(r, r->X & 0xFF);
    } else {
        r->X++;
        set_nz16(r, r->X);
    }
    r->cycles = 2;
}

static void op_iny(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_x(r)) {
        r->Y = (r->Y + 1) & 0xFF;
        set_nz8(r, r->Y & 0xFF);
    } else {
        r->Y++;
        set_nz16(r, r->Y);
    }
    r->cycles = 2;
}

static void op_dex(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_x(r)) {
        r->X = (r->X - 1) & 0xFF;
        set_nz8(r, r->X & 0xFF);
    } else {
        r->X--;
        set_nz16(r, r->X);
    }
    r->cycles = 2;
}

static void op_dey(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_x(r)) {
        r->Y = (r->Y - 1) & 0xFF;
        set_nz8(r, r->Y & 0xFF);
    } else {
        r->Y--;
        set_nz16(r, r->Y);
    }
    r->cycles = 2;
}

static void op_inc_a(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_m(r)) {
        r->A = (r->A & 0xFF00) | ((r->A + 1) & 0xFF);
        set_nz8(r, r->A & 0xFF);
    } else {
        r->A++;
        set_nz16(r, r->A);
    }
    r->cycles = 2;
}

static void op_dec_a(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    if (flag_m(r)) {
        r->A = (r->A & 0xFF00) | ((r->A - 1) & 0xFF);
        set_nz8(r, r->A & 0xFF);
    } else {
        r->A--;
        set_nz16(r, r->A);
    }
    r->cycles = 2;
}

// ============================================================
// Flag operations
// ============================================================

static void op_clc(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    r->P &= ~FLAG_C; r->cycles = 2;
}
static void op_sec(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    r->P |= FLAG_C; r->cycles = 2;
}
static void op_cli(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    r->P &= ~FLAG_I; r->cycles = 2;
}
static void op_sei(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    r->P |= FLAG_I; r->cycles = 2;
}
static void op_cld(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    r->P &= ~FLAG_D; r->cycles = 2;
}
static void op_sed(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    r->P |= FLAG_D; r->cycles = 2;
}
static void op_clv(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    r->P &= ~FLAG_V; r->cycles = 2;
}

static void op_xce(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    bool old_c = (r->P & FLAG_C) != 0;
    bool old_e = r->emulationMode;
    r->emulationMode = old_c;
    if (old_e) r->P |= FLAG_C; else r->P &= ~FLAG_C;
    if (r->emulationMode) {
        r->P |= (FLAG_M | FLAG_X);
        r->S = 0x0100 | (r->S & 0xFF);
        r->X &= 0xFF;
        r->Y &= 0xFF;
    }
    r->cycles = 2;
}

static void op_rep(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    uint8_t val = fetch8(r, rd, ctx);
    r->P &= ~val;
    if (r->emulationMode) {
        r->P |= (FLAG_M | FLAG_X);
    }
    if (r->P & FLAG_X) {
        r->X &= 0xFF;
        r->Y &= 0xFF;
    }
    r->cycles = 3;
}

static void op_sep(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    uint8_t val = fetch8(r, rd, ctx);
    r->P |= val;
    if (r->P & FLAG_X) {
        r->X &= 0xFF;
        r->Y &= 0xFF;
    }
    r->cycles = 3;
}

// ============================================================
// Misc
// ============================================================

static void op_nop(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    r->cycles = 2;
}

static void op_wdm(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    fetch8(r, rd, ctx); // skip signature byte
    r->cycles = 2;
}

static void op_stp(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    r->stopped = true;
    r->cycles = 3;
}

static void op_wai(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    r->waiting = true;
    r->cycles = 3;
}

static void op_brk(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    fetch8(r, rd, ctx); // signature byte
    if (!r->emulationMode) {
        push8(r, wr, ctx, r->PBR);
    }
    push16(r, wr, ctx, r->PC);
    push8(r, wr, ctx, r->P);
    r->P |= FLAG_I;
    r->P &= ~FLAG_D;
    r->PBR = 0;
    if (r->emulationMode) {
        r->PC = read16(rd, ctx, 0xFFFE);
    } else {
        r->PC = read16(rd, ctx, 0xFFE6);
    }
    r->cycles = 8;
}

static void op_cop(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    fetch8(r, rd, ctx);
    if (!r->emulationMode) {
        push8(r, wr, ctx, r->PBR);
    }
    push16(r, wr, ctx, r->PC);
    push8(r, wr, ctx, r->P);
    r->P |= FLAG_I;
    r->P &= ~FLAG_D;
    r->PBR = 0;
    if (r->emulationMode) {
        r->PC = read16(rd, ctx, 0xFFF4);
    } else {
        r->PC = read16(rd, ctx, 0xFFE4);
    }
    r->cycles = 8;
}

// MVN / MVP - block move
static void op_mvn(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    uint8_t dst_bank = fetch8(r, rd, ctx);
    uint8_t src_bank = fetch8(r, rd, ctx);
    r->DBR = dst_bank;
    uint8_t val = rd(ctx, full_addr(src_bank, r->X));
    wr(ctx, full_addr(dst_bank, r->Y), val);
    if (flag_x(r)) {
        r->X = (r->X + 1) & 0xFF;
        r->Y = (r->Y + 1) & 0xFF;
    } else {
        r->X++;
        r->Y++;
    }
    r->A--;
    if (r->A != 0xFFFF) {
        r->PC -= 3; // repeat
    }
    r->cycles = 7;
}

static void op_mvp(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    uint8_t dst_bank = fetch8(r, rd, ctx);
    uint8_t src_bank = fetch8(r, rd, ctx);
    r->DBR = dst_bank;
    uint8_t val = rd(ctx, full_addr(src_bank, r->X));
    wr(ctx, full_addr(dst_bank, r->Y), val);
    if (flag_x(r)) {
        r->X = (r->X - 1) & 0xFF;
        r->Y = (r->Y - 1) & 0xFF;
    } else {
        r->X--;
        r->Y--;
    }
    r->A--;
    if (r->A != 0xFFFF) {
        r->PC -= 3;
    }
    r->cycles = 7;
}

// TRB / TSB
static void op_trb_dp(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    uint32_t addr = addr_dp(r, rd, ctx);
    if (flag_m(r)) {
        uint8_t val = read8(rd, ctx, addr);
        r->P &= ~FLAG_Z;
        if ((r->A & val & 0xFF) == 0) r->P |= FLAG_Z;
        wr(ctx, addr, val & ~(r->A & 0xFF));
        r->cycles = 5;
    } else {
        uint16_t val = read16(rd, ctx, addr);
        r->P &= ~FLAG_Z;
        if ((r->A & val) == 0) r->P |= FLAG_Z;
        uint16_t result = val & ~r->A;
        wr(ctx, addr, result & 0xFF);
        wr(ctx, addr + 1, result >> 8);
        r->cycles = 7;
    }
}

static void op_trb_abs(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    uint32_t addr = addr_abs(r, rd, ctx);
    if (flag_m(r)) {
        uint8_t val = read8(rd, ctx, addr);
        r->P &= ~FLAG_Z;
        if ((r->A & val & 0xFF) == 0) r->P |= FLAG_Z;
        wr(ctx, addr, val & ~(r->A & 0xFF));
        r->cycles = 6;
    } else {
        uint16_t val = read16(rd, ctx, addr);
        r->P &= ~FLAG_Z;
        if ((r->A & val) == 0) r->P |= FLAG_Z;
        uint16_t result = val & ~r->A;
        wr(ctx, addr, result & 0xFF);
        wr(ctx, addr + 1, result >> 8);
        r->cycles = 8;
    }
}

static void op_tsb_dp(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    uint32_t addr = addr_dp(r, rd, ctx);
    if (flag_m(r)) {
        uint8_t val = read8(rd, ctx, addr);
        r->P &= ~FLAG_Z;
        if ((r->A & val & 0xFF) == 0) r->P |= FLAG_Z;
        wr(ctx, addr, val | (r->A & 0xFF));
        r->cycles = 5;
    } else {
        uint16_t val = read16(rd, ctx, addr);
        r->P &= ~FLAG_Z;
        if ((r->A & val) == 0) r->P |= FLAG_Z;
        uint16_t result = val | r->A;
        wr(ctx, addr, result & 0xFF);
        wr(ctx, addr + 1, result >> 8);
        r->cycles = 7;
    }
}

static void op_tsb_abs(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    uint32_t addr = addr_abs(r, rd, ctx);
    if (flag_m(r)) {
        uint8_t val = read8(rd, ctx, addr);
        r->P &= ~FLAG_Z;
        if ((r->A & val & 0xFF) == 0) r->P |= FLAG_Z;
        wr(ctx, addr, val | (r->A & 0xFF));
        r->cycles = 6;
    } else {
        uint16_t val = read16(rd, ctx, addr);
        r->P &= ~FLAG_Z;
        if ((r->A & val) == 0) r->P |= FLAG_Z;
        uint16_t result = val | r->A;
        wr(ctx, addr, result & 0xFF);
        wr(ctx, addr + 1, result >> 8);
        r->cycles = 8;
    }
}

// --- XBA (Exchange B and A) ---
static void op_xba(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    uint8_t lo = r->A & 0xFF;
    uint8_t hi = (r->A >> 8) & 0xFF;
    r->A = ((uint16_t)lo << 8) | hi;
    // NZ flags based on new low byte (which is the old high byte)
    set_nz8(r, hi);
    r->cycles = 3;
}

// Unimplemented opcode handler
static void op_unimpl(CPURegisters *r, BusReadFunc rd, BusWriteFunc wr, void *ctx) {
    // Log the unimplemented opcode with PC (PC already advanced past opcode byte)
    uint16_t faultPC = r->PC - 1;
    uint8_t opcode = rd(ctx, full_addr(r->PBR, faultPC));
    printf("UNIMPL opcode $%02X at %02X:%04X\n", opcode, r->PBR, faultPC);
    r->cycles = 2;
}

// ============================================================
// Dispatch table initialization
// ============================================================

void cpu_dispatch_init(void) {
    // Fill with unimplemented handler
    for (int i = 0; i < 256; i++) {
        dispatch_table[i] = op_unimpl;
    }

    // BRK / COP
    dispatch_table[0x00] = op_brk;
    dispatch_table[0x02] = op_cop;

    // ORA
    dispatch_table[0x01] = op_ora_dp_x_ind;
    dispatch_table[0x03] = op_ora_sr;
    dispatch_table[0x05] = op_ora_dp;
    dispatch_table[0x07] = op_ora_dp_ind_long;
    dispatch_table[0x09] = op_ora_imm;
    dispatch_table[0x0D] = op_ora_abs;
    dispatch_table[0x0F] = op_ora_long;
    dispatch_table[0x11] = op_ora_dp_ind_y;
    dispatch_table[0x12] = op_ora_dp_ind;
    dispatch_table[0x13] = op_ora_sr_ind_y;
    dispatch_table[0x15] = op_ora_dp_x;
    dispatch_table[0x17] = op_ora_dp_ind_long_y;
    dispatch_table[0x19] = op_ora_abs_y;
    dispatch_table[0x1D] = op_ora_abs_x;
    dispatch_table[0x1F] = op_ora_long_x;

    // AND
    dispatch_table[0x21] = op_and_dp_x_ind;
    dispatch_table[0x23] = op_and_sr;
    dispatch_table[0x25] = op_and_dp;
    dispatch_table[0x27] = op_and_dp_ind_long;
    dispatch_table[0x29] = op_and_imm;
    dispatch_table[0x2D] = op_and_abs;
    dispatch_table[0x2F] = op_and_long;
    dispatch_table[0x31] = op_and_dp_ind_y;
    dispatch_table[0x32] = op_and_dp_ind;
    dispatch_table[0x33] = op_and_sr_ind_y;
    dispatch_table[0x35] = op_and_dp_x;
    dispatch_table[0x37] = op_and_dp_ind_long_y;
    dispatch_table[0x39] = op_and_abs_y;
    dispatch_table[0x3D] = op_and_abs_x;
    dispatch_table[0x3F] = op_and_long_x;

    // EOR
    dispatch_table[0x41] = op_eor_dp_x_ind;
    dispatch_table[0x43] = op_eor_sr;
    dispatch_table[0x45] = op_eor_dp;
    dispatch_table[0x47] = op_eor_dp_ind_long;
    dispatch_table[0x49] = op_eor_imm;
    dispatch_table[0x4D] = op_eor_abs;
    dispatch_table[0x4F] = op_eor_long;
    dispatch_table[0x51] = op_eor_dp_ind_y;
    dispatch_table[0x52] = op_eor_dp_ind;
    dispatch_table[0x53] = op_eor_sr_ind_y;
    dispatch_table[0x55] = op_eor_dp_x;
    dispatch_table[0x57] = op_eor_dp_ind_long_y;
    dispatch_table[0x59] = op_eor_abs_y;
    dispatch_table[0x5D] = op_eor_abs_x;
    dispatch_table[0x5F] = op_eor_long_x;

    // ADC
    dispatch_table[0x61] = op_adc_dp_x_ind;
    dispatch_table[0x63] = op_adc_sr;
    dispatch_table[0x65] = op_adc_dp;
    dispatch_table[0x67] = op_adc_dp_ind_long;
    dispatch_table[0x69] = op_adc_imm;
    dispatch_table[0x6D] = op_adc_abs;
    dispatch_table[0x6F] = op_adc_long;
    dispatch_table[0x71] = op_adc_dp_ind_y;
    dispatch_table[0x72] = op_adc_dp_ind;
    dispatch_table[0x73] = op_adc_sr_ind_y;
    dispatch_table[0x75] = op_adc_dp_x;
    dispatch_table[0x77] = op_adc_dp_ind_long_y;
    dispatch_table[0x79] = op_adc_abs_y;
    dispatch_table[0x7D] = op_adc_abs_x;
    dispatch_table[0x7F] = op_adc_long_x;

    // SBC
    dispatch_table[0xE1] = op_sbc_dp_x_ind;
    dispatch_table[0xE3] = op_sbc_sr;
    dispatch_table[0xE5] = op_sbc_dp;
    dispatch_table[0xE7] = op_sbc_dp_ind_long;
    dispatch_table[0xE9] = op_sbc_imm;
    dispatch_table[0xED] = op_sbc_abs;
    dispatch_table[0xEF] = op_sbc_long;
    dispatch_table[0xF1] = op_sbc_dp_ind_y;
    dispatch_table[0xF2] = op_sbc_dp_ind;
    dispatch_table[0xF3] = op_sbc_sr_ind_y;
    dispatch_table[0xF5] = op_sbc_dp_x;
    dispatch_table[0xF7] = op_sbc_dp_ind_long_y;
    dispatch_table[0xF9] = op_sbc_abs_y;
    dispatch_table[0xFD] = op_sbc_abs_x;
    dispatch_table[0xFF] = op_sbc_long_x;

    // CMP
    dispatch_table[0xC1] = op_cmp_dp_x_ind;
    dispatch_table[0xC3] = op_cmp_sr;
    dispatch_table[0xC5] = op_cmp_dp;
    dispatch_table[0xC7] = op_cmp_dp_ind_long;
    dispatch_table[0xC9] = op_cmp_imm;
    dispatch_table[0xCD] = op_cmp_abs;
    dispatch_table[0xCF] = op_cmp_long;
    dispatch_table[0xD1] = op_cmp_dp_ind_y;
    dispatch_table[0xD2] = op_cmp_dp_ind;
    dispatch_table[0xD3] = op_cmp_sr_ind_y;
    dispatch_table[0xD5] = op_cmp_dp_x;
    dispatch_table[0xD7] = op_cmp_dp_ind_long_y;
    dispatch_table[0xD9] = op_cmp_abs_y;
    dispatch_table[0xDD] = op_cmp_abs_x;
    dispatch_table[0xDF] = op_cmp_long_x;

    // LDA
    dispatch_table[0xA1] = op_lda_dp_x_ind;
    dispatch_table[0xA3] = op_lda_sr;
    dispatch_table[0xA5] = op_lda_dp;
    dispatch_table[0xA7] = op_lda_dp_ind_long;
    dispatch_table[0xA9] = op_lda_imm;
    dispatch_table[0xAD] = op_lda_abs;
    dispatch_table[0xAF] = op_lda_long;
    dispatch_table[0xB1] = op_lda_dp_ind_y;
    dispatch_table[0xB2] = op_lda_dp_ind;
    dispatch_table[0xB3] = op_lda_sr_ind_y;
    dispatch_table[0xB5] = op_lda_dp_x;
    dispatch_table[0xB7] = op_lda_dp_ind_long_y;
    dispatch_table[0xB9] = op_lda_abs_y;
    dispatch_table[0xBD] = op_lda_abs_x;
    dispatch_table[0xBF] = op_lda_long_x;

    // STA
    dispatch_table[0x81] = op_sta_dp_x_ind;
    dispatch_table[0x83] = op_sta_sr;
    dispatch_table[0x85] = op_sta_dp;
    dispatch_table[0x87] = op_sta_dp_ind_long;
    dispatch_table[0x8D] = op_sta_abs;
    dispatch_table[0x8F] = op_sta_long;
    dispatch_table[0x91] = op_sta_dp_ind_y;
    dispatch_table[0x92] = op_sta_dp_ind;
    dispatch_table[0x93] = op_sta_sr_ind_y;
    dispatch_table[0x95] = op_sta_dp_x;
    dispatch_table[0x97] = op_sta_dp_ind_long_y;
    dispatch_table[0x99] = op_sta_abs_y;
    dispatch_table[0x9D] = op_sta_abs_x;
    dispatch_table[0x9F] = op_sta_long_x;

    // LDX
    dispatch_table[0xA2] = op_ldx_imm;
    dispatch_table[0xA6] = op_ldx_dp;
    dispatch_table[0xAE] = op_ldx_abs;
    dispatch_table[0xB6] = op_ldx_dp_y;
    dispatch_table[0xBE] = op_ldx_abs_y;

    // LDY
    dispatch_table[0xA0] = op_ldy_imm;
    dispatch_table[0xA4] = op_ldy_dp;
    dispatch_table[0xAC] = op_ldy_abs;
    dispatch_table[0xB4] = op_ldy_dp_x;
    dispatch_table[0xBC] = op_ldy_abs_x;

    // STX
    dispatch_table[0x86] = op_stx_dp;
    dispatch_table[0x8E] = op_stx_abs;
    dispatch_table[0x96] = op_stx_dp_y;

    // STY
    dispatch_table[0x84] = op_sty_dp;
    dispatch_table[0x8C] = op_sty_abs;
    dispatch_table[0x94] = op_sty_dp_x;

    // STZ
    dispatch_table[0x64] = op_stz_dp;
    dispatch_table[0x74] = op_stz_dp_x;
    dispatch_table[0x9C] = op_stz_abs;
    dispatch_table[0x9E] = op_stz_abs_x;

    // CPX
    dispatch_table[0xE0] = op_cpx_imm;
    dispatch_table[0xE4] = op_cpx_dp;
    dispatch_table[0xEC] = op_cpx_abs;

    // CPY
    dispatch_table[0xC0] = op_cpy_imm;
    dispatch_table[0xC4] = op_cpy_dp;
    dispatch_table[0xCC] = op_cpy_abs;

    // BIT
    dispatch_table[0x24] = op_bit_dp;
    dispatch_table[0x2C] = op_bit_abs;
    dispatch_table[0x34] = op_bit_dp_x;
    dispatch_table[0x3C] = op_bit_abs_x;
    dispatch_table[0x89] = op_bit_imm;

    // INC
    dispatch_table[0x1A] = op_inc_a;
    dispatch_table[0xE6] = op_inc_dp;
    dispatch_table[0xEE] = op_inc_abs;
    dispatch_table[0xF6] = op_inc_dp_x;
    dispatch_table[0xFE] = op_inc_abs_x;

    // DEC
    dispatch_table[0x3A] = op_dec_a;
    dispatch_table[0xC6] = op_dec_dp;
    dispatch_table[0xCE] = op_dec_abs;
    dispatch_table[0xD6] = op_dec_dp_x;
    dispatch_table[0xDE] = op_dec_abs_x;

    // ASL
    dispatch_table[0x0A] = op_asl_a;
    dispatch_table[0x06] = op_asl_dp;
    dispatch_table[0x0E] = op_asl_abs;
    dispatch_table[0x16] = op_asl_dp_x;
    dispatch_table[0x1E] = op_asl_abs_x;

    // LSR
    dispatch_table[0x4A] = op_lsr_a;
    dispatch_table[0x46] = op_lsr_dp;
    dispatch_table[0x4E] = op_lsr_abs;
    dispatch_table[0x56] = op_lsr_dp_x;
    dispatch_table[0x5E] = op_lsr_abs_x;

    // ROL
    dispatch_table[0x2A] = op_rol_a;
    dispatch_table[0x26] = op_rol_dp;
    dispatch_table[0x2E] = op_rol_abs;
    dispatch_table[0x36] = op_rol_dp_x;
    dispatch_table[0x3E] = op_rol_abs_x;

    // ROR
    dispatch_table[0x6A] = op_ror_a;
    dispatch_table[0x66] = op_ror_dp;
    dispatch_table[0x6E] = op_ror_abs;
    dispatch_table[0x76] = op_ror_dp_x;
    dispatch_table[0x7E] = op_ror_abs_x;

    // Branches
    dispatch_table[0x10] = op_bpl;
    dispatch_table[0x30] = op_bmi;
    dispatch_table[0x50] = op_bvc;
    dispatch_table[0x70] = op_bvs;
    dispatch_table[0x80] = op_bra;
    dispatch_table[0x82] = op_brl;
    dispatch_table[0x90] = op_bcc;
    dispatch_table[0xB0] = op_bcs;
    dispatch_table[0xD0] = op_bne;
    dispatch_table[0xF0] = op_beq;

    // Jumps
    dispatch_table[0x4C] = op_jmp_abs;
    dispatch_table[0x5C] = op_jmp_long;
    dispatch_table[0x6C] = op_jmp_abs_ind;
    dispatch_table[0x7C] = op_jmp_abs_x_ind;
    dispatch_table[0xDC] = op_jmp_abs_ind_long;

    // JSR / RTS / RTL / RTI
    dispatch_table[0x20] = op_jsr_abs;
    dispatch_table[0x22] = op_jsr_long;
    dispatch_table[0xFC] = op_jsr_abs_x_ind;
    dispatch_table[0x60] = op_rts;
    dispatch_table[0x6B] = op_rtl;
    dispatch_table[0x40] = op_rti;

    // Stack
    dispatch_table[0x48] = op_pha;
    dispatch_table[0x68] = op_pla;
    dispatch_table[0xDA] = op_phx;
    dispatch_table[0xFA] = op_plx;
    dispatch_table[0x5A] = op_phy;
    dispatch_table[0x7A] = op_ply;
    dispatch_table[0x08] = op_php;
    dispatch_table[0x28] = op_plp;
    dispatch_table[0x8B] = op_phb;
    dispatch_table[0xAB] = op_plb;
    dispatch_table[0x4B] = op_phk;
    dispatch_table[0x0B] = op_phd;
    dispatch_table[0x2B] = op_pld;
    dispatch_table[0xF4] = op_pea;
    dispatch_table[0xD4] = op_pei;
    dispatch_table[0x62] = op_per;

    // Transfers
    dispatch_table[0xAA] = op_tax;
    dispatch_table[0xA8] = op_tay;
    dispatch_table[0x8A] = op_txa;
    dispatch_table[0x98] = op_tya;
    dispatch_table[0x9A] = op_txs;
    dispatch_table[0xBA] = op_tsx;
    dispatch_table[0x5B] = op_tcd;
    dispatch_table[0x7B] = op_tdc;
    dispatch_table[0x1B] = op_tcs;
    dispatch_table[0x3B] = op_tsc;
    dispatch_table[0x9B] = op_txy;
    dispatch_table[0xBB] = op_tyx;

    // Inc/Dec registers
    dispatch_table[0xE8] = op_inx;
    dispatch_table[0xC8] = op_iny;
    dispatch_table[0xCA] = op_dex;
    dispatch_table[0x88] = op_dey;

    // Flags
    dispatch_table[0x18] = op_clc;
    dispatch_table[0x38] = op_sec;
    dispatch_table[0x58] = op_cli;
    dispatch_table[0x78] = op_sei;
    dispatch_table[0xD8] = op_cld;
    dispatch_table[0xF8] = op_sed;
    dispatch_table[0xB8] = op_clv;
    dispatch_table[0xFB] = op_xce;
    dispatch_table[0xC2] = op_rep;
    dispatch_table[0xE2] = op_sep;

    // Misc
    dispatch_table[0xEA] = op_nop;
    dispatch_table[0x42] = op_wdm;
    dispatch_table[0xDB] = op_stp;
    dispatch_table[0xCB] = op_wai;

    // Block move
    dispatch_table[0x54] = op_mvn;
    dispatch_table[0x44] = op_mvp;

    // TRB / TSB
    dispatch_table[0x04] = op_tsb_dp;
    dispatch_table[0x0C] = op_tsb_abs;
    dispatch_table[0x14] = op_trb_dp;
    dispatch_table[0x1C] = op_trb_abs;

    // XBA
    dispatch_table[0xEB] = op_xba;
}

// ============================================================
// Main step function
// ============================================================

int cpu_step(CPURegisters *regs, BusReadFunc bus_read, BusWriteFunc bus_write, void *ctx) {
    if (regs->stopped) {
        return 1;
    }

    // Handle NMI
    if (regs->nmiPending) {
        regs->nmiPending = false;
        regs->waiting = false;
        if (!regs->emulationMode) {
            push8(regs, bus_write, ctx, regs->PBR);
        }
        push16(regs, bus_write, ctx, regs->PC);
        push8(regs, bus_write, ctx, regs->P);
        regs->P |= FLAG_I;
        regs->P &= ~FLAG_D;
        regs->PBR = 0;
        regs->PC = read16(bus_read, ctx, regs->emulationMode ? 0xFFFA : 0xFFEA);
        return 8;
    }

    // Handle IRQ
    if (regs->irqPending && !(regs->P & FLAG_I)) {
        regs->irqPending = false;
        regs->waiting = false;
        if (!regs->emulationMode) {
            push8(regs, bus_write, ctx, regs->PBR);
        }
        push16(regs, bus_write, ctx, regs->PC);
        push8(regs, bus_write, ctx, regs->P);
        regs->P |= FLAG_I;
        regs->P &= ~FLAG_D;
        regs->PBR = 0;
        regs->PC = read16(bus_read, ctx, regs->emulationMode ? 0xFFFE : 0xFFEE);
        return 8;
    }

    // WAI resumes on any IRQ edge even when the I flag masks vectoring.
    if (regs->irqPending) {
        regs->waiting = false;
    }

    if (regs->waiting) {
        return 1;
    }

    uint8_t opcode = fetch8(regs, bus_read, ctx);
    regs->cycles = 2; // default

    dispatch_table[opcode](regs, bus_read, bus_write, ctx);

    return regs->cycles;
}

void cpu_reset(CPURegisters *regs, BusReadFunc bus_read, void *ctx) {
    memset(regs, 0, sizeof(CPURegisters));
    regs->emulationMode = true;
    regs->P = FLAG_M | FLAG_X | FLAG_I;
    regs->S = 0x01FF;
    regs->D = 0;
    regs->DBR = 0;
    regs->PBR = 0;
    regs->PC = read16(bus_read, ctx, 0xFFFC);
}
