[master]
vm-master ansible_host=${master_ip} ansible_user=${admin_user}

[workers]
vm-worker-app   ansible_host=10.10.1.8 ansible_user=${admin_user} node_role=app      public_ip=${app_worker_ip}
vm-worker-infra ansible_host=10.10.1.5 ansible_user=${admin_user} node_role=infra
vm-worker-pg    ansible_host=10.10.1.6 ansible_user=${admin_user} node_role=db-sql
vm-worker-mongo ansible_host=10.10.1.7 ansible_user=${admin_user} node_role=db-nosql

[all:vars]
ansible_user=${admin_user}
ansible_ssh_private_key_file=~/.ssh/id_rsa
ansible_python_interpreter=/usr/bin/python3
master_public_ip=${master_ip}
app_worker_public_ip=${app_worker_ip}

[workers:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand="ssh -W %h:%p -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${admin_user}@${master_ip}"'
