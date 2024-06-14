[all]
${node_name} ansible_host=${node_ip}
${worker}

[kube_control_plane]
${node_name}

[etcd]
${node_name}

[kube_node]
${worker_name}

[k8s_cluster:children]
kube_control_plane
kube_node