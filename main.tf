# Based on the tutorial in 
# https://docs.aws.amazon.com/AmazonS3/latest/userguide/website-hosting-custom-domain-walkthrough.html
# https://www.alexhyett.com/terraform-s3-static-website-hosting/

# DEPLOY:
# Sync the files
# aws s3 sync site/ s3://www.devroulette.com 
# Invalidates the cloundfront cache
# aws cloudfront create-invalidation --distribution-id <CLOUDFRONT-DIST-ID> --paths "/*";

# MATCH NS servers:
# Both domain and hosted zones servers need to match so go to these pages:
# https://console.aws.amazon.com/route53/home#DomainDetail:devroulette.com
# https://console.aws.amazon.com/route53/v2/hostedzones#

terraform {
  backend "s3" {
    bucket = "eduardo-terraform-states"
    key    = "production/static_site/"
    region = "us-east-1"
  }
}

provider "aws" {
  profile = "default"
  region  = "us-east-1"
}

locals {
  domain_name    = "devroulette.com"
  bucket_name    = "devroulette.com"
  common_tags    = {
    Owner = "Eduardo"
  }
}

############ S3 buckets ###############
resource "aws_s3_bucket" "www_bucket" {
  bucket = "www.${local.bucket_name}"
  policy = templatefile("templates/s3-policy.json", { bucket = "www.${local.bucket_name}" })
  force_destroy = true

  cors_rule {
    allowed_headers = ["Authorization", "Content-Length"]
    allowed_methods = ["GET"]
    allowed_origins = ["https://www.${local.domain_name}"]
    max_age_seconds = 3000
  }

  website {
    index_document = "index.html"
    error_document = "404.html"
  }

  tags = local.common_tags

  versioning {
    enabled = true
  }
}

resource "aws_s3_bucket" "root_bucket" {
  bucket = local.bucket_name
  acl = "public-read"
  policy = templatefile("templates/s3-policy.json", { bucket = local.bucket_name })
  force_destroy = true
  
  website {
    redirect_all_requests_to = "https://www.devroulette.com"
  }

  versioning {
    enabled = true
  }
}

############### Certificate validation (SSL) ######################
resource "aws_route53_zone" "main" {
  name = local.domain_name
  tags = local.common_tags
}

resource "aws_route53_record" "www-a" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "www.${local.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.www_s3_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.www_s3_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "root-a" {
  zone_id = aws_route53_zone.main.zone_id
  name    = local.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.root_s3_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.root_s3_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_acm_certificate" "ssl_certificate" {
  domain_name               = local.domain_name
  subject_alternative_names = ["*.${local.domain_name}"]
  validation_method         = "EMAIL"

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "cert_validation" {
  certificate_arn = aws_acm_certificate.ssl_certificate.arn
}

############ CLOUD FRONT ###############
resource "aws_cloudfront_distribution" "www_s3_distribution" {
  origin {
    # Assets origin. Resource in Aws that will provide the assets
    domain_name = aws_s3_bucket.www_bucket.website_endpoint
    # An unique identifer
    origin_id   = "S3-www.${local.bucket_name}"

    # Customs headers
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1", "TLSv1.1", "TLSv1.2"]
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  aliases = ["www.${local.domain_name}"]

  custom_error_response {
    error_caching_min_ttl = 0
    error_code            = 404
    response_code         = 200
    response_page_path    = "/404.html"
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-www.${local.bucket_name}"

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 31536000
    default_ttl            = 31536000
    max_ttl                = 31536000
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cert_validation.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.1_2016"
  }

  tags = local.common_tags
}

resource "aws_cloudfront_distribution" "root_s3_distribution" {
  origin {
    domain_name = aws_s3_bucket.root_bucket.website_endpoint
    origin_id   = "S3-.${local.bucket_name}"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1", "TLSv1.1", "TLSv1.2"]
    }
  }

  enabled         = true
  is_ipv6_enabled = true

  aliases = [local.domain_name]

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-.${local.bucket_name}"

    forwarded_values {
      query_string = true

      cookies {
        forward = "none"
      }

      headers = ["Origin"]
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 86400
    max_ttl                = 31536000
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cert_validation.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.1_2016"
  }

  tags = local.common_tags
}

output "root_cdn_distribution_id" {
  value       = aws_cloudfront_distribution.root_s3_distribution.id
  description = "Id for the root cdn distribution"
}

output "www_cdn_distribution_id" {
  value       = aws_cloudfront_distribution.www_s3_distribution.id
  description = "Id for the www cdn distribution"
}