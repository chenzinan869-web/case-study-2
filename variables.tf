variable "region" {
  type    = string
  default = "eu-central-1"
}
variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}
variable "onprem_cidr" {
  description = "CIDR of the on-premise LAN behind the firewall"
  type        = string
  default     = "192.168.10.0/24"
}
variable "internal_domain" {
  type    = string
  default = "innovatech.internal"
}
variable "ssh_public_key" {
  description = "Public key of the Ansible node"
  type        = string
}
variable "instance_type_small" {
  type    = string
  default = "t3.small"
}
variable "instance_type_monitoring" {
  type    = string
  default = "t3.medium"
}
variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}
variable "log_retention_days" {
  type    = number
  default = 30
}
variable "soar_webhook_token" {
  description = "Shared secret Elastic sends in the X-Webhook-Token header"
  type        = string
  sensitive   = true
}
variable "kibana_url" {
  type    = string
  default = ""
}
variable "kibana_api_key" {
  type      = string
  default   = ""
  sensitive = true
}
variable "soar_min_tasks" {
  type    = number
  default = 2
}
variable "soar_max_tasks" {
  type    = number
  default = 6
}

variable "wireguard_client_public_key" {
  description = "Public key of the WireGuard client on the on-prem Ansible node"
  type        = string
}
variable "wireguard_port" {
  description = "UDP port of the WireGuard server"
  type        = number
  default     = 51820
}