subscription-manager repos --enable=openstack-15-tools-for-rhel-8-x86_64-rpms
alias python="python3"
yum -y install libvirt-libs libvirt-client ipmitool mkisofs tmux python3-openstackclient python3-ironicclient
nmcli connection add ifname provisioning type bridge con-name provisioning
nmcli con add type bridge-slave ifname eth1 master provisioning
nmcli connection add ifname baremetal type bridge con-name baremetal
nmcli con add type bridge-slave ifname eth0 master baremetal
nmcli con down "System eth0"; sudo pkill dhclient; sudo dhclient baremetal
nmcli connection modify provisioning ipv4.addresses {{ provisioning_installer_ip }}/{{ provisioning_cidr }} ipv4.method manual
nmcli con down provisioning
nmcli con up provisioning
