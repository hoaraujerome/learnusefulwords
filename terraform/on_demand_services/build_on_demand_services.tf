variable "aws_region" {
  type    = string
  default = "ca-central-1"
}

variable "aws_availability_zone" {
  type    = string
  default = "ca-central-1a"
}

# Configure the AWS Provider
provider "aws" {
  version = "~> 2.0"
  region  = var.aws_region
}

# Create a VPC in which containers will be networked.
resource "aws_vpc" "learnusefulwords" {
  cidr_block           = "10.0.0.0/16"
  instance_tenancy     = "default"
  enable_dns_support   = true
  enable_dns_hostnames = true
  enable_classiclink   = false

  tags = {
    Name = "learnusefulwords"
  }
}

# Create a public subnet where a public load balancer will later be created
resource "aws_subnet" "learnusefulwords-public" {
  vpc_id                  = aws_vpc.learnusefulwords.id
  cidr_block              = "10.0.0.0/24"
  map_public_ip_on_launch = true
  availability_zone       = var.aws_availability_zone

  tags = {
    Name = "learnusefulwords-public"
  }
}

# Create a private subnet where containers will only have private IP addresses, and will only be reachable by other members of the VPC
resource "aws_subnet" "learnusefulwords-private" {
  vpc_id                  = aws_vpc.learnusefulwords.id
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = false
  availability_zone       = var.aws_availability_zone

  tags = {
    Name = "learnusefulwords-private"
  }
}

# Setup networking resources for the public subnets.
# Create an internet gateway that enables communication between your VPC and the internet
resource "aws_internet_gateway" "learnusefulwords-gw" {
  vpc_id = aws_vpc.learnusefulwords.id

  tags = {
    Name = "learnusefulwords-gw"
  }
}

resource "aws_route_table" "learnusefulwords-public-rt" {
  vpc_id = aws_vpc.learnusefulwords.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.learnusefulwords-gw.id
  }

  tags = {
    Name = "learnusefulwords-public-rt"
  }
}

resource "aws_route_table_association" "learnusefulwords-public-subnet-rta" {
  subnet_id      = aws_subnet.learnusefulwords-public.id
  route_table_id = aws_route_table.learnusefulwords-public-rt.id
}

# Setup networking resources for the private subnets.
# Containers in these subnets have only private IP addresses, and must use a NAT gateway to talk to the internet.
resource "aws_eip" "learnusefulwords-nat" {
  vpc = true
}

resource "aws_nat_gateway" "learnusefulwords-gw" {
  allocation_id = aws_eip.learnusefulwords-nat.id
  subnet_id     = aws_subnet.learnusefulwords-public.id

  depends_on = [aws_internet_gateway.learnusefulwords-gw]

  tags = {
    Name = "learnusefulwords-gw"
  }
}

resource "aws_route_table" "learnusefulwords-private-rt" {
  vpc_id = aws_vpc.learnusefulwords.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_nat_gateway.learnusefulwords-gw.id
  }

  tags = {
    Name = "learnusefulwords-private-rt"
  }
}

resource "aws_route_table_association" "learnusefulwords-private-subnet-rta" {
  subnet_id      = aws_subnet.learnusefulwords-private.id
  route_table_id = aws_route_table.learnusefulwords-private-rt.id
}

# VPC Endpoint for DynamoDB
# If a container needs to access DynamoDB this
# allows a container in the private subnet to talk to DynamoDB directly
# without needing to go via the NAT gateway.
resource "aws_vpc_endpoint" "learnusefulwords-dynamodb" {
  vpc_id          = aws_vpc.learnusefulwords.id
  service_name    = "com.amazonaws.${var.aws_region}.dynamodb"
  route_table_ids = [aws_route_table.learnusefulwords-private-rt.id]

  tags = {
    Name = "learnusefulwords-dynamodb"
  }
}

# The security group for our service containers to be hosted in Fargate.
# Even though traffic from users will pass through a Network Load Balancer,
# that traffic is purely TCP passthrough, without security group inspection.
# Therefore, we will allow for traffic from the Internet to be accepted by our
# containers.  But, because the containers will only have Private IP addresses,
# the only traffic that will reach the containers is traffic that is routed
# to them by the public load balancer on the specific ports that we configure.
resource "aws_security_group" "learnusefulwords-fargate-container-sg" {
  name        = "learnusefulwords-fargate-container-sg"
  description = "Access to the fargate containers from the Internet"
  vpc_id      = aws_vpc.learnusefulwords.id

  ingress {
    from_port   = 0
    protocol    = -1
    to_port     = 0
    cidr_blocks = [aws_vpc.learnusefulwords.cidr_block]
  }

  egress {
    from_port   = 0
    protocol    = -1
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "learnusefulwords-fargate-container-sg"
  }
}

# This is an IAM role which authorizes ECS to manage resources on your
# account on your behalf, such as updating your load balancer with the
# details of where your containers are, so that traffic can reach your
# containers.
data "aws_iam_policy_document" "learnusefulwords-ecs-service-assume-role" {
  statement {
    effect = "Allow"
    principals {
      identifiers = ["ecs.amazonaws.com", "ecs-tasks.amazonaws.com"]
      type        = "Service"
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "learnusefulwords-ecs-service" {
  name               = "learnusefulwords-ecs-service"
  path               = "/"
  assume_role_policy = data.aws_iam_policy_document.learnusefulwords-ecs-service-assume-role.json

  tags = {
    Name = "learnusefulwords-ecs-service"
  }
}

data "aws_iam_policy_document" "learnusefulwords-ecs-service" {
  statement {
    effect = "Allow"
    actions = [
      # Rules which allow ECS to attach network interfaces to instances
      # on your behalf in order for awsvpc networking mode to work right
      "ec2:AttachNetworkInterface",
      "ec2:CreateNetworkInterface",
      "ec2:CreateNetworkInterfacePermission",
      "ec2:DeleteNetworkInterface",
      "ec2:DeleteNetworkInterfacePermission",
      "ec2:Describe*",
      "ec2:DetachNetworkInterface",
      # Rules which allow ECS to update load balancers on your behalf
      # with the information sabout how to send traffic to your containers
      "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
      "elasticloadbalancing:DeregisterTargets",
      "elasticloadbalancing:Describe*",
      "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
      "elasticloadbalancing:RegisterTargets",
      # Rules which allow ECS to run tasks that have IAM roles assigned to them.
      "iam:PassRole",
      # Rules that let ECS interact with container images.
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      # Rules that let ECS create and push logs to CloudWatch.
      "logs:DescribeLogStreams",
      "logs:CreateLogStream",
      "logs:CreateLogGroup",
      "logs:PutLogEvents"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "learnusefulwords-ecs-service" {
  name   = "learnusefulwords-ecs-service"
  role   = aws_iam_role.learnusefulwords-ecs-service.id
  policy = data.aws_iam_policy_document.learnusefulwords-ecs-service.json
}

# This is a role which is used by the ECS tasks. Tasks in Amazon ECS define
# the containers that should be deployed togehter and the resources they
# require from a compute/memory perspective. So, the policies below will define
# the IAM permissions that our learnusefulwords docker containers will have.
# If you attempted to write any code for the learnusefulwords service that
# interacted with different AWS service APIs, these roles would need to include
# those as allowed actions.
data "aws_iam_policy_document" "learnusefulwords-ecs-task-assume-role" {
  statement {
    effect = "Allow"
    principals {
      identifiers = ["ecs-tasks.amazonaws.com"]
      type        = "Service"
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "learnusefulwords-ecs-task" {
  name               = "learnusefulwords-ecs-task"
  path               = "/"
  assume_role_policy = data.aws_iam_policy_document.learnusefulwords-ecs-task-assume-role.json

  tags = {
    Name = "learnusefulwords-ecs-task"
  }
}

data "aws_dynamodb_table" "learnusefulwords-word" {
  name = "word"
}

data "aws_iam_policy_document" "learnusefulwords-ecs-task" {
  statement {
    effect = "Allow"
    actions = [
      # Allow the ECS Tasks to download images from ECR
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      # Allow the ECS tasks to upload logs to CloudWatch
      "logs:CreateLogStream",
      "logs:CreateLogGroup",
      "logs:PutLogEvents"
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      # Allows the ECS tasks to interact with only the learnusefulwords in DynamoDB
      "dynamodb:DeleteItem",
      "dynamodb:BatchWriteItem",
      "dynamodb:GetItem",
      "dynamodb:Scan",
      "dynamodb:UpdateItem"
    ]
    resources = [data.aws_dynamodb_table.learnusefulwords-word.arn]
  }
}

resource "aws_iam_role_policy" "learnusefulwords-ecs-task" {
  name   = "learnusefulwords-ecs-task"
  role   = aws_iam_role.learnusefulwords-ecs-task.id
  policy = data.aws_iam_policy_document.learnusefulwords-ecs-task.json
}

resource "aws_ecs_cluster" "learnusefulwords-cluster" {
  name = "learnusefulwords-cluster"
}

resource "aws_cloudwatch_log_group" "learnusefulwords-logs" {
  name = "learnusefulwords-logs"
}

data "aws_ecr_image" "learnusefulwords-microservice" {
  repository_name = "learnusefulwords/service"
  image_tag       = "latest"
}

resource "aws_ecs_task_definition" "learnusefulwords-service" {
  family                   = "learnusefulwords-service"
  cpu                      = "256"
  memory                   = "512"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.learnusefulwords-ecs-service.arn
  task_role_arn            = aws_iam_role.learnusefulwords-ecs-task.arn
  container_definitions    = <<TASK_DEFINITION
[{
	"name": "learnusefulwords-service",
	"image": "${data.aws_ecr_image.learnusefulwords-microservice.registry_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${data.aws_ecr_image.learnusefulwords-microservice.repository_name}:${data.aws_ecr_image.learnusefulwords-microservice.image_tag}",
	"portMappings": [{
		"containerPort": 8080,
		"protocol": "http"
	}],
	"environment": [{
		"name": "SPRING_PROFILES_ACTIVE",
		"value": "prod"
	}],
	"logConfiguration": {
		"logDriver": "awslogs",
		"options": {
			"awslogs-group": "${aws_cloudwatch_log_group.learnusefulwords-logs.name}",
			"awslogs-region": "${var.aws_region}",
			"awslogs-stream-prefix": "awslogs-learnusefulwords-service"
		}
	},
	"essential": true
}]
TASK_DEFINITION
}

resource "aws_lb" "learnusefulwords-nlb" {
  name               = "learnusefulwords-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets = [
  aws_subnet.learnusefulwords-public.id]
}

resource "aws_lb_target_group" "learnusefulwords-targetgroup" {
  name        = "learnusefulwords-targetgroup"
  port        = 8080
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = aws_vpc.learnusefulwords.id
  health_check {
    interval            = 10
    path                = "/actuator/health"
    protocol            = "HTTP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "learnusefulwords-listener" {
  load_balancer_arn = aws_lb.learnusefulwords-nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.learnusefulwords-targetgroup.arn
  }
}

resource "aws_ecs_service" "learnusefulwords-service" {
  name                               = "learnusefulwords-service"
  cluster                            = aws_ecs_cluster.learnusefulwords-cluster.id
  launch_type                        = "FARGATE"
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 0
  desired_count                      = 1
  network_configuration {
    assign_public_ip = "false"
    security_groups = [
      aws_security_group.learnusefulwords-fargate-container-sg.id
    ]
    subnets = [
      aws_subnet.learnusefulwords-private.id
    ]
  }
  task_definition = aws_ecs_task_definition.learnusefulwords-service.id
  load_balancer {
    container_name   = "learnusefulwords-service"
    container_port   = 8080
    target_group_arn = aws_lb_target_group.learnusefulwords-targetgroup.arn
  }
  depends_on = [
    aws_iam_role_policy.learnusefulwords-ecs-service,
    aws_iam_role_policy.learnusefulwords-ecs-task,
    aws_lb_listener.learnusefulwords-listener
  ]
}

# *********************************************************************
#                        API GATEWAY CONFIGURATION
# *********************************************************************
variable "api-gateway-request-header-authorization" {
  type    = string
  default = "method.request.header.Authorization"
}

resource "aws_api_gateway_rest_api" "learnusefulwords-api" {
  name = "learnusefulwords-api"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

variable "cognito-authorizer-type" {
  type    = string
  default = "COGNITO_USER_POOLS"
}

resource "aws_api_gateway_vpc_link" "learnusefulwords-api-vpc-link" {
  name = "learnusefulwords-api-vpc-link"
  target_arns = [
    aws_lb.learnusefulwords-nlb.arn
  ]
}

resource "aws_api_gateway_authorizer" "learnusefulwords-cognito-authorizer" {
  name        = "learnusefulwords-cognito-authorizer"
  rest_api_id = aws_api_gateway_rest_api.learnusefulwords-api.id
  type        = var.cognito-authorizer-type
  provider_arns = [
    "arn:aws:cognito-idp:us-east-1:577624126722:userpool/us-east-1_8zI40nKEX"
  ]
  identity_source = var.api-gateway-request-header-authorization
}

variable "cors-allowed-origin-learnusefulwords" {
  type    = string
  default = "'https://learnusefulwords.com'"
}

variable "cors-allowed-headers-learnusefulwords" {
  type    = string
  default = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'"
}

# REST Resource : addingsword
variable "learnusefulwords-api-ressource-addingsword" {
  type    = string
  default = "addingsword"
}

resource "aws_api_gateway_resource" "learnusefulwords-addingsword" {
  rest_api_id = aws_api_gateway_rest_api.learnusefulwords-api.id
  parent_id   = aws_api_gateway_rest_api.learnusefulwords-api.root_resource_id
  path_part   = var.learnusefulwords-api-ressource-addingsword
}

# Method : POST
resource "aws_api_gateway_method" "learnusefulwords-addingsword-post" {
  rest_api_id          = aws_api_gateway_rest_api.learnusefulwords-api.id
  resource_id          = aws_api_gateway_resource.learnusefulwords-addingsword.id
  http_method          = "POST"
  authorization        = var.cognito-authorizer-type
  authorizer_id        = aws_api_gateway_authorizer.learnusefulwords-cognito-authorizer.id
  authorization_scopes = ["email"]
  request_parameters = {
    "${var.api-gateway-request-header-authorization}" = true
  }
}

resource "aws_api_gateway_integration" "learnusefulwords-addingsword-post-integration-request" {
  http_method             = aws_api_gateway_method.learnusefulwords-addingsword-post.http_method
  resource_id             = aws_api_gateway_resource.learnusefulwords-addingsword.id
  rest_api_id             = aws_api_gateway_rest_api.learnusefulwords-api.id
  integration_http_method = aws_api_gateway_method.learnusefulwords-addingsword-post.http_method
  type                    = "HTTP"
  connection_type         = "VPC_LINK"
  connection_id           = aws_api_gateway_vpc_link.learnusefulwords-api-vpc-link.id
  uri                     = "http://${aws_lb.learnusefulwords-nlb.dns_name}/${var.learnusefulwords-api-ressource-addingsword}"
}

resource "aws_api_gateway_method_response" "learnusefulwords-addingsword-post-response" {
  http_method = aws_api_gateway_method.learnusefulwords-addingsword-post.http_method
  resource_id = aws_api_gateway_resource.learnusefulwords-addingsword.id
  rest_api_id = aws_api_gateway_rest_api.learnusefulwords-api.id
  status_code = 200
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_integration_response" "learnusefulwords-addingsword-post-integration-response" {
  http_method = aws_api_gateway_method.learnusefulwords-addingsword-post.http_method
  resource_id = aws_api_gateway_resource.learnusefulwords-addingsword.id
  rest_api_id = aws_api_gateway_rest_api.learnusefulwords-api.id
  status_code = aws_api_gateway_method_response.learnusefulwords-addingsword-post-response.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = var.cors-allowed-origin-learnusefulwords
  }
  response_templates = {
    "application/json" = ""
  }

  depends_on = [
    aws_api_gateway_integration.learnusefulwords-addingsword-post-integration-request,
    aws_api_gateway_method_response.learnusefulwords-addingsword-post-response
  ]
}

# Method : OPTIONS
resource "aws_api_gateway_method" "learnusefulwords-addingsword-options" {
  rest_api_id   = aws_api_gateway_rest_api.learnusefulwords-api.id
  resource_id   = aws_api_gateway_resource.learnusefulwords-addingsword.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "learnusefulwords-addingsword-options-integration-request" {
  http_method = aws_api_gateway_method.learnusefulwords-addingsword-options.http_method
  resource_id = aws_api_gateway_resource.learnusefulwords-addingsword.id
  rest_api_id = aws_api_gateway_rest_api.learnusefulwords-api.id
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "learnusefulwords-addingsword-options-response" {
  http_method = aws_api_gateway_method.learnusefulwords-addingsword-options.http_method
  resource_id = aws_api_gateway_resource.learnusefulwords-addingsword.id
  rest_api_id = aws_api_gateway_rest_api.learnusefulwords-api.id
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true,
    "method.response.header.Access-Control-Allow-Methods" = true,
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_integration_response" "learnusefulwords-addingsword-options-integration-response" {
  http_method = aws_api_gateway_method.learnusefulwords-addingsword-options.http_method
  resource_id = aws_api_gateway_resource.learnusefulwords-addingsword.id
  rest_api_id = aws_api_gateway_rest_api.learnusefulwords-api.id
  status_code = aws_api_gateway_method_response.learnusefulwords-addingsword-options-response.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = var.cors-allowed-headers-learnusefulwords,
    "method.response.header.Access-Control-Allow-Methods" = "'OPTIONS,POST'",
    "method.response.header.Access-Control-Allow-Origin" = var.cors-allowed-origin-learnusefulwords
  }
  response_templates = {
    "application/json" = ""
  }

  depends_on = [
    aws_api_gateway_integration.learnusefulwords-addingsword-options-integration-request,
    aws_api_gateway_method_response.learnusefulwords-addingsword-options-response
  ]
}

# REST Resource : words
variable "learnusefulwords-api-ressource-words" {
  type    = string
  default = "words"
}

resource "aws_api_gateway_resource" "learnusefulwords-words" {
  rest_api_id = aws_api_gateway_rest_api.learnusefulwords-api.id
  parent_id   = aws_api_gateway_rest_api.learnusefulwords-api.root_resource_id
  path_part   = var.learnusefulwords-api-ressource-words
}

# Method : GET
resource "aws_api_gateway_method" "learnusefulwords-words-get" {
  rest_api_id          = aws_api_gateway_rest_api.learnusefulwords-api.id
  resource_id          = aws_api_gateway_resource.learnusefulwords-words.id
  http_method          = "GET"
  authorization        = var.cognito-authorizer-type
  authorizer_id        = aws_api_gateway_authorizer.learnusefulwords-cognito-authorizer.id
  authorization_scopes = ["email"]
  request_parameters = {
    "${var.api-gateway-request-header-authorization}" = true
  }
}

resource "aws_api_gateway_integration" "learnusefulwords-words-get-integration-request" {
  http_method             = aws_api_gateway_method.learnusefulwords-words-get.http_method
  resource_id             = aws_api_gateway_resource.learnusefulwords-words.id
  rest_api_id             = aws_api_gateway_rest_api.learnusefulwords-api.id
  integration_http_method = aws_api_gateway_method.learnusefulwords-words-get.http_method
  type                    = "HTTP"
  connection_type         = "VPC_LINK"
  connection_id           = aws_api_gateway_vpc_link.learnusefulwords-api-vpc-link.id
  uri                     = "http://${aws_lb.learnusefulwords-nlb.dns_name}/${var.learnusefulwords-api-ressource-words}"
}

resource "aws_api_gateway_method_response" "learnusefulwords-words-get-response" {
  http_method = aws_api_gateway_method.learnusefulwords-words-get.http_method
  resource_id = aws_api_gateway_resource.learnusefulwords-words.id
  rest_api_id = aws_api_gateway_rest_api.learnusefulwords-api.id
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_integration_response" "learnusefulwords-words-get-integration-response" {
  http_method = aws_api_gateway_method.learnusefulwords-words-get.http_method
  resource_id = aws_api_gateway_resource.learnusefulwords-words.id
  rest_api_id = aws_api_gateway_rest_api.learnusefulwords-api.id
  status_code = aws_api_gateway_method_response.learnusefulwords-words-get-response.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = var.cors-allowed-origin-learnusefulwords
  }
  response_templates = {
    "application/json" = ""
  }

  depends_on = [
    aws_api_gateway_integration.learnusefulwords-words-get-integration-request,
    aws_api_gateway_method_response.learnusefulwords-words-get-response
  ]
}

# Method : OPTIONS
resource "aws_api_gateway_method" "learnusefulwords-words-options" {
  rest_api_id   = aws_api_gateway_rest_api.learnusefulwords-api.id
  resource_id   = aws_api_gateway_resource.learnusefulwords-words.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "learnusefulwords-words-options-integration-request" {
  http_method = aws_api_gateway_method.learnusefulwords-words-options.http_method
  resource_id = aws_api_gateway_resource.learnusefulwords-words.id
  rest_api_id = aws_api_gateway_rest_api.learnusefulwords-api.id
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "learnusefulwords-words-options-response" {
  http_method = aws_api_gateway_method.learnusefulwords-words-options.http_method
  resource_id = aws_api_gateway_resource.learnusefulwords-words.id
  rest_api_id = aws_api_gateway_rest_api.learnusefulwords-api.id
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true,
    "method.response.header.Access-Control-Allow-Methods" = true,
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_integration_response" "learnusefulwords-words-options-integration-response" {
  http_method = aws_api_gateway_method.learnusefulwords-words-options.http_method
  resource_id = aws_api_gateway_resource.learnusefulwords-words.id
  rest_api_id = aws_api_gateway_rest_api.learnusefulwords-api.id
  status_code = aws_api_gateway_method_response.learnusefulwords-words-options-response.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = var.cors-allowed-headers-learnusefulwords,
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'",
    "method.response.header.Access-Control-Allow-Origin" = var.cors-allowed-origin-learnusefulwords
  }
  response_templates = {
    "application/json" = ""
  }

  depends_on = [
    aws_api_gateway_integration.learnusefulwords-words-options-integration-request,
    aws_api_gateway_method_response.learnusefulwords-words-options-response
  ]
}

# REST Resource : words/{wordId}
variable "learnusefulwords-api-ressource-words_wordid" {
  type    = string
  default = "{wordId}"
}

resource "aws_api_gateway_resource" "learnusefulwords-words_wordid" {
  rest_api_id = aws_api_gateway_rest_api.learnusefulwords-api.id
  parent_id   = aws_api_gateway_resource.learnusefulwords-words.id
  path_part   = var.learnusefulwords-api-ressource-words_wordid
}

# Method : DELETE
resource "aws_api_gateway_method" "learnusefulwords-words_wordid-delete" {
  rest_api_id          = aws_api_gateway_rest_api.learnusefulwords-api.id
  resource_id          = aws_api_gateway_resource.learnusefulwords-words_wordid.id
  http_method          = "DELETE"
  authorization        = var.cognito-authorizer-type
  authorizer_id        = aws_api_gateway_authorizer.learnusefulwords-cognito-authorizer.id
  authorization_scopes = ["email"]
  request_parameters = {
    "${var.api-gateway-request-header-authorization}" = true,
    "method.request.path.wordId" = true
  }
}

resource "aws_api_gateway_integration" "learnusefulwords-words_wordid-delete-integration-request" {
  http_method             = aws_api_gateway_method.learnusefulwords-words_wordid-delete.http_method
  resource_id             = aws_api_gateway_resource.learnusefulwords-words_wordid.id
  rest_api_id             = aws_api_gateway_rest_api.learnusefulwords-api.id
  integration_http_method = aws_api_gateway_method.learnusefulwords-words_wordid-delete.http_method
  type                    = "HTTP"
  connection_type         = "VPC_LINK"
  connection_id           = aws_api_gateway_vpc_link.learnusefulwords-api-vpc-link.id
  uri                     = "http://${aws_lb.learnusefulwords-nlb.dns_name}/${var.learnusefulwords-api-ressource-words}/${var.learnusefulwords-api-ressource-words_wordid}"

  request_parameters = {
    "integration.request.path.wordId" = "method.request.path.wordId"
  }
}

resource "aws_api_gateway_method_response" "learnusefulwords-words_wordid-delete-response" {
  http_method = aws_api_gateway_method.learnusefulwords-words_wordid-delete.http_method
  resource_id = aws_api_gateway_resource.learnusefulwords-words_wordid.id
  rest_api_id = aws_api_gateway_rest_api.learnusefulwords-api.id
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_integration_response" "learnusefulwords-words_wordid-delete-integration-response" {
  http_method = aws_api_gateway_method.learnusefulwords-words_wordid-delete.http_method
  resource_id = aws_api_gateway_resource.learnusefulwords-words_wordid.id
  rest_api_id = aws_api_gateway_rest_api.learnusefulwords-api.id
  status_code = aws_api_gateway_method_response.learnusefulwords-words_wordid-delete-response.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = var.cors-allowed-origin-learnusefulwords
  }
  response_templates = {
    "application/json" = ""
  }

  depends_on = [
    aws_api_gateway_integration.learnusefulwords-words_wordid-delete-integration-request,
    aws_api_gateway_method_response.learnusefulwords-words_wordid-delete-response
  ]
}

# Method : OPTIONS
resource "aws_api_gateway_method" "learnusefulwords-words_wordid-options" {
  rest_api_id   = aws_api_gateway_rest_api.learnusefulwords-api.id
  resource_id   = aws_api_gateway_resource.learnusefulwords-words_wordid.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "learnusefulwords-words_wordid-options-integration-request" {
  http_method = aws_api_gateway_method.learnusefulwords-words_wordid-options.http_method
  resource_id = aws_api_gateway_resource.learnusefulwords-words_wordid.id
  rest_api_id = aws_api_gateway_rest_api.learnusefulwords-api.id
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "learnusefulwords-words_wordid-options-response" {
  http_method = aws_api_gateway_method.learnusefulwords-words_wordid-options.http_method
  resource_id = aws_api_gateway_resource.learnusefulwords-words_wordid.id
  rest_api_id = aws_api_gateway_rest_api.learnusefulwords-api.id
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true,
    "method.response.header.Access-Control-Allow-Methods" = true,
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_integration_response" "learnusefulwords-words_wordid-options-integration-response" {
  http_method = aws_api_gateway_method.learnusefulwords-words_wordid-options.http_method
  resource_id = aws_api_gateway_resource.learnusefulwords-words_wordid.id
  rest_api_id = aws_api_gateway_rest_api.learnusefulwords-api.id
  status_code = aws_api_gateway_method_response.learnusefulwords-words_wordid-options-response.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = var.cors-allowed-headers-learnusefulwords,
    "method.response.header.Access-Control-Allow-Methods" = "'DELETE,OPTIONS'",
    "method.response.header.Access-Control-Allow-Origin" = var.cors-allowed-origin-learnusefulwords
  }
  response_templates = {
    "application/json" = ""
  }

  depends_on = [
    aws_api_gateway_integration.learnusefulwords-words_wordid-options-integration-request,
    aws_api_gateway_method_response.learnusefulwords-words_wordid-options-response
  ]
}

# API Deployment
resource "aws_api_gateway_deployment" "learnusefulwords-api-deployment" {
  depends_on = [
    aws_api_gateway_integration.learnusefulwords-addingsword-post-integration-request,
    aws_api_gateway_integration.learnusefulwords-addingsword-options-integration-request,
    aws_api_gateway_integration.learnusefulwords-words-get-integration-request,
    aws_api_gateway_integration.learnusefulwords-words-options-integration-request,
    aws_api_gateway_integration.learnusefulwords-words_wordid-delete-integration-request,
    aws_api_gateway_integration.learnusefulwords-words_wordid-options-integration-request
  ]

  rest_api_id = aws_api_gateway_rest_api.learnusefulwords-api.id
  stage_name  = "prod"

  lifecycle {
    create_before_destroy = true
  }
}