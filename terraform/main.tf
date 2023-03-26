terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "4.51.0"
    }
  }
  backend "gcs" {
    bucket = "parkcheep-tf-state-prod"
    prefix = "terraform/state"
  }
}

provider "google" {
  credentials = file("parkcheep-gcp.json")

  project = "parkcheep"
  region  = "asia-southeast1"
  zone    = "asia-southeast1-a"
}

resource "google_compute_network" "vpc_network" {
  name                    = "terraform-network"
  auto_create_subnetworks = "true"
}

resource "google_service_account" "parkcheep_service_account" {
  account_id   = "parkcheep"
  display_name = "parkcheep"
  project      = "parkcheep"
}

resource "google_compute_instance" "vm_instance" {
  name         = "parkcheep-telegram"
  machine_type = "e2-micro"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
    }
  }

  network_interface {
    # A default network is created for all GCP projects
    network = google_compute_network.vpc_network.self_link
    access_config {
    }
  }

  service_account {
    email = google_service_account.parkcheep_service_account.email
    scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }
}

resource "google_compute_firewall" "default" {
  description        = "Allow SSH from anywhere"
  destination_ranges = []
  direction          = "INGRESS"
  disabled           = false
  name               = "default-allow-ssh"
  network            = google_compute_network.vpc_network.self_link
  priority           = 65534
  project            = "parkcheep"
  source_ranges = [
    "0.0.0.0/0",
  ]

  allow {
    ports = [
      "22",
    ]
    protocol = "tcp"
  }
}
