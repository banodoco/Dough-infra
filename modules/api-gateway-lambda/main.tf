# defining root and endpoints ----------------------
resource "aws_api_gateway_rest_api" "api" {
  name = var.api_name
}

resource "aws_api_gateway_resource" "resource" {
  for_each    = var.endpoints
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = each.key
}

#  method request -----------------
resource "aws_api_gateway_method" "method" {
  for_each         = var.endpoints
  rest_api_id      = aws_api_gateway_rest_api.api.id
  resource_id      = aws_api_gateway_resource.resource[each.key].id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

# integration request ----------------------
# with using AWS_PROXY you don't need to set request template in the integration_request
# this format will be passed to the lambda - https://docs.aws.amazon.com/apigateway/latest/developerguide/set-up-lambda-proxy-integrations.html#api-gateway-simple-proxy-for-lambda-input-format
resource "aws_api_gateway_integration" "integration" {
  for_each                = var.endpoints
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.resource[each.key].id
  http_method             = aws_api_gateway_method.method[each.key].http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = each.value.lambda_invoke_arn
}


# method response ----------------------
resource "aws_api_gateway_method_response" "proxy" {
  for_each    = var.endpoints
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.resource[each.key].id
  http_method = aws_api_gateway_method.method[each.key].http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true,
    "method.response.header.Access-Control-Allow-Methods" = true,
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

# NOTE: you don't need integration_response as aws maps it automatically (provided we are returning the json with statuscode, headers)
# in the AWS_PROXY mode
# integration response ----------------------
# resource "aws_api_gateway_integration_response" "proxy" {
#   for_each    = var.endpoints
#   rest_api_id = aws_api_gateway_rest_api.api.id
#   resource_id = aws_api_gateway_resource.resource[each.key].id
#   http_method = aws_api_gateway_method.method[each.key].http_method
#   status_code = aws_api_gateway_method_response.proxy[each.key].status_code

#   response_parameters = {
#     "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'",
#     "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS,POST,PUT'",
#     "method.response.header.Access-Control-Allow-Origin"  = "'*'"
#   }
# }

# creating deployment and setting auth/usage limits ----------------------------------
resource "aws_api_gateway_deployment" "prod_deployment" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  depends_on  = [aws_api_gateway_integration.integration]
  stage_name = "prod"
}


resource "aws_api_gateway_usage_plan" "usage_plan" {
  name = "usage-plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.api.id
    stage  = aws_api_gateway_deployment.prod_deployment.stage_name
  }

  throttle_settings {
    burst_limit = var.burst_limit
    rate_limit  = var.rate_limit
  }
}

resource "aws_api_gateway_usage_plan_key" "usage_plan_key" {
  key_id        = var.api_key.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.usage_plan.id
}

# logging -------------------------
# NOTE: check the terraform docs for this - this method requires two "terraform applies" to work (if api_gateway_stage is not used)
resource "aws_api_gateway_method_settings" "logging_settings" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  stage_name  = aws_api_gateway_deployment.prod_deployment.stage_name
  method_path = "*/*" # Enable logging for all methods and paths

  settings {
    logging_level   = "INFO"
    metrics_enabled = true
  }
}

# updating permissions for lambda to be invoked by api gateway ---------------------
resource "aws_lambda_permission" "lambda_permission" {
  for_each      = var.endpoints
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = each.value.lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/${each.key}"
}

resource "aws_lambda_alias" "dummy_alias" {
  for_each         = var.endpoints
  name             = "api_endpoint"
  description      = "dummy desc"
  function_name    = each.value.lambda_function_name
  function_version = "$LATEST"
}
