output "resource_group_name" {
  description = "The name of the resource group"
  value       = azurerm_resource_group.rg.name
}

output "cluster_name" {
  description = "The name of the managed AKS cluster"
  value       = azurerm_kubernetes_cluster.aks.name
}

output "connect_command" {
  description = "Command to configure kubectl to connect to the new AKS cluster"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.rg.name} --name ${azurerm_kubernetes_cluster.aks.name} --overwrite-existing"
}
