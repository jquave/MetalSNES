// Adapted from the bsnes GSU / Super FX implementation for local integration.

#include "superfx.h"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <new>
#include <type_traits>
#include <vector>

namespace {

using uint = unsigned int;
using int8 = int8_t;
using int16 = int16_t;
using int32 = int32_t;
using uint8 = uint8_t;
using uint16 = uint16_t;
using uint32 = uint32_t;
using uint64 = uint64_t;

template<int...> struct BitField;
template<int Precision, int Index> struct BitField<Precision, Index> {
  static_assert(Precision >= 1 && Precision <= 64);
  using type =
    std::conditional_t<Precision <= 8, uint8_t,
    std::conditional_t<Precision <= 16, uint16_t,
    std::conditional_t<Precision <= 32, uint32_t,
    uint64_t>>>;

  static constexpr uint shift = Index < 0 ? Precision + Index : Index;
  static constexpr type mask = static_cast<type>(type(1) << shift);

  BitField(const BitField&) = delete;

  template<typename T>
  explicit BitField(T* source) : target(reinterpret_cast<type&>(*source)) {
    static_assert(sizeof(T) == sizeof(type));
  }

  operator bool() const {
    return (target & mask) != 0;
  }

  auto& operator=(bool source) {
    target = static_cast<type>((target & ~mask) | (source ? mask : 0));
    return *this;
  }

private:
  type& target;
};

template<int...> struct BitRange;
template<int Precision, int Lo, int Hi> struct BitRange<Precision, Lo, Hi> {
  static_assert(Precision >= 1 && Precision <= 64);
  using type =
    std::conditional_t<Precision <= 8, uint8_t,
    std::conditional_t<Precision <= 16, uint16_t,
    std::conditional_t<Precision <= 32, uint32_t,
    uint64_t>>>;

  static constexpr uint lo = Lo < 0 ? Precision + Lo : Lo;
  static constexpr uint hi = Hi < 0 ? Precision + Hi : Hi;
  static constexpr uint shift = lo;
  static constexpr type mask = static_cast<type>(((uint64(1) << (hi - lo + 1)) - 1) << lo);

  BitRange(const BitRange&) = delete;

  template<typename T>
  explicit BitRange(T* source) : target(reinterpret_cast<type&>(*source)) {
    static_assert(sizeof(T) == sizeof(type));
  }

  operator type() const {
    return static_cast<type>((target & mask) >> shift);
  }

  template<typename T>
  auto& operator=(const T& source) {
    const type value = static_cast<type>(source);
    target = static_cast<type>((target & ~mask) | ((value << shift) & mask));
    return *this;
  }

private:
  type& target;
};

struct Range {
  struct Iterator {
    uint value;

    auto operator*() const -> uint { return value; }
    auto operator++() -> Iterator& { ++value; return *this; }
    auto operator!=(const Iterator& other) const -> bool { return value != other.value; }
  };

  uint size;

  auto begin() const -> Iterator { return {0}; }
  auto end() const -> Iterator { return {size}; }
};

inline auto range(uint size) -> Range {
  return {size};
}

static constexpr uint32 kSuperFXTraceCapacity = 2048;

struct PersistedTraceEntry {
  uint8 pbr = 0;
  uint8 rombr = 0;
  uint8 opcode = 0;
  uint16 r12 = 0;
  uint16 r13 = 0;
  uint16 r14 = 0;
  uint16 r15 = 0;
  uint16 sfr = 0;
};

struct PersistedState {
  uint8 pipeline = 0;
  uint16 ramaddr = 0;
  uint16 regs[16]{};
  uint8 regModified[16]{};
  uint16 sfr = 0;
  uint8 pbr = 0;
  uint8 rombr = 0;
  uint8 rambr = 0;
  uint16 cbr = 0;
  uint8 scbr = 0;
  uint8 scmr = 0;
  uint8 colr = 0;
  uint8 por = 0;
  uint8 bramr = 0;
  uint8 vcr = 0;
  uint8 cfgr = 0;
  uint8 clsr = 0;
  uint32 romcl = 0;
  uint8 romdr = 0;
  uint32 ramcl = 0;
  uint16 ramar = 0;
  uint8 ramdr = 0;
  uint8 sreg = 0;
  uint8 dreg = 0;
  uint8 cacheBuffer[512]{};
  uint8 cacheValid[32]{};
  uint16 pixelcacheOffset[2]{};
  uint8 pixelcacheBitpend[2]{};
  uint8 pixelcacheData[2][8]{};
  PersistedTraceEntry trace[kSuperFXTraceCapacity]{};
  uint32 traceHead = 0;
  uint32 traceCount = 0;
  int64_t cycleBudget = 0;
  uint8 irqLine = 0;
};

class SuperFXCore {
public:
  SuperFXCore(const uint8* romData, size_t romSize, uint8* ramData, size_t ramSize)
  : rom(romData, romData + romSize), ram(ramData), ramSize(ramSize) {
    romMask = rom.empty() ? 0u : static_cast<uint>(rom.size() - 1);
    ramMask = ramSize == 0 ? 0u : static_cast<uint>(ramSize - 1);
    power();
  }

  auto run(uint32 masterCycles) -> void {
    cycleBudget += static_cast<int64_t>(masterCycles);
    while(cycleBudget > 0) {
      main();
    }
  }

  auto cpuReadIO(uint16 addr, uint8 data) -> uint8 {
    return readIO(addr, data);
  }

  auto cpuWriteIO(uint16 addr, uint8 data) -> void {
    writeIO(addr, data);
  }

  auto cpuReadROM(uint32 addr, uint8 data) -> uint8 {
    if(regs.sfr.g && regs.scmr.ron) {
      static const uint8 vector[16] = {
        0x00, 0x01, 0x00, 0x01, 0x04, 0x01, 0x00, 0x01,
        0x00, 0x01, 0x08, 0x01, 0x00, 0x01, 0x0c, 0x01,
      };
      return vector[addr & 15];
    }
    return romRead(addr, data);
  }

  auto cpuReadRAM(uint32 addr, uint8 data) -> uint8 {
    if(regs.sfr.g && regs.scmr.ran) return data;
    return ramRead(addr);
  }

  auto cpuWriteRAM(uint32 addr, uint8 data) -> void {
    ramWrite(addr, data);
  }

  auto irqActive() const -> bool {
    return irqLine;
  }

  struct DebugState {
    uint16 r[16]{};
    uint16 sfr = 0;
    uint8 pbr = 0;
    uint8 rombr = 0;
    uint8 rambr = 0;
    uint16 cbr = 0;
    uint8 scbr = 0;
    uint8 scmr = 0;
    uint8 colr = 0;
    uint8 por = 0;
    uint8 vcr = 0;
    uint8 cfgr = 0;
    uint8 clsr = 0;
    uint8 pipeline = 0;
    uint16 ramaddr = 0;
    uint32 romcl = 0;
    uint8 romdr = 0;
    uint32 ramcl = 0;
    uint16 ramar = 0;
    uint8 ramdr = 0;
  };

  struct TraceEntry {
    uint8 pbr = 0;
    uint8 rombr = 0;
    uint8 opcode = 0;
    uint16 r12 = 0;
    uint16 r13 = 0;
    uint16 r14 = 0;
    uint16 r15 = 0;
    uint16 sfr = 0;
  };

  auto debugState() const -> DebugState {
    DebugState state;
    for(uint index : range(16)) {
      state.r[index] = regs.r[index].data;
    }
    state.sfr = static_cast<uint16>(static_cast<uint>(regs.sfr));
    state.pbr = regs.pbr;
    state.rombr = regs.rombr;
    state.rambr = static_cast<uint8>(regs.rambr ? 1 : 0);
    state.cbr = regs.cbr;
    state.scbr = regs.scbr;
    state.scmr = static_cast<uint8>(static_cast<uint>(regs.scmr));
    state.colr = regs.colr;
    state.por = static_cast<uint8>(static_cast<uint>(regs.por));
    state.vcr = regs.vcr;
    state.cfgr = static_cast<uint8>(static_cast<uint>(regs.cfgr));
    state.clsr = static_cast<uint8>(regs.clsr ? 1 : 0);
    state.pipeline = regs.pipeline;
    state.ramaddr = regs.ramaddr;
    state.romcl = static_cast<uint32>(regs.romcl);
    state.romdr = regs.romdr;
    state.ramcl = static_cast<uint32>(regs.ramcl);
    state.ramar = regs.ramar;
    state.ramdr = regs.ramdr;
    return state;
  }

  auto traceSize() const -> uint32 {
    return traceCount;
  }

  auto traceEntry(uint32 index) const -> TraceEntry {
    if(index >= traceCount) return {};
    uint32 start = traceCount == traceCapacity ? traceHead : 0;
    uint32 slot = (start + index) % traceCapacity;
    return trace[slot];
  }

  auto persistedState() const -> PersistedState;
  auto loadPersistedState(const PersistedState& state) -> void;

private:
  struct Register {
    uint16 data = 0;
    bool modified = false;

    operator uint() const {
      return data;
    }

    auto assign(uint value) -> uint16 {
      modified = true;
      data = static_cast<uint16>(value);
      return data;
    }

    auto operator++() -> uint16 { return assign(data + 1); }
    auto operator--() -> uint16 { return assign(data - 1); }
    auto operator++(int) -> uint { uint r = data; assign(data + 1); return r; }
    auto operator--(int) -> uint { uint r = data; assign(data - 1); return r; }
    auto operator=(uint value) -> uint16 { return assign(value); }
    auto operator|=(uint value) -> uint16 { return assign(data | value); }
    auto operator^=(uint value) -> uint16 { return assign(data ^ value); }
    auto operator&=(uint value) -> uint16 { return assign(data & value); }
    auto operator<<=(uint value) -> uint16 { return assign(data << value); }
    auto operator>>=(uint value) -> uint16 { return assign(data >> value); }
    auto operator+=(uint value) -> uint16 { return assign(data + value); }
    auto operator-=(uint value) -> uint16 { return assign(data - value); }
    auto operator*=(uint value) -> uint16 { return assign(data * value); }
    auto operator/=(uint value) -> uint16 { return assign(data / value); }
    auto operator%=(uint value) -> uint16 { return assign(data % value); }

    auto operator=(const Register& value) -> uint16 {
      return assign(value.data);
    }
  };

  struct SFR {
    uint16 data = 0;

    BitField<16, 1> z{&data};
    BitField<16, 2> cy{&data};
    BitField<16, 3> s{&data};
    BitField<16, 4> ov{&data};
    BitField<16, 5> g{&data};
    BitField<16, 6> r{&data};
    BitField<16, 8> alt1{&data};
    BitField<16, 9> alt2{&data};
    BitField<16,10> il{&data};
    BitField<16,11> ih{&data};
    BitField<16,12> b{&data};
    BitField<16,15> irq{&data};

    BitRange<16,8,9> alt{&data};

    operator uint() const {
      return data & 0x9f7e;
    }

    auto& operator=(uint value) {
      data = static_cast<uint16>(value);
      return *this;
    }
  };

  struct SCMR {
    uint ht = 0;
    bool ron = false;
    bool ran = false;
    uint md = 0;

    operator uint() const {
      return ((ht >> 1) << 5) | (static_cast<uint>(ron) << 4) | (static_cast<uint>(ran) << 3) | ((ht & 1) << 2) | md;
    }

    auto& operator=(uint data) {
      ht  = ((data & 0x20) ? 1u : 0u) << 1;
      ht |= ((data & 0x04) ? 1u : 0u) << 0;
      ron = (data & 0x10) != 0;
      ran = (data & 0x08) != 0;
      md  = data & 0x03;
      return *this;
    }
  };

  struct POR {
    bool obj = false;
    bool freezehigh = false;
    bool highnibble = false;
    bool dither = false;
    bool transparent = false;

    operator uint() const {
      return (static_cast<uint>(obj) << 4)
        | (static_cast<uint>(freezehigh) << 3)
        | (static_cast<uint>(highnibble) << 2)
        | (static_cast<uint>(dither) << 1)
        | static_cast<uint>(transparent);
    }

    auto& operator=(uint data) {
      obj         = (data & 0x10) != 0;
      freezehigh  = (data & 0x08) != 0;
      highnibble  = (data & 0x04) != 0;
      dither      = (data & 0x02) != 0;
      transparent = (data & 0x01) != 0;
      return *this;
    }
  };

  struct CFGR {
    bool irq = false;
    bool ms0 = false;

    operator uint() const {
      return (static_cast<uint>(irq) << 7) | (static_cast<uint>(ms0) << 5);
    }

    auto& operator=(uint data) {
      irq = (data & 0x80) != 0;
      ms0 = (data & 0x20) != 0;
      return *this;
    }
  };

  struct Registers {
    uint8 pipeline = 0;
    uint16 ramaddr = 0;

    Register r[16];
    SFR sfr;
    uint8 pbr = 0;
    uint8 rombr = 0;
    bool rambr = false;
    uint16 cbr = 0;
    uint8 scbr = 0;
    SCMR scmr;
    uint8 colr = 0;
    POR por;
    bool bramr = false;
    uint8 vcr = 0;
    CFGR cfgr;
    bool clsr = false;

    uint romcl = 0;
    uint8 romdr = 0;

    uint ramcl = 0;
    uint16 ramar = 0;
    uint8 ramdr = 0;

    uint sreg = 0;
    uint dreg = 0;

    auto& sr() { return r[sreg]; }
    auto& dr() { return r[dreg]; }

    auto reset() -> void {
      sfr.b = 0;
      sfr.alt1 = 0;
      sfr.alt2 = 0;
      sreg = 0;
      dreg = 0;
    }
  } regs;

  struct Cache {
    uint8 buffer[512]{};
    bool valid[32]{};
  } cache;

  struct PixelCache {
    uint16 offset = 0;
    uint8 bitpend = 0;
    uint8 data[8]{};
  } pixelcache[2];

  std::vector<uint8> rom;
  uint8* ram = nullptr;
  size_t ramSize = 0;
  uint romMask = 0;
  uint ramMask = 0;
  static constexpr uint32 traceCapacity = kSuperFXTraceCapacity;
  std::array<TraceEntry, traceCapacity> trace{};
  uint32 traceHead = 0;
  uint32 traceCount = 0;
  int64_t cycleBudget = 0;
  bool irqLine = false;

  auto romRead(uint32 addr, uint8 data = 0x00) const -> uint8 {
    return rom.empty() ? data : rom[addr & romMask];
  }

  auto ramRead(uint32 addr) const -> uint8 {
    return (!ram || ramSize == 0) ? 0x00 : ram[addr & ramMask];
  }

  auto ramWrite(uint32 addr, uint8 data) -> void {
    if(ram && ramSize != 0) {
      ram[addr & ramMask] = data;
    }
  }

  auto power() -> void;
  auto main() -> void;

  auto step(uint clocks) -> void;
  auto stop() -> void;
  auto recordTrace(uint8 opcode) -> void;
  auto color(uint8 source) -> uint8;
  auto plot(uint8 x, uint8 y) -> void;
  auto rpix(uint8 x, uint8 y) -> uint8;
  auto flushPixelCache(PixelCache& cacheEntry) -> void;

  auto read(uint addr, uint8 data = 0x00) -> uint8;
  auto write(uint addr, uint8 data) -> void;
  auto readOpcode(uint16 addr) -> uint8;
  auto peekpipe() -> uint8;
  auto pipe() -> uint8;

  auto flushCache() -> void;
  auto readCache(uint16 addr) -> uint8;
  auto writeCache(uint16 addr, uint8 data) -> void;

  auto readIO(uint addr, uint8 data) -> uint8;
  auto writeIO(uint addr, uint8 data) -> void;

  auto syncROMBuffer() -> void;
  auto readROMBuffer() -> uint8;
  auto updateROMBuffer() -> void;
  auto syncRAMBuffer() -> void;
  auto readRAMBuffer(uint16 addr) -> uint8;
  auto writeRAMBuffer(uint16 addr, uint8 data) -> void;

  auto instruction(uint8 opcode) -> void;
  auto instructionADD_ADC(uint n) -> void;
  auto instructionALT1() -> void;
  auto instructionALT2() -> void;
  auto instructionALT3() -> void;
  auto instructionAND_BIC(uint n) -> void;
  auto instructionASR_DIV2() -> void;
  auto instructionBranch(bool c) -> void;
  auto instructionCACHE() -> void;
  auto instructionCOLOR_CMODE() -> void;
  auto instructionDEC(uint n) -> void;
  auto instructionFMULT_LMULT() -> void;
  auto instructionFROM_MOVES(uint n) -> void;
  auto instructionGETB() -> void;
  auto instructionGETC_RAMB_ROMB() -> void;
  auto instructionHIB() -> void;
  auto instructionIBT_LMS_SMS(uint n) -> void;
  auto instructionINC(uint n) -> void;
  auto instructionIWT_LM_SM(uint n) -> void;
  auto instructionJMP_LJMP(uint n) -> void;
  auto instructionLINK(uint n) -> void;
  auto instructionLoad(uint n) -> void;
  auto instructionLOB() -> void;
  auto instructionLOOP() -> void;
  auto instructionLSR() -> void;
  auto instructionMERGE() -> void;
  auto instructionMULT_UMULT(uint n) -> void;
  auto instructionNOP() -> void;
  auto instructionNOT() -> void;
  auto instructionOR_XOR(uint n) -> void;
  auto instructionPLOT_RPIX() -> void;
  auto instructionROL() -> void;
  auto instructionROR() -> void;
  auto instructionSBK() -> void;
  auto instructionSEX() -> void;
  auto instructionStore(uint n) -> void;
  auto instructionSTOP() -> void;
  auto instructionSUB_SBC_CMP(uint n) -> void;
  auto instructionSWAP() -> void;
  auto instructionTO_MOVE(uint n) -> void;
  auto instructionWITH(uint n) -> void;
};

auto SuperFXCore::power() -> void {
  for(auto& reg : regs.r) {
    reg.data = 0x0000;
    reg.modified = false;
  }

  regs.sfr      = 0x0000;
  regs.pbr      = 0x00;
  regs.rombr    = 0x00;
  regs.rambr    = 0;
  regs.cbr      = 0x0000;
  regs.scbr     = 0x00;
  regs.scmr     = 0x00;
  regs.colr     = 0x00;
  regs.por      = 0x00;
  regs.bramr    = 0;
  regs.vcr      = 0x04;
  regs.cfgr     = 0x00;
  regs.clsr     = 0;
  regs.pipeline = 0x01;
  regs.ramaddr  = 0x0000;
  regs.reset();

  for(uint n : range(512)) cache.buffer[n] = 0x00;
  for(uint n : range(32)) cache.valid[n] = false;
  for(uint n : range(2)) {
    pixelcache[n].offset = 0xffff;
    pixelcache[n].bitpend = 0x00;
    std::fill(std::begin(pixelcache[n].data), std::end(pixelcache[n].data), 0);
  }

  regs.romcl = 0;
  regs.romdr = 0;
  regs.ramcl = 0;
  regs.ramar = 0;
  regs.ramdr = 0;
  traceHead = 0;
  traceCount = 0;
  cycleBudget = 0;
  irqLine = false;
}

auto SuperFXCore::main() -> void {
  if(regs.sfr.g == 0) {
    return step(6);
  }

  uint8 opcode = peekpipe();
  recordTrace(opcode);
  instruction(opcode);

  if(regs.r[14].modified) {
    regs.r[14].modified = false;
    updateROMBuffer();
  }

  if(regs.r[15].modified) {
    regs.r[15].modified = false;
  } else {
    regs.r[15]++;
  }
}

auto SuperFXCore::step(uint clocks) -> void {
  if(regs.romcl) {
    regs.romcl -= std::min<uint>(clocks, regs.romcl);
    if(regs.romcl == 0) {
      regs.sfr.r = 0;
      regs.romdr = read((static_cast<uint>(regs.rombr) << 16) + regs.r[14]);
    }
  }

  if(regs.ramcl) {
    regs.ramcl -= std::min<uint>(clocks, regs.ramcl);
    if(regs.ramcl == 0) {
      write(0x700000 + (static_cast<uint>(regs.rambr) << 16) + regs.ramar, regs.ramdr);
    }
  }

  cycleBudget -= static_cast<int64_t>(clocks);
}

auto SuperFXCore::stop() -> void {
  irqLine = true;
}

auto SuperFXCore::recordTrace(uint8 opcode) -> void {
  trace[traceHead] = TraceEntry{
    .pbr = regs.pbr,
    .rombr = regs.rombr,
    .opcode = opcode,
    .r12 = regs.r[12].data,
    .r13 = regs.r[13].data,
    .r14 = regs.r[14].data,
    .r15 = regs.r[15].data,
    .sfr = regs.sfr.data
  };
  traceHead = (traceHead + 1) % traceCapacity;
  if(traceCount < traceCapacity) traceCount++;
}

auto SuperFXCore::persistedState() const -> PersistedState {
  PersistedState state;
  state.pipeline = regs.pipeline;
  state.ramaddr = regs.ramaddr;
  for(uint index : range(16)) {
    state.regs[index] = regs.r[index].data;
    state.regModified[index] = regs.r[index].modified ? 1 : 0;
  }
  state.sfr = regs.sfr.data;
  state.pbr = regs.pbr;
  state.rombr = regs.rombr;
  state.rambr = regs.rambr ? 1 : 0;
  state.cbr = regs.cbr;
  state.scbr = regs.scbr;
  state.scmr = static_cast<uint8>(static_cast<uint>(regs.scmr));
  state.colr = regs.colr;
  state.por = static_cast<uint8>(static_cast<uint>(regs.por));
  state.bramr = regs.bramr ? 1 : 0;
  state.vcr = regs.vcr;
  state.cfgr = static_cast<uint8>(static_cast<uint>(regs.cfgr));
  state.clsr = regs.clsr ? 1 : 0;
  state.romcl = static_cast<uint32>(regs.romcl);
  state.romdr = regs.romdr;
  state.ramcl = static_cast<uint32>(regs.ramcl);
  state.ramar = regs.ramar;
  state.ramdr = regs.ramdr;
  state.sreg = static_cast<uint8>(regs.sreg);
  state.dreg = static_cast<uint8>(regs.dreg);
  std::memcpy(state.cacheBuffer, cache.buffer, sizeof(cache.buffer));
  for(uint index : range(32)) {
    state.cacheValid[index] = cache.valid[index] ? 1 : 0;
  }
  for(uint index : range(2)) {
    state.pixelcacheOffset[index] = pixelcache[index].offset;
    state.pixelcacheBitpend[index] = pixelcache[index].bitpend;
    std::memcpy(state.pixelcacheData[index], pixelcache[index].data, sizeof(pixelcache[index].data));
  }
  for(uint index : range(traceCapacity)) {
    state.trace[index] = PersistedTraceEntry{
      .pbr = trace[index].pbr,
      .rombr = trace[index].rombr,
      .opcode = trace[index].opcode,
      .r12 = trace[index].r12,
      .r13 = trace[index].r13,
      .r14 = trace[index].r14,
      .r15 = trace[index].r15,
      .sfr = trace[index].sfr
    };
  }
  state.traceHead = traceHead;
  state.traceCount = traceCount;
  state.cycleBudget = cycleBudget;
  state.irqLine = irqLine ? 1 : 0;
  return state;
}

auto SuperFXCore::loadPersistedState(const PersistedState& state) -> void {
  regs.pipeline = state.pipeline;
  regs.ramaddr = state.ramaddr;
  for(uint index : range(16)) {
    regs.r[index].data = state.regs[index];
    regs.r[index].modified = state.regModified[index] != 0;
  }
  regs.sfr.data = state.sfr;
  regs.pbr = state.pbr;
  regs.rombr = state.rombr;
  regs.rambr = state.rambr != 0;
  regs.cbr = state.cbr;
  regs.scbr = state.scbr;
  regs.scmr = state.scmr;
  regs.colr = state.colr;
  regs.por = state.por;
  regs.bramr = state.bramr != 0;
  regs.vcr = state.vcr;
  regs.cfgr = state.cfgr;
  regs.clsr = state.clsr != 0;
  regs.romcl = state.romcl;
  regs.romdr = state.romdr;
  regs.ramcl = state.ramcl;
  regs.ramar = state.ramar;
  regs.ramdr = state.ramdr;
  regs.sreg = state.sreg & 0x0f;
  regs.dreg = state.dreg & 0x0f;
  std::memcpy(cache.buffer, state.cacheBuffer, sizeof(cache.buffer));
  for(uint index : range(32)) {
    cache.valid[index] = state.cacheValid[index] != 0;
  }
  for(uint index : range(2)) {
    pixelcache[index].offset = state.pixelcacheOffset[index];
    pixelcache[index].bitpend = state.pixelcacheBitpend[index];
    std::memcpy(pixelcache[index].data, state.pixelcacheData[index], sizeof(pixelcache[index].data));
  }
  for(uint index : range(traceCapacity)) {
    trace[index] = TraceEntry{
      .pbr = state.trace[index].pbr,
      .rombr = state.trace[index].rombr,
      .opcode = state.trace[index].opcode,
      .r12 = state.trace[index].r12,
      .r13 = state.trace[index].r13,
      .r14 = state.trace[index].r14,
      .r15 = state.trace[index].r15,
      .sfr = state.trace[index].sfr
    };
  }
  traceHead = state.traceHead % traceCapacity;
  traceCount = std::min<uint32>(state.traceCount, traceCapacity);
  cycleBudget = state.cycleBudget;
  irqLine = state.irqLine != 0;
}

auto SuperFXCore::color(uint8 source) -> uint8 {
  if(regs.por.highnibble) return static_cast<uint8>((regs.colr & 0xf0) | (source >> 4));
  if(regs.por.freezehigh) return static_cast<uint8>((regs.colr & 0xf0) | (source & 0x0f));
  return source;
}

auto SuperFXCore::plot(uint8 x, uint8 y) -> void {
  if(!regs.por.transparent) {
    if(regs.scmr.md == 3) {
      if(regs.por.freezehigh) {
        if((regs.colr & 0x0f) == 0) return;
      } else {
        if(regs.colr == 0) return;
      }
    } else {
      if((regs.colr & 0x0f) == 0) return;
    }
  }

  uint8 colorValue = regs.colr;
  if(regs.por.dither && regs.scmr.md != 3) {
    if((x ^ y) & 1) colorValue >>= 4;
    colorValue &= 0x0f;
  }

  uint16 offset = static_cast<uint16>((y << 5) + (x >> 3));
  if(offset != pixelcache[0].offset) {
    flushPixelCache(pixelcache[1]);
    pixelcache[1] = pixelcache[0];
    pixelcache[0].bitpend = 0x00;
    pixelcache[0].offset = offset;
  }

  x = static_cast<uint8>((x & 7) ^ 7);
  pixelcache[0].data[x] = colorValue;
  pixelcache[0].bitpend |= static_cast<uint8>(1u << x);
  if(pixelcache[0].bitpend == 0xff) {
    flushPixelCache(pixelcache[1]);
    pixelcache[1] = pixelcache[0];
    pixelcache[0].bitpend = 0x00;
  }
}

auto SuperFXCore::rpix(uint8 x, uint8 y) -> uint8 {
  flushPixelCache(pixelcache[1]);
  flushPixelCache(pixelcache[0]);

  uint cn = 0;
  switch(regs.por.obj ? 3 : regs.scmr.ht) {
  case 0: cn = ((x & 0xf8) << 1) + ((y & 0xf8) >> 3); break;
  case 1: cn = ((x & 0xf8) << 1) + ((x & 0xf8) >> 1) + ((y & 0xf8) >> 3); break;
  case 2: cn = ((x & 0xf8) << 1) + ((x & 0xf8) << 0) + ((y & 0xf8) >> 3); break;
  case 3: cn = ((y & 0x80) << 2) + ((x & 0x80) << 1) + ((y & 0x78) << 1) + ((x & 0x78) >> 3); break;
  }

  uint bpp = 2u << (regs.scmr.md - (regs.scmr.md >> 1));
  uint addr = 0x700000 + (cn * (bpp << 3)) + (static_cast<uint>(regs.scbr) << 10) + ((y & 0x07) * 2);
  uint8 data = 0x00;
  x = static_cast<uint8>((x & 7) ^ 7);

  for(uint n : range(bpp)) {
    uint byte = ((n >> 1) << 4) + (n & 1);
    step(regs.clsr ? 5 : 6);
    data |= static_cast<uint8>(((read(addr + byte) >> x) & 1) << n);
  }

  return data;
}

auto SuperFXCore::flushPixelCache(PixelCache& cacheEntry) -> void {
  if(cacheEntry.bitpend == 0x00) return;

  uint8 x = static_cast<uint8>(cacheEntry.offset << 3);
  uint8 y = static_cast<uint8>(cacheEntry.offset >> 5);

  uint cn = 0;
  switch(regs.por.obj ? 3 : regs.scmr.ht) {
  case 0: cn = ((x & 0xf8) << 1) + ((y & 0xf8) >> 3); break;
  case 1: cn = ((x & 0xf8) << 1) + ((x & 0xf8) >> 1) + ((y & 0xf8) >> 3); break;
  case 2: cn = ((x & 0xf8) << 1) + ((x & 0xf8) << 0) + ((y & 0xf8) >> 3); break;
  case 3: cn = ((y & 0x80) << 2) + ((x & 0x80) << 1) + ((y & 0x78) << 1) + ((x & 0x78) >> 3); break;
  }

  uint bpp = 2u << (regs.scmr.md - (regs.scmr.md >> 1));
  uint addr = 0x700000 + (cn * (bpp << 3)) + (static_cast<uint>(regs.scbr) << 10) + ((y & 0x07) * 2);

  for(uint n : range(bpp)) {
    uint byte = ((n >> 1) << 4) + (n & 1);
    uint8 data = 0x00;
    for(uint px : range(8)) {
      data |= static_cast<uint8>(((cacheEntry.data[px] >> n) & 1) << px);
    }
    if(cacheEntry.bitpend != 0xff) {
      step(regs.clsr ? 5 : 6);
      data &= cacheEntry.bitpend;
      data |= static_cast<uint8>(read(addr + byte) & ~cacheEntry.bitpend);
    }
    step(regs.clsr ? 5 : 6);
    write(addr + byte, data);
  }

  cacheEntry.bitpend = 0x00;
}

auto SuperFXCore::read(uint addr, uint8 data) -> uint8 {
  if((addr & 0xc00000) == 0x000000) {
    return romRead((((addr & 0x3f0000) >> 1) | (addr & 0x7fff)) & romMask, data);
  }

  if((addr & 0xe00000) == 0x400000) {
    return romRead(addr & romMask, data);
  }

  if((addr & 0xe00000) == 0x600000) {
    return ramRead(addr & ramMask);
  }

  return data;
}

auto SuperFXCore::write(uint addr, uint8 data) -> void {
  if((addr & 0xe00000) == 0x600000) {
    ramWrite(addr & ramMask, data);
  }
}

auto SuperFXCore::readOpcode(uint16 addr) -> uint8 {
  uint16 offset = static_cast<uint16>(addr - regs.cbr);
  if(offset < 512) {
    if(cache.valid[offset >> 4] == false) {
      uint dp = offset & 0xfff0;
      uint sp = (static_cast<uint>(regs.pbr) << 16) + ((regs.cbr + dp) & 0xfff0);
      for(uint n : range(16)) {
        (void)n;
        step(regs.clsr ? 5 : 6);
        cache.buffer[dp++] = read(sp++);
      }
      cache.valid[offset >> 4] = true;
    } else {
      step(regs.clsr ? 1 : 2);
    }
    return cache.buffer[offset];
  }

  if(regs.pbr <= 0x5f) {
    syncROMBuffer();
    step(regs.clsr ? 5 : 6);
    return read((static_cast<uint>(regs.pbr) << 16) | addr);
  }

  syncRAMBuffer();
  step(regs.clsr ? 5 : 6);
  return read((static_cast<uint>(regs.pbr) << 16) | addr);
}

auto SuperFXCore::peekpipe() -> uint8 {
  uint8 result = regs.pipeline;
  regs.pipeline = readOpcode(regs.r[15]);
  regs.r[15].modified = false;
  return result;
}

auto SuperFXCore::pipe() -> uint8 {
  uint8 result = regs.pipeline;
  regs.pipeline = readOpcode(++regs.r[15]);
  regs.r[15].modified = false;
  return result;
}

auto SuperFXCore::flushCache() -> void {
  for(uint n : range(32)) cache.valid[n] = false;
}

auto SuperFXCore::readCache(uint16 addr) -> uint8 {
  addr = static_cast<uint16>((addr + regs.cbr) & 511);
  return cache.buffer[addr];
}

auto SuperFXCore::writeCache(uint16 addr, uint8 data) -> void {
  addr = static_cast<uint16>((addr + regs.cbr) & 511);
  cache.buffer[addr] = data;
  if((addr & 15) == 15) cache.valid[addr >> 4] = true;
}

auto SuperFXCore::readIO(uint addr, uint8) -> uint8 {
  addr = 0x3000 | (addr & 0x3ff);

  if(addr >= 0x3100 && addr <= 0x32ff) {
    return readCache(static_cast<uint16>(addr - 0x3100));
  }

  if(addr >= 0x3000 && addr <= 0x301f) {
    return static_cast<uint8>(regs.r[(addr >> 1) & 15] >> ((addr & 1) << 3));
  }

  switch(addr) {
  case 0x3030:
    return static_cast<uint8>(regs.sfr >> 0);

  case 0x3031: {
    uint8 r = static_cast<uint8>(regs.sfr >> 8);
    regs.sfr.irq = 0;
    irqLine = false;
    return r;
  }

  case 0x3034:
    return regs.pbr;

  case 0x3036:
    return regs.rombr;

  case 0x303b:
    return regs.vcr;

  case 0x303c:
    return static_cast<uint8>(regs.rambr);

  case 0x303e:
    return static_cast<uint8>(regs.cbr >> 0);

  case 0x303f:
    return static_cast<uint8>(regs.cbr >> 8);
  }

  return 0x00;
}

auto SuperFXCore::writeIO(uint addr, uint8 data) -> void {
  addr = 0x3000 | (addr & 0x3ff);

  if(addr >= 0x3100 && addr <= 0x32ff) {
    return writeCache(static_cast<uint16>(addr - 0x3100), data);
  }

  if(addr >= 0x3000 && addr <= 0x301f) {
    uint n = (addr >> 1) & 15;
    if((addr & 1) == 0) {
      regs.r[n] = (regs.r[n] & 0xff00) | data;
    } else {
      regs.r[n] = (static_cast<uint>(data) << 8) | (regs.r[n] & 0x00ff);
    }
    if(n == 14) updateROMBuffer();
    if(addr == 0x301f) regs.sfr.g = 1;
    return;
  }

  switch(addr) {
  case 0x3030: {
    bool g = regs.sfr.g;
    regs.sfr = (static_cast<uint>(regs.sfr) & 0xff00) | (static_cast<uint>(data) << 0);
    if(g == 1 && regs.sfr.g == 0) {
      regs.cbr = 0x0000;
      flushCache();
    }
  } break;

  case 0x3031:
    regs.sfr = (static_cast<uint>(data) << 8) | (static_cast<uint>(regs.sfr) & 0x00ff);
    break;

  case 0x3033:
    regs.bramr = (data & 0x01) != 0;
    break;

  case 0x3034:
    regs.pbr = data & 0x7f;
    flushCache();
    break;

  case 0x3037:
    regs.cfgr = data;
    break;

  case 0x3038:
    regs.scbr = data;
    break;

  case 0x3039:
    regs.clsr = (data & 0x01) != 0;
    break;

  case 0x303a:
    regs.scmr = data;
    break;
  }
}

auto SuperFXCore::syncROMBuffer() -> void {
  if(regs.romcl) step(regs.romcl);
}

auto SuperFXCore::readROMBuffer() -> uint8 {
  syncROMBuffer();
  return regs.romdr;
}

auto SuperFXCore::updateROMBuffer() -> void {
  regs.sfr.r = 1;
  regs.romcl = regs.clsr ? 5 : 6;
}

auto SuperFXCore::syncRAMBuffer() -> void {
  if(regs.ramcl) step(regs.ramcl);
}

auto SuperFXCore::readRAMBuffer(uint16 addr) -> uint8 {
  syncRAMBuffer();
  return read(0x700000 + (static_cast<uint>(regs.rambr) << 16) + addr);
}

auto SuperFXCore::writeRAMBuffer(uint16 addr, uint8 data) -> void {
  syncRAMBuffer();
  regs.ramcl = regs.clsr ? 5 : 6;
  regs.ramar = addr;
  regs.ramdr = data;
}

auto SuperFXCore::instructionSTOP() -> void {
  if(regs.cfgr.irq == 0) {
    regs.sfr.irq = 1;
    stop();
  }
  regs.sfr.g = 0;
  regs.pipeline = 0x01;
  regs.reset();
}

auto SuperFXCore::instructionNOP() -> void {
  regs.reset();
}

auto SuperFXCore::instructionCACHE() -> void {
  if(regs.cbr != (regs.r[15] & 0xfff0)) {
    regs.cbr = regs.r[15] & 0xfff0;
    flushCache();
  }
  regs.reset();
}

auto SuperFXCore::instructionLSR() -> void {
  regs.sfr.cy = (regs.sr() & 1) != 0;
  regs.dr() = regs.sr() >> 1;
  regs.sfr.s = (regs.dr() & 0x8000) != 0;
  regs.sfr.z = regs.dr() == 0;
  regs.reset();
}

auto SuperFXCore::instructionROL() -> void {
  bool carry = (regs.sr() & 0x8000) != 0;
  regs.dr() = (regs.sr() << 1) | static_cast<uint>(regs.sfr.cy);
  regs.sfr.s = (regs.dr() & 0x8000) != 0;
  regs.sfr.cy = carry;
  regs.sfr.z = regs.dr() == 0;
  regs.reset();
}

auto SuperFXCore::instructionBranch(bool take) -> void {
  int8 displacement = static_cast<int8>(pipe());
  if(take) regs.r[15] += displacement;
}

auto SuperFXCore::instructionTO_MOVE(uint n) -> void {
  if(!regs.sfr.b) {
    regs.dreg = n;
  } else {
    regs.r[n] = regs.sr();
    regs.reset();
  }
}

auto SuperFXCore::instructionWITH(uint n) -> void {
  regs.sreg = n;
  regs.dreg = n;
  regs.sfr.b = 1;
}

auto SuperFXCore::instructionStore(uint n) -> void {
  regs.ramaddr = regs.r[n];
  writeRAMBuffer(regs.ramaddr, regs.sr());
  if(!regs.sfr.alt1) writeRAMBuffer(regs.ramaddr ^ 1, regs.sr() >> 8);
  regs.reset();
}

auto SuperFXCore::instructionLOOP() -> void {
  regs.r[12]--;
  regs.sfr.s = (regs.r[12] & 0x8000) != 0;
  regs.sfr.z = regs.r[12] == 0;
  if(!regs.sfr.z) regs.r[15] = regs.r[13];
  regs.reset();
}

auto SuperFXCore::instructionALT1() -> void {
  regs.sfr.b = 0;
  regs.sfr.alt1 = 1;
}

auto SuperFXCore::instructionALT2() -> void {
  regs.sfr.b = 0;
  regs.sfr.alt2 = 1;
}

auto SuperFXCore::instructionALT3() -> void {
  regs.sfr.b = 0;
  regs.sfr.alt1 = 1;
  regs.sfr.alt2 = 1;
}

auto SuperFXCore::instructionLoad(uint n) -> void {
  regs.ramaddr = regs.r[n];
  regs.dr() = readRAMBuffer(regs.ramaddr);
  if(!regs.sfr.alt1) regs.dr() |= readRAMBuffer(regs.ramaddr ^ 1) << 8;
  regs.reset();
}

auto SuperFXCore::instructionPLOT_RPIX() -> void {
  if(!regs.sfr.alt1) {
    plot(regs.r[1], regs.r[2]);
    regs.r[1]++;
  } else {
    regs.dr() = rpix(regs.r[1], regs.r[2]);
    regs.sfr.s = (regs.dr() & 0x8000) != 0;
    regs.sfr.z = regs.dr() == 0;
  }
  regs.reset();
}

auto SuperFXCore::instructionSWAP() -> void {
  regs.dr() = (regs.sr() >> 8) | (regs.sr() << 8);
  regs.sfr.s = (regs.dr() & 0x8000) != 0;
  regs.sfr.z = regs.dr() == 0;
  regs.reset();
}

auto SuperFXCore::instructionCOLOR_CMODE() -> void {
  if(!regs.sfr.alt1) {
    regs.colr = color(regs.sr());
  } else {
    regs.por = regs.sr();
  }
  regs.reset();
}

auto SuperFXCore::instructionNOT() -> void {
  regs.dr() = ~regs.sr();
  regs.sfr.s = (regs.dr() & 0x8000) != 0;
  regs.sfr.z = regs.dr() == 0;
  regs.reset();
}

auto SuperFXCore::instructionADD_ADC(uint n) -> void {
  if(!regs.sfr.alt2) n = regs.r[n];
  int r = static_cast<int>(regs.sr()) + static_cast<int>(n) + (regs.sfr.alt1 ? 1 : 0) * (regs.sfr.cy ? 1 : 0);
  regs.sfr.ov = (~(regs.sr() ^ n) & (n ^ r) & 0x8000) != 0;
  regs.sfr.s  = (r & 0x8000) != 0;
  regs.sfr.cy = r >= 0x10000;
  regs.sfr.z  = static_cast<uint16>(r) == 0;
  regs.dr() = static_cast<uint>(r);
  regs.reset();
}

auto SuperFXCore::instructionSUB_SBC_CMP(uint n) -> void {
  if(!regs.sfr.alt2 || regs.sfr.alt1) n = regs.r[n];
  int r = static_cast<int>(regs.sr()) - static_cast<int>(n) - ((!regs.sfr.alt2 && regs.sfr.alt1) ? (regs.sfr.cy ? 0 : 1) : 0);
  regs.sfr.ov = ((regs.sr() ^ n) & (regs.sr() ^ r) & 0x8000) != 0;
  regs.sfr.s  = (r & 0x8000) != 0;
  regs.sfr.cy = r >= 0;
  regs.sfr.z  = static_cast<uint16>(r) == 0;
  if(!regs.sfr.alt2 || !regs.sfr.alt1) regs.dr() = static_cast<uint>(r);
  regs.reset();
}

auto SuperFXCore::instructionMERGE() -> void {
  regs.dr() = (regs.r[7] & 0xff00) | (regs.r[8] >> 8);
  regs.sfr.ov = (regs.dr() & 0xc0c0) != 0;
  regs.sfr.s  = (regs.dr() & 0x8080) != 0;
  regs.sfr.cy = (regs.dr() & 0xe0e0) != 0;
  regs.sfr.z  = (regs.dr() & 0xf0f0) != 0;
  regs.reset();
}

auto SuperFXCore::instructionAND_BIC(uint n) -> void {
  if(!regs.sfr.alt2) n = regs.r[n];
  regs.dr() = regs.sr() & (regs.sfr.alt1 ? ~n : n);
  regs.sfr.s = (regs.dr() & 0x8000) != 0;
  regs.sfr.z = regs.dr() == 0;
  regs.reset();
}

auto SuperFXCore::instructionMULT_UMULT(uint n) -> void {
  if(!regs.sfr.alt2) n = regs.r[n];
  regs.dr() = !regs.sfr.alt1
    ? static_cast<uint16>(static_cast<int8>(regs.sr()) * static_cast<int8>(n))
    : static_cast<uint16>(static_cast<uint8>(regs.sr()) * static_cast<uint8>(n));
  regs.sfr.s = (regs.dr() & 0x8000) != 0;
  regs.sfr.z = regs.dr() == 0;
  regs.reset();
  if(!regs.cfgr.ms0) step(regs.clsr ? 1 : 2);
}

auto SuperFXCore::instructionSBK() -> void {
  writeRAMBuffer(regs.ramaddr ^ 0, regs.sr() >> 0);
  writeRAMBuffer(regs.ramaddr ^ 1, regs.sr() >> 8);
  regs.reset();
}

auto SuperFXCore::instructionLINK(uint n) -> void {
  regs.r[11] = regs.r[15] + n;
  regs.reset();
}

auto SuperFXCore::instructionSEX() -> void {
  regs.dr() = static_cast<int8>(regs.sr());
  regs.sfr.s = (regs.dr() & 0x8000) != 0;
  regs.sfr.z = regs.dr() == 0;
  regs.reset();
}

auto SuperFXCore::instructionASR_DIV2() -> void {
  regs.sfr.cy = (regs.sr() & 1) != 0;
  regs.dr() = (static_cast<int16>(regs.sr()) >> 1) + (regs.sfr.alt1 ? ((regs.sr() + 1) >> 16) : 0);
  regs.sfr.s = (regs.dr() & 0x8000) != 0;
  regs.sfr.z = regs.dr() == 0;
  regs.reset();
}

auto SuperFXCore::instructionROR() -> void {
  bool carry = (regs.sr() & 1) != 0;
  regs.dr() = (static_cast<uint>(regs.sfr.cy) << 15) | (regs.sr() >> 1);
  regs.sfr.s  = (regs.dr() & 0x8000) != 0;
  regs.sfr.cy = carry;
  regs.sfr.z  = regs.dr() == 0;
  regs.reset();
}

auto SuperFXCore::instructionJMP_LJMP(uint n) -> void {
  if(!regs.sfr.alt1) {
    regs.r[15] = regs.r[n];
  } else {
    regs.pbr = regs.r[n] & 0x7f;
    regs.r[15] = regs.sr();
    regs.cbr = regs.r[15] & 0xfff0;
    flushCache();
  }
  regs.reset();
}

auto SuperFXCore::instructionLOB() -> void {
  regs.dr() = regs.sr() & 0xff;
  regs.sfr.s = (regs.dr() & 0x80) != 0;
  regs.sfr.z = regs.dr() == 0;
  regs.reset();
}

auto SuperFXCore::instructionFMULT_LMULT() -> void {
  uint32 result = static_cast<uint32>(static_cast<int16>(regs.sr()) * static_cast<int16>(regs.r[6]));
  if(regs.sfr.alt1) regs.r[4] = result;
  regs.dr() = result >> 16;
  regs.sfr.s  = (regs.dr() & 0x8000) != 0;
  regs.sfr.cy = (result & 0x8000) != 0;
  regs.sfr.z  = regs.dr() == 0;
  regs.reset();
  step((regs.cfgr.ms0 ? 3 : 7) * (regs.clsr ? 1 : 2));
}

auto SuperFXCore::instructionIBT_LMS_SMS(uint n) -> void {
  if(regs.sfr.alt1) {
    regs.ramaddr = pipe() << 1;
    uint8 lo = static_cast<uint8>(readRAMBuffer(regs.ramaddr ^ 0) << 0);
    regs.r[n] = (readRAMBuffer(regs.ramaddr ^ 1) << 8) | lo;
  } else if(regs.sfr.alt2) {
    regs.ramaddr = pipe() << 1;
    writeRAMBuffer(regs.ramaddr ^ 0, regs.r[n] >> 0);
    writeRAMBuffer(regs.ramaddr ^ 1, regs.r[n] >> 8);
  } else {
    regs.r[n] = static_cast<int8>(pipe());
  }
  regs.reset();
}

auto SuperFXCore::instructionFROM_MOVES(uint n) -> void {
  if(!regs.sfr.b) {
    regs.sreg = n;
  } else {
    regs.dr() = regs.r[n];
    regs.sfr.ov = (regs.dr() & 0x80) != 0;
    regs.sfr.s  = (regs.dr() & 0x8000) != 0;
    regs.sfr.z  = regs.dr() == 0;
    regs.reset();
  }
}

auto SuperFXCore::instructionHIB() -> void {
  regs.dr() = regs.sr() >> 8;
  regs.sfr.s = (regs.dr() & 0x80) != 0;
  regs.sfr.z = regs.dr() == 0;
  regs.reset();
}

auto SuperFXCore::instructionOR_XOR(uint n) -> void {
  if(!regs.sfr.alt2) n = regs.r[n];
  regs.dr() = !regs.sfr.alt1 ? (regs.sr() | n) : (regs.sr() ^ n);
  regs.sfr.s = (regs.dr() & 0x8000) != 0;
  regs.sfr.z = regs.dr() == 0;
  regs.reset();
}

auto SuperFXCore::instructionINC(uint n) -> void {
  regs.r[n]++;
  regs.sfr.s = (regs.r[n] & 0x8000) != 0;
  regs.sfr.z = regs.r[n] == 0;
  regs.reset();
}

auto SuperFXCore::instructionGETC_RAMB_ROMB() -> void {
  if(!regs.sfr.alt2) {
    regs.colr = color(readROMBuffer());
  } else if(!regs.sfr.alt1) {
    syncRAMBuffer();
    regs.rambr = (regs.sr() & 0x01) != 0;
  } else {
    syncROMBuffer();
    regs.rombr = regs.sr() & 0x7f;
  }
  regs.reset();
}

auto SuperFXCore::instructionDEC(uint n) -> void {
  regs.r[n]--;
  regs.sfr.s = (regs.r[n] & 0x8000) != 0;
  regs.sfr.z = regs.r[n] == 0;
  regs.reset();
}

auto SuperFXCore::instructionGETB() -> void {
  switch((static_cast<uint>(regs.sfr.alt2) << 1) | static_cast<uint>(regs.sfr.alt1)) {
  case 0: regs.dr() = readROMBuffer(); break;
  case 1: regs.dr() = (readROMBuffer() << 8) | static_cast<uint8>(regs.sr()); break;
  case 2: regs.dr() = (regs.sr() & 0xff00) | readROMBuffer(); break;
  case 3: regs.dr() = static_cast<int8>(readROMBuffer()); break;
  }
  regs.reset();
}

auto SuperFXCore::instructionIWT_LM_SM(uint n) -> void {
  if(regs.sfr.alt1) {
    regs.ramaddr  = pipe() << 0;
    regs.ramaddr |= pipe() << 8;
    uint8 lo  = static_cast<uint8>(readRAMBuffer(regs.ramaddr ^ 0) << 0);
    regs.r[n] = (readRAMBuffer(regs.ramaddr ^ 1) << 8) | lo;
  } else if(regs.sfr.alt2) {
    regs.ramaddr  = pipe() << 0;
    regs.ramaddr |= pipe() << 8;
    writeRAMBuffer(regs.ramaddr ^ 0, regs.r[n] >> 0);
    writeRAMBuffer(regs.ramaddr ^ 1, regs.r[n] >> 8);
  } else {
    uint8 lo = pipe();
    regs.r[n] = (pipe() << 8) | lo;
  }
  regs.reset();
}

auto SuperFXCore::instruction(uint8 opcode) -> void {
#define op(id, name, ...) case id: return instruction##name(__VA_ARGS__)
#define op4(id, name) \
  case id + 0: return instruction##name(opcode & 0x0f); \
  case id + 1: return instruction##name(opcode & 0x0f); \
  case id + 2: return instruction##name(opcode & 0x0f); \
  case id + 3: return instruction##name(opcode & 0x0f)
#define op6(id, name) \
  op4(id, name); \
  case id + 4: return instruction##name(opcode & 0x0f); \
  case id + 5: return instruction##name(opcode & 0x0f)
#define op12(id, name) \
  op6(id, name); \
  case id + 6: return instruction##name(opcode & 0x0f); \
  case id + 7: return instruction##name(opcode & 0x0f); \
  case id + 8: return instruction##name(opcode & 0x0f); \
  case id + 9: return instruction##name(opcode & 0x0f); \
  case id + 10: return instruction##name(opcode & 0x0f); \
  case id + 11: return instruction##name(opcode & 0x0f)
#define op15(id, name) \
  op12(id, name); \
  case id + 12: return instruction##name(opcode & 0x0f); \
  case id + 13: return instruction##name(opcode & 0x0f); \
  case id + 14: return instruction##name(opcode & 0x0f)
#define op16(id, name) \
  op15(id, name); \
  case id + 15: return instruction##name(opcode & 0x0f)

  switch(opcode) {
  op  (0x00, STOP);
  op  (0x01, NOP);
  op  (0x02, CACHE);
  op  (0x03, LSR);
  op  (0x04, ROL);
  op  (0x05, Branch, true);
  op  (0x06, Branch, (regs.sfr.s ^ regs.sfr.ov) == 0);
  op  (0x07, Branch, (regs.sfr.s ^ regs.sfr.ov) == 1);
  op  (0x08, Branch, regs.sfr.z == 0);
  op  (0x09, Branch, regs.sfr.z == 1);
  op  (0x0a, Branch, regs.sfr.s == 0);
  op  (0x0b, Branch, regs.sfr.s == 1);
  op  (0x0c, Branch, regs.sfr.cy == 0);
  op  (0x0d, Branch, regs.sfr.cy == 1);
  op  (0x0e, Branch, regs.sfr.ov == 0);
  op  (0x0f, Branch, regs.sfr.ov == 1);
  op16(0x10, TO_MOVE);
  op16(0x20, WITH);
  op12(0x30, Store);
  op  (0x3c, LOOP);
  op  (0x3d, ALT1);
  op  (0x3e, ALT2);
  op  (0x3f, ALT3);
  op12(0x40, Load);
  op  (0x4c, PLOT_RPIX);
  op  (0x4d, SWAP);
  op  (0x4e, COLOR_CMODE);
  op  (0x4f, NOT);
  op16(0x50, ADD_ADC);
  op16(0x60, SUB_SBC_CMP);
  op  (0x70, MERGE);
  op15(0x71, AND_BIC);
  op16(0x80, MULT_UMULT);
  op  (0x90, SBK);
  op4 (0x91, LINK);
  op  (0x95, SEX);
  op  (0x96, ASR_DIV2);
  op  (0x97, ROR);
  op6 (0x98, JMP_LJMP);
  op  (0x9e, LOB);
  op  (0x9f, FMULT_LMULT);
  op16(0xa0, IBT_LMS_SMS);
  op16(0xb0, FROM_MOVES);
  op  (0xc0, HIB);
  op15(0xc1, OR_XOR);
  op15(0xd0, INC);
  op  (0xdf, GETC_RAMB_ROMB);
  op15(0xe0, DEC);
  op  (0xef, GETB);
  op16(0xf0, IWT_LM_SM);
  }

#undef op
#undef op4
#undef op6
#undef op12
#undef op15
#undef op16
}

}  // namespace

struct MetalSNES_SuperFX {
  SuperFXCore core;

  MetalSNES_SuperFX(const uint8_t *rom, size_t rom_size, uint8_t *ram, size_t ram_size)
  : core(rom, rom_size, ram, ram_size) {}
};

extern "C" {

void *ms_superfx_create(
    const uint8_t *rom,
    size_t rom_size,
    uint8_t *ram,
    size_t ram_size
) {
  if(!rom || rom_size == 0 || !ram || ram_size == 0) return nullptr;
  return new (std::nothrow) MetalSNES_SuperFX(rom, rom_size, ram, ram_size);
}

void ms_superfx_destroy(void *superfx) {
  delete static_cast<MetalSNES_SuperFX *>(superfx);
}

void ms_superfx_run(void *superfx, uint32_t master_cycles) {
  if(!superfx) return;
  static_cast<MetalSNES_SuperFX *>(superfx)->core.run(master_cycles);
}

uint8_t ms_superfx_read_io(void *superfx, uint16_t addr, uint8_t default_data) {
  if(!superfx) return default_data;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.cpuReadIO(addr, default_data);
}

void ms_superfx_write_io(void *superfx, uint16_t addr, uint8_t data) {
  if(!superfx) return;
  static_cast<MetalSNES_SuperFX *>(superfx)->core.cpuWriteIO(addr, data);
}

uint8_t ms_superfx_cpu_read_rom(void *superfx, uint32_t addr, uint8_t default_data) {
  if(!superfx) return default_data;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.cpuReadROM(addr, default_data);
}

uint8_t ms_superfx_cpu_read_ram(void *superfx, uint32_t addr, uint8_t default_data) {
  if(!superfx) return default_data;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.cpuReadRAM(addr, default_data);
}

void ms_superfx_cpu_write_ram(void *superfx, uint32_t addr, uint8_t data) {
  if(!superfx) return;
  static_cast<MetalSNES_SuperFX *>(superfx)->core.cpuWriteRAM(addr, data);
}

bool ms_superfx_irq_active(void *superfx) {
  if(!superfx) return false;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.irqActive();
}

uint32_t ms_superfx_state_size(void) {
  return static_cast<uint32_t>(sizeof(PersistedState));
}

bool ms_superfx_save_state(void *superfx, uint8_t *buffer, uint32_t size) {
  if(!superfx || !buffer || size != sizeof(PersistedState)) return false;
  PersistedState state = static_cast<MetalSNES_SuperFX *>(superfx)->core.persistedState();
  std::memcpy(buffer, &state, sizeof(state));
  return true;
}

bool ms_superfx_load_state(void *superfx, const uint8_t *buffer, uint32_t size) {
  if(!superfx || !buffer || size != sizeof(PersistedState)) return false;
  PersistedState state{};
  std::memcpy(&state, buffer, sizeof(state));
  static_cast<MetalSNES_SuperFX *>(superfx)->core.loadPersistedState(state);
  return true;
}

uint16_t ms_superfx_get_reg(void *superfx, uint32_t index) {
  if(!superfx || index >= 16) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.debugState().r[index];
}

uint16_t ms_superfx_get_sfr(void *superfx) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.debugState().sfr;
}

uint8_t ms_superfx_get_pbr(void *superfx) {
  return superfx ? static_cast<MetalSNES_SuperFX *>(superfx)->core.debugState().pbr : 0;
}

uint8_t ms_superfx_get_rombr(void *superfx) {
  return superfx ? static_cast<MetalSNES_SuperFX *>(superfx)->core.debugState().rombr : 0;
}

uint8_t ms_superfx_get_rambr(void *superfx) {
  return superfx ? static_cast<MetalSNES_SuperFX *>(superfx)->core.debugState().rambr : 0;
}

uint16_t ms_superfx_get_cbr(void *superfx) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.debugState().cbr;
}

uint8_t ms_superfx_get_scbr(void *superfx) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.debugState().scbr;
}

uint8_t ms_superfx_get_scmr(void *superfx) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.debugState().scmr;
}

uint8_t ms_superfx_get_colr(void *superfx) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.debugState().colr;
}

uint8_t ms_superfx_get_por(void *superfx) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.debugState().por;
}

uint8_t ms_superfx_get_vcr(void *superfx) {
  return superfx ? static_cast<MetalSNES_SuperFX *>(superfx)->core.debugState().vcr : 0;
}

uint8_t ms_superfx_get_cfgr(void *superfx) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.debugState().cfgr;
}

uint8_t ms_superfx_get_clsr(void *superfx) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.debugState().clsr;
}

uint8_t ms_superfx_get_pipeline(void *superfx) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.debugState().pipeline;
}

uint16_t ms_superfx_get_ramaddr(void *superfx) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.debugState().ramaddr;
}

uint32_t ms_superfx_get_romcl(void *superfx) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.debugState().romcl;
}

uint8_t ms_superfx_get_romdr(void *superfx) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.debugState().romdr;
}

uint32_t ms_superfx_get_ramcl(void *superfx) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.debugState().ramcl;
}

uint16_t ms_superfx_get_ramar(void *superfx) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.debugState().ramar;
}

uint8_t ms_superfx_get_ramdr(void *superfx) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.debugState().ramdr;
}

uint32_t ms_superfx_get_trace_count(void *superfx) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.traceSize();
}

uint8_t ms_superfx_get_trace_pbr(void *superfx, uint32_t index) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.traceEntry(index).pbr;
}

uint8_t ms_superfx_get_trace_rombr(void *superfx, uint32_t index) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.traceEntry(index).rombr;
}

uint8_t ms_superfx_get_trace_opcode(void *superfx, uint32_t index) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.traceEntry(index).opcode;
}

uint16_t ms_superfx_get_trace_r12(void *superfx, uint32_t index) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.traceEntry(index).r12;
}

uint16_t ms_superfx_get_trace_r13(void *superfx, uint32_t index) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.traceEntry(index).r13;
}

uint16_t ms_superfx_get_trace_r14(void *superfx, uint32_t index) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.traceEntry(index).r14;
}

uint16_t ms_superfx_get_trace_r15(void *superfx, uint32_t index) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.traceEntry(index).r15;
}

uint16_t ms_superfx_get_trace_sfr(void *superfx, uint32_t index) {
  if(!superfx) return 0;
  return static_cast<MetalSNES_SuperFX *>(superfx)->core.traceEntry(index).sfr;
}

}  // extern "C"
