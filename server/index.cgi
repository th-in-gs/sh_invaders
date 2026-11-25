#!/bin/sh
# Front page for invaders.now. BusyBox httpd runs this for / because the
# docroot has no index.html. Browsers ask for text/html and get the
# page; everything else (curl, wget, sh -c "$(curl ...)") gets the game.
# Both are read in place, so there is still one copy of the script.
game=/usr/local/games/sh_invaders.sh
page=/usr/local/share/sh-invaders/index.html

case ${HTTP_ACCEPT-} in
  *text/html*)
    file=$page
    type='text/html; charset=utf-8'
    ;;
  *)
    file=$game
    type='text/plain; charset=utf-8'
    ;;
esac

size=$(wc -c <"$file") || exit 1
printf 'Content-Type: %s\r\n' "$type"
printf 'Content-Length: %d\r\n' "$size"
# Same URL, two bodies: caches must key on Accept.
printf 'Vary: Accept\r\n'
printf '\r\n'

[ "${REQUEST_METHOD-}" = HEAD ] && exit 0
exec cat "$file"
