provider "aws" {
  region = "us-west-1" # Change to your preferred region
}

# Generate a random suffix for the S3 bucket name
resource "random_id" "bucket_suffix" {
  byte_length = 8
}

# S3 Bucket for Frontend
resource "aws_s3_bucket" "frontend" {
  bucket = "food-delivery-frontend-${random_id.bucket_suffix.hex}"
}

# Disable Block Public Access for the S3 bucket
resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.bucket

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Set the S3 bucket ACL to public-read
resource "aws_s3_bucket_acl" "frontend" {
  bucket = aws_s3_bucket.frontend.bucket
  acl    = "public-read"

  depends_on = [aws_s3_bucket_public_access_block.frontend]
}

# Configure the S3 bucket as a static website
resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.bucket

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

# CloudFront Distribution
resource "aws_cloudfront_distribution" "frontend" {
  origin {
    domain_name = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id   = "S3-${aws_s3_bucket.frontend.bucket}"
  }

  enabled             = true
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${aws_s3_bucket.frontend.bucket}"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# DynamoDB Tables
resource "aws_dynamodb_table" "orders" {
  name           = "Orders"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "OrderID"

  attribute {
    name = "OrderID"
    type = "S"
  }
}

resource "aws_dynamodb_table" "users" {
  name           = "Users"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "UserID"

  attribute {
    name = "UserID"
    type = "S"
  }
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_exec" {
  name = "lambda_exec_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_dynamodb" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
}

# Lambda Functions
resource "aws_lambda_function" "order_management" {
  function_name = "OrderManagement"
  handler       = "index.handler"
  runtime       = "nodejs20.x" # Updated runtime
  role          = aws_iam_role.lambda_exec.arn

  filename         = "order_management.zip"
  source_code_hash = filebase64sha256("order_management.zip")
}

resource "aws_lambda_function" "user_authentication" {
  function_name = "UserAuthentication"
  handler       = "index.handler"
  runtime       = "nodejs20.x" # Updated runtime
  role          = aws_iam_role.lambda_exec.arn

  filename         = "user_authentication.zip"
  source_code_hash = filebase64sha256("user_authentication.zip")
}

resource "aws_lambda_function" "delivery_tracking" {
  function_name = "DeliveryTracking"
  handler       = "index.handler"
  runtime       = "nodejs20.x" # Updated runtime
  role          = aws_iam_role.lambda_exec.arn

  filename         = "delivery_tracking.zip"
  source_code_hash = filebase64sha256("delivery_tracking.zip")
}

# API Gateway
resource "aws_api_gateway_rest_api" "food_delivery" {
  name = "FoodDeliveryAPI"
}

resource "aws_api_gateway_resource" "orders" {
  rest_api_id = aws_api_gateway_rest_api.food_delivery.id
  parent_id   = aws_api_gateway_rest_api.food_delivery.root_resource_id
  path_part   = "orders"
}

resource "aws_api_gateway_method" "post_orders" {
  rest_api_id   = aws_api_gateway_rest_api.food_delivery.id
  resource_id   = aws_api_gateway_resource.orders.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "orders_integration" {
  rest_api_id             = aws_api_gateway_rest_api.food_delivery.id
  resource_id             = aws_api_gateway_resource.orders.id
  http_method             = aws_api_gateway_method.post_orders.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.order_management.invoke_arn
}

resource "aws_api_gateway_deployment" "food_delivery" {
  rest_api_id = aws_api_gateway_rest_api.food_delivery.id

  depends_on = [aws_api_gateway_integration.orders_integration]
}

resource "aws_api_gateway_stage" "prod" {
  stage_name    = "prod"
  rest_api_id   = aws_api_gateway_rest_api.food_delivery.id
  deployment_id = aws_api_gateway_deployment.food_delivery.id
}

# Cognito User Pool
resource "aws_cognito_user_pool" "users" {
  name = "FoodDeliveryUsers"
}

resource "aws_cognito_user_pool_client" "app_client" {
  name         = "FoodDeliveryApp"
  user_pool_id = aws_cognito_user_pool.users.id

  depends_on = [aws_cognito_user_pool.users]
}

# Outputs
output "s3_bucket_name" {
  value = aws_s3_bucket.frontend.bucket
}

output "cloudfront_domain" {
  value = aws_cloudfront_distribution.frontend.domain_name
}

output "api_gateway_endpoint" {
  value = "${aws_api_gateway_stage.prod.invoke_url}/prod"
}