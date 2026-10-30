# Пайплайн полногеномного анализа редких заболеваний (СВФУ, лаборатория МГГ)

Конфиги и скрипты для запуска nf-core/raredisease 3.1.2 (GRCh38, Docker в WSL2 Ubuntu-24.04)
на лабораторных ПК и для просмотра результатов в Scout.

В репозитории **нет** данных пациентов, результатов, референсов и паролей. Референсы
(gnomAD, CADD, dbNSFP, REVEL, SpliceAI из CADD, индексы bwa/bwamem2, VEP cache) и Docker-образы
лежат внутри WSL (`/data/raredisease/references`) и переносятся клоном WSL (папка `second_pc/`).

## Что где

| Папка | Что внутри | Куда ставится на ПК |
|---|---|---|
| `raredisease-setup/` | `conf/local.config` (ресурсы под Ryzen 9950X / 126 ГБ), VEP-конфиги, params, ранг-модели, скрипты подготовки референсов | `/home/ngs/raredisease-setup` в Ubuntu |
| `manual/` | команда `ngs` (запуск, очередь, архив на D:), меню `NGS.bat`, инструкция `ngs_guide.html` | `bash manual/install_ngs.sh` |
| `scout-setup/` | установка Scout в отдельный WSL `scout`, загрузка кейсов, IGV | см. `scout-setup/README_ru.md` |
| `second_pc/` | клон всей системы на второй ПК через диск на доке | см. ниже |
| `windows/startup/` | keep-alive для автозапуска Ubuntu (`.wslconfig` в `raredisease-setup/windows/`) | папка «Автозагрузка» Windows |

## Второй ПК (такой же)

1. Старый ПК, когда ничего не считается: `second_pc\EXPORT_OLD_PC.bat` → копия в `E:\pc_clone`
   (Ubuntu с референсами и образами, Scout, `C:\NGS_pipeline`, `.wslconfig`, keep-alive).
2. Новый ПК: `wsl --install --no-distribution`, перезагрузка, подключить диск, `E:\pc_clone\IMPORT_NEW_PC.bat`.
3. Проверка: в Ubuntu `ngs check`.

## Обновление скриптов на обоих ПК

Правки делаются здесь, затем на каждом ПК в Ubuntu:

```bash
cd ~/nefu_mmhg_arctic_genomes_pipeline && git pull
rsync -a raredisease-setup/ ~/raredisease-setup/
bash manual/install_ngs.sh
```

## Правила

- Никаких имён пациентов в ID и путях; коды образцов в репозиторий не кладём.
- Результаты прогонов: `D:\data_annotated\<дата>_<код>_<пол>\{raw,processed}`, на C: не храним.
