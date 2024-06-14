terraform {
  backend "s3" {
    endpoint = "https://storage.yandexcloud.net"
    bucket = "diplom-barankov"
    region = "ru-central1"
    key    = "terraform.tfstate"
    access_key = ""
    secret_key = ""
    skip_region_validation      = true
    skip_credentials_validation = true
  }
}