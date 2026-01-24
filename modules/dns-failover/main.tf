################################################################################
# Route 53 Health Checks
################################################################################

resource "aws_route53_health_check" "primary" {
  fqdn              = var.primary_ingress_fqdn
  port              = 443
  type              = "HTTPS"
  resource_path     = "/healthz"
  failure_threshold = 3
  request_interval  = 10

  regions = ["us-east-1", "us-west-2", "eu-west-1"]

  tags = merge(var.tags, {
    Name = "${var.name}-primary-hc"
  })
}

resource "aws_route53_health_check" "secondary" {
  fqdn              = var.secondary_ingress_fqdn
  port              = 443
  type              = "HTTPS"
  resource_path     = "/healthz"
  failure_threshold = 3
  request_interval  = 10

  regions = ["us-east-1", "us-west-2", "eu-west-1"]

  tags = merge(var.tags, {
    Name = "${var.name}-secondary-hc"
  })
}

################################################################################
# Route 53 Latency-Based Routing with Health Checks
################################################################################

resource "aws_route53_record" "primary" {
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"

  set_identifier = "primary-us-east-1"

  latency_routing_policy {
    region = "us-east-1"
  }

  alias {
    name                   = var.primary_alb_dns_name
    zone_id                = var.primary_alb_zone_id
    evaluate_target_health = true
  }

  health_check_id = aws_route53_health_check.primary.id
}

resource "aws_route53_record" "secondary" {
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"

  set_identifier = "secondary-eu-west-1"

  latency_routing_policy {
    region = "eu-west-1"
  }

  alias {
    name                   = var.secondary_alb_dns_name
    zone_id                = var.secondary_alb_zone_id
    evaluate_target_health = true
  }

  health_check_id = aws_route53_health_check.secondary.id
}
