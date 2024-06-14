resource "yandex_vpc_network" "my_vpc2" {
  name        = "my-vpc2"
  folder_id   = var.yandex_folder_id
}

resource "yandex_vpc_subnet" "my_subnet" {
  count        = 4
  name         = "my-subnet-${count.index+1}"
  folder_id    = var.yandex_folder_id
  zone = element(["ru-central1-a", "ru-central1-b", "ru-central1-c", "ru-central1-d"], count.index)
  network_id   = yandex_vpc_network.my_vpc2.id
  v4_cidr_blocks = ["192.168.${count.index}.0/16"]
}

resource "yandex_iam_service_account" "kluster-service" {
  folder_id = var.yandex_folder_id
  name      = "kluster-service"
}

resource "yandex_resourcemanager_folder_iam_member" "service-editor" {
  folder_id = var.yandex_folder_id
  role      = "editor"
  member    = "serviceAccount:${yandex_iam_service_account.kluster-service.id}"
}

resource "yandex_iam_service_account_static_access_key" "service-key" {
  service_account_id = yandex_iam_service_account.kluster-service.id
  description        = "static access key for object storage"
}

resource "yandex_kubernetes_cluster" "master" {
  name        = "master"
  network_id  = yandex_vpc_network.my_vpc2.id

  master {
    regional {
      region = "ru-central1"

      location {
      zone      = yandex_vpc_subnet.my_subnet[0].zone
      subnet_id = yandex_vpc_subnet.my_subnet[0].id
    }

      location {
      zone      = yandex_vpc_subnet.my_subnet[1].zone
      subnet_id = yandex_vpc_subnet.my_subnet[1].id
    }

    location {
      zone      = yandex_vpc_subnet.my_subnet[3].zone
      subnet_id = yandex_vpc_subnet.my_subnet[3].id
    }
    }
    public_ip = true
  }
  service_account_id       = yandex_iam_service_account.kluster-service.id
  node_service_account_id  = yandex_iam_service_account.kluster-service.id
  depends_on = [yandex_resourcemanager_folder_iam_member.service-editor]
}

resource "yandex_kubernetes_node_group" "worker-1-group" {
  cluster_id   = yandex_kubernetes_cluster.master.id
  name         = "worker-1-group"

  instance_template {
    platform_id = "standard-v2"

    resources {
    cores  = 2
    memory = 4
    core_fraction = 20
   }
    metadata = {
    ssh-keys = "ubuntu:${file(var.ssh_root_key)}"
    }
    network_interface {
      nat        = true
      subnet_ids = [yandex_vpc_subnet.my_subnet[0].id]
    }
    boot_disk {
      type = "network-hdd"
      size = 64
    }
    scheduling_policy {
      preemptible = false
    }
    container_runtime {
      type = "containerd"
    }
  }

  scale_policy {
    fixed_scale {
      size = 1
    }
  }

  allocation_policy {
    location {
      zone = yandex_vpc_subnet.my_subnet[0].zone
    }
  }
}

resource "yandex_kubernetes_node_group" "worker-2-group" {
  cluster_id = yandex_kubernetes_cluster.master.id
  name       = "worker-2-group"

  instance_template {
    platform_id = "standard-v2"
    
    resources {
    cores  = 2
    memory = 4
    core_fraction = 20
   }
    metadata = {
    ssh-keys = "ubuntu:${file(var.ssh_root_key)}"
    }
    network_interface {
      nat        = true
      subnet_ids = [yandex_vpc_subnet.my_subnet[1].id]
    }
    boot_disk {
      type = "network-hdd"
      size = 64
    }
    scheduling_policy {
      preemptible = false
    }
    container_runtime {
      type = "containerd"
    }
  }

  scale_policy {
    fixed_scale {
      size = 1
    }
  }

  allocation_policy {
    location {
      zone = yandex_vpc_subnet.my_subnet[1].zone
    }
  }
}

resource "yandex_kubernetes_node_group" "worker-3-group" {
  cluster_id = yandex_kubernetes_cluster.master.id
  name       = "worker-2-group"

  instance_template {
    platform_id = "standard-v2"
    
    resources {
    cores  = 2
    memory = 4
    core_fraction = 20
   }
    metadata = {
    ssh-keys = "ubuntu:${file(var.ssh_root_key)}"
    }
    network_interface {
      nat        = true
      subnet_ids = [yandex_vpc_subnet.my_subnet[3].id]
    }
    boot_disk {
      type = "network-hdd"
      size = 64
    }
    scheduling_policy {
      preemptible = false
    }
    container_runtime {
      type = "containerd"
    }
  }

  scale_policy {
    fixed_scale {
      size = 1
    }
  }

  allocation_policy {
    location {
      zone = yandex_vpc_subnet.my_subnet[3].zone
    }
  }
}

resource "null_resource" "cluster" {
  provisioner "local-exec" {
    command = <<EOF
kubectl config unset contexts.yc-master 
yc managed-kubernetes cluster get-credentials master --external 
kubectl cluster-info --kubeconfig ${var.home_dir}/.kube/config
EOF
  }
  depends_on = [
    yandex_kubernetes_cluster.master,
    yandex_kubernetes_node_group.worker-1-group,
    yandex_kubernetes_node_group.worker-2-group,
  ]
}

resource "yandex_container_registry" "diplom" {
  name      = "diplom"
  folder_id = var.yandex_folder_id

  provisioner "local-exec" {
    when    = destroy
    command = <<-CMD
    yc container image delete $(yc container image list | awk 'NR==4 {print $2}')
    CMD
  }
}

resource "yandex_container_registry_iam_binding" "puller" {
  registry_id = yandex_container_registry.diplom.id
  role        = "container-registry.images.puller"

  members = ["system:allUsers"]
}

locals {
  github_url = var.github_url
  repo_name  = regex("([^/]+)\\.git$", local.github_url)[0]
}

resource "null_resource" "example" {
  triggers = {
    repo_name = local.repo_name
  }
}

resource "null_resource" "download_githubfile" {
  provisioner "local-exec" {
    command     = "git clone ${var.github_url}"
    working_dir = var.diplom_dir
  }
}

resource "null_resource" "image_docker" {

  provisioner "local-exec" {
    command = <<-EOT
    sudo docker build -t cr.yandex/${yandex_container_registry.diplom.id}/nginx-image:latest .
    sudo docker login --username oauth --password-stdin var.yandex_token cr.yandex
    sudo docker push cr.yandex/${yandex_container_registry.diplom.id}/nginx-image:latest
  EOT
    working_dir = "${var.diplom_dir}/${local.repo_name}"
    interpreter = ["sudo", "sh", "-c"]
  }
  depends_on = [yandex_container_registry.diplom]
}

resource "local_file" "ingress_file" {
  filename = "ingress.yaml"
  content  = templatefile("./templates/ingress.tpl", {
    docker_image = yandex_container_registry.diplom.id
  })
  depends_on = [
    yandex_kubernetes_cluster.master,
    yandex_kubernetes_node_group.worker-1-group,
    yandex_kubernetes_node_group.worker-2-group
  ]
}

resource "null_resource" "install_kube-prometheus-ingress" {
  triggers = {
    always_run = "${timestamp()}"
  }

  provisioner "local-exec" {
    
    command = <<EOD
      kubectl create ns monitoring
      git clone https://github.com/prometheus-operator/kube-prometheus.git
      cd kube-prometheus
      kubectl apply --server-side -f manifests/setup
      kubectl wait --for condition=Established --all CustomResourceDefinition --namespace=monitoring
      kubectl apply -f manifests/
      helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && \
      helm repo update && \
      helm install ingress-nginx ingress-nginx/ingress-nginx
    EOD
    working_dir = var.diplom_dir
  }
  depends_on = [
    yandex_kubernetes_cluster.master,
    yandex_kubernetes_node_group.worker-1-group,
    yandex_kubernetes_node_group.worker-2-group
  ]
}

resource "null_resource" "install_patch" {

  provisioner "local-exec" {
    command = <<EOD
      if kubectl get nodes >/dev/null; then
        echo 'spec:' > external-ip.yaml
        echo '  externalIPs:' >> external-ip.yaml
        echo -n '  -  ' >> external-ip.yaml
        kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' >> external-ip.yaml
        echo -n '\n  -  ' >> external-ip.yaml
        kubectl get nodes -o jsonpath='{.items[1].status.addresses[?(@.type=="ExternalIP")].address}' >> external-ip.yaml
        kubectl -n default svc ingress-nginx-controller --patch "$(cat external-ip.yaml)"
        echo -n '  -  ' >> external-ip.yaml
        kubectl get nodes -o jsonpath='{.items[3].status.addresses[?(@.type=="ExternalIP")].address}' >> external-ip.yaml
        kubectl -n default patch svc ingress-nginx-controller --patch "$(cat external-ip.yaml)"
      fi
    EOD
  }
}

resource "null_resource" "install_qbec" {
  triggers = {
    always_run = "${timestamp()}"
  }
  provisioner "local-exec" {
    command = <<EOD
      wget https://github.com/splunk/qbec/releases/download/v0.15.2/qbec-linux-amd64.tar.gz
      mkdir qbec && tar -xvzf qbec-linux-amd64.tar.gz -C qbec
      rm qbec-linux-amd64.tar.gz
      sudo mv qbec/qbec /usr/local/bin/
    EOD
    working_dir = var.diplom_dir
  }
}
