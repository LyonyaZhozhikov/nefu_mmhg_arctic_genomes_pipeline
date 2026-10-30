#!/usr/bin/env bash
# Run (or resume) the nf-core/raredisease 3.1.2 built-in test inside WSL.
# Usage inside Ubuntu:  bash ~/raredisease-setup/windows/run_test.sh
# Safe to re-run: -resume keeps finished steps and already pulled containers.
if pgrep -f "nextflow.*run nf-core/raredisease" >/dev/null; then
  echo "Тест уже идёт. Смотреть: tail -f /data/raredisease/test/run.log"
  exit 0
fi
mkdir -p /data/raredisease/test && cd /data/raredisease/test
nextflow run nf-core/raredisease -r 3.1.2 -profile test,docker \
    --outdir /data/raredisease/test/results \
    -c "$HOME/raredisease-setup/conf/local.config" \
    -ansi-log false -resume 2>&1 | tee -a run.log
