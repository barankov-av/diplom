resource "yandex_iam_service_account" "diplom-service" {
  folder_id = var.yandex_folder_id
  name      = "diplom-service"
}

resource "yandex_resourcemanager_folder_iam_member" "service-editor" {
  folder_id = var.yandex_folder_id
  role      = "editor"
  member    = "serviceAccount:${yandex_iam_service_account.diplom-service.id}"
}

resource "yandex_iam_service_account_static_access_key" "service-key" {
  service_account_id = yandex_iam_service_account.diplom-service.id
  description        = "static access key for object storage"
}

resource "local_file" "credentials_json_file" {
  filename = "key.json"
  content  = jsonencode({
    access_key = yandex_iam_service_account_static_access_key.service-key.access_key,
    secret_key = yandex_iam_service_account_static_access_key.service-key.secret_key
  })
}

resource "yandex_storage_bucket" "my_bucket" {
  access_key = yandex_iam_service_account_static_access_key.service-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.service-key.secret_key
  bucket = "diplom-barankov"
  acl  = "private"
  depends_on = [yandex_iam_service_account_static_access_key.service-key]
}