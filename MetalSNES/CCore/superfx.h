#ifndef METALSNES_SUPERFX_H
#define METALSNES_SUPERFX_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void *ms_superfx_create(
    const uint8_t *rom,
    size_t rom_size,
    uint8_t *ram,
    size_t ram_size
);

void ms_superfx_destroy(void *superfx);
void ms_superfx_run(void *superfx, uint32_t master_cycles);

uint8_t ms_superfx_read_io(void *superfx, uint16_t addr, uint8_t default_data);
void ms_superfx_write_io(void *superfx, uint16_t addr, uint8_t data);

uint8_t ms_superfx_cpu_read_rom(void *superfx, uint32_t addr, uint8_t default_data);
uint8_t ms_superfx_cpu_read_ram(void *superfx, uint32_t addr, uint8_t default_data);
void ms_superfx_cpu_write_ram(void *superfx, uint32_t addr, uint8_t data);

bool ms_superfx_irq_active(void *superfx);

uint32_t ms_superfx_state_size(void);
bool ms_superfx_save_state(void *superfx, uint8_t *buffer, uint32_t size);
bool ms_superfx_load_state(void *superfx, const uint8_t *buffer, uint32_t size);

uint16_t ms_superfx_get_reg(void *superfx, uint32_t index);
uint16_t ms_superfx_get_sfr(void *superfx);
uint8_t ms_superfx_get_pbr(void *superfx);
uint8_t ms_superfx_get_rombr(void *superfx);
uint8_t ms_superfx_get_rambr(void *superfx);
uint16_t ms_superfx_get_cbr(void *superfx);
uint8_t ms_superfx_get_scbr(void *superfx);
uint8_t ms_superfx_get_scmr(void *superfx);
uint8_t ms_superfx_get_colr(void *superfx);
uint8_t ms_superfx_get_por(void *superfx);
uint8_t ms_superfx_get_vcr(void *superfx);
uint8_t ms_superfx_get_cfgr(void *superfx);
uint8_t ms_superfx_get_clsr(void *superfx);
uint8_t ms_superfx_get_pipeline(void *superfx);
uint16_t ms_superfx_get_ramaddr(void *superfx);
uint32_t ms_superfx_get_romcl(void *superfx);
uint8_t ms_superfx_get_romdr(void *superfx);
uint32_t ms_superfx_get_ramcl(void *superfx);
uint16_t ms_superfx_get_ramar(void *superfx);
uint8_t ms_superfx_get_ramdr(void *superfx);
uint32_t ms_superfx_get_trace_count(void *superfx);
uint8_t ms_superfx_get_trace_pbr(void *superfx, uint32_t index);
uint8_t ms_superfx_get_trace_rombr(void *superfx, uint32_t index);
uint8_t ms_superfx_get_trace_opcode(void *superfx, uint32_t index);
uint16_t ms_superfx_get_trace_r12(void *superfx, uint32_t index);
uint16_t ms_superfx_get_trace_r13(void *superfx, uint32_t index);
uint16_t ms_superfx_get_trace_r14(void *superfx, uint32_t index);
uint16_t ms_superfx_get_trace_r15(void *superfx, uint32_t index);
uint16_t ms_superfx_get_trace_sfr(void *superfx, uint32_t index);

#ifdef __cplusplus
}
#endif

#endif
