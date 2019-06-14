#!/bin/bash

if [ "$#" == '1' ] ; then
    envname="$1"
    . env.sh.$envname || true
else
    envname="testk"
    . env.sh || true
fi
cluster="${cluster:-$envname}"
helper_template="${helper_template:-CentOS-7-x86_64-GenericCloud.qcow2}"
template="${template:-rhcos-410.8.20190520.1-qemu.qcow2}"
api_ip="${api_ip:-}"
domain="${domain:-karmalabs.com}"
numcpus="${numcpus:-4}"
network="${network:-default}"
use_br="${use_br:-false}"
extra_disk="${extra_disk:-false}"
master_memory="${master_memory:-8192}"
worker_memory="${worker_memory:-8192}"
bootstrap_memory="${bootstrap_memory:-4096}"
disk_size="${disk_size:-30}"
extra_disk_size="${extra_disk_size:-10}"
masters="${masters:-1}"
workers="${workers:-0}"
tag="${tag:-cnvlab}"
pub_key="${pubkey:-$HOME/.ssh/id_rsa.pub}"
pull_secret="${pullsecret:-openshift_pull.json}"
RED='\033[0;31m'
BLUE='\033[0;36m'
NC='\033[0m'



clusterdir=clusters/$cluster
export KUBECONFIG=$PWD/$clusterdir/auth/kubeconfig
INSTALLER=$(which openshift-install 2>/dev/null)
if  [ "$INSTALLER" == "" ] ; then
 echo -e "${RED}Missing openshift-install binary. Get it at https://mirror.openshift.com/pub/openshift-v4/clients/ocp${NC}"
 exit 1
fi
OC=$(which oc 2>/dev/null)
if  [ "$OC" == "" ] ; then
 echo -e "${RED}Missing oc binary. Get it at https://mirror.openshift.com/pub/openshift-v4/clients/ocp${NC}"
 exit 1
fi

pub_key=`cat $pub_key`
pull_secret=`cat $pull_secret | tr -d '\n'`
mkdir -p $clusterdir || exit 1
sed "s%DOMAIN%$domain%" install-config.yaml > $clusterdir/install-config.yaml
sed -i "s%WORKERS%$workers%" $clusterdir/install-config.yaml
sed -i "s%MASTERS%$masters%" $clusterdir/install-config.yaml
sed -i "s%CLUSTER%$cluster%" $clusterdir/install-config.yaml
sed -i "s%PULLSECRET%$pull_secret%" $clusterdir/install-config.yaml
sed -i "s%PUBKEY%$pub_key%" $clusterdir/install-config.yaml

openshift-install --dir=$clusterdir create manifests
cp customisation/* $clusterdir/openshift
sed -i "s/3/$masters/" $clusterdir/openshift/99-ingress-controller.yaml
openshift-install --dir=$clusterdir create ignition-configs

platform=$(kcli list --clients | grep X | awk -F'|' '{print $3}' | xargs | sed 's/kvm/libvirt/')

if [[ "$platform" == *virt* ]]; then
  if [ -z "$api_ip" ] ; then
    # we deploy a temp vm to grab an ip for the api, if not predefined
    kcli vm -p $helper_template -P plan=$cluster -P nets=[$network] $cluster-helper
    api_ip=""
    while [ "$api_ip" == "" ] ; do
      api_ip=$(kcli info -f ip -v $cluster-helper)
      echo -e "${BLUE}Waiting 5s to retrieve api ip from helper node...${NC}"
      sleep 5
    done
    kcli delete --yes $cluster-helper
    echo -e "${BLUE}Using $api_ip for api vip ...${NC}"
    echo -e "${BLUE}Adding entry for api.$cluster.$domain in your /etc/hosts...${NC}"
    sudo sed -i "/api.$cluster.$domain/d" /etc/hosts
    sudo sh -c "echo $api_ip api.$cluster.$domain console-openshift-console.apps.$cluster.$domain oauth-openshift.apps.$cluster.$domain >> /etc/hosts"
  else
    echo -e "${BLUE}Using $api_ip for api vip ...${NC}"
    grep -q "$api_ip api.$cluster.$domain" /etc/hosts || sudo sh -c "echo $api_ip api.$cluster.$domain console-openshift-console.apps.$cluster.$domain oauth-openshift.apps.$cluster.$domain >> /etc/hosts"
  fi
  if [ "$platform" == "kubevirt" ] ; then
    # bootstrap ignition is too big for kubevirt to handle so we serve it from a dedicated temporary node
    kcli vm -p $helper_template -P plan=$cluster -P nets=[$network] -P files=$cluster-bootstrap-helper
    bootstrap_api_ip=""
    while [ "$bootstrap_api_ip" == "" ] ; do
      bootstrap_api_ip=$(kcli info -f ip -v $cluster-bootstrap-helper)
      echo -e "${BLUE}Waiting 5s for bootstrap helper node to be running...${NC}"
      sleep 5
    done
    sleep 15
    kcli ssh root@$cluster-bootstrap-helper "yum -y install httpd ; systemctl start httpd"
    kcli scp $clusterdir/bootstrap.ign root@$cluster-bootstrap-helper:/var/www/html/bootstrap
    sed "s@https://api-int.$cluster.$domain:22623/config/master@http://$bootstrap_api_ip/bootstrap@" $clusterdir/master.ign > $clusterdir/bootstrap.ign
  fi
  sed -i "s@https://api-int.$cluster.$domain:22623/config@http://$api_ip:8080@" $clusterdir/master.ign $clusterdir/worker.ign
fi

if [[ "$platform" != *virt* ]]; then
  # bootstrap ignition is too big for cloud platforms to handle so we serve it from a dedicated temporary node
  kcli vm -p $helper_template -P reservedns=true -P domain=$cluster.$domain -P tags=[$tag] -P plan=$cluster -P nets=[$network] $cluster-bootstrap-helper
  status=""
  while [ "$status" != "running" ] ; do
      status=$(kcli info -f status -v $cluster-bootstrap-helper | tr '[:upper:]' '[:lower:]')
      echo -e "${BLUE}Waiting 5s for bootstrap helper node to be running...${NC}"
      sleep 5
  done
  kcli ssh root@$cluster-bootstrap-helper "yum -y install httpd ; systemctl start httpd ; systemctl stop firewalld"
  kcli scp $cluster/bootstrap.ign root@$cluster-bootstrap-helper:/var/www/html/bootstrap
  sed s@https://api-int.$cluster.$domain:22623/config/master@http://$cluster-bootstrap-helper.$cluster.$domain/bootstrap@ $clusterdir/master.ign > $clusterdir/bootstrap.ign
fi

echo """cluster: $cluster
numcpus: $numcpus
network: $network
use_br: $use_br
extra_disk: $extra_disk
master_memory: $master_memory
worker_memory: $worker_memory
deploy_bootstrap: true
bootstrap_memory: $bootstrap_memory
disk_size: $disk_size
extra_disk_size: $extra_disk_size
template: $template
domain: $domain
masters: $masters
workers: $workers
api_ip: $api_ip""" > $clusterdir/kcli.yml

if [[ "$platform" == *virt* ]]; then
  kcli plan -f ocp.yml --paramfile $clusterdir/kcli.yml $cluster
  openshift-install --dir=$clusterdir wait-for bootstrap-complete || exit 1
  todelete="$cluster-bootstrap"
  [ "$platform" == "kubevirt" ] && todelete="$todelete $cluster-bootstrap-helper"
  [[ "$platform" != *"virt"* ]] && todelete="$todelete $cluster-bootstrap-helper"
  kcli delete --yes $todelete
else
  kcli plan -f ocp_cloud.yml --paramfile $clusterdir/kcli.yml $cluster
  openshift-install --dir=$clusterdir wait-for bootstrap-complete || exit 1
  api_ip=$(kcli info $cluster-master-0 -f ip -v)
  kcli delete --yes $cluster-bootstrap $cluster-helper
  kcli dns -n $domain -i $api_ip api.$cluster
  kcli dns -n $domain -i $api_ip api-int.$cluster
  echo -e "${BLUE}Adding temporary entry for api.$cluster.$domain in your /etc/hosts...${NC}"
  sudo sed -i "/api.$cluster.$domain/d" /etc/hosts
  sudo sh -c "echo $api_ip api.$cluster.$domain >> /etc/hosts"
fi

sed -i "s/deploy_bootstrap: .*/deploy_bootstrap: false/" $clusterdir/kcli.yml
if [ "$workers" -lt "1" ]; then
 oc adm taint nodes -l node-role.kubernetes.io/master node-role.kubernetes.io/master:NoSchedule-
fi
openshift-install --dir=$clusterdir wait-for install-complete || exit 1

if [[ "$platform" == *virt* ]]; then
  echo -e "${BLUE}Deleting temporary entry for api.$cluster.$domain in your /etc/hosts...${NC}"
  sudo sed -i "/api.$cluster.$domain/d" /etc/hosts
fi

if [[ "$platform" == *virt* ]]; then
  cp $clusterdir/worker.ign $clusterdir/worker.ign.ori
  curl -kL https://$api_ip:22623/config/worker -o $clusterdir/worker.ign
fi