sudo ifconfig ens17f0np0 inet 10.3.95.134 netmask 255.255.255.0 mtu 9000
sudo ethtool -G ens17f0np0 rx 8192
sudo ethtool -G ens17f0np0 tx 8192


