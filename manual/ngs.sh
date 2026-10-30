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
#
# Layout:
#   C:\NGS_pipeline\new_samples\CODE\      you put FASTQ here (any MGI/Illumina names, *_1/*_2 or *_R1/*_R2)
#   /data/raredisease/samples/CODE/        fast copy inside WSL (deleted by archive)
#   /data/raredisease/runs/CODE/           samplesheet, params, log, work/ (temporary, deleted by archive)
#   D:\data_annotated\<date>_<CODE>_<SEX>\   raw\ (FASTQ) and processed\ (results), md5 lists
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
  done < <(find "$dir" -maxdepth 1 -type f \( -name '*_R1*.f*q.gz' -o -name '*_1.f*q.gz' \) | sort)
  [ $n -gt 0 ] || die "в $dir не найдено FASTQ (*_1.fq.gz / *_R1.fastq.gz ...)"
  local total; total=$(find "$dir" -maxdepth 1 -type f -name '*.f*q.gz' | wc -l)
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
    rsync -rt --info=progress2 "$src"/ "$smp"/
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
      rm -f "$QSTOP"
      tmux new-session -d -s ngs_queue "bash '$ME' _queue_loop"
      say "очередь запущена в фоне. Окно можно закрыть."
      say "смотреть: ngs queue   журнал: tail -f $QLOG" ;;
    stop)
      queue_running || die "очередь не запущена"
      touch "$QSTOP"
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
md5list() {
  (cd "$1" && find -L . -type f ! -name '.*' -print0 | nice -n 19 ionice -c3 xargs -0 -r -n 4 -P "$2" md5sum) | LC_ALL=C sort
}

# Archive: /data -> D:, md5 check of every file, then delete the C: copies (no question).
cmd__autoarchive() {
  local code=$1 run=$RUNS/$1
  local try tries=${NGS_ARCHIVE_TRIES:-24}   # 24 x 20 min = 8 h: outlasts the RAM-heavy phases of the next sample
  echo "ARCHIVING" > "$run/STATUS"
  # Writes to D: (/mnt/d) can fail with "Cannot allocate memory" while the next sample
  # fills the RAM; rsync continues where it stopped, so simply try again a bit later.
  for try in $(seq 1 "$tries"); do
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
  size=$(( $(du -s --block-size=1G "$raw" | cut -f1) + $(du -sL --block-size=1G "$res" | cut -f1) + 5 ))
  [ "$(gb /mnt/d)" -ge "$size" ] || { echo "на D: мало места: нужно ~$size ГБ"; return 1; }
  qlog "$code: копирую на D:\\data_annotated\\${date}_${code}_${sex} (~$size ГБ)"
  mkdir -p "$dest/raw" "$dest/processed"
  local prog=(); [ -t 1 ] && prog=(--info=progress2)
  nice -n 19 rsync -rtL "${prog[@]}" "$raw"/ "$dest/raw"/
  nice -n 19 rsync -rtL "${prog[@]}" "$res"/ "$dest/processed"/
  for f in run.log params.yaml samplesheet.csv timing.txt run_info.txt; do
    if [ -f "$run/$f" ]; then cp "$run/$f" "$dest/processed/"; fi
  done

  qlog "$code: сверяю md5 (C: и D:)"
  md5list "$raw" 8 > "$run/md5_raw_C.txt"
  md5list "$dest/raw" 2 > "$run/md5_raw_D.txt"
  { md5list "$res" 8
    (cd "$run" && for f in run.log params.yaml samplesheet.csv timing.txt run_info.txt; do if [ -f "$f" ]; then md5sum "./$f"; fi; done)
  } | LC_ALL=C sort > "$run/md5_processed_C.txt"
  md5list "$dest/processed" 2 > "$run/md5_processed_D.txt"
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
      0|q) exit 0 ;;
    esac || true
  done
}

case "${1:-menu}" in
  menu|run|resume|status|log|stop|archive|discard|check|queue|_worker|_queue_loop|_autoarchive|_autoarchive_core) c=${1:-menu}; shift || true; "cmd_$c" "$@" ;;
  *) sed -n '2,28p' "$ME" ;;
esac
