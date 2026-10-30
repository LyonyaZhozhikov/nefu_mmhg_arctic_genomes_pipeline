#!/usr/bin/env bash
# rename_user.sh OLD_EMAIL NEW_EMAIL: change a Scout login (run as root in the "scout" distro).
# Roles, institutes and the user's comments/assignments carry over.
set -euo pipefail
OLD=$1 NEW=$2
mongosh --quiet scout --eval "
  const u = db.user.findOne({_id:'$OLD'});
  if (!u) { print('ОШИБКА: нет пользователя $OLD'); quit(1); }
  if (db.user.findOne({_id:'$NEW'})) { print('ОШИБКА: $NEW уже есть'); quit(1); }
  u._id = '$NEW'; u.email = '$NEW';
  db.user.insertOne(u);
  db.user.deleteOne({_id:'$OLD'});
  db.event.updateMany({user_id:'$OLD'}, {\$set:{user_id:'$NEW'}});
  db.case.updateMany({assignees:'$OLD'}, {\$set:{'assignees.\$':'$NEW'}});
  print('вход теперь по адресу $NEW');"
systemctl restart scout-web
