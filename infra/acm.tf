resource "aws_acm_certificate" "app" {
  count             = var.app_domain == "" ? 0 : 1
  domain_name       = var.app_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "app" {
  count           = var.app_domain == "" ? 0 : 1
  certificate_arn = aws_acm_certificate.app[0].arn
}

output "acm_validation_record" {
  description = "Create this CNAME in your DNS so ACM can issue the certificate"
  value = var.app_domain == "" ? null : {
    for o in aws_acm_certificate.app[0].domain_validation_options :
    o.domain_name => { name = o.resource_record_name, type = o.resource_record_type, value = o.resource_record_value }
  }
}