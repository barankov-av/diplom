resource "yandex_vpc_network" "my_vpc" {
  name        = "my-vpc"
  description = "my-vpc"
  folder_id   = var.yandex_folder_id
}

resource "yandex_vpc_subnet" "my_subnet" {
  count        = 4
  name         = "my-subnet-${count.index+1}"
  folder_id    = var.yandex_folder_id
  zone = element(["ru-central1-a", "ru-central1-b", "ru-central1-c", "ru-central1-d"], count.index)
  network_id   = yandex_vpc_network.my_vpc.id
  v4_cidr_blocks = ["192.168.${count.index+1}.0/24"]
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

resource "yandex_compute_disk" "k8s-node-disk" {
  name     = "k8s-node-disk"
  type     = "network-ssd"
  zone     = yandex_vpc_subnet.my_subnet[0].zone
  size     = 50
  image_id = "${var.node_worker_image_id}"
}

resource "yandex_compute_instance" "k8s-node" {
  name        = "k8s-node"
  zone        = yandex_vpc_subnet.my_subnet[0].zone
  platform_id = "standard-v1"

  resources {
    cores  = 2
    memory = 4
  }

  boot_disk {
    disk_id = yandex_compute_disk.k8s-node-disk.id
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.my_subnet[0].id
    nat = true
  }

  metadata = {
    ssh-keys = "ubuntu:${file(var.ssh_root_key)}"
  }
}

resource "yandex_compute_disk" "k8s-worker-disk" {
  count    = 2
  name     = "k8s-worker-disk${count.index + 1}"
  type     = "network-hdd"
  zone  = count.index == 0 ? yandex_vpc_subnet.my_subnet[1].zone : yandex_vpc_subnet.my_subnet[3].zone
  size     = 70
  image_id = "${var.node_worker_image_id}"
}

resource "yandex_compute_instance" "worker_instance" {
  count = 2
  name  = "k8s-worker-${count.index + 1}"
  zone  = count.index == 0 ? yandex_vpc_subnet.my_subnet[1].zone : yandex_vpc_subnet.my_subnet[3].zone
  platform_id = "standard-v2"

  resources {
    cores  = 4
    memory = 8
  }

  boot_disk {
    disk_id = element(yandex_compute_disk.k8s-worker-disk.*.id, count.index)
  }

  network_interface {
    subnet_id = count.index == 0 ? yandex_vpc_subnet.my_subnet[1].id : yandex_vpc_subnet.my_subnet[3].id
    nat = true
  }

  scheduling_policy {
    preemptible = true
  }

  metadata = {
    ssh-keys = "ubuntu:${file(var.ssh_root_key)}"
  }
}

resource "local_file" "ansible_inventory" {
  filename = "ansible_inventory.ini"
  content  = <<-EOT
  [webservers]
  k8s-node ansible_host=${yandex_compute_instance.k8s-node.network_interface.0.nat_ip_address}
  ${join("\n", [
    for instance in yandex_compute_instance.worker_instance :
    "${instance.name} ansible_host=${instance.network_interface.0.nat_ip_address}"
  ])}
  EOT
}

resource "local_file" "k8s_inventory" {
  filename = "k8s_inventory.ini"
  content  = templatefile("./templates/inventory_k8s.tpl", {
    node_name = yandex_compute_instance.k8s-node.name, ansible_host=yandex_compute_instance.k8s-node.network_interface.0.ip_address
    node_ip = yandex_compute_instance.k8s-node.network_interface.0.ip_address
    worker = join("\n", [
    for instance in yandex_compute_instance.worker_instance :
    "${instance.name} ansible_host=${instance.network_interface.0.ip_address}"
  ])
  worker_name = join("\n", [
    for instance in yandex_compute_instance.worker_instance : "${instance.name}"
  ])
  })
}

resource "yandex_container_registry" "diplom" {
  name      = "diplom"
  folder_id = var.yandex_folder_id
}

resource "yandex_container_registry_iam_binding" "puller" {
 registry_id = yandex_container_registry.diplom.id
 role        = "editor"

 members = ["serviceAccount:${yandex_iam_service_account.kluster-service.id}"]
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
  triggers = {
    always_run = "${timestamp()}"
  }

  provisioner "local-exec" {
    command = <<-EOT
    sudo usermod -aG docker root
    sudo docker build -t cr.yandex/${yandex_container_registry.diplom.id}/nginx-image:latest .
    sudo docker login --username oauth --var.yandex_token cr.yandex
    docker push cr.yandex/${yandex_container_registry.diplom.id}/nginx-image:latest
  EOT
    working_dir = "${var.diplom_dir}/${local.repo_name}"
    interpreter = ["sudo", "sh", "-c"]
  }
}

