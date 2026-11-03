#!/usr/bin/env bash
#
# boot-timeline.sh -- how long did this machine take to come back after each restart?
#
#     bash bench/boot-timeline.sh            # no root needed on Ubuntu if your user is in "adm";
#     sudo bash bench/boot-timeline.sh       # otherwise run it with sudo
#
# For every boot still in the system journal it prints one line:
#   start         the first journal line of that boot (the kernel starting)
#   gap_before    seconds between the last line of the previous boot and this start, i.e. how
#                 long the machine was off (for a plain restart this is the hypervisor's
#                 stop + start time; for an outage it is the whole outage)
#   net / ssh / docker / postgres / apache ...   seconds after start until that service was up,
#                 "-" when the service is not installed or did not log within 30 minutes
#   timeouts      services whose start timed out in the first 30 minutes (a sign the machine
#                 was starved of disk or CPU while booting)
# It ends with "systemd-analyze" for the current boot (kernel + userspace time) and the five
# slowest units of the current boot.
export LC_ALL=C
echo "== $(hostname)  now $(date '+%F %T %Z')  virt=$(systemd-detect-virt 2>/dev/null)  $(uptime -p)"
B=$(mktemp); journalctl --list-boots --no-pager 2>/dev/null | grep -E '^ *-?[0-9]+ ' | tail -n 12 > "$B"
echo "boots in journal: $(journalctl --list-boots --no-pager 2>/dev/null | grep -cE '^ *-?[0-9]+ ')  (showing last $(wc -l < "$B"))"
prev_last=""
while read -r idx _id _rest; do
  first=$(journalctl -b "$idx" -o short-unix -n all --no-pager 2>/dev/null | head -1 | cut -d' ' -f1 | cut -d. -f1)
  last=$(journalctl -b "$idx" -o short-unix -n 1 --no-pager 2>/dev/null | tail -1 | cut -d' ' -f1 | cut -d. -f1)
  [ -n "$first" ] || continue
  W=$(mktemp); journalctl -b "$idx" -o short-unix --no-pager --until "$(date -d @$((first+1800)) '+%F %T')" 2>/dev/null > "$W"
  t() { grep -m1 -E "$1" "$W" | cut -d' ' -f1 | cut -d. -f1; }
  d() { if [ -n "$1" ]; then echo "+$(( $1 - first ))s"; else echo "-"; fi; }
  net_t=$(t 'Reached target .*Network is Online')
  ssh_t=$(t 'Started (ssh.service - )?OpenBSD Secure Shell server|sshd\[[0-9]+\]: Server listening')
  pg_t=$(t 'database system is ready to accept')
  ap_t=$(t 'Started (apache2.service - )?The Apache HTTP Server')
  ng_t=$(t 'Started (nginx.service - )?A high performance web server')
  dk_t=$(t 'Started (docker.service - )?Docker Application Container Engine')
  fin_t=$(t 'systemd\[1\]: Startup finished in')
  tmo=$(grep -cE 'start operation timed out' "$W")
  gap="-"; [ -n "$prev_last" ] && gap="$(( first - prev_last ))s"
  echo "boot $idx  start $(date -d "@$first" '+%F %T')  gap_before $gap  net $(d "$net_t")  ssh $(d "$ssh_t")  docker $(d "$dk_t")  postgres $(d "$pg_t")  apache $(d "$ap_t")  nginx $(d "$ng_t")  startup-finished $(d "$fin_t")  timeouts $tmo  last_line $(date -d "@$last" '+%F %T')"
  prev_last=$last; rm -f "$W"
done < "$B"
rm -f "$B"
echo "-- current boot:"; systemd-analyze 2>/dev/null | head -1
echo "-- five slowest units of the current boot:"; systemd-analyze blame --no-pager 2>/dev/null | head -5
echo "-- what the critical path waited on:"; systemd-analyze critical-chain --no-pager 2>/dev/null | sed -n '4,12p'
