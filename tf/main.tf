data "google_project" "project" {
  project_id = var.gcp_project_id
}

locals {
  compute_service_account = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

resource "google_project_service" "services" {
  for_each = toset([
    "compute.googleapis.com",
    "bigquery.googleapis.com",
    "storage.googleapis.com",
    "bigqueryunified.googleapis.com",
    "aiplatform.googleapis.com",
    "pubsub.googleapis.com",
    "iam.googleapis.com",
    "cloudaicompanion.googleapis.com",
  ])
  project = var.gcp_project_id
  service = each.key
}

resource "google_compute_network" "vpc_network" {
  project                 = var.gcp_project_id
  name                    = "qwiklab-vpc"
  auto_create_subnetworks = true
}

resource "google_storage_bucket" "cloud-bucket" {
  name                        = "${var.gcp_project_id}-bucket"
  location                    = var.gcp_region
  project                     = var.gcp_project_id
  force_destroy               = true
  uniform_bucket_level_access = true
}

# ------------------------------------------------------------------------------
# IAM Roles for the Compute Engine default service account
# ------------------------------------------------------------------------------

resource "google_project_iam_member" "biquery_data_editor" {
  project = var.gcp_project_id
  role    = "roles/bigquery.dataEditor"
  member  = local.compute_service_account
  depends_on = [
    google_project_service.services
  ]
}

resource "google_project_iam_member" "biquery_user" {
  project = var.gcp_project_id
  role    = "roles/bigquery.user"
  member  = local.compute_service_account
  depends_on = [
    google_project_service.services
  ]
}

resource "google_project_iam_member" "aiplatform_user" {
  project = var.gcp_project_id
  role    = "roles/aiplatform.user"
  member  = local.compute_service_account
  depends_on = [
    google_project_service.services
  ]
}

resource "google_storage_bucket_iam_member" "public_access" {
  bucket = google_storage_bucket.cloud-bucket.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# ------------------------------------------------------------------------------
# Enable Audit Logs for all services
# ------------------------------------------------------------------------------
resource "google_project_iam_audit_config" "all-services" {
  project = "${var.gcp_project_id}"
  service = "allServices"
  audit_log_config {
    log_type = "ADMIN_READ"
  }
  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }
}

# ------------------------------------------------------------------------------
# Service Account for BigQuery Continuous Query
# ------------------------------------------------------------------------------
resource "google_service_account" "bq_continuous_query_sa" {
  account_id   = "bq-continuous-query-sa"
  display_name = "BigQuery Continuous Query Service Account"
  project      = var.gcp_project_id
  depends_on   = [google_project_service.services] 
}
resource "google_project_iam_member" "bq_job_user" {
  project = var.gcp_project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.bq_continuous_query_sa.email}"
}
resource "google_bigquery_dataset_iam_member" "sa_dataset_editor" {
  dataset_id = google_bigquery_dataset.continuous_queries.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.bq_continuous_query_sa.email}"
  depends_on = [google_bigquery_dataset.continuous_queries]
}

# ------------------------------------------------------------------------------
# Review GCS Upload
# ------------------------------------------------------------------------------
variable "local_review_directory" {
  description = "The path to the local 'review' directory."
  type        = string
  default     = "./review" # Assumes 'review' directory is in the same folder as main.tf
}

locals {
  review_files_to_upload = fileset(var.local_review_directory, "**/*")
}

resource "google_storage_bucket_object" "file_uploads" {
  for_each = local.review_files_to_upload

  bucket = google_storage_bucket.cloud-bucket.name
  name   = "review/${each.key}"
  source = "${var.local_review_directory}/${each.key}"

  # Optional: Automatically determine and set the MIME type for the object.
  #content_type = filemime("${var.local_upload_directory}/${each.key}")

  depends_on = [
    google_storage_bucket.cloud-bucket
  ]
}

# ------------------------------------------------------------------------------
# BigQuery
# ------------------------------------------------------------------------------
resource "google_bigquery_dataset" "dataset" {
  dataset_id                   = "cymbal"
  location                     = var.gcp_region
  project                      = var.gcp_project_id
  delete_contents_on_destroy  = true
  default_table_expiration_ms = 2592000000
}

# ------------------------------------------------------------------------------
# BigQuery Table (Customers)
# ------------------------------------------------------------------------------
resource "google_bigquery_table" "customers_table" {
  project    = var.gcp_project_id
  dataset_id = google_bigquery_dataset.dataset.dataset_id
  table_id   = "customers"
  schema     = file("rawdata/alchemy_data1.json") # Path relative to the main.tf file

  depends_on = [
    google_bigquery_dataset.dataset
  ]
}

# ------------------------------------------------------------------------------
# BigQuery Table (Products)
# ------------------------------------------------------------------------------
resource "google_bigquery_table" "products_table" {
  project    = var.gcp_project_id
  dataset_id = google_bigquery_dataset.dataset.dataset_id
  table_id   = "products"
  schema     = file("rawdata/products_schema.json") # Path relative to the main.tf file

  depends_on = [
    google_bigquery_dataset.dataset
  ]
}

# ------------------------------------------------------------------------------
# BigQuery Dataset for Continuous Queries
# ------------------------------------------------------------------------------
resource "google_bigquery_dataset" "continuous_queries" {
  dataset_id  = "continuous_queries"
  description = "BigQuery dataset for continuous queries"
  location    = var.gcp_region
  project     = var.gcp_project_id

  labels = {
    env = "prod"
  }
  depends_on = [google_project_service.services]
}

resource "google_bigquery_table" "negative_customer_segment_products" {
  dataset_id = google_bigquery_dataset.continuous_queries.dataset_id
  table_id   = "negative_customer_segment_products"
  project    = var.gcp_project_id
  schema = jsonencode([
    {
      name = "customer_id",
      type = "INTEGER"
    },
    {
      name = "customer_name",
      type = "STRING"
    },
    {
      name = "customer_email",
      type = "STRING"
    },
    {
      name = "segment",
      type = "STRING"
    },
    {
      name = "top_products",
      type = "STRING"
    },
    {
      name = "recommended_products",
      type = "STRING"
    }
  ])
  depends_on = [google_bigquery_dataset.continuous_queries]
}

# ------------------------------------------------------------------------------
# Upload the alchemy_data1.csv file to GCS
# ------------------------------------------------------------------------------
resource "google_storage_bucket_object" "alchemy_csv_upload" {
  bucket = google_storage_bucket.cloud-bucket.name
  name   = "bq_data/alchemy_data1.csv" # Object name in GCS
  source = "rawdata/alchemy_data1.csv"      # Path to local CSV file, relative to main.tf

  depends_on = [
    google_storage_bucket.cloud-bucket
  ]
}

# ------------------------------------------------------------------------------
# Upload the products_info.csv file to GCS
# ------------------------------------------------------------------------------
resource "google_storage_bucket_object" "products_csv_upload" {
  bucket = google_storage_bucket.cloud-bucket.name
  name   = "bq_data/products_info.csv" # Object name in GCS
  source = "rawdata/products_info.csv"      # Path to local json file

  depends_on = [
    google_storage_bucket.cloud-bucket
  ]
}

# ------------------------------------------------------------------------------
# Upload the eventdata json to GCS
# ------------------------------------------------------------------------------
resource "google_storage_bucket_object" "eventdata_json_upload" {
  bucket = google_storage_bucket.cloud-bucket.name
  name   = "eventdata/recent_retail_events.json" # Object name in GCS
  source = "eventdata/recent_retail_events.json"      # Path to local json file

  depends_on = [
    google_storage_bucket.cloud-bucket
  ]
}
# ------------------------------------------------------------------------------
# Upload the eventdata py to GCS
# ------------------------------------------------------------------------------
resource "google_storage_bucket_object" "eventdata_py_upload" {
  bucket = google_storage_bucket.cloud-bucket.name
  name   = "eventdata/update_event_time.py" # Object name in GCS
  source = "eventdata/update_event_time.py"      # Path to local json file

  depends_on = [
    google_storage_bucket.cloud-bucket
  ]
}

# ------------------------------------------------------------------------------
# Upload the customer_review_enforcement file to GCS
# ------------------------------------------------------------------------------
resource "google_storage_bucket_object" "customer_review_enforcement_upload" {
  bucket = google_storage_bucket.cloud-bucket.name
  name   = "task5/customer_review_enforcement.csv" # Object name in GCS
  source = "rawdata/customer_review_enforcement.csv" # Local path to file

  depends_on = [
    google_storage_bucket.cloud-bucket
  ]
}

# ------------------------------------------------------------------------------
# Upload the product_info_enforcement file to GCS
# ------------------------------------------------------------------------------
resource "google_storage_bucket_object" "product_info_enforcement_upload" {
  bucket = google_storage_bucket.cloud-bucket.name
  name   = "task5/product_info_enforcement.csv" # Object name in GCS
  source = "rawdata/product_info_enforcement.csv" # Local path to file

  depends_on = [
    google_storage_bucket.cloud-bucket
  ]
}

# ------------------------------------------------------------------------------
# Compute to run startup script
# ------------------------------------------------------------------------------
resource "google_compute_instance" "lab_setup" {
  project      = var.gcp_project_id
  zone         = var.gcp_zone
  name         = "lab-setup"
  machine_type = "e2-standard-2"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  network_interface {
    network = google_compute_network.vpc_network.name
  }
  service_account {
    scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
      "https://www.googleapis.com/auth/devstorage.read_write"
    ]
  }

  metadata = {
    startup-script     = file("script/startup.sh")
  }
  depends_on = [
    google_storage_bucket_object.eventdata_json_upload, 
    google_storage_bucket_object.eventdata_py_upload,
    google_storage_bucket_object.customer_review_enforcement_upload,
    google_storage_bucket_object.product_info_enforcement_upload,
  ]
}

# ------------------------------------------------------------------------------
# BigQuery job to load data into the customers table
# ------------------------------------------------------------------------------
resource "google_bigquery_job" "load_customers_data" {
  project  = var.gcp_project_id
  location = var.gcp_region
  job_id   = "${var.gcp_project_id}-load-customers-data" # Unique job ID

  load {
    source_uris = [
      "gs://${google_storage_bucket.cloud-bucket.name}/${google_storage_bucket_object.alchemy_csv_upload.name}"
    ]

    destination_table {
      project_id = var.gcp_project_id
      dataset_id = google_bigquery_dataset.dataset.dataset_id
      table_id   = google_bigquery_table.customers_table.table_id
    }

    source_format      = "CSV"
    skip_leading_rows  = 1 # Skip the header row
    write_disposition  = "WRITE_TRUNCATE" # Overwrite table if it exists
    autodetect         = false # Rely on the table's predefined schema
  }

  depends_on = [
    google_storage_bucket_object.alchemy_csv_upload,
    google_bigquery_table.customers_table
  ]
}

# ------------------------------------------------------------------------------
# BigQuery job to load data into the products table
# ------------------------------------------------------------------------------
resource "google_bigquery_job" "load_products_data" {
  project  = var.gcp_project_id
  location = var.gcp_region
  job_id   = "${var.gcp_project_id}-load-products-data" # Unique job ID

  load {
    source_uris = [
      "gs://${google_storage_bucket.cloud-bucket.name}/${google_storage_bucket_object.products_csv_upload.name}"
    ]

    destination_table {
      project_id = var.gcp_project_id
      dataset_id = google_bigquery_dataset.dataset.dataset_id
      table_id   = google_bigquery_table.products_table.table_id
    }

    source_format      = "CSV"
    skip_leading_rows  = 1
    write_disposition  = "WRITE_TRUNCATE" # Overwrite table if it exists
    #autodetect         = false # Rely on the table's predefined schema
  }

  depends_on = [
    google_storage_bucket_object.products_csv_upload,
    google_bigquery_table.products_table
  ]
}

# ------------------------------------------------------------------------------
# Pub/Sub Topic for Event Data
# ------------------------------------------------------------------------------

resource "google_pubsub_topic" "recapture_customer" {
  name    = "recapture_customer"
  project = var.gcp_project_id

  labels = {
    foo = "recapture_customer"
  }
  depends_on = [google_project_service.services]
}
resource "google_pubsub_subscription" "recapture_customer_sub" {
  name    = "recapture_customer_subscription"
  topic   = google_pubsub_topic.recapture_customer.name
  project = var.gcp_project_id

  ack_deadline_seconds = 10
  
  depends_on = [google_pubsub_topic.recapture_customer]
}