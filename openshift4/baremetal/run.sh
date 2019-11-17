python ipmi.py off
export PATH=/root:$PATH
export KUBECONFIG=/root/{{ cluster }}/auth/kubeconfig
export OS_CLOUD=metal3-bootstrap
export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=registry.svc.ci.openshift.org/ocp/release:{{ tag }}
mkdir {{ cluster }}
cp install-config.yaml {{ cluster }}
screen -S fix_configmap -dm bash -c "/root/fix_configmap.sh"
openshift-baremetal-install --dir {{ cluster }} --log-level debug create cluster