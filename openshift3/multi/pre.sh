yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
sed -i -e "s/^enabled=1/enabled=0/" /etc/yum.repos.d/epel.repo
yum -y install NetworkManager wget nc nano
systemctl enable NetworkManager
systemctl start NetworkManager
#yum -y update
#hostname | grep -q m01 || reboot
