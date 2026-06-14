#!/bin/bash

for i in `seq 1 23`
do
    echo 0 > /sys/devices/system/cpu/cpu$i/online
done

