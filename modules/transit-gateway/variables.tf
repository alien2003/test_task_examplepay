variable "name" {
  description = "Name prefix for transit gateway resources"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to attach to the transit gateway"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for the transit gateway attachment"
  type        = list(string)
}

variable "private_route_table_ids" {
  description = "Private route table IDs for adding routes to peer VPC"
  type        = list(string)
  default     = []
}

variable "peer_transit_gateway_id" {
  description = "Transit gateway ID in the peer region (null to skip peering)"
  type        = string
  default     = null
}

variable "peer_region" {
  description = "AWS region of the peer transit gateway"
  type        = string
  default     = ""
}

variable "peer_vpc_cidr" {
  description = "CIDR block of the peer VPC for routing"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags for all resources"
  type        = map(string)
  default     = {}
}
