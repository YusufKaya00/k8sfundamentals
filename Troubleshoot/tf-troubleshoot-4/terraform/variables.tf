variable "environment" {
  description = "Deployment environment name"
  type        = string
  default     = "production"
}

# [FAULT 1A] Type is declared as number, but default is a string ("two")
variable "worker_threads" {
  description = "Number of gateway worker threads"
  type        = number
  default     = 2
}

variable "gateway_listen_port" {
  description = "External HTTP port for ChronoPay Edge Proxy"
  type        = number
  default     = 18080
}

variable "backend_internal_port" {
  description = "Internal TCP port where ChronoPay payment engine listens"
  type        = number
  default     = 19090
}
