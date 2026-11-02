output "deployment_id" {
  description = "Hex identifier of the ChronoPay deployment"
  # [FAULT 1D] random_id does not have a '.value' attribute (should be '.hex')
  value       = random_id.deployment_id.hex
}

output "gateway_url" {
  description = "ChronoPay Edge Gateway Health Endpoint"
  value       = "http://127.0.0.1:${var.gateway_listen_port}/healthz"
}
