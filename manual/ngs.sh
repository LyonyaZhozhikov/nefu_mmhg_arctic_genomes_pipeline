#!/usr/bin/env bash
# ngs.sh: run nf-core/raredisease 3.1.2 on the lab PC without Claude.
#
#   ngs                      menu (same as double-clicking C:\NGS_pipeline\NGS.bat)
#   ngs run CODE SEX [PHENO] start a sample from C:\NGS_pipeline\new_samples\CODE
#                            SEX: F, M or U;  PHENO: 2 affected (default), 1 unaffected
#                            When it succeeds it is moved to D: by itself (see ngs archive).
#   ngs resume CODE          restart a failed/stopped run from where it stopped (-resume)
#   ngs status               all runs: running / done / failed, disk space
#   ngs log CODE             follow the run log live (Ctrl+C to leave, the run keeps going)
#   ngs stop CODE            stop a run (it can be resumed later)
#   ngs archive CODE         copy to D:\data_annotated\<date>_<CODE>_<SEX>\{raw,processed},
#                            check every file by md5, then delete all C: copies (no question).
#                            Runs by itself after every successful run; by hand only to retry.
#   ngs discard CODE         delete a failed/unwanted run's temporary files (FASTQ in new_samples kept)
#   ngs check                check Docker, disk space and that references are in place
#   ngs queue add CODE SEX [PHENO]   put a sample in the queue (FASTQ in new_samples\CODE)
#   ngs queue                show the queue;  ngs queue start  run it in the background
#   ngs queue remove CODE    take a sample out;  ngs queue stop  stop after the current sample
#                            Queue: one sample at a time; the archive of each finished sample
#                            runs alongside the next one.
#   ngs intake sex           Очередь на D: показать новых пациентов (ФИО + код) и задать пол M/F/U
#   ngs intake               автоприём: что лежит в Очереди, что считается, что готово
#   ngs intake start|stop    включить/выключить фоновый автоприём (tmux ngs_intake, сам стартует с Windows)
#   ngs intake now           проверить Очередь прямо сейчас (то же, что делает фон раз в 10 минут)
#                            Автоприём держит ~5 образцов готовыми на C:, копирует FASTQ из Очереди
#                            с проверкой gzip/md5, ставит в ngs queue, а после прогона и md5 архива
#                            кладёт <дата>_<код>_<пол> в папку пациента и переносит её в
#                            D:\1_fastq_rec (есть PDF) или D:\2_fastq (PDF нет). Журнал: Очередь\_журнал.txt
#
# Layout:
#   C:\NGS_pipeline\new_samples\CODE\      you put FASTQ here (any MGI/Illumina names, *_1/*_2 or *_R1/*_R2)
#   /data/raredisease/samples/CODE/        fast copy inside WSL (deleted by archive)
#   /data/raredisease/runs/CODE/           samplesheet, params, log, work/ (temporary, deleted by archive)
#   D:\data_annotated\<date>_<CODE>_<SEX>\   raw\ (FASTQ) and processed\ (results without the trimmed
#                                            FASTQ trimming\*.fastp.fastq.gz; fastp reports kept), md5 lists
#   /data/raredisease/runs/queue.log       archive and queue journal
set -euo pipefail

SETUP=/home/ngs/raredisease-setup
NF_CONFIGS=(-c "$SETUP/conf/local.config" -c "$SETUP/conf/vep_spliceai_cadd.config")
TEMPLATE=$SETUP/params_template.yaml     # params.yaml of a good run; input/outdir are replaced per sample
PIPELINE=(nf-core/raredisease -r 3.1.2)
REFS=/data/raredisease/references/grch38
WIN=/mnt/c/NGS_pipeline
NEW_SAMPLES=$WIN/new_samples
NEW_RESULTS=$WIN/new_results
SAMPLES=/data/raredisease/samples
RUNS=/data/raredisease/runs
ARCHIVE=/mnt/d/data_annotated
ME=$(readlink -f "$0")
QUEUE=$RUNS/queue.txt          # waiting samples, one "CODE SEX PHENO" per line
QLOG=$RUNS/queue.log
QSTOP=$RUNS/queue.stop
QHOLD=$RUNS/queue.hold         # set by ngs queue stop: the intake must not start the queue again
COPYLOCK=$RUNS/intake.copying  # the intake is copying FASTQ from D: (archives wait for it)

say()  { printf '\e[1;36m>>\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m!!\e[0m %s\n' "$*"; }
die()  { printf '\e[1;31mОШИБКА:\e[0m %s\n' "$*" >&2; exit 1; }
gb()   { df -BG --output=avail "$1" | tail -1 | tr -dc 0-9; }
running() { tmux has-session -t "run_$1" 2>/dev/null; }
check_code() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die "код образца '$1': только латиница, цифры, _ и - (без имён пациентов и пробелов)"
}
mount_d() {
  mountpoint -q /mnt/d && return
  say "подключаю диск D: (может спросить пароль Linux)"
  sudo mkdir -p /mnt/d && sudo mount -t drvfs D: /mnt/d
}

# ---------------------------------------------------------------- check
cmd_check() {
  local ok=1
  docker info >/dev/null 2>&1 && say "Docker работает" || { warn "Docker не отвечает: sudo service docker start"; ok=0; }
  command -v nextflow >/dev/null && say "Nextflow: $(nextflow -version 2>/dev/null | grep -o 'version [0-9.]*')" || { warn "nextflow не найден"; ok=0; }
  [ -f "$TEMPLATE" ] && say "шаблон параметров: $TEMPLATE" || { warn "нет шаблона $TEMPLATE"; ok=0; }
  for f in "$REFS"/GCA_000001405.15_GRCh38_no_alt_analysis_set.fna "$REFS"/bwamem2 "$REFS"/bwa/GCA_000001405.15_GRCh38_no_alt_analysis_set.bwt "$REFS"/vep_cache "$REFS"/cadd_annotations; do
    [ -e "$f" ] || { warn "нет референса: $f"; ok=0; }
  done
  say "свободно: /data (WSL на C:) $(gb /data) ГБ, C:\\ $(gb /mnt/c) ГБ"
  mountpoint -q /mnt/d && say "D:\\ $(gb /mnt/d) ГБ" || echo "   D: пока не подключён (подключится при архивации)"
  [ $ok = 1 ] && say "всё готово к запуску" || warn "есть проблемы, см. выше"
}

# ---------------------------------------------------------------- samplesheet
# One row per FASTQ pair. lane = file name without the read suffix (unique per flowcell/lane).
make_samplesheet() {
  local code=$1 sexnum=$2 pheno=$3 dir=$4 out=$5 n=0 r1 r2 base
  echo "sample,lane,fastq_1,fastq_2,sex,phenotype,paternal_id,maternal_id,case_id" > "$out"
  while IFS= read -r r1; do
    case "$r1" in
      *_R1_*) r2=${r1/_R1_/_R2_}; base=${r1/_R1_/_} ;;
      *_R1.*) r2=${r1/_R1./_R2.}; base=${r1%%_R1.*} ;;
      *_1.*)  r2=${r1/%_1.${r1##*_1.}/_2.${r1##*_1.}}; base=${r1%_1.*} ;;
      *) continue ;;
    esac
    [ -f "$r2" ] || die "нет пары для $(basename "$r1") (ожидал $(basename "$r2"))"
    base=$(basename "${base%.f*q.gz}"); base=${base#"${code}"_}; base=${base//[^A-Za-z0-9_-]/_}
    echo "$code,$base,$r1,$r2,$sexnum,$pheno,0,0,case_$code" >> "$out"; n=$((n+1))
  done < <(find "$dir" -maxdepth 3 -type f \( -name '*_R1*.f*q.gz' -o -name '*_1.f*q.gz' \) | sort)
  [ $n -gt 0 ] || die "в $dir не найдено FASTQ (*_1.fq.gz / *_R1.fastq.gz ...)"
  local total; total=$(find "$dir" -maxdepth 3 -type f -name '*.f*q.gz' | wc -l)
  [ $((n*2)) -eq "$total" ] || die "FASTQ файлов $total, а пар найдено $n: проверьте имена"
  say "samplesheet: $n пар FASTQ"
}

# ---------------------------------------------------------------- run
cmd_run() {
  local code=${1:-} sex=${2:-} pheno=${3:-2} sexnum
  check_code "$code"
  case "$sex" in F) sexnum=2;; M) sexnum=1;; U) sexnum=0;; *) die "пол: F, M или U";; esac
  case "$pheno" in 1|2) ;; *) die "фенотип: 2 больной, 1 здоровый";; esac
  local src=$NEW_SAMPLES/$code run=$RUNS/$code smp=$SAMPLES/$code
  # FASTQ copied straight into /data/raredisease/samples/CODE (copy_sample_fastq.sh) also work
  [ -d "$src" ] || src=$smp
  [ -d "$src" ] || die "нет папки C:\\NGS_pipeline\\new_samples\\$code"
  running "$code" && die "$code уже идёт (ngs log $code)"
  [ -d "$run/work" ] && die "$code уже запускался. Продолжить: ngs resume $code. Начать заново: сначала ngs archive или удалите $run"
  docker info >/dev/null 2>&1 || die "Docker не запущен: sudo service docker start"
  [ -f "$TEMPLATE" ] || die "нет шаблона параметров $TEMPLATE"

  local need=$(( $(du -s --block-size=1G "$src" | cut -f1) * 6 + 200 ))
  [ "$(gb /data)" -ge "$need" ] || die "мало места: нужно ~${need} ГБ, свободно $(gb /data) ГБ. Заархивируйте прошлые прогоны (ngs archive)"

  mkdir -p "$run" "$smp"
  if [ "$src" != "$smp" ]; then
    say "копирую FASTQ из C:\\NGS_pipeline\\new_samples\\$code внутрь WSL (быстрее для пайплайна)"
    # Reads from C: (/mnt/c, 9p) fail with "Cannot allocate memory" when the kernel has no free
    # contiguous memory (page cache full, a sample computing). rsync continues where it stopped,
    # so drop the cache, compact and try again (NGS_COPY_TRIES x 10 min).
    local try tries=${NGS_COPY_TRIES:-6} ok=""
    for try in $(seq 1 "$tries"); do
      sync; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
      echo 1 | sudo -n tee /proc/sys/vm/compact_memory >/dev/null 2>&1 || true
      if rsync -rt --info=progress2 "$src"/ "$smp"/; then ok=1; break; fi
      [ "$try" -lt "$tries" ] || break
      say "копирование прервалось (попытка $try из $tries), повторю через 10 минут"
      sleep 600
    done
    [ -n "$ok" ] || die "FASTQ не скопировались за $tries попыток (ngs queue add $code $sex $pheno, когда ПК свободнее)"
  fi

  if [ -f "$smp/samplesheet.csv" ]; then
    # your own samplesheet (trio etc.): file names in fastq_1/fastq_2 are taken relative to the sample folder
    say "использую ваш samplesheet.csv из папки образца"
    awk -F, -v OFS=, -v d="$smp" 'NR>1 { if ($3 !~ /^\//) $3=d"/"$3; if ($4 !~ /^\//) $4=d"/"$4 } {print}' \
      "$smp/samplesheet.csv" | tr -d '\r' > "$run/samplesheet.csv"
  else
    make_samplesheet "$code" "$sexnum" "$pheno" "$smp" "$run/samplesheet.csv"
  fi

  sed -e "s|^input:.*|input: \"$run/samplesheet.csv\"|" -e "s|^outdir:.*|outdir: \"$run/results\"|" \
    "$TEMPLATE" > "$run/params.yaml"
  grep -q "^outdir: \"$run/results\"" "$run/params.yaml" || die "в шаблоне нет строк input:/outdir:"
  printf 'code=%s\nsex=%s\nrun_date=%s\n' "$code" "$sex" "$(date +%F)" > "$run/run_info.txt"
  mount_d   # now, while you are here: the archive at the end runs in the background
  start_worker "$code"
}

cmd_resume() {
  local code=${1:-}; check_code "$code"
  [ -f "$RUNS/$code/params.yaml" ] || die "прогона $code нет"
  running "$code" && die "$code уже идёт"
  rm -f "$RUNS/$code/STATUS"
  # a queue sample resumed by hand after its queue has gone: nobody else will archive it
  queue_running || rm -f "${RUNS:?}/$code/IN_QUEUE"
  start_worker "$code"
}

start_worker() {
  tmux new-session -d -s "run_$1" "bash '$ME' _worker '$1'"
  say "запущено в фоне: $1. Окно можно закрыть, прогон продолжится."
  say "смотреть ход: ngs log $1   общий статус: ngs status"
}

cmd__worker() {
  local code=$1 run=$RUNS/$1 rc=0
  cd "$run"
  echo "RUNNING" > STATUS
  echo "start $(TZ=Asia/Yakutsk date '+%F %T') (Якутск)" >> timing.txt
  nextflow run "${PIPELINE[@]}" -profile docker "${NF_CONFIGS[@]}" \
    -params-file params.yaml -resume -ansi-log false 2>&1 | tee -a run.log || rc=$?
  echo "end   $(TZ=Asia/Yakutsk date '+%F %T') (Якутск) rc=$rc" >> timing.txt
  if [ $rc = 0 ]; then
    echo "DONE" > STATUS
    # the queue archives its samples itself, alongside the next sample
    [ -f IN_QUEUE ] || bash "$ME" _autoarchive "$code"
  else
    echo "FAILED" > STATUS
  fi
  echo; echo "=== $(cat STATUS) ==="
}

# ---------------------------------------------------------------- status / log / stop
cmd_status() {
  printf '%-22s %-12s %-12s %s\n' "ОБРАЗЕЦ" "СОСТОЯНИЕ" "ДАТА" "ПОСЛЕДНЯЯ ЗАДАЧА"
  local d code st last
  for d in "$RUNS"/*/; do
    code=$(basename "$d"); [ -f "$d/run_info.txt" ] || continue
    st=$(cat "$d/STATUS" 2>/dev/null || echo "-")
    [ "$st" = RUNNING ] && ! running "$code" && st="ПРЕРВАН"
    last=$(grep -a -o 'Submitted process > [^ ]*\|Pipeline completed.*\|ERROR.*' "$d/run.log" 2>/dev/null | tail -1 | cut -c1-60)
    printf '%-22s %-12s %-12s %s\n' "$code" "$st" "$(grep -o 'run_date=.*' "$d/run_info.txt" | cut -d= -f2)" "$last"
  done
  echo; say "свободно: /data $(gb /data) ГБ, C:\\ $(gb /mnt/c) ГБ"
  echo "RUNNING идёт, DONE посчитан (ждёт переноса на D:), ARCHIVING копируется на D: и сверяется md5,"
  echo "ARCHIVED готово, данные на D:, с C: удалены. ARCHIVE_FAILED копия не удалась, C: не тронут (ngs archive CODE)"
  echo "FAILED упал (ngs log CODE, затем ngs resume CODE), ПРЕРВАН остановлен (ngs resume CODE)"
  if [ -s "$QUEUE" ] || queue_running; then echo; cmd_queue list; fi
}

cmd_log() {
  local code=${1:-}; check_code "$code"
  if [ ! -f "$RUNS/$code/run.log" ] && grep -q " $code: старт" "$QLOG" 2>/dev/null; then
    # the queue is still copying its FASTQ into WSL: Nextflow (and run.log) start after that
    say "$code ещё готовится (копирование FASTQ внутрь WSL), показываю журнал очереди. Ctrl+C чтобы выйти"
    tail -n 5 -f "$QLOG"; return
  fi
  [ -f "$RUNS/$code/run.log" ] || die "лога $code нет (Nextflow для него ещё не запускался)"
  say "Ctrl+C чтобы выйти (прогон продолжится)"
  tail -n 40 -f "$RUNS/$code/run.log"
}

cmd_stop() {
  local code=${1:-}; check_code "$code"
  running "$code" || die "$code не идёт"
  tmux send-keys -t "run_$code" C-c
  say "отправлен сигнал остановки, Nextflow завершит задачи за 1-2 минуты. Продолжить потом: ngs resume $code"
}

# ---------------------------------------------------------------- archive
# By hand only to retry: after every successful run this runs by itself.
cmd_archive() {
  local code=${1:-}; check_code "$code"
  local run=$RUNS/$code
  [ -f "$run/run_info.txt" ] || die "прогона $code нет"
  running "$code" && die "$code ещё идёт"
  case "$(cat "$run/STATUS" 2>/dev/null)" in
    DONE|ARCHIVE_FAILED|COPY_FAILED|ARCHIVING) ;;
    ARCHIVED) die "$code уже на D: ($(grep -o 'archive=.*' "$run/run_info.txt" | cut -d= -f2))" ;;
    *) die "прогон $code не завершён успешно (ngs status). Переношу на D: только посчитанные." ;;
  esac
  mount_d
  bash "$ME" _autoarchive "$code"
}

# ---------------------------------------------------------------- queue
queue_running() { tmux has-session -t ngs_queue 2>/dev/null; }
other_run() { tmux ls -F '#S' 2>/dev/null | grep -q '^run_'; }
qlog() {
  local l; l="$(TZ=Asia/Yakutsk date '+%F %T') $*"
  echo "$l" >> "$QLOG"; [ -t 1 ] && echo "$l"; return 0
}

cmd_queue() {
  local sub=${1:-list}; shift || true
  case "$sub" in
    add)
      local code=${1:-} sex=${2:-} pheno=${3:-2}
      check_code "$code"; sex=${sex^^}
      case "$sex" in F|M|U) ;; *) die "пол: F, M или U";; esac
      case "$pheno" in 1|2) ;; *) die "фенотип: 2 больной, 1 здоровый";; esac
      [ -d "$NEW_SAMPLES/$code" ] || [ -d "$SAMPLES/$code" ] \
        || [ -f "$RUNS/$code/run_info.txt" ] || die "нет папки C:\\NGS_pipeline\\new_samples\\$code"
      grep -q "^$code " "$QUEUE" 2>/dev/null && die "$code уже в очереди"
      mkdir -p "$RUNS"; echo "$code $sex $pheno" >> "$QUEUE"
      say "$code добавлен в очередь (место $(wc -l < "$QUEUE"))"
      queue_running || echo "   очередь не запущена: ngs queue start" ;;
    remove)
      local code=${1:-}; check_code "$code"
      grep -q "^$code " "$QUEUE" 2>/dev/null || die "$code нет в очереди"
      sed -i "/^$code /d" "$QUEUE"; say "$code убран из очереди" ;;
    start)
      queue_running && die "очередь уже работает (ngs queue)"
      [ -s "$QUEUE" ] || die "очередь пуста: ngs queue add CODE F/M/U"
      docker info >/dev/null 2>&1 || die "Docker не запущен: sudo service docker start"
      mount_d   # now, while you are here: the background queue cannot type a password
      rm -f "$QSTOP" "$QHOLD"
      tmux new-session -d -s ngs_queue "bash '$ME' _queue_loop"
      say "очередь запущена в фоне. Окно можно закрыть."
      say "смотреть: ngs queue   журнал: tail -f $QLOG" ;;
    stop)
      queue_running || die "очередь не запущена"
      touch "$QSTOP" "$QHOLD"   # hold: the intake does not restart it until ngs queue start
      say "очередь остановится после текущего образца (сам образец и его архивация доработают)" ;;
    list)
      if queue_running; then say "очередь РАБОТАЕТ$([ -f "$QSTOP" ] && echo ', остановится после текущего образца')"
      else say "очередь не запущена"; fi
      if [ -s "$QUEUE" ]; then echo "ждут (по порядку):"; nl -w3 -s'  ' "$QUEUE"; else echo "   ожидающих нет"; fi
      if [ -f "$QLOG" ]; then echo "последние события:"; tail -n 6 "$QLOG" | sed 's/^/   /'; fi ;;
    archive) cmd_archive "$@" ;;
    *) die "ngs queue add|remove|start|stop|list" ;;
  esac
}

# The background loop (tmux ngs_queue). One sample at a time; archiving the
# previous one to D: runs alongside the next sample (it is disk work, little CPU).
cmd__queue_loop() {
  local line code sex pheno run st need src arch_pid="" finished=()
  qlog "очередь запущена"
  while true; do
    [ -f "$QSTOP" ] && { qlog "остановлена по ngs queue stop"; break; }
    line=$(head -n 1 "$QUEUE" 2>/dev/null || true)
    [ -n "$line" ] || { qlog "очередь пуста"; break; }
    read -r code sex pheno <<< "$line"
    run=$RUNS/$code

    # one sample loads the PC at a time: wait for any run started by hand
    if other_run && ! running "$code"; then
      qlog "жду окончания уже идущего прогона ($(tmux ls -F '#S' | grep '^run_' | tr '\n' ' '))"
      while other_run; do sleep 300; done
    fi

    if [ ! -f "$run/run_info.txt" ]; then
      src=$NEW_SAMPLES/$code; [ -d "$src" ] || src=$SAMPLES/$code
      need=$(( $(du -s --block-size=1G "$src" | cut -f1) * 6 + 200 ))
      if [ "$(gb /data)" -lt "$need" ] && [ -n "$arch_pid" ]; then
        qlog "$code: на /data $(gb /data) ГБ, нужно ~$need: жду архивации предыдущего"
        wait "$arch_pid" || true; arch_pid=""
      fi
      if [ "$(gb /data)" -lt "$need" ]; then
        qlog "$code: мало места на /data ($(gb /data) из ~$need ГБ), очередь остановлена"; break
      fi
      sed -i 1d "$QUEUE"
      qlog "$code: старт"
      mkdir -p "$run"; touch "$run/IN_QUEUE"   # before the start: the worker must not archive by itself
      if ! bash "$ME" run "$code" "$sex" "$pheno" >> "$QLOG" 2>&1; then
        qlog "$code: не запустился (см. выше), пропускаю"; continue
      fi
    else
      sed -i 1d "$QUEUE"
      qlog "$code: прогон уже существует ($(cat "$run/STATUS" 2>/dev/null)), беру его"
      touch "$run/IN_QUEUE"   # its worker leaves the archive to the queue
    fi

    sleep 5; while running "$code"; do sleep 120; done
    st=$(cat "$run/STATUS" 2>/dev/null || echo "-")
    if [ "$st" = FAILED ] || [ "$st" = RUNNING ]; then
      qlog "$code: $st, одна автоматическая попытка ngs resume"
      bash "$ME" resume "$code" >> "$QLOG" 2>&1 || true
      sleep 5; while running "$code"; do sleep 120; done
      st=$(cat "$run/STATUS" 2>/dev/null || echo "-")
    fi
    if [ "$st" = ARCHIVED ]; then
      qlog "$code: уже перенесён на D:"; continue
    fi
    if [ "$st" != DONE ]; then
      qlog "$code: $st. Оставлен на C: для разбора (ngs log $code), иду дальше"; continue
    fi
    qlog "$code: DONE ($(tail -n 1 "$run/timing.txt")). Архивирую на D: параллельно со следующим"
    if [ -n "$arch_pid" ]; then wait "$arch_pid" || true; fi
    bash "$ME" _autoarchive "$code" >> "$QLOG" 2>&1 &
    arch_pid=$!; finished+=("$code")
  done
  if [ -n "$arch_pid" ]; then qlog "жду окончания архивации"; wait "$arch_pid" || true; fi
  # nothing is computing now, the memory is free: one more go for archives that failed
  for code in "${finished[@]}"; do
    [ "$(cat "$RUNS/$code/STATUS" 2>/dev/null)" = ARCHIVE_FAILED ] || continue
    if other_run; then qlog "$code: перенос не повторяю, идёт другой прогон (ngs archive $code)"; continue; fi
    qlog "$code: повторяю перенос на D: (машина свободна)"
    bash "$ME" _autoarchive "$code" >> "$QLOG" 2>&1 || true
  done
  rm -f "$QSTOP"; qlog "очередь завершена"
}

# md5 of every file under $1, "hash  ./path" sorted; low priority so the running sample is not slowed
# hidden files are skipped: an interrupted rsync can leave its temporary ".name.XXXXXX" on D:
# $3 = notrim: also skip the fastp-trimmed FASTQ (see TRIMMED_FASTQ)
md5list() {
  local ex=(); [ "${3:-}" = notrim ] && ex=(! -name "$TRIMMED_FASTQ")
  (cd "$1" && find -L . -type f ! -name '.*' "${ex[@]}" -print0 | nice -n 19 ionice -c3 xargs -0 -r -n 4 -P "$2" md5sum) | LC_ALL=C sort
}

# results/trimming/*.fastp.fastq.gz: the reads after fastp, ~87 GB per WGS. They are an intermediate of
# bwa-mem2 (the BAM holds the same reads, and the original FASTQ are archived in raw\), so they are not
# copied to D: and not listed in md5_processed.txt; the fastp reports (*.fastp.json/html/log) are kept.
# raredisease 3.1.2 has no parameter to stop publishing them, so they are left out at archive time.
TRIMMED_FASTQ='*.fastp.fastq*'

# Archive: /data -> D:, md5 check of every file, then delete the C: copies (no question).
cmd__autoarchive() {
  local code=$1 run=$RUNS/$1
  local try tries=${NGS_ARCHIVE_TRIES:-24}   # 24 x 20 min = 8 h: outlasts the RAM-heavy phases of the next sample
  echo "ARCHIVING" > "$run/STATUS"
  # Writes to D: (/mnt/d) can fail with "Cannot allocate memory" while the next sample
  # fills the RAM; rsync continues where it stopped, so simply try again a bit later.
  for try in $(seq 1 "$tries"); do
    # wait (up to 2 h) for a light phase of the running sample: bwa-mem2, DeepVariant and genmod
    # take most of the RAM, CADD/VEP leave plenty
    local w=0
    # also wait while the intake copies FASTQ from D:: both at once overload the C:/D: bridge
    while { [ "$(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo)" -lt "${NGS_ARCHIVE_MIN_RAM_GB:-24}" ] \
            || [ -f "$COPYLOCK" ]; } && [ $w -lt 120 ]; do
      sleep 60; w=$((w + 1))
    done
    # /mnt/d writes need free contiguous kernel memory: drop the page cache and compact first
    sync; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
    echo 1 | sudo -n tee /proc/sys/vm/compact_memory >/dev/null 2>&1 || true
    # separate process so that set -e really stops at the first failed step (it is off inside "if")
    if bash "$ME" _autoarchive_core "$code"; then
      echo "ARCHIVED" > "$run/STATUS"; return 0
    fi
    [ "$try" -lt "$tries" ] || break
    qlog "$code: перенос на D: прервался (попытка $try из $tries), повторю через 20 минут"
    sleep 1200
  done
  echo "ARCHIVE_FAILED" > "$run/STATUS"
  qlog "$code: АРХИВАЦИЯ НЕ УДАЛАСЬ, на C: ничего не удалено. Очередь повторит её в конце; вручную: ngs archive $code"
}

cmd__autoarchive_core() {
  local code=${1:?} run sex date raw res dest size f
  run=${RUNS:?}/$code
  sex=$(grep -o 'sex=.*' "$run/run_info.txt" | cut -d= -f2); date=$(grep -o 'run_date=.*' "$run/run_info.txt" | cut -d= -f2)
  raw=$NEW_SAMPLES/$code; [ -d "$raw" ] || raw=$SAMPLES/$code
  res=$run/results
  [ -d "$raw" ] && [ -d "$res" ] || { echo "нет $raw или $res"; return 1; }
  mountpoint -q /mnt/d || sudo -n mount -t drvfs D: /mnt/d || { echo "D: не подключён"; return 1; }
  dest=$ARCHIVE/${date}_${code}_${sex}
  size=$(( $(du -s --block-size=1G "$raw" | cut -f1) + $(du -sL --block-size=1G --exclude="$TRIMMED_FASTQ" "$res" | cut -f1) + 5 ))
  [ "$(gb /mnt/d)" -ge "$size" ] || { echo "на D: мало места: нужно ~$size ГБ"; return 1; }
  qlog "$code: копирую на D:\\data_annotated\\${date}_${code}_${sex} (~$size ГБ)"
  # a sample taken from the Очередь by ngs intake: its original FASTQ are already on D:, so move them
  # into raw\ (instant, same disk) instead of writing them back; the md5 check below compares them
  # with the copy that was computed on
  local orig; orig=$(intake_fastq_of "$code")
  if [ -n "$orig" ] && [ -d "$orig" ] && [ ! -e "$dest/raw" ]; then
    mkdir -p "$dest" && mv "$orig" "$dest/raw" && qlog "$code: исходные FASTQ из папки пациента перенесены в raw (без копирования)"
  fi
  mkdir -p "$dest/raw" "$dest/processed"
  local prog=(); [ -t 1 ] && prog=(--info=progress2)
  nice -n 19 rsync -rtL "${prog[@]}" "$raw"/ "$dest/raw"/
  nice -n 19 rsync -rtL "${prog[@]}" --exclude="$TRIMMED_FASTQ" "$res"/ "$dest/processed"/
  find "$dest/processed" -type f -name "$TRIMMED_FASTQ" -delete   # left by an attempt made before this change
  for f in run.log params.yaml samplesheet.csv timing.txt run_info.txt; do
    if [ -f "$run/$f" ]; then cp "$run/$f" "$dest/processed/"; fi
  done

  qlog "$code: сверяю md5 (C: и D:)"
  md5list "$raw" 8 > "$run/md5_raw_C.txt"
  md5list "$dest/raw" 2 > "$run/md5_raw_D.txt"
  { md5list "$res" 8 notrim
    (cd "$run" && for f in run.log params.yaml samplesheet.csv timing.txt run_info.txt; do if [ -f "$f" ]; then md5sum "./$f"; fi; done)
  } | LC_ALL=C sort > "$run/md5_processed_C.txt"
  md5list "$dest/processed" 2 notrim > "$run/md5_processed_D.txt"
  [ -s "$run/md5_raw_C.txt" ] && [ -s "$run/md5_processed_C.txt" ] || { echo "пустой список файлов"; return 1; }
  cmp -s "$run/md5_raw_C.txt" "$run/md5_raw_D.txt" || { echo "raw: md5 НЕ совпадает"; return 1; }
  cmp -s "$run/md5_processed_C.txt" "$run/md5_processed_D.txt" || { echo "processed: md5 НЕ совпадает"; return 1; }
  cp "$run/md5_raw_C.txt" "$dest/md5_raw.txt"; cp "$run/md5_processed_C.txt" "$dest/md5_processed.txt"
  qlog "$code: md5 совпали ($(wc -l < "$run/md5_raw_C.txt") + $(wc -l < "$run/md5_processed_C.txt") файлов), удаляю копии на C:"

  rm -rf "${NEW_SAMPLES:?}/$code" "${NEW_RESULTS:?}/$code" "${SAMPLES:?}/$code" "$run/work" "$run/results" "$run"/.nextflow*
  echo "archive=$dest" >> "$run/run_info.txt"
  qlog "$code: ГОТОВО, данные в D:\\data_annotated\\${date}_${code}_${sex}"
}

# Throw away a failed/unwanted run: deletes only temporary copies, never the FASTQ in new_samples.
cmd_discard() {
  local code=${1:-}; check_code "$code"
  local run=$RUNS/$code
  [ -d "$run" ] || die "прогона $code нет"
  running "$code" && die "$code ещё идёт, сначала ngs stop $code"
  echo "Будет удалено (исходные FASTQ в C:\\NGS_pipeline\\new_samples\\$code НЕ трогаются):"
  du -sh "$run" "$SAMPLES/$code" "$NEW_RESULTS/$code" 2>/dev/null | sed 's/^/   /'
  read -r -e -p "Напишите YES чтобы удалить: " ans
  [ "$(printf %s "$ans" | sed "s/\x1b\[[0-9;]*[A-Za-z]//g" | tr -dc A-Za-z)" = YES ] || { say "ничего не удалено"; return; }
  rm -rf "$run" "$SAMPLES/$code" "$NEW_RESULTS/$code"
  say "удалено. Образец можно запустить заново: ngs run $code F/M/U"
}

# ---------------------------------------------------------------- intake (автоприём из Очереди)
# You put a patient folder (ФИО in its name) into D:\data_annotated\Очередь; inside it one folder
# with the FASTQ (code at the end of its name, e.g. "..._F2500027392") and maybe PDF reports.
# `ngs intake sex` asks the sex; then the background intake (tmux ngs_intake):
#   1. keeps ~INTAKE_TARGET samples waiting in ngs queue, copying the next one D: -> /data/raredisease/samples
#      (inside WSL on C:, so ngs run does not copy it a second time) only when RAM is free, no archive
#      is writing to D: and /data keeps INTAKE_MIN_FREE_GB free; checks every FASTQ with gzip -t and
#      against the vendor's md5 list if there is one; moves the patient folder to D:\data_annotated
#   2. after the run and the md5-checked archive puts <date>_<code>_<sex> into the patient folder and
#      moves it to D:\1_fastq_rec (any PDF) or D:\2_fastq (no PDF)
# State of each patient lives in a small file ngs_intake.txt inside the patient folder (code, sex,
# state; no names). Patient names are only ever written on D: (folder names and Очередь\_журнал.txt),
# never into the pipeline folders, sample codes or queue.log.
INTAKE_CONF=$SETUP/conf/intake.conf
INTAKE_INBOX=/mnt/d/data_annotated/Очередь
INTAKE_WORK=/mnt/d/data_annotated
INTAKE_DONE_PDF=/mnt/d/1_fastq_rec
INTAKE_DONE_NOPDF=/mnt/d/2_fastq
INTAKE_TARGET=5            # samples waiting in the queue (the one computing is not counted)
INTAKE_MIN_FREE_GB=1000    # /data must still have this much free after copying a sample
INTAKE_MIN_RAM_GB=24       # copy only when this much RAM is available (9p bridge ENOMEM otherwise)
INTAKE_PERIOD_MIN=10
# shellcheck disable=SC1090
[ -f "$INTAKE_CONF" ] && . "$INTAKE_CONF"
MARK=ngs_intake.txt
ILOCK=$RUNS/intake.lock
ILAST=$RUNS/intake.last

intake_running() { tmux has-session -t ngs_intake 2>/dev/null; }
mget() { [ -f "$1/$MARK" ] || return 0; sed -n "s/^$2=//p" "$1/$MARK" | tail -n 1; }
mset() {  # mset DIR key value  (rewrite through a temp file: drvfs has no in-place sed -i rename issues)
  local f=$1/$MARK
  { grep -v "^$2=" "$f" 2>/dev/null || true; echo "$2=$3"; } > "$f.tmp" && mv -f "$f.tmp" "$f"
}
# journal on D: (may contain ФИО); the code-only part also goes to queue.log
jlog() {
  local l; l="$(TZ=Asia/Yakutsk date '+%F %T') $*"
  printf '%s\r\n' "$l" >> "$INTAKE_INBOX/_журнал.txt" 2>/dev/null || true
  [ -t 1 ] && echo "$l"; return 0
}
# the same waiting message only once until something changes
jlog_once() { [ "$(cat "$ILAST" 2>/dev/null)" = "$*" ] && return 0; echo "$*" > "$ILAST"; jlog "$*"; }
ram_gb() { awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo; }
fio() { basename "$1"; }

# patient folders: in the Очередь, and (with ngs_intake.txt) those already taken into work
intake_dirs() {
  local d
  for d in "$INTAKE_INBOX"/*/; do
    [ -d "$d" ] || continue; case "$(basename "$d")" in _*) continue;; esac; echo "${d%/}"
  done
  for d in "$INTAKE_WORK"/*/ "$INTAKE_DONE_PDF"/*/ "$INTAKE_DONE_NOPDF"/*/; do
    [ -f "$d$MARK" ] && [ "${d%/}" != "$INTAKE_INBOX" ] && echo "${d%/}"
  done
  return 0
}
# the one sub-folder of a patient folder that holds the FASTQ ("" + reason on stderr otherwise)
fastq_sub() {
  local p=$1 tops
  tops=$(find "$p" -mindepth 1 -maxdepth 4 -type f -name '*.f*q.gz' ! -path "$p/20??-??-??_*" -printf '%P\n' 2>/dev/null \
         | awk -F/ '{print (NF==1 ? "." : $1)}' | sort -u)
  if [ -z "$tops" ]; then echo "нет FASTQ (*.fq.gz / *.fastq.gz)" >&2; return 1; fi
  if printf '%s\n' "$tops" | grep -qx '\.'; then echo "FASTQ лежат прямо в папке пациента, нужна подпапка" >&2; return 1; fi
  if [ "$(printf '%s\n' "$tops" | wc -l)" -gt 1 ]; then echo "FASTQ в нескольких подпапках: $(printf '%s\n' "$tops" | tr '\n' ';')" >&2; return 1; fi
  echo "$tops"
}
# code from the end of the FASTQ folder name: "Первичные данные ..._F2500027392" -> F2500027392
guess_code() {
  local s=$1; s=${s##*[!A-Za-z0-9_-]}; s=${s#"${s%%[A-Za-z0-9]*}"}
  [ ${#s} -ge 4 ] && echo "$s"; return 0
}
code_busy() {  # prints why the code cannot be used now
  local c=$1
  [ -e "$RUNS/$c" ] && { echo "уже есть прогон $c (ngs status)"; return 0; }
  [ -e "$SAMPLES/$c" ] && { echo "уже есть /data/raredisease/samples/$c"; return 0; }
  [ -e "$NEW_SAMPLES/$c" ] && { echo "уже есть new_samples\\$c"; return 0; }
  grep -q "^$c " "$QUEUE" 2>/dev/null && { echo "$c уже в очереди"; return 0; }
  compgen -G "$INTAKE_WORK/20??-??-??_${c}_?" >/dev/null && { echo "на D: уже есть архив ..._${c}_"; return 0; }
  return 1
}
# the original FASTQ folder on D: of a sample taken through the intake (used by the archive)
intake_fastq_of() {
  local f d
  for f in "$INTAKE_WORK"/*/"$MARK" "$INTAKE_INBOX"/*/"$MARK"; do
    [ -f "$f" ] && grep -qx "code=$1" "$f" || continue
    d=$(dirname "$f"); [ -n "$(mget "$d" fastq)" ] && echo "$d/$(mget "$d" fastq)"; return 0
  done
  return 0
}

cmd_intake() {
  export LANG=C.UTF-8
  local sub=${1:-status}; shift || true
  case "$sub" in
    sex) intake_sex ;;
    status|list) intake_status ;;
    now) intake_mounted || die "диск D: не подключён"; mkdir -p "$RUNS"
         ( flock -n 9 || die "автоприём сейчас уже работает (подождите или ngs intake)"; intake_cycle ) 9> "$ILOCK" ;;
    start)
      intake_running && { say "автоприём уже работает"; return 0; }
      mkdir -p "$RUNS"
      tmux new-session -d -s ngs_intake "bash '$ME' _intake_loop"
      say "автоприём включён: проверяет Очередь каждые $INTAKE_PERIOD_MIN минут. Журнал: D:\\data_annotated\\Очередь\\_журнал.txt" ;;
    stop)
      intake_running || { say "автоприём и так выключен"; return 0; }
      tmux kill-session -t ngs_intake; rm -f "$COPYLOCK"
      say "автоприём выключен (очередь и прогоны продолжают работать). Если шло копирование, оно продолжится со следующего включения" ;;
    *) die "ngs intake sex|status|now|start|stop" ;;
  esac
}
intake_mounted() { mountpoint -q /mnt/d || sudo -n mount -t drvfs D: /mnt/d 2>/dev/null; }

cmd__intake_loop() {
  export LANG=C.UTF-8
  jlog "автоприём включён"
  while true; do
    if intake_mounted && [ -d "$INTAKE_INBOX" ]; then
      ( flock -n 9 || exit 0; intake_cycle ) 9> "$ILOCK" || true
    fi
    sleep $((INTAKE_PERIOD_MIN * 60))
  done
}

state_ru() {
  case "$1" in
    "") echo "нужен пол" ;; READY) echo "ждёт копирования" ;; COPYING) echo "копируется на C:" ;;
    QUEUED) echo "в очереди / считается" ;; FAILED) echo "ПРОГОН УПАЛ" ;; BAD) echo "ОШИБКА" ;;
    DONE) echo "готово" ;; MANUAL) echo "готово, перенести вручную" ;; *) echo "$1" ;;
  esac
}

intake_status() {
  export LANG=C.UTF-8
  intake_mounted || die "диск D: не подключён"
  intake_running && say "автоприём ВКЛЮЧЁН (каждые $INTAKE_PERIOD_MIN мин)" || warn "автоприём выключен (ngs intake start)"
  # padding by characters, not bytes (Cyrillic names)
  pad() { local t=${1:0:$2}; printf '%s%*s ' "$t" $(( $2 - ${#t} )) ''; }
  pad "ПАЦИЕНТ (папка)" 38; pad "КОД" 14; pad "ПОЛ" 3; pad "СОСТОЯНИЕ" 24; echo "ПРОГОН"
  local p st code rs why
  while IFS= read -r p; do
    st=$(mget "$p" state); code=$(mget "$p" code)
    [ "$st" = DONE ] && [ "$(dirname "$p")" != "$INTAKE_WORK" ] && [ "$(dirname "$p")" != "$INTAKE_INBOX" ] && continue
    why=""
    if [ -z "$st" ]; then
      if code=$(fastq_sub "$p" 2>/tmp/ngs_why.$$); then code=$(guess_code "$code"); else code=""; st=BAD; why=$(cat /tmp/ngs_why.$$); fi
      rm -f /tmp/ngs_why.$$
    fi
    rs=""; [ -n "$code" ] && rs=$(cat "$RUNS/$code/STATUS" 2>/dev/null || true)
    pad "$(fio "$p")" 38; pad "${code:--}" 14; pad "$(mget "$p" sex)" 3; pad "$(state_ru "$st")" 24; echo "$rs"
    [ -n "$why" ] && echo "      причина: $why"
    [ "$st" = BAD ] && [ -z "$why" ] && echo "      причина: $(mget "$p" note)"
  done < <(intake_dirs)
  echo; say "в очереди ждут: $(grep -c . "$QUEUE" 2>/dev/null || true) (цель $INTAKE_TARGET), /data свободно $(gb /data) ГБ, RAM свободно $(ram_gb) ГБ"
  [ -f "$INTAKE_INBOX/_журнал.txt" ] && { echo "журнал (последнее):"; tail -n 8 "$INTAKE_INBOX/_журнал.txt" | tr -d '\r' | sed 's/^/   /'; }
  return 0
}

# Ask the sex (and confirm the code) for the patients in the Очередь that are not taken yet.
intake_sex() {
  export LANG=C.UTF-8
  intake_mounted || die "диск D: не подключён"
  [ -d "$INTAKE_INBOX" ] || die "нет папки $INTAKE_INBOX"
  local p list=() sub code why sex pdf size st a n=0
  while IFS= read -r p; do [ "$(dirname "$p")" = "$INTAKE_INBOX" ] && list+=("$p"); done < <(intake_dirs)
  [ ${#list[@]} -gt 0 ] || { say "в Очереди пусто"; return 0; }
  say "Пациенты в Очереди. Пол: M, F или U (неизвестен). Enter оставить как есть / позже, k исправить код"
  for p in "${list[@]}"; do
    n=$((n+1)); st=$(mget "$p" state)
    case "$st" in COPYING|QUEUED|DONE|MANUAL) continue;; esac
    echo
    if ! sub=$(fastq_sub "$p" 2>/tmp/ngs_why.$$); then
      printf '%2d) %s\n    НЕ ПОДХОДИТ: %s\n' "$n" "$(fio "$p")" "$(cat /tmp/ngs_why.$$)"; rm -f /tmp/ngs_why.$$; continue
    fi
    rm -f /tmp/ngs_why.$$
    code=$(mget "$p" code); [ -n "$code" ] || code=$(guess_code "$sub")
    pdf=$(find "$p" -maxdepth 3 -iname '*.pdf' -print -quit); [ -n "$pdf" ] && pdf="есть -> 1_fastq_rec" || pdf="нет -> 2_fastq"
    size=$(du -s --block-size=1G "$p/$sub" 2>/dev/null | cut -f1)
    printf '%2d) %s\n    код: %s   FASTQ: %s файлов, %s ГБ   PDF: %s\n' "$n" "$(fio "$p")" "${code:-НЕ НАЙДЕН}" \
      "$(find "$p/$sub" -type f -name '*.f*q.gz' | wc -l)" "$size" "$pdf"
    [ "$st" = BAD ] && echo "    прошлый раз: ОШИБКА: $(mget "$p" note)  (новый ввод пола = попробовать снова)"
    while true; do
      read -r -p "    пол [$(mget "$p" sex)]: " a </dev/tty || return 0
      a=${a^^}
      case "$a" in
        "") break ;;
        K|К) read -r -p "    код образца (латиница, цифры, _ -): " code </dev/tty
             [[ "$code" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || { warn "такой код нельзя"; code=""; } ;;
        M|F|U|М)
          [ "$a" = М ] && a=M
          [ -n "$code" ] || { warn "сначала задайте код (k)"; continue; }
          if why=$(code_busy "$code"); then warn "$why. Задайте другой код (k) или разберитесь со старым прогоном"; continue; fi
          mset "$p" code "$code"; mset "$p" sex "$a"; mset "$p" fastq "$sub"
          [ -n "$(mget "$p" pheno)" ] || mset "$p" pheno 2
          mset "$p" state READY; mset "$p" ready_at "$(date +%s)"; mset "$p" note ""
          jlog "$(fio "$p") ($code): пол $a, ждёт копирования"
          say "записано: $code $a"; break ;;
        *) warn "M, F, U, Enter или k" ;;
      esac
    done
  done
  echo; intake_running && say "автоприём заберёт их сам (до $INTAKE_TARGET в очереди)" \
    || warn "автоприём выключен: включите (пункт 15 / ngs intake start) или проверьте сейчас (пункт 14)"
}

# gzip test + md5 in one read. Prints "OK <md5> <file>" or "BAD - <file>"
cmd__gzcheck() {
  local f=$1 z=gzip m; command -v pigz >/dev/null && z=pigz
  m=$(mktemp)
  if nice -n 10 tee >(md5sum | cut -c1-32 > "$m") < "$f" | $z -t 2>/dev/null; then
    local w=0; while [ ! -s "$m" ] && [ $w -lt 60 ]; do sleep 1; w=$((w+1)); done
    echo "OK $(cat "$m") $f"
  else echo "BAD - $f"; fi
  rm -f "$m"
}
# check every FASTQ in DIR; prints the bad files (relative), returns 1 if any
check_copy() {
  local dir=$1 vend res bad=""
  res=$(cd "$dir" && find . -type f -name '*.f*q.gz' -print0 | xargs -0 -r -n 1 -P 4 bash "$ME" _gzcheck)
  bad=$(printf '%s\n' "$res" | sed -n 's/^BAD - //p')
  # the vendor's md5 list (any *md5* file with "hash  name" lines) if there is one
  vend=$(cd "$dir" && find . -type f -iname '*md5*' ! -name '*.gz' -print -quit)
  if [ -n "$vend" ]; then
    local h f n=0 miss
    while read -r _ h f; do
      [ "$h" != - ] || continue
      miss=$(tr -d '\r' < "$dir/$vend" | awk -v n="$(basename "$f")" '{x=$NF; sub(/^\*/,"",x); sub(/.*\//,"",x)} x==n {print tolower($1); exit}')
      [ -n "$miss" ] || continue; n=$((n+1))
      [ "$miss" = "$h" ] || bad+=$'\n'"$f"
    done <<< "$res"
    echo "md5 поставщика: сверено $n файлов" >&2
  fi
  bad=$(printf '%s\n' "$bad" | sed '/^$/d' | sort -u)
  [ -z "$bad" ] && return 0
  printf '%s\n' "$bad"; return 1
}

# copy one patient's FASTQ D: -> /data/raredisease/samples/CODE, check, queue it. 0 ok, 1 bad, 2 try later
intake_stage() {
  local p=$1 code sex pheno sub src dst why try ok="" bad f
  code=$(mget "$p" code); sex=$(mget "$p" sex); pheno=$(mget "$p" pheno); sub=$(mget "$p" fastq)
  src=$p/$sub; dst=$SAMPLES/$code
  [ -d "$src" ] || { mset "$p" state BAD; mset "$p" note "нет папки FASTQ $sub"; jlog "$(fio "$p") ($code): ОШИБКА, нет папки $sub"; return 1; }
  if why=$(code_busy "$code"); then
    mset "$p" state BAD; mset "$p" note "$why"; jlog "$(fio "$p") ($code): ОШИБКА, $why"; return 1
  fi
  mset "$p" state COPYING; touch "$COPYLOCK"
  jlog "$(fio "$p") ($code): копирую FASTQ на C: ($(du -s --block-size=1G "$src" | cut -f1) ГБ)"
  qlog "$code: автоприём копирует FASTQ с D:"
  mkdir -p "$dst.part"
  for try in 1 2 3 4 5 6; do
    sync; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
    echo 1 | sudo -n tee /proc/sys/vm/compact_memory >/dev/null 2>&1 || true
    if nice -n 10 rsync -rt "$src"/ "$dst.part"/ 2>>"$QLOG"; then ok=1; break; fi
    [ $try -lt 6 ] && { qlog "$code: копирование прервалось (попытка $try из 6), повтор через 10 минут"; sleep 600; }
  done
  if [ -z "$ok" ]; then
    rm -f "$COPYLOCK"; mset "$p" state READY
    jlog "$(fio "$p") ($code): копирование не удалось 6 раз подряд, попробую позже"; return 2
  fi
  jlog "$(fio "$p") ($code): проверяю целостность FASTQ (gzip + md5)"
  if ! bad=$(check_copy "$dst.part" 2>>"$QLOG"); then
    # once more for the bad files: a bad copy over the bridge, or the source itself is broken
    while IFS= read -r f; do rm -f "$dst.part/$f"; done <<< "$bad"
    rsync -rt "$src"/ "$dst.part"/ 2>>"$QLOG" || true
    if ! bad=$(check_copy "$dst.part" 2>>"$QLOG"); then
      rm -rf "${dst:?}.part"; rm -f "$COPYLOCK"
      mset "$p" state BAD; mset "$p" note "битые FASTQ в исходной папке: $(echo "$bad" | sed 's|^\./||' | tr '\n' ' ')"
      jlog "$(fio "$p") ($code): ОШИБКА, битые FASTQ (дважды): $(echo "$bad" | sed 's|^\./||' | tr '\n' ' ' | sed 's/ *$//'). Нужна новая выгрузка; образец не ставлю"
      qlog "$code: автоприём: битые FASTQ, образец не поставлен"
      return 1
    fi
  fi
  mv "$dst.part" "$dst"; rm -f "$COPYLOCK"
  if ! bash "$ME" queue add "$code" "$sex" "$pheno" >> "$QLOG" 2>&1; then
    mset "$p" state BAD; mset "$p" note "не удалось поставить в очередь (см. queue.log)"
    jlog "$(fio "$p") ($code): ОШИБКА постановки в очередь"; return 1
  fi
  mset "$p" state QUEUED; mset "$p" queued_at "$(date +%s)"
  # the patient folder leaves the Очередь (as done by hand before): D:\data_annotated\ФИО
  local np=$INTAKE_WORK/$(fio "$p")
  if [ "$(dirname "$p")" = "$INTAKE_INBOX" ] && [ ! -e "$np" ] && mv "$p" "$np"; then p=$np; fi
  jlog "$(fio "$p") ($code $sex): FASTQ проверены, в очереди. Папка: $p"
  qlog "$code: автоприём: FASTQ проверены, поставлен в очередь"
  return 0
}

# after the md5-checked archive: <date>_<code>_<sex> into the patient folder, patient folder to its shelf
intake_finish() {
  local p=$1 code dest name target pdf
  code=$(mget "$p" code)
  dest=$(sed -n 's/^archive=//p' "$RUNS/$code/run_info.txt" | tail -n 1)
  [ -n "$dest" ] && [ -d "$dest" ] && [ -s "$dest/md5_raw.txt" ] && [ -s "$dest/md5_processed.txt" ] || {
    jlog_once "$(fio "$p") ($code): архив отмечен готовым, но папки $dest или её md5-списков нет, не трогаю"; return 1; }
  name=$(basename "$dest")
  if [ "$(dirname "$dest")" != "$p" ]; then
    [ -e "$p/$name" ] && { jlog_once "$(fio "$p") ($code): в папке пациента уже есть $name, не трогаю"; return 1; }
    mv "$dest" "$p/" || return 1
    sed -i "s|^archive=.*|archive=$RUNS/$code (перенесён в папку пациента)|" "$RUNS/$code/run_info.txt"
  fi
  [ -d "$p/$(mget "$p" fastq)" ] && [ -n "$(mget "$p" fastq)" ] && \
    jlog "$(fio "$p") ($code): исходная папка FASTQ осталась рядом (её копия в $name\\raw), можно удалить вручную"
  pdf=$(find "$p" -maxdepth 3 -iname '*.pdf' ! -path "$p/$name/*" -print -quit)
  [ -n "$pdf" ] && target=$INTAKE_DONE_PDF || target=$INTAKE_DONE_NOPDF
  mset "$p" state DONE; mset "$p" done_at "$(date +%s)"
  if [ -e "$target/$(fio "$p")" ]; then
    mset "$p" state MANUAL
    jlog "$(fio "$p") ($code): ГОТОВО, но в $(basename "$target") уже есть папка с таким именем; оставил в $(dirname "$p"), перенесите вручную"
    return 0
  fi
  mkdir -p "$target"
  if mv "$p" "$target/"; then
    jlog "$(fio "$p") ($code): ГОТОВО, md5 совпали, папка перенесена в $(basename "$target")"
    qlog "$code: автоприём: готово, разложено по папкам на D:"
  else
    mset "$p" state MANUAL; jlog "$(fio "$p") ($code): ГОТОВО, но перенести в $(basename "$target") не удалось, перенесите вручную"
  fi
}

intake_cycle() {
  local p st code rs waiting next
  # we hold the lock: a copy left half-done by a stopped intake / restart continues from where it was
  rm -f "$COPYLOCK"
  while IFS= read -r p; do
    [ "$(mget "$p" state)" = COPYING ] && mset "$p" state READY
  done < <(intake_dirs)
  # 1. finished / failed / interrupted samples
  while IFS= read -r p; do
    st=$(mget "$p" state); code=$(mget "$p" code)
    case "$st" in QUEUED|FAILED) ;; *) continue;; esac
    rs=$(cat "$RUNS/$code/STATUS" 2>/dev/null || echo "")
    case "$rs" in
      ARCHIVED) intake_finish "$p" || true ;;
      FAILED|RUNNING)
        running "$code" && continue
        grep -q "^$code " "$QUEUE" 2>/dev/null && continue
        if [ "$rs" = RUNNING ] && ! queue_running && [ "$(mget "$p" resumed)" != 1 ]; then
          # interrupted (PC restart): back to the head of the queue, the queue resumes it
          mset "$p" resumed 1; mkdir -p "$RUNS"; touch "$QUEUE"
          sed -i "1i $code $(mget "$p" sex) $(mget "$p" pheno)" "$QUEUE"; [ -s "$QUEUE" ] || echo "$code $(mget "$p" sex) $(mget "$p" pheno)" > "$QUEUE"
          jlog "$(fio "$p") ($code): прогон был прерван (перезагрузка?), вернул в начало очереди"
        elif [ "$st" != FAILED ] && { ! queue_running || tail -n 50 "$QLOG" | grep -q "$code: .*Оставлен на C:"; }; then
          mset "$p" state FAILED
          jlog "$(fio "$p") ($code): ПРОГОН УПАЛ (дважды). Данные оставлены на C:, разбор: ngs log $code; потом ngs resume $code"
        fi ;;
      ARCHIVING)
        # left by a PC restart in the middle of the copy to D: (nothing is archiving it now): start again,
        # rsync continues where it stopped; otherwise the intake would wait for it forever
        if ! pgrep -f "_autoarchive $code\$" >/dev/null && ! tmux has-session -t "arch_$code" 2>/dev/null; then
          tmux new-session -d -s "arch_$code" "bash '$ME' _autoarchive '$code' >> '$QLOG' 2>&1"
          jlog "$(fio "$p") ($code): перенос на D: был прерван (перезагрузка?), запустил его снова"
        fi ;;
      ARCHIVE_FAILED) jlog_once "$(fio "$p") ($code): перенос на D: пока не удался, повторится сам (ngs archive $code)" ;;
    esac
  done < <(intake_dirs)

  # 2. keep INTAKE_TARGET samples waiting in the queue
  while true; do
    waiting=$(grep -c . "$QUEUE" 2>/dev/null || true); waiting=${waiting:-0}
    [ "$waiting" -lt "$INTAKE_TARGET" ] || break
    next=""
    while IFS= read -r p; do
      [ "$(dirname "$p")" = "$INTAKE_INBOX" ] && [ "$(mget "$p" state)" = READY ] && echo "$(mget "$p" ready_at) $p"
    done < <(intake_dirs) | sort -n | sed -n '1s/^[^ ]* //p' > "$RUNS/intake.next" || true
    next=$(cat "$RUNS/intake.next"); rm -f "$RUNS/intake.next"
    [ -n "$next" ] || break
    code=$(mget "$next" code)
    if grep -qx ARCHIVING "$RUNS"/*/STATUS 2>/dev/null; then jlog_once "жду: идёт перенос архива на D:, копировать параллельно нельзя"; break; fi
    if [ "$(ram_gb)" -lt "$INTAKE_MIN_RAM_GB" ]; then jlog_once "жду: мало свободной памяти ($(ram_gb) ГБ), копирование позже"; break; fi
    local size; size=$(du -s --block-size=1G "$next/$(mget "$next" fastq)" 2>/dev/null | cut -f1)
    if [ $(( $(gb /data) - ${size:-0} )) -lt "$INTAKE_MIN_FREE_GB" ]; then
      jlog_once "жду места на C: (/data свободно $(gb /data) ГБ, образцу $code нужно $size ГБ + запас $INTAKE_MIN_FREE_GB)"; break
    fi
    local rc=0; intake_stage "$next" || rc=$?
    [ $rc = 2 ] && break
    rm -f "$ILAST"
  done

  # 3. the queue must be running when it has samples (after a restart too), unless stopped by hand
  if [ -s "$QUEUE" ] && ! queue_running && [ -f "$QHOLD" ]; then
    jlog_once "очередь остановлена вручную (ngs queue stop): сам не запускаю, запустите ngs queue start"
  elif [ -s "$QUEUE" ] && ! queue_running; then
    local head need=0; head=$(head -n 1 "$QUEUE" | cut -d' ' -f1)
    if [ ! -f "$RUNS/$head/run_info.txt" ] && [ -d "$SAMPLES/$head" ]; then
      need=$(( $(du -s --block-size=1G "$SAMPLES/$head" | cut -f1) * 6 + 200 ))
    fi
    if [ "$(gb /data)" -lt "$need" ]; then
      jlog_once "очередь ждёт места на C: для $head (/data свободно $(gb /data) ГБ, нужно ~$need)"
    elif docker info >/dev/null 2>&1; then
      bash "$ME" queue start >> "$QLOG" 2>&1 && jlog "очередь запущена автоприёмом ($(grep -c . "$QUEUE") образцов)"
    else jlog_once "очередь не запускаю: Docker не отвечает (sudo service docker start)"; fi
  fi
  return 0
}

# ---------------------------------------------------------------- menu
cmd_menu() {
  while true; do
    echo
    echo "=========== NGS пайплайн (nf-core/raredisease 3.1.2) ==========="
    echo " 1  Запустить новый образец (из C:\\NGS_pipeline\\new_samples)"
    echo " 2  Статус всех прогонов"
    echo " 3  Смотреть ход прогона (лог)"
    echo " 4  Продолжить упавший/остановленный прогон"
    echo " 5  Повторить перенос на D: (если сам не удался)"
    echo " 6  Остановить прогон"
    echo " 7  Проверка системы"
    echo " 8  Удалить неудачный прогон (FASTQ в new_samples остаются)"
    echo " 9  Очередь: показать"
    echo "10  Очередь: добавить образец"
    echo "11  Очередь: запустить"
    echo "--- Автоприём из D:\\data_annotated\\Очередь ---"
    echo "12  Указать пол новым пациентам в Очереди"
    echo "13  Автоприём: состояние"
    echo "14  Автоприём: проверить Очередь сейчас"
    echo "15  Автоприём: включить / выключить"
    echo " 0  Выход"
    read -r -p "Выбор: " c
    case "$c" in
      1) echo "Папки в new_samples:"; ls "$NEW_SAMPLES" 2>/dev/null | sed 's/^/   /'
         read -r -p "Код образца (имя папки): " code; read -r -p "Пол (F/M/U): " sex
         read -r -p "Больной? (Enter = да, n = здоровый): " p; [ "$p" = n ] && p=1 || p=2
         ( cmd_run "$code" "${sex^^}" "$p" ) ;;
      2) ( cmd_status ) ;;
      3) read -r -p "Код образца: " code; ( cmd_log "$code" ) || true ;;
      4) read -r -p "Код образца: " code; ( cmd_resume "$code" ) ;;
      5) read -r -p "Код образца: " code; ( cmd_archive "$code" ) ;;
      6) read -r -p "Код образца: " code; ( cmd_stop "$code" ) ;;
      7) ( cmd_check ) ;;
      8) read -r -p "Код образца: " code; ( cmd_discard "$code" ) ;;
      9) ( cmd_queue list ) ;;
     10) echo "Папки в new_samples:"; ls "$NEW_SAMPLES" 2>/dev/null | sed 's/^/   /'
         read -r -p "Код образца (имя папки): " code; read -r -p "Пол (F/M/U): " sex
         read -r -p "Больной? (Enter = да, n = здоровый): " p; [ "$p" = n ] && p=1 || p=2
         ( cmd_queue add "$code" "$sex" "$p" ) ;;
     11) ( cmd_queue start ) ;;
     12) ( cmd_intake sex ) ;;
     13) ( cmd_intake status ) ;;
     14) ( cmd_intake now ) ;;
     15) if intake_running; then ( cmd_intake stop ); else ( cmd_intake start ); fi ;;
      0|q) exit 0 ;;
    esac || true
  done
}

case "${1:-menu}" in
  menu|run|resume|status|log|stop|archive|discard|check|queue|intake|_worker|_queue_loop|_autoarchive|_autoarchive_core|_intake_loop|_gzcheck) c=${1:-menu}; shift || true; "cmd_$c" "$@" ;;
  *) sed -n '2,36p' "$ME" ;;
esac
