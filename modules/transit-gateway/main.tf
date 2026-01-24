################################################################################
# Transit Gateway
################################################################################

resource "aws_ec2_transit_gateway" "this" {
  description                     = "ExamplePay cross-region transit gateway"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  auto_accept_shared_attachments  = "disable"
  dns_support                     = "enable"

  tags = merge(var.tags, {
    Name = "${var.name}-tgw"
  })
}

################################################################################
# Transit Gateway VPC Attachment
################################################################################

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = var.vpc_id
  subnet_ids         = var.subnet_ids

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = merge(var.tags, {
    Name = "${var.name}-tgw-attachment"
  })
}

################################################################################
# Transit Gateway Route Table
################################################################################

resource "aws_ec2_transit_gateway_route_table" "this" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-tgw-rt"
  })
}

resource "aws_ec2_transit_gateway_route_table_association" "this" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "this" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this.id
}

################################################################################
# Cross-Region Peering Attachment
################################################################################

resource "aws_ec2_transit_gateway_peering_attachment" "cross_region" {
  count = var.peer_transit_gateway_id != null ? 1 : 0

  transit_gateway_id      = aws_ec2_transit_gateway.this.id
  peer_transit_gateway_id = var.peer_transit_gateway_id
  peer_region             = var.peer_region

  tags = merge(var.tags, {
    Name = "${var.name}-tgw-peering-${var.peer_region}"
  })
}

resource "aws_ec2_transit_gateway_route" "cross_region" {
  count = var.peer_transit_gateway_id != null ? 1 : 0

  destination_cidr_block         = var.peer_vpc_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.cross_region[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this.id
}

################################################################################
# VPC Route to Transit Gateway
################################################################################

resource "aws_route" "to_peer_region" {
  count = var.peer_transit_gateway_id != null ? length(var.private_route_table_ids) : 0

  route_table_id         = var.private_route_table_ids[count.index]
  destination_cidr_block = var.peer_vpc_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
}
