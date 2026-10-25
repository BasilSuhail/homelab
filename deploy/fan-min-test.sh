#!/usr/bin/env bash
# Finds the lowest power each case fan keeps turning at, for the fan curve
# (deploy/fan-curve.py "start"). About two minutes; changes nothing lasting.
# Pauses the fan control, steps each fan down from 40% and reads its rpm,
# then switches the fan control back on (also if this is interrupted).
# Run on the board:  sudo bash deploy/fan-min-test.sh
h=$(dirname "$(grep -l '^it8' /sys/class/hwmon/hwmon*/name | head -1)")
[ -d "$h" ] || { echo "fan chip not found"; exit 1; }
trap 'systemctl start pi-fans; echo; echo "fan control back on"' EXIT
systemctl stop pi-fans
for p in 2 3 4; do echo 1 > "$h/pwm${p}_enable"; echo 0 > "$h/pwm$p"; done
names=([2]="Exhaust" [3]="Intake top" [4]="Intake bottom")
for p in 2 3 4; do
  echo "== ${names[$p]} (pwm$p)"
  # A stopped fan needs a push; then step down and see where it gives up.
  echo 255 > "$h/pwm$p"; sleep 3
  for d in 102 90 77 64 51 38 26 13; do
    echo "$d" > "$h/pwm$p"; sleep 5
    printf '  %3d%%  %5s rpm\n' $((d * 100 / 255)) "$(cat "$h/fan${p}_input")"
  done
  echo 0 > "$h/pwm$p"
done
