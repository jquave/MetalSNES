#ifndef CPU_DISPATCH_H
#define CPU_DISPATCH_H

#include <stdint.h>
#include <stdbool.h>

typedef uint8_t (*BusReadFunc)(void *ctx, uint32_t address);
typedef void (*BusWriteFunc)(void *ctx, uint32_t address, uint8_t value);

typedef struct {
    // Accumulator (16-bit capable)
    uint16_t A;
    // Index registers (16-bit capable)
    uint16_t X;
    uint16_t Y;
    // Stack pointer
    uint16_t S;
    // Direct page register
    uint16_t D;
    // Data bank register
    uint8_t DBR;
    // Program bank register
    uint8_t PBR;
    // Program counter
    uint16_t PC;
    // Processor status
    uint8_t P;
    // Emulation mode flag
    bool emulationMode;
    // Cycle count for last instruction
    int cycles;
    // Stopped / waiting
    bool stopped;
    bool waiting;
    // IRQ/NMI pending
    bool nmiPending;
    bool irqPending;
} CPURegisters;

// Status register bits
#define FLAG_C 0x01  // Carry
#define FLAG_Z 0x02  // Zero
#define FLAG_I 0x04  // IRQ disable
#define FLAG_D 0x08  // Decimal
#define FLAG_X 0x10  // Index 8-bit (native) / Break (emulation)
#define FLAG_M 0x20  // Accumulator 8-bit (native) / Unused (emulation)
#define FLAG_V 0x40  // Overflow
#define FLAG_N 0x80  // Negative

// Initialize the dispatch table
void cpu_dispatch_init(void);

// Execute one instruction, return number of CPU cycles consumed
int cpu_step(CPURegisters *regs, BusReadFunc bus_read, BusWriteFunc bus_write, void *ctx);

// Reset CPU to initial state
void cpu_reset(CPURegisters *regs, BusReadFunc bus_read, void *ctx);

#endif
