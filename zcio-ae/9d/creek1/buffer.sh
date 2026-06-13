sudo sysctl net.core.rmem_max
sudo sysctl net.core.wmem_max
sudo sysctl net.core.rmem_default
sudo sysctl net.core.wmem_default

sudo sysctl net.ipv4.tcp_rmem
sudo sysctl net.ipv4.tcp_wmem

#sudo sysctl -w net.core.rmem_max=67108864
#sudo sysctl -w net.core.wmem_max=67108864
#sudo sysctl -w net.ipv4.tcp_rmem='4096 1048576 6291456'
#sudo sysctl -w net.ipv4.tcp_wmem='4096 1048576 6291456'

sudo sysctl -w net.core.rmem_max=67108864
sudo sysctl -w net.core.wmem_max=67108864
sudo sysctl -w net.ipv4.tcp_rmem='4096 1048576 67108864'
sudo sysctl -w net.ipv4.tcp_wmem='4096 1048576 67108864'

