anything that takes more than a few minutes to figure out, write it to DEVLOG.md

When running built executables via Bash, always use a single line — do not use newlines to separate commands. Use `;` or `&&` to chain commands on one line (e.g. `/path/to/MetalSNES > /tmp/out.txt 2>&1 & echo "PID=$!"`).

When debugging emulator correctness issues, prefer reusable observability over one-off logging:
- use the debug server / state-inspection APIs first when possible instead of rebuilding just to print more data
- narrow visual bugs to one exact pixel, scanline, sprite, register, or memory range before changing code
- prove which path is wrong early (for example CPU vs Metal output) so renderer bugs and core emulation bugs do not get mixed together
- separate these questions: is the data present, is it transparent/masked, or is it losing a priority/arbitration rule
- for SNES behavior questions, check bsnes in-tree before guessing at hardware rules
- prefer headless ROM/save-state diagnostics for repeatable investigation, but remember a restored state is static unless the emulation loop is actually running
