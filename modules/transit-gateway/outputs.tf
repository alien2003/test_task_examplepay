output "transit_gateway_id" {
  description = "Transit Gateway ID"
  value       = aws_ec2_transit_gateway.this.id
}

output "transit_gateway_arn" {
  description = "Transit Gateway ARN"
  value       = aws_ec2_transit_gateway.this.arn
}

output "transit_gateway_route_table_id" {
  description = "Transit Gateway route table ID"
  value       = aws_ec2_transit_gateway_route_table.this.id
}

output "vpc_attachment_id" {
  description = "Transit Gateway VPC attachment ID"
  value       = aws_ec2_transit_gateway_vpc_attachment.this.id
}
