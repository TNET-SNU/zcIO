for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    sudo echo 1 | sudo tee $cpu/online
done

