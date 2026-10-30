#!/usr/bin/env bash
# rename_institute.sh OLD NEW: move Scout from institute OLD to NEW (run as root in the "scout" distro).
# Cases of OLD are removed (reload them with scout_load.sh); the OMIM-AUTO panel and users move to NEW.
set -euo pipefail
OLD=$1 NEW=$2
export SCOUT_CONFIG=/opt/scout/config.py
SC="scout --flask-config $SCOUT_CONFIG"
say() { printf '\e[1;36m>>\e[0m %s\n' "$*"; }
if pgrep -f "scout.*load" >/dev/null; then
  echo "ОШИБКА: идёт загрузка в Scout; дождитесь конца или прервите её (Ctrl+C)" >&2; exit 1
fi
say "создаю институт $NEW"
mongosh --quiet scout --eval "db.institute.countDocuments({_id:'$NEW'})" | grep -qx 0 \
  && $SC load institute -i "$NEW" -d "$NEW"
say "переношу панели и пользователей, удаляю кейсы и варианты $OLD"
mongosh --quiet scout --eval "
  print('варианты: ' + db.variant.deleteMany({institute:'$OLD'}).deletedCount);
  print('кейсы: ' + db.case.deleteMany({owner:'$OLD'}).deletedCount);
  db.event.deleteMany({institute:'$OLD'});
  print('панели: ' + db.gene_panel.updateMany({institute:'$OLD'},{\$set:{institute:'$NEW'}}).modifiedCount);
  print('пользователи: ' + db.user.updateMany({institutes:'$OLD'},{\$set:{'institutes.\$':'$NEW'}}).modifiedCount);
  db.institute.deleteOne({_id:'$OLD'});"
systemctl restart scout-web
say "готово: теперь загрузите прогоны заново через SCOUT.bat load <прогон>"
