variable "name" {
  description = "Name prefix for DNS resources"
  type        = string
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID"
  type        = string
}

variable "domain_name" {
  description = "Domain name for the DNS records"
  type        = string
}

variable "primary_ingress_fqdn" {
  description = "FQDN of the primary region ingress for health checks"
  type        = string
}

variable "secondary_ingress_fqdn" {
  description = "FQDN of the secondary region ingress for health checks"
  type        = string
}

variable "primary_alb_dns_name" {
  description = "DNS name of the primary ALB"
  type        = string
}

variable "primary_alb_zone_id" {
  description = "Zone ID of the primary ALB"
  type        = string
}

variable "secondary_alb_dns_name" {
  description = "DNS name of the secondary ALB"
  type        = string
}

variable "secondary_alb_zone_id" {
  description = "Zone ID of the secondary ALB"
  type        = string
}

variable "tags" {
  description = "Additional tags for all resources"
  type        = map(string)
  default     = {}
}
