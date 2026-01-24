output "primary_health_check_id" {
  description = "Health check ID for the primary region"
  value       = aws_route53_health_check.primary.id
}

output "secondary_health_check_id" {
  description = "Health check ID for the secondary region"
  value       = aws_route53_health_check.secondary.id
}

output "primary_record_fqdn" {
  description = "FQDN of the primary DNS record"
  value       = aws_route53_record.primary.fqdn
}

output "secondary_record_fqdn" {
  description = "FQDN of the secondary DNS record"
  value       = aws_route53_record.secondary.fqdn
}
