variable "region" {
  description = "Región de AWS donde se crea la infraestructura"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Nombre del entorno, usado en la etiqueta Entorno"
  type        = string
  default     = "lab"
}

variable "name_prefix" {
  description = "Prefijo de los nombres de recursos"
  type        = string
  default     = "rrhh"
}

variable "service_subnet_ids" {
  description = "Subnets para ALB, VPC Link y servicios; vacío descubre 2 subnets por defecto en AZ distintas"
  type        = list(string)
  default     = []
}

variable "data_instance_type" {
  description = "Tipo de instancia de la EC2 de datos (MySQL y Redis en Docker)"
  type        = string
  default     = "t3.small"
}

variable "data_key_name" {
  description = "Key pair de la EC2 de datos; vacío no asigna key pair"
  type        = string
  default     = ""
}

variable "instance_profile_name" {
  description = "Instance profile preexistente del lab para la EC2 de datos y Managed Instances"
  type        = string
  default     = "LabInstanceProfile"
}

variable "ssh_allowed_cidr" {
  description = "CIDR con acceso SSH (22) a la EC2 de datos; vacío no abre el puerto"
  type        = string
  default     = ""
}

variable "associate_data_eip" {
  description = "Asociar una Elastic IP a la EC2 de datos"
  type        = bool
  default     = false
}

variable "db_name" {
  description = "Nombre de la base de datos MySQL"
  type        = string
  default     = "rrhh_db"
}

variable "db_user" {
  description = "Usuario de la base de datos MySQL"
  type        = string
  default     = "rrhh"
}

variable "db_password" {
  description = "Contraseña de la base de datos; se guarda en SSM Parameter Store como SecureString"
  type        = string
  sensitive   = true
}

variable "use_ssm_secrets" {
  description = "Entregar la contraseña a las tareas por secrets (SSM); false la pasa por environment"
  type        = bool
  default     = true
}

variable "desired_count" {
  description = "Cantidad de tareas por servicio ECS"
  type        = number
  default     = 1
}

variable "restrict_egress" {
  description = "Limitar el egress de los security groups ecs y data en lugar de abrirlo"
  type        = bool
  default     = false
}

variable "enable_managed_instances" {
  description = "Agregar un capacity provider de ECS Managed Instances al cluster"
  type        = bool
  default     = false
}

variable "image_tag_suffix" {
  description = "Tag de imagen por servicio cuando difiere del nombre corto del servicio"
  type        = map(string)
  default     = {}
}

variable "google_client_id" {
  description = "Client ID de Google para el login federado en Cognito; vacío no crea el proveedor"
  type        = string
  default     = ""
}

variable "google_client_secret" {
  description = "Client secret de Google para el login federado en Cognito"
  type        = string
  default     = ""
  sensitive   = true
}

variable "cognito_domain_prefix" {
  description = "Prefijo del dominio de Cognito; vacío usa name_prefix y el id de la cuenta"
  type        = string
  default     = ""
}

variable "extra_cors_origins" {
  description = "Orígenes CORS adicionales para el HTTP API"
  type        = list(string)
  default     = []
}

variable "amplify_branch" {
  description = "Nombre de la rama de la app de Amplify"
  type        = string
  default     = "staging"
}

variable "cognito_deletion_protection" {
  description = "Protección contra borrado del user pool (ACTIVE o INACTIVE); el pool vivo está en ACTIVE, ponlo en INACTIVE solo para el teardown"
  type        = string
  default     = "ACTIVE"

  validation {
    condition     = contains(["ACTIVE", "INACTIVE"], var.cognito_deletion_protection)
    error_message = "cognito_deletion_protection debe ser ACTIVE o INACTIVE."
  }
}

variable "extra_capacity_providers" {
  description = "Capacity providers ya adjuntos al cluster que Terraform no administra y no debe quitar (por ejemplo el de Managed Instances creado por la consola)"
  type        = list(string)
  default     = []
}

variable "service_names" {
  description = "Nombre del servicio ECS por servicio cuando difiere de rrhh-<servicio> (el nombre no se puede cambiar, así que para adoptar los vivos hay que repetirlo)"
  type        = map(string)
  default     = {}
}

variable "data_subnet_id" {
  description = "Subnet de la EC2 de datos; vacío usa la primera de las 2 subnets elegidas"
  type        = string
  default     = ""
}

variable "wait_for_data" {
  description = "Esperar (con AWS CLI y bash en la máquina que aplica) a que MySQL y Redis estén listos antes de crear los servicios ECS; false al adoptar una EC2 de datos existente, que nunca publica la señal"
  type        = bool
  default     = true
}
