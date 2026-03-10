anything that takes more than a few minutes to figure out, write it to DEVLOG.md

When running built executables via Bash, always use a single line — do not use newlines to separate commands. Use `;` or `&&` to chain commands on one line (e.g. `/path/to/MetalSNES > /tmp/out.txt 2>&1 & echo "PID=$!"`).
