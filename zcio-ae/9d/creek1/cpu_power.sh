#!/bin/bash

echo "check power"
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
sudo cpupower frequency-set -g performance
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

