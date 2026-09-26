#!/bin/bash
# Print the resolved sysfs dir of whichever Apple iBridge HID device carries
# Touch Bar controls. HID instance suffixes (.0001 etc.) are registration
# ORDER and shift between boots - never hardcode them.
for d in /sys/bus/hid/devices/0003:05AC:8600.*; do
  r=$(readlink -f "$d" 2>/dev/null)
  if [ -e "$r/fnmode" ]; then printf '%s\n' "$r"; exit 0; fi
done
exit 1
