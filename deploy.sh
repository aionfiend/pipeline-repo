#!/usr/bin/env bash
# Blue-green деплой. Использование:
#   deploy.sh deploy <tag>   развернуть новую версию
#   deploy.sh rollback       вернуться на предыдущую версию
#   deploy.sh status         показать состояние
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p state backups nginx/conf.d

ACTIVE=$(cat state/active 2>/dev/null || echo none)

other() { if [ "$1" = blue ]; then echo green; else echo blue; fi; }

load_tags() {
  BLUE_TAG=$(cat state/blue.tag 2>/dev/null || echo none)
  GREEN_TAG=$(cat state/green.tag 2>/dev/null || echo none)
  export BLUE_TAG GREEN_TAG
}

wait_healthy() {
  local s
  for _ in $(seq 1 40); do
    s=$(docker inspect -f '{{.State.Health.Status}}' "wiki-$1" 2>/dev/null || echo missing)
    [ "$s" = healthy ] && return 0
    sleep 3
  done
  return 1
}

point_proxy() {
  echo "upstream wiki_app { server $1:3000; }" > nginx/conf.d/upstream.conf
  if docker compose ps --status running --services | grep -qx proxy; then
    docker compose exec -T proxy nginx -s reload
  else
    docker compose up -d proxy
  fi
}

backup_db() {
  docker run --rm -v wiki_wikidata:/data -v "$PWD/backups:/backups" alpine \
    sh -c 'if [ -f /data/db.sqlite ]; then cp /data/db.sqlite /backups/db-$(date +%Y%m%d-%H%M%S).sqlite; fi'
}

deploy() {
  local tag=$1 new old_tag
  if [ "$ACTIVE" = none ]; then new=blue; else new=$(other "$ACTIVE"); fi
  old_tag=$(cat "state/$new.tag" 2>/dev/null || true)

  backup_db
  echo "$tag" > "state/$new.tag"
  load_tags

  docker compose pull "$new"
  docker compose up -d "$new"

  if ! wait_healthy "$new"; then
    echo "health-check failed: automatic rollback, traffic stays on $ACTIVE"
    docker compose stop "$new"
    if [ -n "$old_tag" ]; then echo "$old_tag" > "state/$new.tag"; else rm -f "state/$new.tag"; fi
    exit 1
  fi

  point_proxy "$new"
  echo "$new" > state/active
  if [ "$ACTIVE" != none ]; then docker compose stop "$ACTIVE"; fi
  echo "deployed $tag on $new"
}

rollback() {
  [ "$ACTIVE" != none ] || { echo "nothing to roll back"; exit 1; }
  local prev
  prev=$(other "$ACTIVE")
  [ -s "state/$prev.tag" ] || { echo "no previous version"; exit 1; }
  load_tags
  docker compose up -d "$prev"
  if ! wait_healthy "$prev"; then
    echo "previous version is unhealthy, rollback aborted"
    docker compose stop "$prev"
    exit 1
  fi
  point_proxy "$prev"
  echo "$prev" > state/active
  docker compose stop "$ACTIVE"
  echo "rolled back to $prev ($(cat "state/$prev.tag"))"
}

case "${1:-}" in
  deploy)   load_tags; deploy "${2:?tag required}" ;;
  rollback) load_tags; rollback ;;
  status)   echo "active=$ACTIVE blue=$(cat state/blue.tag 2>/dev/null || echo -) green=$(cat state/green.tag 2>/dev/null || echo -)" ;;
  *)        echo "usage: $0 deploy <tag> | rollback | status"; exit 1 ;;
esac
