terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 0.13"

  backend "remote" {
    hostname     = "app.terraform.io"
    organization = "home_001"

    workspaces {
      prefix = "anton-1diplom"
    }
  }
}

provider "yandex" {
  token = "${var.yandex_token}"
  cloud_id = "${var.yandex_cloud_id}"
  folder_id = "${var.yandex_folder_id}"
  zone = "${var.yandex_zone}"
}