variable "aws_region" {
  type    = string
  default = "ca-central-1"
}

# Configure the AWS Provider
provider "aws" {
  version = "~> 2.0"
  region  = var.aws_region
}

# Create ECR repository
resource "aws_ecr_repository" "learnusefulwords-service" {
  name                 = "learnusefulwords/service"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Create dynamodb tables
resource "aws_dynamodb_table" "learnusefulwords-word" {
  name           = "word"
  billing_mode   = "PROVISIONED"
  read_capacity  = 1
  write_capacity = 1
  hash_key       = "value"

  attribute {
    name = "value"
    type = "S"
  }

  tags = {
    Environment = "production"
  }
}