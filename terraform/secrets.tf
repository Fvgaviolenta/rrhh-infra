# La contraseña de MySQL vive solo aquí: ni en el user-data ni en el environment de las tareas.
resource "aws_ssm_parameter" "db_password" {
  name        = "/${local.name}/db/password"
  description = "Contraseña del usuario ${var.db_user} de MySQL"
  type        = "SecureString"
  value       = var.db_password
}
